-- Review context: everything the explorer needs to group files and track Viewed state.
-- Loaded asynchronously once per explorer open / refresh, so tree building stays synchronous.
local M = {}

local review_config = require("codediff.review.config")
local viewed = require("codediff.review.viewed")
local codediff_config = require("codediff.config")
local git = require("codediff.core.git") -- required up front: start() can run in a libuv callback
local js_match = require("codediff.review.js_match")

---@class ReviewContext
---@field git_root string
---@field base_revision string
---@field target_revision string|nil
---@field compiled ReviewCompiled compiled groups (may hold no groups)
---@field has_rules boolean true when at least one group (config or Generated) exists
---@field generated table<string, boolean> paths marked linguist-generated
---@field blobs table<string, {old: string, new: string}>
---@field store table viewed store
---@field config_error string|nil parse/compile error of the config (config was ignored)
---@field is_viewed fun(path: string, group: {auto_viewed: boolean}|nil): boolean

-- Parsed repo config cache, per (git_root, base revision), for the session.
-- Values: { config = table|nil, error = string|nil }
local config_cache = {}

local function cache_key(git_root, base)
  return git_root .. "\0" .. base
end

--- Drop cached configs (tests).
function M._reset()
  config_cache = {}
end

local function pr_review_opts()
  return (codediff_config.options.explorer or {}).pr_review or {}
end

--- Debug log (explorer.pr_review.debug). Safe to call from libuv callbacks.
--- Uses print so it always lands in :messages (vim.notify may be routed to a UI plugin).
local function log(fmt, ...)
  if not pr_review_opts().debug then
    return
  end
  local msg = "[codediff:review] " .. string.format(fmt, ...)
  vim.schedule(function()
    print(msg)
  end)
end
M._log = log

--- Whether review groups apply to these explorer params.
---@param params table
---@return boolean
function M.applies(params)
  if pr_review_opts().enabled == false then
    log("skipped: explorer.pr_review.enabled = false")
    return false
  end
  if params.git_root == nil then
    log("skipped: not a git comparison (directory mode)")
    return false
  end
  if params.base_revision == nil then
    log("skipped: status mode (no base revision); use :CodeDiff <rev> or <base>...<target>")
    return false
  end
  return true
end

-- Resolve the parsed config: setup override, else repo file at the base revision (cached).
local function load_config(params, cb)
  local override = pr_review_opts().groups
  if override ~= nil then
    local res = review_config.parse(override, { check_patterns = false })
    if res.ok then
      log("config: using explorer.pr_review.groups from setup (%d groups)", #res.config.groups)
      cb({ config = res.config })
    else
      log("config: explorer.pr_review.groups from setup is invalid: %s", res.error)
      cb({ error = res.error })
    end
    return
  end

  local key = cache_key(params.git_root, params.base_revision)
  if config_cache[key] then
    local c = config_cache[key]
    log("config: cached for base %s (%s)", params.base_revision,
      c.config and (#c.config.groups .. " groups") or c.error and ("error: " .. c.error) or "no config")
    cb(c)
    return
  end
  log("config: reading from base revision %s in %s", params.base_revision, params.git_root)
  git.get_review_config(params.base_revision, params.git_root, function(err, result, attempts)
    for _, a in ipairs(attempts or {}) do
      log("config: git show %s:%s -> %s", params.base_revision, a.path, a.err and vim.trim(a.err) or "found")
    end
    local entry
    if err or not result then
      -- Missing config is not an error; git failures degrade to "no config"
      if err then
        log("config: git failed, continuing without config: %s", vim.trim(err))
      else
        log("config: no pr-groups.json/.jsonc at base revision %s", params.base_revision)
      end
      entry = {}
    else
      local res = review_config.parse(result.text, { check_patterns = false })
      if res.ok then
        log("config: %s parsed, %d groups", result.path, #res.config.groups)
        entry = { config = res.config }
      else
        log("config: %s invalid: %s", result.path, res.error)
        entry = { error = string.format("%s: %s", result.path, res.error) }
      end
    end
    config_cache[key] = entry
    cb(entry)
  end)
end

---@class ReviewPending
---@field finish fun(self: ReviewPending, files: table[], cb: fun(err: string|nil, ctx: ReviewContext|nil))

--- Start the file-independent loads (config, blobs, store) so they run alongside the status fetch.
--- Call `pending:finish(files, cb)` once the changed files are known.
--- params: { git_root, base_revision, target_revision, prev_ctx? }
---   prev_ctx: previous context of the same explorer; an unchanged config error is not reported twice.
---@param params table
---@return ReviewPending|nil nil when review groups do not apply
function M.start(params)
  if not M.applies(params) then
    return nil
  end

  local state = { config = nil, blobs = nil }
  local waiter = nil -- set by finish
  local function try_complete()
    if waiter and state.config and state.blobs then
      local w = waiter
      waiter = nil
      w()
    end
  end

  load_config(params, function(entry)
    state.config = entry
    try_complete()
  end)
  log("start: base=%s target=%s", params.base_revision, tostring(params.target_revision))
  git.get_diff_blobs(params.git_root, params.base_revision, params.target_revision, function(err, blobs)
    if err then
      log("blobs: git diff --raw failed (viewed state unavailable): %s", vim.trim(err))
    end
    state.blobs = (not err and blobs) or {}
    try_complete()
  end)

  local pending = {}
  function pending:finish(files, cb)
    local paths = {}
    for _, f in ipairs(files or {}) do
      paths[#paths + 1] = type(f) == "string" and f or f.path
    end
    local generated
    local function build()
      vim.schedule(function()
        M._resolve_matching(state.config, paths, function(resolved)
          M._build(params, { config = resolved, blobs = state.blobs }, generated or {}, cb)
        end)
      end)
    end
    local function when_generated(g)
      generated = g
      -- Wait for config + blobs as well (usually done by now)
      waiter = build
      try_complete()
    end
    git.check_attr_generated(params.git_root, paths, params.base_revision, function(err, set)
      if err then
        log("generated: git check-attr failed: %s", vim.trim(err))
      end
      when_generated((not err and set) or {})
    end)
  end
  return pending
end

--- Match the config's patterns with the configured engine (explorer.pr_review.regex_engine).
--- "auto": node when found (native JS regexes), else the Vim regex translator.
--- "node": node only (no node -> config ignored with an error). "vim": translator only.
--- cb(entry) on the main loop; entry: { config?, error?, matches?, engine? }.
function M._resolve_matching(entry, paths, cb)
  if not entry.config then
    cb(entry)
    return
  end
  local engine = pr_review_opts().regex_engine or "auto"

  local function use_vim()
    local err = review_config.check_patterns(entry.config)
    if err then
      log("regex: vim translator rejected config: %s", err)
      cb({ error = err, engine = "vim" })
    else
      log("regex: using vim translator")
      cb({ config = entry.config, engine = "vim" })
    end
  end

  if engine == "vim" then
    use_vim()
    return
  end
  local node = js_match.node()
  if not node then
    if engine == "node" then
      log("regex: regex_engine = node but node is not on PATH")
      cb({ error = 'regex_engine = "node" but node was not found on PATH', engine = "node" })
    else
      log("regex: node not found on PATH, falling back to vim translator")
      use_vim()
    end
    return
  end

  local groups = {}
  for i, g in ipairs(entry.config.groups) do
    groups[i] = g.paths
  end
  js_match.run(node, groups, paths, function(err, result)
    if err then
      if engine == "node" then
        log("regex: %s", err)
        cb({ error = err, engine = "node" })
      else
        log("regex: %s; falling back to vim translator", err)
        use_vim()
      end
      return
    end
    local first = result.errors[1]
    if first then
      local g = entry.config.groups[first.group]
      local msg = review_config.pattern_error(g and g.name or ("#" .. first.group), first.pattern, first.message)
      log("regex: node rejected config: %s", msg)
      cb({ error = msg, engine = "node" })
      return
    end
    log("regex: using node (%s), %d of %d files matched a group", node, vim.tbl_count(result.matches), #paths)
    cb({ config = entry.config, matches = result.matches, engine = "node" })
  end)
end

--- Assemble the context from loaded parts.
function M._build(params, state, generated, cb)
  local store = viewed.open(params.git_root) -- main loop only (uses vimscript functions)
  local entry = state.config
  local error_msg = entry.error

  local generated_test = nil
  if next(generated) ~= nil then
    generated_test = function(path)
      return generated[path] == true
    end
  end

  local compiled, cerr = review_config.compile(entry.config, generated_test, entry.matches)
  if not compiled then
    error_msg = cerr
    compiled = review_config.compile(nil, generated_test)
  end

  if error_msg and not (params.prev_ctx and params.prev_ctx.config_error == error_msg) then
    -- nvim_echo with history: shown as an error and kept in :messages
    -- (vim.notify may be routed to a UI plugin that bypasses :messages).
    vim.api.nvim_echo({ { "codediff: ignoring review groups config: " .. error_msg, "ErrorMsg" } }, true, {})
  end

  local blobs = state.blobs
  if pr_review_opts().debug then
    local names = {}
    for _, g in ipairs(compiled.groups) do
      names[#names + 1] = g.name .. (g.auto_viewed and "*" or "")
    end
    log("built: %d groups [%s] (* = auto-viewed), %d generated files, %d file blobs%s",
      #compiled.groups, table.concat(names, ", "), vim.tbl_count(generated), vim.tbl_count(blobs),
      #compiled.groups == 0 and " -> no rules, showing plain Changes group" or "")
  end
  local ctx = {
    git_root = params.git_root,
    base_revision = params.base_revision,
    target_revision = params.target_revision,
    compiled = compiled,
    has_rules = #compiled.groups > 0,
    generated = generated,
    blobs = blobs,
    store = store,
    config_error = error_msg,
  }

  --- Effective viewed: store entry if present, else the auto-viewed default.
  function ctx.is_viewed(path, group)
    local blob = blobs[path]
    if blob then
      local v = store:get(path, blob.old, blob.new)
      if v ~= nil then
        return v
      end
    end
    return (group and group.auto_viewed == true and pr_review_opts().auto_mark_viewed ~= false) or false
  end

  cb(nil, ctx)
end

--- Load the context in one go.
--- params: { git_root, base_revision, target_revision, files, prev_ctx? }
--- cb(err, ctx): ctx is nil in status/dir mode or when pr_review is disabled. Runs on the main loop.
---@param params table
---@param cb fun(err: string|nil, ctx: ReviewContext|nil)
function M.load(params, cb)
  local pending = M.start(params)
  if not pending then
    cb(nil, nil)
    return
  end
  pending:finish(params.files, cb)
end

return M
