-- Test: review groups in the revision-mode explorer (list/tree view, fallback, collapse, status mode)

local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

local config = require("codediff.config")
local viewed = require("codediff.review.viewed")
local review_context = require("codediff.review.context")
local lifecycle = require("codediff.ui.lifecycle")

local PR_GROUPS = [[{
  "groups": [
    { "name": "Backend", "paths": ["^server/"] },
    { "name": "Lockfiles", "paths": ["\\.lock$"], "autoViewed": true }
  ]
}]]

local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, { nargs = "*", bang = true })
end

local function node_children(explorer, node)
  local out = {}
  for _, id in ipairs(node:get_child_ids()) do
    out[#out + 1] = explorer.tree:get_node(id)
  end
  return out
end

local function root_names(explorer)
  local names = {}
  for _, n in ipairs(explorer.tree:get_nodes()) do
    names[#names + 1] = n.data.name
  end
  return names
end

local function find_root(explorer, name)
  for _, n in ipairs(explorer.tree:get_nodes()) do
    if n.data.name == name then
      return n
    end
  end
end

local function wait_for_explorer(timeout_ms)
  local explorer
  local ok = vim.wait(timeout_ms or 10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and s.explorer then
        local o, m = lifecycle.get_buffers(tp)
        if o and m and vim.api.nvim_buf_is_valid(o) and vim.api.nvim_buf_is_valid(m) then
          explorer = s.explorer
          return true
        end
      end
    end
    return false
  end, 100)
  assert.is_true(ok, "explorer should open")
  return explorer
end

describe("explorer review groups", function()
  local repo, state_dir, saved_config, saved_cwd, base, head

  local function commit_all(msg)
    repo.git("add -A")
    repo.git("commit -m " .. msg)
    return vim.trim(repo.git("rev-parse HEAD"))
  end

  local function open(cmd)
    vim.fn.chdir(repo.dir)
    vim.cmd("edit " .. repo.path("web/b.js"))
    vim.cmd(cmd)
    return wait_for_explorer()
  end

  before_each(function()
    setup_command()
    saved_config = vim.deepcopy(config.options)
    saved_cwd = vim.fn.getcwd()
    config.options.explorer.show_line_stats = false
    state_dir = vim.fn.tempname()
    vim.fn.mkdir(state_dir, "p")
    viewed._state_dir = state_dir
    viewed._reset()
    review_context._reset()
    repo = h.create_temp_git_repo()
  end)

  after_each(function()
    h.close_extra_tabs()
    config.options = saved_config
    viewed._reset()
    viewed._state_dir = nil
    review_context._reset()
    vim.fn.chdir(saved_cwd)
    repo.cleanup()
    vim.fn.delete(state_dir, "rf")
  end)

  local function grouped_repo()
    repo.write_file(".github/pr-groups.json", vim.split(PR_GROUPS, "\n"))
    repo.write_file("server/a.go", { "a" })
    repo.write_file("server/sub/c.go", { "c" })
    repo.write_file("web/b.js", { "b" })
    repo.write_file("yarn.lock", { "l" })
    repo.write_file(".gitattributes", { "*.pb.go linguist-generated" }) -- attributes are read at the base revision
    base = commit_all("base")
    repo.write_file("server/a.go", { "a2" })
    repo.write_file("server/sub/c.go", { "c2" })
    repo.write_file("web/b.js", { "b2" })
    repo.write_file("yarn.lock", { "l2" })
    repo.write_file("api.pb.go", { "gen" })
    head = commit_all("head")
  end

  it("builds grouped list view with collapsed auto-viewed groups", function()
    grouped_repo()
    local explorer = open(string.format("CodeDiff %s %s", base, head))

    assert.same({ "review:Backend", "review:Ungrouped", "review:Lockfiles", "review:Generated" }, root_names(explorer))
    assert.is_not_nil(explorer.review_ctx)

    local backend = find_root(explorer, "review:Backend")
    assert.is_true(backend:is_expanded())
    assert.is_true(find_root(explorer, "review:Ungrouped"):is_expanded())
    assert.is_false(find_root(explorer, "review:Lockfiles"):is_expanded())
    assert.is_false(find_root(explorer, "review:Generated"):is_expanded())

    local r = backend.data.review
    assert.equals("Backend", r.name)
    assert.equals(2, r.total)
    assert.equals(0, r.viewed)
    assert.is_false(r.auto_viewed)

    local lock = find_root(explorer, "review:Lockfiles")
    assert.equals(1, lock.data.review.viewed)
    assert.is_true(lock.data.review.auto_viewed)

    local files = node_children(explorer, backend)
    assert.same({ "server/a.go", "server/sub/c.go" }, { files[1].data.path, files[2].data.path })
    for _, f in ipairs(files) do
      assert.equals("unstaged", f.data.group)
      assert.equals("Backend", f.data.review_group)
      assert.is_false(f.data.viewed)
    end
    local lock_file = node_children(explorer, lock)[1]
    assert.equals("unstaged", lock_file.data.group)
    assert.equals("Lockfiles", lock_file.data.review_group)
    assert.is_true(lock_file.data.viewed)
  end)

  it("builds a directory tree per group in tree view", function()
    config.options.explorer.view_mode = "tree"
    grouped_repo()
    local explorer = open(string.format("CodeDiff %s %s", base, head))

    local backend = find_root(explorer, "review:Backend")
    local kids = node_children(explorer, backend)
    -- flatten_dirs does not merge "server" (it has a file and a subdir)
    assert.equals(1, #kids)
    assert.equals("directory", kids[1].data.type)
    assert.equals("server", kids[1].data.name)
    assert.equals("review:Backend/server", kids[1].data.collapse_key)
    local server_kids = node_children(explorer, kids[1])
    assert.equals("directory", server_kids[1].data.type)
    assert.equals("server/a.go", server_kids[2].data.path)
    assert.equals("Backend", server_kids[2].data.review_group)
    assert.equals("unstaged", server_kids[2].data.group)

    local ungrouped = node_children(explorer, find_root(explorer, "review:Ungrouped"))
    assert.equals("directory", ungrouped[1].data.type)
    assert.equals("web", ungrouped[1].data.name)
  end)

  it("shows one Changes group in a plain repo", function()
    repo.write_file("a.txt", { "a" })
    repo.write_file("web/b.js", { "b" })
    base = commit_all("base")
    repo.write_file("a.txt", { "a2" })
    repo.write_file("web/b.js", { "b2" })
    head = commit_all("head")
    local explorer = open(string.format("CodeDiff %s %s", base, head))

    assert.same({ "unstaged" }, root_names(explorer))
    local group = explorer.tree:get_nodes()[1]
    assert.equals("Changes (2)", group.text)
    assert.same({ name = "Changes", auto_viewed = false, total = 2, viewed = 0, ins = 0, del = 0, default_collapsed = false }, group.data.review)
    assert.is_true(group:is_expanded())
    for _, f in ipairs(node_children(explorer, group)) do
      assert.is_false(f.data.viewed)
      assert.equals("unstaged", f.data.group)
    end
  end)

  it("keeps today's output when pr_review is disabled", function()
    config.options.explorer.pr_review.enabled = false
    grouped_repo()
    local explorer = open(string.format("CodeDiff %s %s", base, head))

    assert.is_nil(explorer.review_ctx)
    assert.same({ "unstaged" }, root_names(explorer))
    local group = explorer.tree:get_nodes()[1]
    assert.equals("Changes (5)", group.text)
    assert.is_nil(group.data.review)
    for _, f in ipairs(node_children(explorer, group)) do
      assert.is_nil(f.data.viewed)
      assert.is_nil(f.data.review_group)
    end
  end)

  it("keeps a collapsed group collapsed and a user-expanded group expanded across refresh", function()
    grouped_repo()
    local explorer = open(string.format("CodeDiff %s %s", base, head))

    find_root(explorer, "review:Backend"):collapse()
    find_root(explorer, "review:Lockfiles"):expand()
    explorer.tree:render()

    local old_ctx = explorer.review_ctx
    require("codediff.ui.explorer.refresh").refresh(explorer)
    assert.is_true(vim.wait(5000, function()
      return explorer.review_ctx ~= old_ctx
    end, 20))

    assert.same({ "review:Backend", "review:Ungrouped", "review:Lockfiles", "review:Generated" }, root_names(explorer))
    assert.is_false(find_root(explorer, "review:Backend"):is_expanded())
    assert.is_true(find_root(explorer, "review:Ungrouped"):is_expanded())
    assert.is_true(find_root(explorer, "review:Lockfiles"):is_expanded())
    assert.is_false(find_root(explorer, "review:Generated"):is_expanded())
  end)

  it("starts every group collapsed with collapse_groups", function()
    config.options.explorer.pr_review.collapse_groups = true
    grouped_repo()
    local explorer = open(string.format("CodeDiff %s %s", base, head))
    for _, n in ipairs(explorer.tree:get_nodes()) do
      assert.is_false(n:is_expanded(), n.data.name)
    end
  end)

  it("ignores toggle_group for review groups", function()
    grouped_repo()
    local explorer = open(string.format("CodeDiff %s %s", base, head))
    local before = vim.deepcopy(explorer.visible_groups)
    require("codediff.ui.explorer.actions").toggle_group(explorer, "review:Backend")
    assert.same(before, explorer.visible_groups)
  end)

  it("leaves status mode unchanged", function()
    repo.write_file("a.txt", { "a" })
    repo.write_file("web/b.js", { "b" })
    commit_all("base")
    repo.write_file("a.txt", { "a2" })
    repo.write_file("staged.txt", { "s" })
    repo.git("add staged.txt")
    local explorer = open("CodeDiff")

    assert.is_nil(explorer.review_ctx)
    assert.same({ "unstaged", "staged" }, root_names(explorer))
    for _, n in ipairs(explorer.tree:get_nodes()) do
      assert.is_nil(n.data.review)
    end
    assert.equals("Changes (1)", explorer.tree:get_nodes()[1].text)
    local f = node_children(explorer, explorer.tree:get_nodes()[1])[1]
    assert.is_nil(f.data.viewed)
    assert.is_nil(f.data.review_group)
  end)
end)
