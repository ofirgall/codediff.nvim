-- Review groups config: JSONC parsing, validation and compilation.
-- Port of github-fast-pr src/core/{jsonc,config}.ts.
local regex = require("codediff.review.regex")

local M = {}

M.GENERATED_GROUP = "Generated"
M.CONFIG_PATH = ".github/pr-groups.json"
M.CONFIG_PATHS = { ".github/pr-groups.json", ".github/pr-groups.jsonc" }
M.UNGROUPED_VIEW_PRIORITY = -1

function M.default_match_priority(auto_viewed)
  return auto_viewed and 1 or 0
end

function M.default_view_priority(auto_viewed)
  return auto_viewed and -2 or 0
end

--- Blank out // and /* */ comments and trailing commas outside strings.
---@param text string
---@return string
function M.strip_jsonc(text)
  local out = {}
  for k = 1, #text do
    out[k] = text:sub(k, k)
  end
  local last_comma = nil
  local function blank(from, to) -- inclusive from, exclusive to (1-based)
    for k = from, to - 1 do
      if out[k] ~= "\n" and out[k] ~= "\r" then
        out[k] = " "
      end
    end
  end
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    local c2 = text:sub(i + 1, i + 1)
    if c == '"' then
      last_comma = nil
      i = i + 1
      while i <= n and text:sub(i, i) ~= '"' do
        if text:sub(i, i) == "\\" then
          i = i + 1
        end
        i = i + 1
      end
      i = i + 1
    elseif c == "/" and c2 == "/" then
      local e = text:find("\n", i, true)
      local to = e or (n + 1)
      blank(i, to)
      i = to
    elseif c == "/" and c2 == "*" then
      local _, e = text:find("*/", i + 2, true)
      local to = e and (e + 1) or (n + 1)
      blank(i, to)
      i = to
    else
      if (c == "}" or c == "]") and last_comma then
        out[last_comma] = " "
      end
      if not c:match("%s") then
        last_comma = (c == ",") and i or nil
      end
      i = i + 1
    end
  end
  return table.concat(out)
end

local empty_dict_mt = getmetatable(vim.empty_dict())

local function is_object(v)
  if type(v) ~= "table" then
    return false
  end
  if next(v) == nil then
    return true
  end
  return not vim.islist(v)
end

local function is_array(v)
  if type(v) ~= "table" then
    return false
  end
  if next(v) == nil then
    return getmetatable(v) ~= empty_dict_mt
  end
  return vim.islist(v)
end

local function is_number(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Returns a table of set priority fields, or nil, err.
local function read_priorities(o, keys, where)
  local out = {}
  for _, k in ipairs(keys) do
    local v = o[k]
    if v ~= nil then
      if not is_number(v) then
        return nil, string.format('%s: "%s" must be a number', where, k)
      end
      out[k] = v
    end
  end
  return out
end

-- Returns priorities table | nil (absent/empty) , err
local function read_top_priorities(raw, key, keys)
  local v = raw[key]
  if v == nil then
    return nil
  end
  if not is_object(v) then
    return nil, string.format('"%s" must be an object', key)
  end
  local p, err = read_priorities(v, keys, '"' .. key .. '"')
  if not p then
    return nil, err
  end
  if next(p) then
    return p
  end
  return nil
end

---@class ReviewGroupConfig
---@field name string
---@field paths string[]
---@field autoViewed boolean
---@field matchPriority number|nil
---@field viewPriority number|nil

---@class ReviewConfig
---@field groups ReviewGroupConfig[]
---@field generated {matchPriority: number|nil, viewPriority: number|nil}|nil
---@field ungrouped {viewPriority: number|nil}|nil

--- Format a pattern error the way github-fast-pr does.
function M.pattern_error(name, pattern, err)
  return string.format('Group "%s": invalid regex "%s": %s', name, pattern, err)
end

--- Check every path pattern with the Vim regex translator. Returns nil or the first error.
---@param config ReviewConfig
---@return string|nil
function M.check_patterns(config)
  for _, g in ipairs(config.groups) do
    for _, p in ipairs(g.paths) do
      local m, err = regex.compile(p)
      if not m then
        return M.pattern_error(g.name, p, err)
      end
    end
  end
  return nil
end

--- Parse and validate JSONC text or an already-decoded Lua table.
--- opts.check_patterns (default true): validate patterns with the Vim regex translator.
--- Pass false when patterns are matched by node instead (it reports its own errors).
---@param input string|table
---@param opts {check_patterns: boolean|nil}|nil
---@return {ok: true, config: ReviewConfig}|{ok: false, error: string}
function M.parse(input, opts)
  local check_patterns = not (opts and opts.check_patterns == false)
  local raw = input
  if type(input) == "string" then
    local ok, decoded = pcall(vim.json.decode, M.strip_jsonc(input), { luanil = { object = true, array = true } })
    if not ok then
      return { ok = false, error = "Invalid JSON: " .. tostring(decoded) }
    end
    raw = decoded
  end
  if not is_object(raw) then
    return { ok = false, error = 'Config must be a JSON object with a "groups" array' }
  end
  local raw_groups = raw.groups
  if not is_array(raw_groups) then
    return { ok = false, error = 'Config is missing the "groups" array' }
  end
  local groups = {}
  for i, g in ipairs(raw_groups) do
    if not is_object(g) or (next(g) ~= nil and vim.islist(g)) then
      return { ok = false, error = string.format("Group #%d must be an object", i) }
    end
    if type(g.name) ~= "string" or vim.trim(g.name) == "" then
      return { ok = false, error = string.format('Group #%d needs a non-empty string "name"', i) }
    end
    local name = g.name
    if not is_array(g.paths) or #g.paths == 0 then
      return { ok = false, error = string.format('Group "%s" needs a non-empty "paths" array', name) }
    end
    for _, p in ipairs(g.paths) do
      if type(p) ~= "string" then
        return { ok = false, error = string.format('Group "%s": every entry in "paths" must be a string', name) }
      end
    end
    if g.autoViewed ~= nil and type(g.autoViewed) ~= "boolean" then
      return { ok = false, error = string.format('Group "%s": "autoViewed" must be a boolean', name) }
    end
    if check_patterns then
      for _, p in ipairs(g.paths) do
        local m, err = regex.compile(p)
        if not m then
          return { ok = false, error = M.pattern_error(name, p, err) }
        end
      end
    end
    local prio, perr = read_priorities(g, { "matchPriority", "viewPriority" }, string.format('Group "%s"', name))
    if not prio then
      return { ok = false, error = perr }
    end
    groups[#groups + 1] = {
      name = name,
      paths = vim.list_extend({}, g.paths),
      autoViewed = g.autoViewed == true,
      matchPriority = prio.matchPriority,
      viewPriority = prio.viewPriority,
    }
  end
  local generated, gerr = read_top_priorities(raw, "generated", { "matchPriority", "viewPriority" })
  if gerr then
    return { ok = false, error = gerr }
  end
  local ungrouped, uerr = read_top_priorities(raw, "ungrouped", { "viewPriority" })
  if uerr then
    return { ok = false, error = uerr }
  end
  return { ok = true, config = { groups = groups, generated = generated, ungrouped = ungrouped } }
end

---@class ReviewCompiledGroup
---@field name string
---@field auto_viewed boolean
---@field index integer 1-based config order (Generated last)
---@field match fun(path: string): boolean
---@field match_priority number
---@field view_priority number

---@class ReviewCompiled
---@field groups ReviewCompiledGroup[]
---@field ungrouped_view_priority number

--- Compile a parsed config (may be nil: no config) into matchers.
--- When `generated_test` is given, a Generated group is appended.
---@param config ReviewConfig|nil
---@param generated_test (fun(path: string): boolean)|nil
---@param matches table<string, integer[]>|nil precomputed by node: path -> matching group indices
---@return ReviewCompiled|nil, string|nil
function M.compile(config, generated_test, matches)
  config = config or { groups = {} }
  local groups = {}
  for idx, g in ipairs(config.groups) do
    local match
    if matches then
      -- Precomputed by node (native JS regexes): matches[path] lists group indices.
      match = function(path)
        return vim.tbl_contains(matches[path] or {}, idx)
      end
    else
      local matchers = {}
      for _, p in ipairs(g.paths) do
        local m, err = regex.compile(p)
        if not m then
          return nil, M.pattern_error(g.name, p, err)
        end
        matchers[#matchers + 1] = m
      end
      match = function(path)
        for _, m in ipairs(matchers) do
          if m(path) then
            return true
          end
        end
        return false
      end
    end
    local auto = g.autoViewed == true
    groups[#groups + 1] = {
      name = g.name,
      auto_viewed = auto,
      index = idx,
      match = match,
      match_priority = g.matchPriority or M.default_match_priority(auto),
      view_priority = g.viewPriority or M.default_view_priority(auto),
    }
  end
  if generated_test then
    local gp = config.generated or {}
    groups[#groups + 1] = {
      name = M.GENERATED_GROUP,
      auto_viewed = true,
      index = #groups + 1,
      match = generated_test,
      match_priority = gp.matchPriority or M.default_match_priority(true),
      view_priority = gp.viewPriority or M.default_view_priority(true),
    }
  end
  local ug = config.ungrouped or {}
  return { groups = groups, ungrouped_view_priority = ug.viewPriority or M.UNGROUPED_VIEW_PRIORITY }
end

return M
