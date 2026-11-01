local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

local context = require("codediff.review.context")
local viewed = require("codediff.review.viewed")
local config = require("codediff.config")

local CONFIG = [[{
  // groups
  "groups": [
    { "name": "Backend", "paths": ["^server/"] },
    { "name": "Lockfiles", "paths": ["\\.lock$"], "autoViewed": true },
  ],
}]]

local function load(params)
  local result
  context.load(params, function(err, ctx)
    result = { err = err, ctx = ctx, done = true }
  end)
  assert.is_true(vim.wait(5000, function()
    return result ~= nil
  end, 20))
  return result.ctx
end

describe("review config defaults", function()
  it("exposes pr_review options and viewed keymaps", function()
    local d = config.defaults
    assert.same({ enabled = true, auto_mark_viewed = true, collapse_groups = false, skip_viewed = true, viewed_icon = "\u{f00c}", regex_engine = "auto", debug = false }, d.explorer.pr_review)
    assert.equals("v", d.keymaps.explorer.toggle_viewed)
    assert.equals("<leader>v", d.keymaps.view.toggle_viewed)
  end)
end)

describe("review.context", function()
  local repo, state_dir, saved_config, base, head

  before_each(function()
    saved_config = vim.deepcopy(config.options)
    state_dir = vim.fn.tempname()
    vim.fn.mkdir(state_dir, "p")
    viewed._state_dir = state_dir
    viewed._reset()
    context._reset()

    repo = h.create_temp_git_repo()
    repo.write_file(".github/pr-groups.json", vim.split(CONFIG, "\n"))
    repo.write_file(".gitattributes", { "*.pb.go linguist-generated" })
    repo.write_file("server/a.go", { "a" })
    repo.write_file("web/b.js", { "b" })
    repo.write_file("yarn.lock", { "l" })
    repo.git("add -A")
    repo.git("commit -m base")
    base = vim.trim(repo.git("rev-parse HEAD"))
    repo.write_file("server/a.go", { "a2" })
    repo.write_file("web/b.js", { "b2" })
    repo.write_file("yarn.lock", { "l2" })
    repo.write_file("api.pb.go", { "gen" })
    repo.git("add -A")
    repo.git("commit -m head")
    head = vim.trim(repo.git("rev-parse HEAD"))
  end)

  after_each(function()
    config.options = saved_config
    viewed._reset()
    viewed._state_dir = nil
    context._reset()
    repo.cleanup()
    vim.fn.delete(state_dir, "rf")
  end)

  local function files()
    return { { path = "server/a.go" }, { path = "web/b.js" }, { path = "yarn.lock" }, { path = "api.pb.go" } }
  end

  local function params(extra)
    return vim.tbl_extend("force", { git_root = repo.dir, base_revision = base, target_revision = head, files = files() }, extra or {})
  end

  it("builds groups, generated set and blobs", function()
    local ctx = load(params())
    assert.is_not_nil(ctx)
    local names = {}
    for _, g in ipairs(ctx.compiled.groups) do
      names[#names + 1] = g.name
    end
    assert.same({ "Backend", "Lockfiles", "Generated" }, names)
    assert.is_true(ctx.has_rules)
    assert.same({ ["api.pb.go"] = true }, ctx.generated)
    for _, p in ipairs({ "server/a.go", "web/b.js", "yarn.lock", "api.pb.go" }) do
      assert.is_not_nil(ctx.blobs[p], p)
    end
    assert.is_nil(ctx.config_error)
  end)

  it("yields no context in status mode, dir mode or when disabled", function()
    -- status mode: no base revision
    assert.is_nil(load({ git_root = repo.dir, files = files() }))
    -- dir mode: no git root
    assert.is_nil(load({ base_revision = base, files = files() }))
    config.options.explorer.pr_review.enabled = false
    assert.is_nil(load(params()))
  end)

  it("computes effective viewed from store, auto-viewed default and auto_mark_viewed", function()
    local ctx = load(params())
    local lock = { auto_viewed = true }
    assert.is_true(ctx.is_viewed("yarn.lock", lock))
    assert.is_false(ctx.is_viewed("server/a.go", { auto_viewed = false }))

    local b = ctx.blobs["yarn.lock"]
    ctx.store:set("yarn.lock", b.old, b.new, false)
    assert.is_false(ctx.is_viewed("yarn.lock", lock))
    local s = ctx.blobs["server/a.go"]
    ctx.store:set("server/a.go", s.old, s.new, true)
    assert.is_true(ctx.is_viewed("server/a.go", { auto_viewed = false }))

    config.options.explorer.pr_review.auto_mark_viewed = false
    local ctx2 = load(params())
    ctx.store:set("yarn.lock", b.old, b.new, nil)
    assert.is_false(ctx2.is_viewed("api.pb.go", { auto_viewed = true }))
  end)

  it("uses the setup groups override instead of the repo config", function()
    config.options.explorer.pr_review.groups = { groups = { { name = "Web", paths = { "^web/" } } } }
    local ctx = load(params())
    assert.equals("Web", ctx.compiled.groups[1].name)
    assert.equals("Generated", ctx.compiled.groups[2].name)
    assert.equals(2, #ctx.compiled.groups)
  end)

  it("reports an invalid config once and continues without it", function()
    repo.write_file(".github/pr-groups.json", { '{ "groups": [ { "name": "X", "paths": ["(unclosed"] } ] }' })
    repo.git("add -A")
    repo.git("commit -m badcfg")
    local bad_base = vim.trim(repo.git("rev-parse HEAD"))
    repo.write_file("web/b.js", { "b3" })
    repo.git("add -A")
    repo.git("commit -m more")
    local bad_head = vim.trim(repo.git("rev-parse HEAD"))

    local notes = {}
    local orig = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks, history)
      notes[#notes + 1] = { msg = chunks[1][1], hl = chunks[1][2], history = history }
    end
    local p = { git_root = repo.dir, base_revision = bad_base, target_revision = bad_head, files = { { path = "web/b.js" } } }
    local ctx = load(p)
    p.prev_ctx = ctx
    local ctx2 = load(p)
    vim.api.nvim_echo = orig

    assert.is_not_nil(ctx)
    assert.is_not_nil(ctx.config_error)
    assert.is_false(ctx.has_rules)
    assert.equals(ctx.config_error, ctx2.config_error)
    assert.equals(1, #notes)
    assert.equals("ErrorMsg", notes[1].hl)
    assert.is_true(notes[1].history)
    assert.is_truthy(notes[1].msg:find("unclosed", 1, true))
  end)

  it("ignores a config that only exists on the target", function()
    -- base commit without config, target (head) has it
    repo.git("checkout -q --orphan other")
    repo.git("rm -rf -q .")
    repo.write_file("x.txt", { "x" })
    repo.git("add -A")
    repo.git("commit -m nocfg")
    local orphan = vim.trim(repo.git("rev-parse HEAD"))
    local ctx2 = load(params({ base_revision = orphan, target_revision = head, files = { { path = "web/b.js" } } }))
    assert.is_false(ctx2.has_rules)
  end)
  describe("debug logging", function()
    local orig, logs
    before_each(function()
      logs = {}
      orig = _G.print
      _G.print = function(msg)
        if type(msg) == "string" and msg:find("[codediff:review]", 1, true) then
          logs[#logs + 1] = msg
        end
      end
    end)
    after_each(function()
      _G.print = orig
    end)
    local function flush()
      vim.wait(200, function() return false end, 20)
      return table.concat(logs, "\n")
    end

    it("is silent when debug is off", function()
      load(params({ files = { { path = "server/a.go" } } }))
      assert.equals("", flush())
    end)

    it("logs the config lookup, parse and built groups", function()
      config.options.explorer.pr_review.debug = true
      load(params({ files = { { path = "server/a.go" }, { path = "api.pb.go" } } }))
      local out = flush()
      assert.is_truthy(out:find("reading from base revision " .. base, 1, true))
      assert.is_truthy(out:find("git show " .. base .. ":.github/pr-groups.json -> found", 1, true))
      assert.is_truthy(out:find(".github/pr-groups.json parsed, 2 groups", 1, true))
      assert.is_truthy(out:find("built: 3 groups [Backend, Lockfiles*, Generated*]", 1, true))
    end)

    it("logs git's error for each missing config path", function()
      config.options.explorer.pr_review.debug = true
      repo.git("checkout -q --orphan other")
      repo.git("rm -rf -q .")
      repo.write_file("x.txt", { "x" })
      repo.git("add -A")
      repo.git("commit -m nocfg")
      local orphan = vim.trim(repo.git("rev-parse HEAD"))
      load(params({ base_revision = orphan, target_revision = head, files = {} }))
      local out = flush()
      assert.is_truthy(out:find(":.github/pr-groups.json -> fatal:", 1, true))
      assert.is_truthy(out:find(":.github/pr-groups.jsonc -> fatal:", 1, true))
      assert.is_truthy(out:find("no pr-groups.json/.jsonc at base revision " .. orphan, 1, true))
      assert.is_truthy(out:find("no rules, showing plain Changes group", 1, true))
    end)

    it("logs why groups are skipped in status mode", function()
      config.options.explorer.pr_review.debug = true
      load({ git_root = repo.dir, files = files() })
      assert.is_truthy(flush():find("skipped: status mode", 1, true))
    end)
  end)
end)
