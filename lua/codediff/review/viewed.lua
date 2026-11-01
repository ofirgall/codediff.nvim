-- Persistent "viewed" state for revision-mode reviews.
--
-- Identity of a viewed file is (path, old blob sha, new blob sha). State is
-- stored per repo in one JSON file:
--   { version = 1, entries = { [key] = { v = true|false, t = epoch_seconds } } }
-- where key = path .. "\0" .. old .. "\0" .. new. vim.json round-trips the NUL
-- byte in object keys (encoded as \u0000), so NUL is used as the separator.
local M = {}

local uv = vim.uv or vim.loop

local DEBOUNCE_MS = 200
local PRUNE_SECONDS = 90 * 24 * 60 * 60

-- Base directory for store files (overridable for tests).
M._state_dir = nil

local stores = {} -- git_root -> store
local augroup_set = false

local function base_dir()
  return M._state_dir or (vim.fn.stdpath("state") .. "/codediff/viewed")
end

local Store = {}
Store.__index = Store

local function make_key(path, old, new)
  return path .. "\0" .. (old or "") .. "\0" .. (new or "")
end

-- Returns entries table, or nil + err. A missing file yields an empty table.
local function read_file(file)
  local f = io.open(file, "rb")
  if not f then
    if uv.fs_stat(file) then
      return nil, "cannot open " .. file
    end
    return {}
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or type(data.entries) ~= "table" then
    return nil, "invalid viewed state in " .. file
  end
  local entries = {}
  for k, e in pairs(data.entries) do
    if type(e) == "table" and type(e.v) == "boolean" and type(e.t) == "number" then
      entries[k] = { v = e.v, t = e.t }
    end
  end
  return entries
end

function Store:_disable(err)
  self.disabled = true
  if not self.warned then
    self.warned = true
    vim.notify("codediff: viewed state unavailable, using in-memory state only (" .. tostring(err) .. ")", vim.log.levels.WARN)
  end
end

function Store:get(path, old, new)
  local e = self.entries[make_key(path, old, new)]
  if e then
    return e.v
  end
  return nil
end

function Store:_put(path, old, new, viewed, t)
  local key = make_key(path, old, new)
  self.entries[key] = { v = viewed and true or false, t = t }
  self.dirty[key] = true
end

function Store:_schedule()
  if self.disabled then
    return
  end
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  local timer = uv.new_timer()
  self.timer = timer
  timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if self.timer == timer then
        self.timer = nil
        timer:stop()
        timer:close()
        self:flush()
      end
    end)
  )
end

function Store:set(path, old, new, viewed)
  self:_put(path, old, new, viewed, os.time())
  self:_schedule()
end

-- list: array of { path = , old = , new = , viewed = }
function Store:set_many(list)
  local t = os.time()
  for _, it in ipairs(list) do
    self:_put(it.path, it.old, it.new, it.viewed, t)
  end
  self:_schedule()
end

-- Synchronous write: re-read disk, merge, prune, atomic replace.
function Store:flush()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  if self.disabled or next(self.dirty) == nil then
    return
  end

  local disk, err = read_file(self.file)
  if not disk then
    self:_disable(err)
    return
  end

  -- Start from disk; local dirty entries win unless disk has a strictly newer one.
  for key in pairs(self.dirty) do
    local mine, theirs = self.entries[key], disk[key]
    if not theirs or mine.t >= theirs.t then
      disk[key] = mine
    end
  end
  local cutoff = os.time() - PRUNE_SECONDS
  for key, e in pairs(disk) do
    if e.t < cutoff then
      disk[key] = nil
    end
  end

  local dir = vim.fn.fnamemodify(self.file, ":h")
  vim.fn.mkdir(dir, "p")
  local tmp = string.format("%s.%d.%d.tmp", self.file, uv.os_getpid(), math.floor(uv.hrtime() % 1e9))
  local f, ferr = io.open(tmp, "wb")
  if not f then
    self:_disable(ferr)
    return
  end
  local ok, encoded = pcall(vim.json.encode, { version = 1, entries = disk })
  if not ok then
    f:close()
    os.remove(tmp)
    self:_disable(encoded)
    return
  end
  f:write(encoded)
  f:close()
  local rok, rerr = uv.fs_rename(tmp, self.file)
  if not rok then
    os.remove(tmp)
    self:_disable(rerr)
    return
  end

  self.entries = disk
  self.dirty = {}
end

local function ensure_autocmd()
  if augroup_set then
    return
  end
  augroup_set = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("CodeDiffReviewViewed", { clear = true }),
    callback = function()
      for _, s in pairs(stores) do
        pcall(s.flush, s)
      end
    end,
  })
end

--- Open (or return the cached) store for a git root.
---@param git_root string
---@return table store
function M.open(git_root)
  if stores[git_root] then
    return stores[git_root]
  end
  ensure_autocmd()
  local store = setmetatable({
    file = base_dir() .. "/" .. vim.fn.sha256(git_root) .. ".json",
    entries = {},
    dirty = {},
    disabled = false,
    warned = false,
  }, Store)
  local entries, err = read_file(store.file)
  if entries then
    store.entries = entries
  else
    store:_disable(err)
  end
  stores[git_root] = store
  return store
end

--- Drop the session cache (tests). Pending writes are discarded.
function M._reset()
  for _, s in pairs(stores) do
    if s.timer then
      s.timer:stop()
      s.timer:close()
      s.timer = nil
    end
  end
  stores = {}
end

return M
