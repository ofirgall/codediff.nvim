-- Test: viewed identity (path, old blob, new blob) end to end on a temp repo, via the review context

local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

local viewed = require("codediff.review.viewed")
local review_context = require("codediff.review.context")

describe("viewed identity", function()
  local repo, state_dir, saved_cwd

  local function commit_all(msg)
    repo.git("add -A")
    repo.git("commit -m " .. msg)
    return vim.trim(repo.git("rev-parse HEAD"))
  end

  -- Load a context for (base, target) and return it
  local function load(base, target, files)
    local ctx
    review_context.load({
      git_root = repo.dir,
      base_revision = base,
      target_revision = target,
      files = files or { "a.txt", "b.txt" },
    }, function(err, c)
      assert.is_nil(err)
      ctx = c
    end)
    assert.is_true(vim.wait(10000, function()
      return ctx ~= nil
    end, 20))
    return ctx
  end

  local function mark(ctx, path, v)
    local b = ctx.blobs[path]
    ctx.store:set(path, b.old, b.new, v)
    ctx.store:flush()
  end

  local function fresh_session()
    viewed._reset()
    review_context._reset()
  end

  before_each(function()
    saved_cwd = vim.fn.getcwd()
    state_dir = vim.fn.tempname()
    vim.fn.mkdir(state_dir, "p")
    viewed._state_dir = state_dir
    viewed._reset()
    review_context._reset()
    repo = h.create_temp_git_repo()
    repo.write_file("a.txt", { "a" })
    repo.write_file("b.txt", { "b" })
    commit_all("init")
    repo.git("checkout -q -b feature")
    repo.write_file("a.txt", { "a2" })
    repo.write_file("b.txt", { "b2" })
    commit_all("feature")
  end)

  after_each(function()
    viewed._reset()
    viewed._state_dir = nil
    review_context._reset()
    vim.fn.chdir(saved_cwd)
    repo.cleanup()
    vim.fn.delete(state_dir, "rf")
  end)

  local function default_branch()
    return vim.trim(repo.git("rev-parse --abbrev-ref @{-1}"))
  end

  it("a new commit touching a viewed file unviews it; one touching other files does not", function()
    local base = default_branch()
    local ctx = load(base, "feature")
    mark(ctx, "a.txt", true)
    mark(ctx, "b.txt", true)
    assert.is_true(ctx.is_viewed("a.txt"))

    -- new commit changes only b.txt
    repo.write_file("b.txt", { "b3" })
    commit_all("touch_b")
    fresh_session()
    ctx = load(base, "feature")
    assert.is_true(ctx.is_viewed("a.txt"))
    assert.is_false(ctx.is_viewed("b.txt"))

    -- and a commit touching a.txt unviews a.txt too
    repo.write_file("a.txt", { "a3" })
    commit_all("touch_a")
    fresh_session()
    ctx = load(base, "feature")
    assert.is_false(ctx.is_viewed("a.txt"))
  end)

  it("a working-tree edit unviews the file after refresh", function()
    local base = default_branch()
    local ctx = load(base, "WORKING")
    mark(ctx, "a.txt", true)
    assert.is_true(load(base, "WORKING").is_viewed("a.txt"))

    repo.write_file("a.txt", { "edited" })
    assert.is_false(load(base, "WORKING").is_viewed("a.txt"))
    -- other file unaffected by the edit
    mark(ctx, "b.txt", true)
    assert.is_true(load(base, "WORKING").is_viewed("b.txt"))
  end)

  it("shares state between branch names and explicit SHAs", function()
    local base = default_branch()
    local ctx = load(base, "feature")
    mark(ctx, "a.txt", true)

    local base_sha = vim.trim(repo.git("rev-parse " .. base))
    local head_sha = vim.trim(repo.git("rev-parse feature"))
    fresh_session()
    ctx = load(base_sha, head_sha)
    assert.is_true(ctx.is_viewed("a.txt"))
    assert.is_false(ctx.is_viewed("b.txt"))
  end)
end)
