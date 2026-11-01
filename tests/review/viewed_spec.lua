local viewed = require("codediff.review.viewed")

describe("review.viewed", function()
  local dir, orig_notify, notes

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    viewed._state_dir = dir
    viewed._reset()
    notes = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = orig_notify
    viewed._reset()
    viewed._state_dir = nil
    vim.fn.delete(dir, "rf")
  end)

  local function file_for(root)
    return dir .. "/" .. vim.fn.sha256(root) .. ".json"
  end

  it("returns nil for unknown entries and no warning for a missing file", function()
    local s = viewed.open("/repo")
    assert.is_nil(s:get("a.lua", "o", "n"))
    assert.equals(0, #notes)
  end)

  it("round trips across a fresh open, including NUL keys and paths", function()
    local s = viewed.open("/repo")
    s:set("dir/a b.lua", "old1", "new1", true)
    s:flush()
    viewed._reset()
    local s2 = viewed.open("/repo")
    assert.is_true(s2:get("dir/a b.lua", "old1", "new1"))
    assert.is_nil(s2:get("dir/a b.lua", "old1", "other"))
    assert.is_nil(s2:get("x", "old1", "new1"))
  end)

  it("caches the store per git root and isolates roots", function()
    assert.equals(viewed.open("/r1"), viewed.open("/r1"))
    viewed.open("/r1"):set("a", "o", "n", true)
    assert.is_nil(viewed.open("/r2"):get("a", "o", "n"))
  end)

  it("stores explicit v=false", function()
    local s = viewed.open("/repo")
    s:set("a", "o", "n", true)
    s:set("a", "o", "n", false)
    s:flush()
    viewed._reset()
    assert.is_false(viewed.open("/repo"):get("a", "o", "n"))
  end)

  it("set_many writes all entries", function()
    local s = viewed.open("/repo")
    s:set_many({
      { path = "a", old = "o", new = "n", viewed = true },
      { path = "b", old = "o", new = "n", viewed = false },
    })
    s:flush()
    viewed._reset()
    local s2 = viewed.open("/repo")
    assert.is_true(s2:get("a", "o", "n"))
    assert.is_false(s2:get("b", "o", "n"))
  end)

  it("debounced write lands on disk", function()
    local s = viewed.open("/repo")
    s:set("a", "o", "n", true)
    assert.equals(0, vim.fn.filereadable(file_for("/repo")))
    vim.wait(2000, function()
      return vim.fn.filereadable(file_for("/repo")) == 1
    end)
    assert.equals(1, vim.fn.filereadable(file_for("/repo")))
  end)

  it("prunes entries older than 90 days on write", function()
    local old_t = os.time() - 91 * 86400
    local key = "old.lua\0o\0n"
    local f = io.open(file_for("/repo"), "wb")
    f:write(vim.json.encode({ version = 1, entries = { [key] = { v = true, t = old_t } } }))
    f:close()
    local s = viewed.open("/repo")
    assert.is_true(s:get("old.lua", "o", "n"))
    s:set("new.lua", "o", "n", true)
    s:flush()
    viewed._reset()
    local s2 = viewed.open("/repo")
    assert.is_nil(s2:get("old.lua", "o", "n"))
    assert.is_true(s2:get("new.lua", "o", "n"))
  end)

  it("merges entries written by a concurrent writer between open and flush", function()
    local s = viewed.open("/repo")
    -- another instance writes to the same file
    local key = "other.lua\0o\0n"
    local f = io.open(file_for("/repo"), "wb")
    f:write(vim.json.encode({ version = 1, entries = { [key] = { v = true, t = os.time() } } }))
    f:close()
    s:set("mine.lua", "o", "n", true)
    s:flush()
    viewed._reset()
    local s2 = viewed.open("/repo")
    assert.is_true(s2:get("mine.lua", "o", "n"))
    assert.is_true(s2:get("other.lua", "o", "n"))
  end)

  it("keeps a strictly newer disk entry over an older local one", function()
    local s = viewed.open("/repo")
    s:set("a", "o", "n", true)
    local key = "a\0o\0n"
    local f = io.open(file_for("/repo"), "wb")
    f:write(vim.json.encode({ version = 1, entries = { [key] = { v = false, t = os.time() + 100 } } }))
    f:close()
    s:flush()
    viewed._reset()
    assert.is_false(viewed.open("/repo"):get("a", "o", "n"))
  end)

  it("corrupt file: empty store, single warning, file untouched", function()
    local f = io.open(file_for("/repo"), "wb")
    f:write("{not json")
    f:close()
    local s = viewed.open("/repo")
    assert.is_nil(s:get("a", "o", "n"))
    s:set("a", "o", "n", true)
    s:flush()
    s:set("b", "o", "n", true)
    s:flush()
    assert.is_true(s:get("a", "o", "n"))
    assert.equals(1, #notes)
    assert.equals(vim.log.levels.WARN, notes[1].level)
    local r = io.open(file_for("/repo"), "rb")
    assert.equals("{not json", r:read("*a"))
    r:close()
    -- re-opening via cache does not warn again
    viewed.open("/repo")
    assert.equals(1, #notes)
  end)
end)
