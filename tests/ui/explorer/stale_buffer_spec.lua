-- Test: Stale buffer after git operations in explorer mode
-- Validates that diff panes update after stage, unstage, commit, and stash.
--
-- The bug: process_result() in refresh.lua rebuilds the explorer tree but
-- never calls on_file_select to update the diff panes. After any git
-- operation (stage, unstage, commit, stash) the diff panes show stale
-- content from the *previous* state.
--
-- These tests are written TDD-style — they should FAIL until the fix
-- is implemented in refresh.lua.

local h = dofile("tests/helpers.lua")

-- Ensure plugin is loaded (needed for PlenaryBustedFile subprocess)
h.ensure_plugin_loaded()

-- Setup CodeDiff command for tests
local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    complete = function()
      return { "file", "install" }
    end,
  })
end

--- Trigger an explorer refresh and wait for the async git-status +
--- vim.schedule callback to propagate.
--- @param explorer table  The explorer object from lifecycle
--- @param timeout_ms? number  How long to spin (default 3000)
local function refresh_and_wait(explorer, timeout_ms)
  timeout_ms = timeout_ms or 3000
  local refresh = require("codediff.ui.explorer.refresh")
  refresh.refresh(explorer)
  -- The refresh is async (git status → vim.schedule). We must let the
  -- event loop run so the callback fires and the tree / session update.
  vim.wait(timeout_ms, function()
    return false -- just spin, processing the event loop
  end, 50)
end

--- Open :CodeDiff in the given repo directory and wait until the explorer
--- is fully ready (session exists, explorer is set, diff buffers loaded).
--- Returns tabpage, session, explorer.
--- @param repo table  Repo helper from h.create_temp_git_repo()
--- @return number tabpage
--- @return table session
--- @return table explorer
local function open_codediff_and_wait(repo)
  vim.fn.chdir(repo.dir)
  -- Open a file so CodeDiff has context
  vim.cmd("edit " .. repo.path("file1.txt"))
  vim.cmd("CodeDiff")

  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage

  local ready = vim.wait(10000, function()
    for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
      local s = lifecycle.get_session(tp)
      if s and s.explorer then
        tabpage = tp
        local orig_buf, mod_buf = lifecycle.get_buffers(tp)
        if orig_buf and mod_buf then
          return vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)
        end
      end
    end
    return false
  end, 100)

  assert.is_true(ready, "CodeDiff explorer and diff panes should be ready")

  local session = lifecycle.get_session(tabpage)
  local explorer = session.explorer
  assert.is_not_nil(explorer, "Explorer should exist on session")

  return tabpage, session, explorer
end

--- Count the total number of file entries across all groups in the tree.
--- @param explorer table
--- @return number
local function count_tree_files(explorer)
  local refresh = require("codediff.ui.explorer.refresh")
  local files = refresh.get_all_files(explorer.tree)
  return #files
end

--- Check whether a file path exists in any group of the explorer tree.
--- @param explorer table
--- @param path string  Relative file path
--- @return boolean
local function file_exists_in_tree(explorer, path)
  local refresh = require("codediff.ui.explorer.refresh")
  local files = refresh.get_all_files(explorer.tree)
  for _, f in ipairs(files) do
    if f.data.path == path then
      return true
    end
  end
  return false
end

-- ============================================================================
describe("Stale Buffer After Git Operations", function()
  local repo
  local original_cwd

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" } })
    setup_command()
    original_cwd = vim.fn.getcwd()

    -- Create temp git repo with two modified files
    repo = h.create_temp_git_repo()

    -- file1.txt: committed, then modified (unstaged)
    repo.write_file("file1.txt", { "line1", "line2", "line3" })
    repo.git("add file1.txt")
    repo.git("commit -m 'add file1'")
    repo.write_file("file1.txt", { "line1", "modified line2", "line3" })

    -- file2.txt: committed, then modified (unstaged)
    repo.write_file("file2.txt", { "alpha", "beta", "gamma" })
    repo.git("add file2.txt")
    repo.git("commit -m 'add file2'")
    repo.write_file("file2.txt", { "alpha", "modified beta", "gamma" })
  end)

  after_each(function()
    -- Safe cleanup: create fresh tab, close all others
    pcall(function()
      vim.cmd("tabnew")
      vim.cmd("tabonly")
    end)
    vim.fn.chdir(original_cwd)
    vim.wait(200)
    if repo then
      repo.cleanup()
    end
  end)

  -- --------------------------------------------------------------------------
  -- Test 1: Staging the currently viewed file should update diff panes
  -- --------------------------------------------------------------------------
  it("updates diff panes when current file is staged", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Precondition: file1.txt should be in unstaged with working-tree diff
    assert.equals("unstaged", explorer.current_file_group,
      "Initial file should be in unstaged group")
    assert.equals("file1.txt", explorer.current_file_path,
      "Initial file should be file1.txt")

    -- The modified side should show the working copy (modified_revision == nil or "WORKING")
    session = lifecycle.get_session(tabpage)
    local pre_mod_rev = session.modified_revision
    assert.is_true(pre_mod_rev == nil or pre_mod_rev == "WORKING",
      "Before staging: modified_revision should be nil/WORKING, got: " .. tostring(pre_mod_rev))

    -- Stage file1.txt
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " add file1.txt")

    -- Refresh and wait for async completion
    refresh_and_wait(explorer)

    -- After staging, the file should have moved to the staged group
    -- and the diff panes should reflect the staged comparison (HEAD vs :0)
    session = lifecycle.get_session(tabpage)
    assert.equals("staged", explorer.current_file_group,
      "After staging: file should move to staged group")
    assert.equals(":0", session.modified_revision,
      "After staging: modified_revision should be :0 (staged index)")
  end)

  -- --------------------------------------------------------------------------
  -- Test 2: Unstaging the currently viewed file should update diff panes
  -- --------------------------------------------------------------------------
  it("updates diff panes when current file is unstaged", function()
    -- First stage file1.txt so it starts in the staged group
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " add file1.txt")

    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- file2.txt is still unstaged, so auto-select picks it first.
    -- Explicitly select file1 in staged. The wrapper sets
    -- explorer.current_file_group synchronously.
    explorer.on_file_select({
      path = "file1.txt",
      status = "M",
      git_root = repo.dir,
      group = "staged",
    })
    -- Give the async view.update chain time to settle
    vim.wait(3000, function() return false end, 50)

    -- Precondition: the synchronous tracker should reflect staged
    assert.equals("staged", explorer.current_file_group,
      "Precondition: should be viewing staged file1")
    assert.equals("file1.txt", explorer.current_file_path,
      "Precondition: should be viewing file1.txt")

    -- Unstage file1.txt
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " reset HEAD file1.txt")

    refresh_and_wait(explorer)

    -- After unstaging, the file should be back in the unstaged group
    -- and the diff panes should be re-selected with the new group.
    assert.equals("unstaged", explorer.current_file_group,
      "After unstaging: file should move to unstaged group")

    -- Also check that the session revision was updated
    session = lifecycle.get_session(tabpage)
    local post_mod_rev = session.modified_revision
    assert.is_true(post_mod_rev == nil or post_mod_rev == "WORKING",
      "After unstaging: modified_revision should be nil/WORKING, got: " .. tostring(post_mod_rev))
  end)

  -- --------------------------------------------------------------------------
  -- Test 3: File in both groups (stage, then modify again) — re-staging
  -- --------------------------------------------------------------------------
  it("updates diff panes when file exists in both groups and is re-staged", function()
    -- Stage file1.txt (original change)
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " add file1.txt")
    -- Modify file1.txt again → now appears in BOTH unstaged and staged
    repo.write_file("file1.txt", { "line1", "re-modified line2", "line3" })

    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Select file1 in unstaged group
    explorer.on_file_select({
      path = "file1.txt",
      status = "M",
      git_root = repo.dir,
      group = "unstaged",
    })
    vim.wait(3000, function() return false end, 50)

    assert.equals("unstaged", explorer.current_file_group,
      "Precondition: should be viewing unstaged file1")

    -- Stage the new changes too (git add merges into staged)
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " add file1.txt")

    refresh_and_wait(explorer)

    -- File should now be in staged only, diff panes updated
    session = lifecycle.get_session(tabpage)
    assert.equals("staged", explorer.current_file_group,
      "After re-staging: file should move to staged group")
    assert.equals(":0", session.modified_revision,
      "After re-staging: modified_revision should be :0")
  end)

  -- --------------------------------------------------------------------------
  -- Test 4: Stage all hunks — file moves from unstaged to staged only
  -- --------------------------------------------------------------------------
  it("moves file to staged group after staging all hunks", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")

    -- Precondition: viewing file1.txt in unstaged
    assert.equals("unstaged", explorer.current_file_group,
      "Precondition: file should be unstaged")

    -- Stage file1.txt
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " add file1.txt")

    refresh_and_wait(explorer)

    session = lifecycle.get_session(tabpage)
    assert.equals("staged", explorer.current_file_group,
      "After staging: current_file_group should be staged")
    assert.equals(":0", session.modified_revision,
      "After staging: diff panes should show staged comparison (modified_revision = :0)")
  end)

  -- --------------------------------------------------------------------------
  -- Test 5: Commit current file — others remain, welcome if empty
  -- --------------------------------------------------------------------------
  it("shows welcome or next file when current file is committed", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local welcome = require("codediff.ui.welcome")

    -- Precondition: file1.txt selected in unstaged
    assert.equals("file1.txt", explorer.current_file_path,
      "Precondition: should be viewing file1.txt")

    -- Commit only file1.txt
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " add file1.txt")
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " commit -m 'commit file1'")

    refresh_and_wait(explorer)

    -- file1.txt should be gone from the tree
    assert.is_false(file_exists_in_tree(explorer, "file1.txt"),
      "file1.txt should be removed from explorer after commit")

    -- file2.txt should still be present
    assert.is_true(file_exists_in_tree(explorer, "file2.txt"),
      "file2.txt should still be in explorer tree")

    -- The diff panes should NOT show stale file1.txt content.
    -- They should either show welcome (if nothing auto-selected)
    -- or show a different file.
    session = lifecycle.get_session(tabpage)
    local shows_welcome = welcome.is_welcome_buffer(session.modified_bufnr)
    local shows_different_file = explorer.current_file_path ~= "file1.txt"
    assert.is_true(shows_welcome or shows_different_file,
      "After committing file1: should show welcome or a different file, not stale file1 content")
  end)

  -- --------------------------------------------------------------------------
  -- Test 6: Commit everything — welcome page shows
  -- --------------------------------------------------------------------------
  it("shows welcome page when all files are committed", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local welcome = require("codediff.ui.welcome")

    -- Commit everything
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " add -A")
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " commit -m 'commit all'")

    refresh_and_wait(explorer)

    -- Explorer tree should have zero files
    assert.equals(0, count_tree_files(explorer),
      "Explorer tree should have 0 files after committing everything")

    -- Diff panes should show the welcome page
    session = lifecycle.get_session(tabpage)
    assert.is_true(welcome.is_welcome_buffer(session.modified_bufnr),
      "Welcome buffer should be shown after committing all files")
  end)

  -- --------------------------------------------------------------------------
  -- Test 7: Stash all changes — welcome page shows
  -- --------------------------------------------------------------------------
  it("shows welcome page when all changes are stashed", function()
    local tabpage, session, explorer = open_codediff_and_wait(repo)
    local lifecycle = require("codediff.ui.lifecycle")
    local welcome = require("codediff.ui.welcome")

    -- Stash everything
    vim.fn.system("git -C " .. vim.fn.shellescape(repo.dir) .. " stash")

    refresh_and_wait(explorer)

    -- Explorer tree should have zero files
    assert.equals(0, count_tree_files(explorer),
      "Explorer tree should have 0 files after stashing all changes")

    -- Diff panes should show the welcome page
    session = lifecycle.get_session(tabpage)
    assert.is_true(welcome.is_welcome_buffer(session.modified_bufnr),
      "Welcome buffer should be shown after stashing all changes")
  end)
end)
