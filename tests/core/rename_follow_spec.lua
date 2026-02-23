-- Test: resolve_path_at_revision follows renames and copies
-- Validates that git.resolve_path_at_revision correctly detects old file paths

local git = require("codediff.core.git")

-- Helper: create a temp git repo (uses table-form vim.fn.system for Windows compat)
local function create_rename_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function run(...)
    return vim.fn.system(vim.list_extend({ "git", "-C", dir }, { ... }))
  end
  run("init")
  run("config", "user.email", "test@test.com")
  run("config", "user.name", "test")
  return dir, run
end

describe("resolve_path_at_revision", function()
  it("Returns old path for a renamed file", function()
    local dir, run = create_rename_repo()

    vim.fn.writefile({ "content" }, dir .. "/old.lua")
    run("add", ".")
    run("commit", "-m", "initial")
    local initial = vim.trim(run("rev-parse", "HEAD"))

    run("mv", "old.lua", "new.lua")
    run("commit", "-m", "rename")

    local done = false
    local resolved = nil

    git.resolve_path_at_revision(initial, dir, "new.lua", function(err, path)
      assert.is_nil(err)
      resolved = path
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done, "Callback should complete")
    assert.equal("old.lua", resolved, "Should resolve to old path before rename")

    vim.fn.delete(dir, "rf")
  end)

  it("Returns same path for a file without renames", function()
    local dir, run = create_rename_repo()

    vim.fn.writefile({ "content" }, dir .. "/stable.lua")
    run("add", ".")
    run("commit", "-m", "initial")
    local initial = vim.trim(run("rev-parse", "HEAD"))

    vim.fn.writefile({ "modified" }, dir .. "/stable.lua")
    run("add", ".")
    run("commit", "-m", "modify")

    local done = false
    local resolved = nil

    git.resolve_path_at_revision(initial, dir, "stable.lua", function(err, path)
      assert.is_nil(err)
      resolved = path
      done = true
    end)

    vim.wait(5000, function() return done end)
    assert.is_true(done, "Callback should complete")
    assert.equal("stable.lua", resolved, "Should return same path when no rename")

    vim.fn.delete(dir, "rf")
  end)

end)
