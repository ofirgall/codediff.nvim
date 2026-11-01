local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

local context = require("codediff.review.context")
local viewed = require("codediff.review.viewed")
local js_match = require("codediff.review.js_match")
local grouping = require("codediff.review.grouping")
local config = require("codediff.config")

local has_node = js_match.node() ~= nil
local it_node = has_node and it or pending

local function wait_result(start)
  local result
  start(function(...)
    result = { ... }
  end)
  assert.is_true(vim.wait(5000, function()
    return result ~= nil
  end, 20))
  return unpack(result)
end

describe("review.js_match", function()
  it_node("matches with native JS regexes, 1-based group indices", function()
    local err, res = wait_result(function(cb)
      js_match.run(js_match.node(), { { "^server/", "\\bmain\\b" }, { "\\.go$" } }, { "server/a.go", "cmd/main.go", "web/x.js" }, cb)
    end)
    assert.is_nil(err)
    assert.same({}, res.errors)
    assert.same({ 1, 2 }, res.matches["server/a.go"])
    assert.same({ 1, 2 }, res.matches["cmd/main.go"])
    assert.is_nil(res.matches["web/x.js"])
  end)

  it_node("reports invalid patterns with JS messages", function()
    local err, res = wait_result(function(cb)
      js_match.run(js_match.node(), { { "ok" }, { "(unclosed" } }, { "a" }, cb)
    end)
    assert.is_nil(err)
    assert.equals(1, #res.errors)
    assert.equals(2, res.errors[1].group)
    assert.equals("(unclosed", res.errors[1].pattern)
    assert.matches("Invalid regular expression", res.errors[1].message)
    assert.same({}, res.matches)
  end)

  it("reports a node that cannot run", function()
    local err, res = wait_result(function(cb)
      js_match.run("/nonexistent/node", { { "a" } }, { "a" }, cb)
    end)
    assert.is_string(err)
    assert.is_nil(res)
  end)
end)

describe("review regex_engine", function()
  local repo, state_dir, saved_config, saved_node, saved_run, base, head

  -- \b only works with native JS regexes; (?!...) works with both engines.
  local CONFIG = [[{
    "groups": [
      { "name": "Main", "paths": ["\\bmain\\.go$"] },
      { "name": "Scripts", "paths": ["^scripts/(?!pre-pr/)"] },
    ],
  }]]

  before_each(function()
    saved_config = vim.deepcopy(config.options)
    saved_node, saved_run = js_match.node, js_match.run
    state_dir = vim.fn.tempname()
    vim.fn.mkdir(state_dir, "p")
    viewed._state_dir = state_dir
    viewed._reset()
    context._reset()

    repo = h.create_temp_git_repo()
    repo.write_file(".github/pr-groups.jsonc", vim.split(CONFIG, "\n"))
    repo.write_file("README.md", { "x" })
    repo.git("add -A")
    repo.git("commit -m base")
    base = vim.trim(repo.git("rev-parse HEAD"))
    repo.write_file("cmd/main.go", { "m" })
    repo.write_file("scripts/deploy.sh", { "d" })
    repo.write_file("scripts/pre-pr/check.sh", { "c" })
    repo.git("add -A")
    repo.git("commit -m head")
    head = vim.trim(repo.git("rev-parse HEAD"))
  end)

  after_each(function()
    js_match.node, js_match.run = saved_node, saved_run
    config.options = saved_config
    viewed._reset()
    viewed._state_dir = nil
    context._reset()
    repo.cleanup()
    vim.fn.delete(state_dir, "rf")
  end)

  local FILES = { { path = "cmd/main.go" }, { path = "scripts/deploy.sh" }, { path = "scripts/pre-pr/check.sh" } }

  local function load_ctx(engine)
    config.options.explorer.pr_review.regex_engine = engine
    local orig_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function() end -- keep config errors quiet
    local _, ctx = wait_result(function(cb)
      context.load({ git_root = repo.dir, base_revision = base, target_revision = head, files = FILES }, cb)
    end)
    vim.api.nvim_echo = orig_echo
    return ctx
  end

  local function assignment(ctx)
    return grouping.order(FILES, ctx.compiled).assignment
  end

  it_node("auto uses node: \\b and lookahead both work", function()
    local ctx = load_ctx("auto")
    assert.is_nil(ctx.config_error)
    assert.same({
      ["cmd/main.go"] = "Main",
      ["scripts/deploy.sh"] = "Scripts",
      ["scripts/pre-pr/check.sh"] = "Ungrouped",
    }, assignment(ctx))
  end)

  it("vim engine rejects \\b and ignores the config", function()
    local ctx = load_ctx("vim")
    assert.matches('Group "Main": invalid regex', ctx.config_error)
    assert.is_false(ctx.has_rules)
  end)

  it("auto falls back to the vim translator when node is missing", function()
    js_match.node = function()
      return nil
    end
    local ctx = load_ctx("auto")
    assert.matches("boundary", ctx.config_error) -- translator's own error
  end)

  it("auto falls back to the vim translator when node fails", function()
    js_match.node = function()
      return "/fake/node"
    end
    js_match.run = function(_, _, _, cb)
      cb("node exited with 1: boom", nil)
    end
    local ctx = load_ctx("auto")
    assert.matches("boundary", ctx.config_error)
  end)

  it("node engine without node ignores the config with an error", function()
    js_match.node = function()
      return nil
    end
    local ctx = load_ctx("node")
    assert.matches("node was not found", ctx.config_error)
    assert.is_false(ctx.has_rules)
  end)

  it_node("node engine reports JS regex errors in fast-pr's format", function()
    repo.write_file(".github/pr-groups.jsonc", { '{"groups":[{"name":"Bad","paths":["(unclosed"]}]}' })
    repo.git("add -A")
    repo.git("commit -m bad")
    base = vim.trim(repo.git("rev-parse HEAD"))
    local ctx = load_ctx("node")
    assert.matches('^Group "Bad": invalid regex "%(unclosed": Invalid regular expression', ctx.config_error)
  end)
end)
