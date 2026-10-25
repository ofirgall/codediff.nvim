-- Test: Explorer auto_width
-- Validates growing to fit content, shrinking on refresh, and manual resize override

local h = dofile("tests/helpers.lua")

local long_path = "some/deeply/nested/directory/structure/with_a_really_long_file_name_here.txt"

local function setup_command()
  local commands = require("codediff.commands")
  vim.api.nvim_create_user_command("CodeDiff", function(opts)
    commands.vscode_diff(opts)
  end, { nargs = "*", bang = true })
end

describe("Explorer auto_width", function()
  local repo
  local original_cwd

  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side" }, explorer = { width = 30, auto_width = true } })
    setup_command()
    original_cwd = vim.fn.getcwd()

    repo = h.create_temp_git_repo()
    repo.write_file("a.txt", { "one" })
    repo.git("add a.txt")
    repo.git('commit -m "init"')
    repo.write_file("a.txt", { "two" })
    repo.write_file(long_path, { "new" })
    vim.fn.chdir(repo.dir)
  end)

  after_each(function()
    vim.cmd("tabnew")
    vim.cmd("tabonly")
    vim.fn.chdir(original_cwd)
    vim.wait(200)
    repo.cleanup()
  end)

  local function open_explorer()
    vim.cmd("CodeDiff")
    local lifecycle = require("codediff.ui.lifecycle")
    local explorer
    vim.wait(5000, function()
      local session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
      explorer = session and session.explorer
      return explorer ~= nil and explorer.winid ~= nil and vim.api.nvim_win_is_valid(explorer.winid)
    end, 50)
    assert.is_not_nil(explorer, "explorer should be created")
    -- Let the scheduled initial file select / line stats settle
    vim.wait(500)
    return explorer
  end

  it("grows the panel to fit the widest entry", function()
    local explorer = open_explorer()
    assert.is_true(vim.api.nvim_win_get_width(explorer.winid) > 30)
  end)

  it("shrinks back to the configured width on refresh once wide entries are gone", function()
    local explorer = open_explorer()
    assert.is_true(vim.api.nvim_win_get_width(explorer.winid) > 30)

    vim.fn.delete(repo.path(long_path))
    require("codediff.ui.explorer.refresh").refresh(explorer)
    local shrunk = vim.wait(5000, function()
      return vim.api.nvim_win_get_width(explorer.winid) == 30
    end, 50)
    assert.is_true(shrunk, "width should shrink to 30, got " .. vim.api.nvim_win_get_width(explorer.winid))
  end)

  it("keeps a manually set width and stops auto-sizing", function()
    local explorer = open_explorer()
    local tabpage = vim.api.nvim_get_current_tabpage()

    local render = require("codediff.ui.explorer.render")
    vim.api.nvim_win_set_width(explorer.winid, 25)
    -- WinResized doesn't fire in headless mode; invoke its handler logic directly
    render.detect_manual_resize(explorer)
    assert.equals(25, explorer.manual_width)

    require("codediff.ui.layout").arrange(tabpage)
    render.fit_panel_width(explorer)
    require("codediff.ui.explorer.refresh").refresh(explorer)
    vim.wait(1000)
    assert.equals(25, vim.api.nvim_win_get_width(explorer.winid))
  end)

  it("does not treat its own resizes as manual", function()
    local explorer = open_explorer()
    local render = require("codediff.ui.explorer.render")
    render.fit_panel_width(explorer)
    render.detect_manual_resize(explorer)
    require("codediff.ui.layout").arrange(vim.api.nvim_get_current_tabpage())
    render.detect_manual_resize(explorer)
    assert.is_nil(explorer.manual_width)
  end)
end)
