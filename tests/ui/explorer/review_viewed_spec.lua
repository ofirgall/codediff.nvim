-- Test: Viewed UX in the revision-mode explorer (markers, headers, toggles, auto-viewed, navigation)

local h = dofile("tests/helpers.lua")
h.ensure_plugin_loaded()

local config = require("codediff.config")
local viewed = require("codediff.review.viewed")
local review_context = require("codediff.review.context")
local lifecycle = require("codediff.ui.lifecycle")
local viewed_ui = require("codediff.ui.explorer.viewed")

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

local function root(explorer, name)
  for _, n in ipairs(explorer.tree:get_nodes()) do
    if n.data.name == name then
      return n
    end
  end
end

local function file_node(explorer, path)
  for _, f in ipairs(require("codediff.ui.explorer.refresh").get_all_files(explorer.tree, { include_collapsed = true })) do
    if f.data.path == path then
      return f.node
    end
  end
end

-- Line number of a node in the explorer buffer
local function line_of(explorer, node)
  for l = 1, vim.api.nvim_buf_line_count(explorer.bufnr) do
    if explorer.tree:get_node(l) == node then
      return l
    end
  end
end

local function buf_line(explorer, l)
  return vim.api.nvim_buf_get_lines(explorer.bufnr, l - 1, l, false)[1]
end

-- Press a key with the explorer cursor on `node`
local function press_on(explorer, node, key)
  vim.api.nvim_set_current_win(explorer.winid)
  if not line_of(explorer, node) then
    -- expand collapsed ancestors
    local pid = node._parent_id
    while pid do
      local p = explorer.tree:get_node(pid)
      p:expand()
      pid = p._parent_id
    end
    explorer.tree:render()
  end
  vim.api.nvim_win_set_cursor(explorer.winid, { line_of(explorer, node), 0 })
  vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
end

describe("explorer viewed state", function()
  local repo, state_dir, saved_config, saved_cwd, base, head

  local function commit_all(msg)
    repo.git("add -A")
    repo.git("commit -m " .. msg)
    return vim.trim(repo.git("rev-parse HEAD"))
  end

  local function lines(prefix, n)
    local out = {}
    for i = 1, n do
      out[i] = prefix .. i
    end
    return out
  end

  local function open(cmd)
    vim.fn.chdir(repo.dir)
    vim.cmd("edit " .. repo.path("web/b.js"))
    vim.cmd(cmd)
    return wait_for_explorer()
  end

  local function reset_sessions()
    h.close_extra_tabs()
    viewed._reset()
    review_context._reset()
  end

  before_each(function()
    setup_command()
    saved_config = vim.deepcopy(config.options)
    saved_cwd = vim.fn.getcwd()
    config.options.explorer.show_line_stats = false
    config.options.explorer.pr_review.viewed_icon = "V"
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

  -- server/a.go +30 -5, server/c.go +70 -1, web/b.js, web/d.js, yarn.lock
  local function grouped_repo()
    repo.write_file(".github/pr-groups.json", vim.split(PR_GROUPS, "\n"))
    repo.write_file("server/a.go", lines("old", 5))
    repo.write_file("server/c.go", { "c" })
    repo.write_file("web/b.js", { "b" })
    repo.write_file("web/d.js", { "d" })
    repo.write_file("yarn.lock", { "l" })
    base = commit_all("base")
    repo.write_file("server/a.go", lines("new", 30))
    repo.write_file("server/c.go", lines("c", 70))
    repo.write_file("web/b.js", { "b2" })
    repo.write_file("web/d.js", { "d2" })
    repo.write_file("yarn.lock", { "l2" })
    head = commit_all("head")
  end

  local function open_grouped()
    return open(string.format("CodeDiff %s %s", base, head))
  end

  it("renders group header progress, remaining stats and the viewed marker", function()
    config.options.explorer.show_line_stats = true
    grouped_repo()
    local explorer = open_grouped()
    local backend = root(explorer, "review:Backend")

    -- Line stats arrive asynchronously; the header sums them once they do
    assert.is_true(vim.wait(10000, function()
      return backend.data.review.ins == 100 and backend.data.review.del == 6
    end, 50))
    local header = buf_line(explorer, line_of(explorer, backend))
    assert.truthy(header:match("^ Backend  0/2%s+%+100 %-6%s*$"), header)

    -- dimmed progress count
    local found = false
    local marks = vim.api.nvim_buf_get_extmarks(explorer.bufnr, explorer.tree._ns_id, { 0, 0 }, { 0, -1 }, { details = true })
    for _, m in ipairs(marks) do
      if m[4].hl_group == "CodeDiffExplorerGroupProgress" then
        found = true
      end
    end
    assert.is_true(found)

    -- mark the +30 -5 file viewed from the explorer
    local a = file_node(explorer, "server/a.go")
    press_on(explorer, a, "v")
    header = buf_line(explorer, line_of(explorer, backend))
    assert.truthy(header:match("^ Backend  1/2%s+%+70 %-1%s*$"), header)
    assert.is_true(a.data.viewed)
    assert.truthy(buf_line(explorer, line_of(explorer, a)):match("^%s*V "))
    local c = file_node(explorer, "server/c.go")
    assert.is_nil(buf_line(explorer, line_of(explorer, c)):match("V "))

    local hl = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(explorer.bufnr, explorer.tree._ns_id, { line_of(explorer, a) - 1, 0 }, { line_of(explorer, a) - 1, -1 }, { details = true })) do
      if m[4].hl_group == "CodeDiffExplorerViewed" then
        hl = true
      end
    end
    assert.is_true(hl)
  end)

  it("shows Changes viewed/total in a plain repo", function()
    repo.write_file("a.txt", { "a" })
    repo.write_file("b.txt", { "b" })
    base = commit_all("base")
    repo.write_file("a.txt", { "a2" })
    repo.write_file("b.txt", { "b2" })
    head = commit_all("head")
    local explorer = open(string.format("CodeDiff %s %s", base, head))
    local group = explorer.tree:get_nodes()[1]
    assert.truthy(buf_line(explorer, 1):match("^ Changes  0/2"))
    press_on(explorer, file_node(explorer, "a.txt"), "v")
    assert.truthy(buf_line(explorer, 1):match("^ Changes  1/2"))
    assert.equals(1, group.data.review.viewed)
  end)

  it("batch toggles a partly viewed group, persists and emits CodeDiffViewedChange", function()
    grouped_repo()
    local explorer = open_grouped()
    local events = {}
    local au = vim.api.nvim_create_autocmd("User", {
      pattern = "CodeDiffViewedChange",
      callback = function(ev)
        events[#events + 1] = ev.data
      end,
    })

    local backend = root(explorer, "review:Backend")
    local a, c = file_node(explorer, "server/a.go"), file_node(explorer, "server/c.go")
    press_on(explorer, a, "v") -- 1 of 2 viewed
    assert.equals(1, backend.data.review.viewed)

    press_on(explorer, backend, "v") -- any unviewed -> mark all
    assert.is_true(a.data.viewed and c.data.viewed)
    assert.equals(2, backend.data.review.viewed)
    -- cursor stays on the group header
    assert.equals(line_of(explorer, backend), vim.api.nvim_win_get_cursor(explorer.winid)[1])

    local blob = explorer.review_ctx.blobs["server/c.go"]
    assert.is_true(explorer.review_ctx.store:get("server/c.go", blob.old, blob.new))

    press_on(explorer, backend, "v") -- all viewed -> unmark all
    assert.is_false(a.data.viewed or c.data.viewed)
    assert.is_false(explorer.review_ctx.store:get("server/c.go", blob.old, blob.new))

    vim.api.nvim_del_autocmd(au)
    assert.equals(3, #events)
    assert.equals(explorer.tabpage, events[2].tabpage)
    assert.same({ "server/a.go", "server/c.go" }, events[2].paths)
    assert.is_true(events[2].viewed)
    assert.is_false(events[3].viewed)
  end)

  it("batch toggles a fully viewed directory in tree view", function()
    config.options.explorer.view_mode = "tree"
    grouped_repo()
    local explorer = open_grouped()
    local backend = root(explorer, "review:Backend")
    local dir = explorer.tree:get_node(backend:get_child_ids()[1])
    assert.equals("directory", dir.data.type)

    press_on(explorer, dir, "v")
    assert.equals(2, backend.data.review.viewed)
    press_on(explorer, dir, "v")
    assert.equals(0, backend.data.review.viewed)
    assert.is_false(file_node(explorer, "server/a.go").data.viewed)
  end)

  -- Highlight groups covering the first occurrence of `text` on line `l`
  local function hls_at(explorer, l, text)
    local col = buf_line(explorer, l):find(text, 1, true) - 1
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(explorer.bufnr, explorer.tree._ns_id, { l - 1, 0 }, { l - 1, -1 }, { details = true })) do
      if m[3] <= col and col < m[4].end_col then
        out[#out + 1] = m[4].hl_group
      end
    end
    return out
  end

  it("shows directory line stats, fades and collapses directories and groups once fully viewed", function()
    config.options.explorer.view_mode = "tree"
    config.options.explorer.show_line_stats = true
    grouped_repo()
    local explorer = open_grouped()
    local backend = root(explorer, "review:Backend")
    local dir = explorer.tree:get_node(backend:get_child_ids()[1])
    assert.equals("server", dir.data.name)
    assert.is_true(vim.wait(10000, function()
      return backend.data.review.ins == 100
    end, 50))

    -- directory sums its files' lines
    assert.truthy(buf_line(explorer, line_of(explorer, dir)):match("server%s+%+100 %-6%s*$"), buf_line(explorer, line_of(explorer, dir)))

    -- one file viewed: the directory shows what is left
    press_on(explorer, file_node(explorer, "server/a.go"), "v")
    assert.truthy(buf_line(explorer, line_of(explorer, dir)):match("server%s+%+70 %-1%s*$"))
    assert.is_true(dir:is_expanded())
    assert.same({ "Directory" }, hls_at(explorer, line_of(explorer, dir), "server"))

    -- last file viewed: directory and group collapse, cursor lands on the group header
    press_on(explorer, file_node(explorer, "server/c.go"), "v")
    assert.is_false(backend:is_expanded())
    assert.is_false(dir:is_expanded())
    local l = line_of(explorer, backend)
    assert.equals(l, vim.api.nvim_win_get_cursor(explorer.winid)[1])
    assert.truthy(buf_line(explorer, l):match("^ Backend  V 2/2%s+%+100 %-6%s*$"), buf_line(explorer, l))
    assert.same({ "CodeDiffExplorerViewed" }, hls_at(explorer, l, "Backend"))
    assert.same({ "CodeDiffExplorerViewed" }, hls_at(explorer, l, "+100"))

    -- reopened by hand: stays open and the directory row is faded
    backend:expand()
    explorer.tree:render()
    assert.same({ "CodeDiffExplorerViewed" }, hls_at(explorer, line_of(explorer, dir), "server"))
    assert.truthy(buf_line(explorer, line_of(explorer, dir)):match("V .*server%s+%+100 %-6%s*$"))

    -- un-viewing does not collapse anything
    dir:expand()
    explorer.tree:render()
    press_on(explorer, file_node(explorer, "server/a.go"), "v")
    assert.is_true(backend:is_expanded() and dir:is_expanded())
  end)

  it("draws auto-viewed group names with CodeDiffExplorerGroupAutoViewed", function()
    grouped_repo()
    local explorer = open_grouped()
    local lock = root(explorer, "review:Lockfiles")
    assert.is_false(lock:is_expanded())
    assert.same({ "CodeDiffExplorerGroupAutoViewed" }, hls_at(explorer, line_of(explorer, lock), "Lockfiles"))
    assert.same({ "CodeDiffExplorerTreeGroup" }, hls_at(explorer, line_of(explorer, root(explorer, "review:Backend")), "Backend"))
  end)

  it("starts fully viewed directories collapsed", function()
    config.options.explorer.view_mode = "tree"
    grouped_repo()
    local explorer = open_grouped()
    press_on(explorer, root(explorer, "review:Backend"), "v")
    explorer.review_ctx.store:flush()
    reset_sessions()
    explorer = open_grouped()
    local backend = root(explorer, "review:Backend")
    assert.is_false(backend:is_expanded())
    assert.is_false(explorer.tree:get_node(backend:get_child_ids()[1]):is_expanded())
  end)

  it("does nothing in status mode", function()
    repo.write_file("a.txt", { "a" })
    commit_all("base")
    repo.write_file("a.txt", { "a2" })
    vim.fn.chdir(repo.dir)
    vim.cmd("edit " .. repo.path("a.txt"))
    vim.cmd("CodeDiff")
    local explorer = wait_for_explorer()
    assert.is_nil(explorer.review_ctx)
    local node = file_node(explorer, "a.txt")
    assert.has_no.errors(function()
      press_on(explorer, node, "v")
      viewed_ui.toggle_current(explorer)
    end)
    assert.is_nil(node.data.viewed)
    assert.is_nil(buf_line(explorer, line_of(explorer, node)):match("V "))
  end)

  it("toggles the current file from the modified pane", function()
    grouped_repo()
    local explorer = open_grouped()
    local c = file_node(explorer, "server/c.go")
    explorer.on_file_select(c.data)
    assert.is_true(vim.wait(10000, function()
      return explorer.current_file_path == "server/c.go"
    end, 50))
    vim.wait(500)

    local _, mod_win = lifecycle.get_windows(explorer.tabpage)
    vim.api.nvim_set_current_win(mod_win)
    vim.api.nvim_feedkeys(vim.keycode(config.options.keymaps.view.toggle_viewed), "x", false)
    assert.is_true(c.data.viewed)
    assert.truthy(buf_line(explorer, line_of(explorer, c)):match("V "))
    vim.api.nvim_feedkeys(vim.keycode(config.options.keymaps.view.toggle_viewed), "x", false)
    assert.is_false(c.data.viewed)
  end)

  describe("auto-viewed defaults", function()
    it("starts lockfiles viewed, keeps an un-view across reopen, and honors auto_mark_viewed=false", function()
      grouped_repo()
      local explorer = open_grouped()
      local lock = file_node(explorer, "yarn.lock")
      assert.is_true(lock.data.viewed)

      press_on(explorer, lock, "v") -- un-view the auto-viewed file
      assert.is_false(lock.data.viewed)

      explorer.review_ctx.store:flush()
      reset_sessions()
      explorer = open_grouped()
      assert.is_false(file_node(explorer, "yarn.lock").data.viewed)

      -- fresh store, auto-viewing off
      reset_sessions()
      vim.fn.delete(state_dir, "rf")
      vim.fn.mkdir(state_dir, "p")
      config.options.explorer.pr_review.auto_mark_viewed = false
      explorer = open_grouped()
      local lock2 = file_node(explorer, "yarn.lock")
      assert.is_false(lock2.data.viewed)
      assert.equals("Lockfiles", lock2.data.review_group)
      -- nothing viewed in it, so it starts open
      assert.is_true(root(explorer, "review:Lockfiles"):is_expanded())
    end)

    it("opens a collapsed viewed group when one of its files is unviewed", function()
      grouped_repo()
      local explorer = open_grouped()
      local group = root(explorer, "review:Lockfiles")
      assert.is_false(group:is_expanded())
      viewed_ui.set_viewed(explorer, { file_node(explorer, "yarn.lock") }, false)
      assert.is_true(group:is_expanded())
      assert.truthy(line_of(explorer, file_node(explorer, "yarn.lock")))
    end)

    it("opens a viewed group and directory when a file's diff changes on refresh", function()
      config.options.explorer.view_mode = "tree"
      grouped_repo()
      local explorer = open(string.format("CodeDiff %s", base)) -- target: working tree
      local backend = root(explorer, "review:Backend")
      viewed_ui.toggle_node(explorer, backend)
      local dir = explorer.tree:get_node(backend:get_child_ids()[1])
      assert.is_false(backend:is_expanded())
      assert.is_false(dir:is_expanded())

      repo.write_file("server/c.go", { "changed again" })
      require("codediff.ui.explorer.refresh").refresh(explorer)
      assert.is_true(vim.wait(10000, function()
        local b = root(explorer, "review:Backend")
        return b and b.data.review.viewed == 1 and b:is_expanded()
      end, 50))
      backend = root(explorer, "review:Backend")
      assert.is_true(explorer.tree:get_node(backend:get_child_ids()[1]):is_expanded())
      assert.is_false(file_node(explorer, "server/c.go").data.viewed)
    end)
  end)

  describe("navigation", function()
    local function current(explorer)
      return explorer.current_file_path
    end

    local function wait_current(explorer, path)
      assert.is_true(vim.wait(10000, function()
        return explorer.current_file_path == path
      end, 50), "expected current file " .. path .. ", got " .. tostring(explorer.current_file_path))
    end

    local function plain_repo()
      repo.write_file("A.txt", { "a" })
      repo.write_file("B.txt", { "b" })
      repo.write_file("C.txt", { "c" })
      base = commit_all("base")
      repo.write_file("A.txt", { "a2" })
      repo.write_file("B.txt", { "b2" })
      repo.write_file("C.txt", { "c2" })
      head = commit_all("head")
      return open(string.format("CodeDiff %s %s", base, head))
    end

    it("skips viewed files with ]f / [f", function()
      local explorer = plain_repo()
      local actions = require("codediff.ui.explorer.actions")
      viewed_ui.set_viewed(explorer, { file_node(explorer, "B.txt") }, true)
      explorer.on_file_select(file_node(explorer, "A.txt").data)
      wait_current(explorer, "A.txt")

      actions.navigate_next(explorer)
      wait_current(explorer, "C.txt")
      actions.navigate_prev(explorer)
      wait_current(explorer, "A.txt")
    end)

    it("does not skip when skip_viewed is off", function()
      config.options.explorer.pr_review.skip_viewed = false
      local explorer = plain_repo()
      local actions = require("codediff.ui.explorer.actions")
      viewed_ui.set_viewed(explorer, { file_node(explorer, "B.txt") }, true)
      explorer.on_file_select(file_node(explorer, "A.txt").data)
      wait_current(explorer, "A.txt")
      actions.navigate_next(explorer)
      wait_current(explorer, "B.txt")
    end)

    it("expands a collapsed group holding the target", function()
      grouped_repo()
      local explorer = open_grouped()
      local actions = require("codediff.ui.explorer.actions")
      local lock_group = root(explorer, "review:Lockfiles")
      assert.is_false(lock_group:is_expanded())
      -- Everything but the lockfile is viewed, and the lockfile was un-viewed
      local lock = file_node(explorer, "yarn.lock")
      viewed_ui.set_viewed(explorer, { lock }, false)
      local others = {}
      for _, f in ipairs(require("codediff.ui.explorer.refresh").get_all_files(explorer.tree, { include_collapsed = true })) do
        if f.data.path ~= "yarn.lock" then
          others[#others + 1] = f.node
        end
      end
      viewed_ui.set_viewed(explorer, others, true)

      explorer.on_file_select(file_node(explorer, "web/b.js").data)
      wait_current(explorer, "web/b.js")
      actions.navigate_next(explorer)
      wait_current(explorer, "yarn.lock")
      assert.is_true(lock_group:is_expanded())
      assert.equals(line_of(explorer, lock), vim.api.nvim_win_get_cursor(explorer.winid)[1])
    end)

    it("reports when all files are viewed and stays", function()
      local explorer = plain_repo()
      local actions = require("codediff.ui.explorer.actions")
      explorer.on_file_select(file_node(explorer, "A.txt").data)
      wait_current(explorer, "A.txt")
      press_on(explorer, explorer.tree:get_nodes()[1], "v")
      vim.api.nvim_set_current_win(select(2, lifecycle.get_windows(explorer.tabpage)))

      actions.navigate_next(explorer)
      vim.wait(200)
      assert.equals("A.txt", current(explorer))
    end)
  end)
end)
