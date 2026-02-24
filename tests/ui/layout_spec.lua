-- Test: layout.lua - Centralized window layout manager
-- Exhaustive tests for all layout cases validating window widths/heights

local layout = require("codediff.ui.layout")
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

-- Tolerance for width assertions (Neovim may round or add separators)
local WIDTH_TOLERANCE = 2

local function assert_width_near(expected, actual, msg)
  assert.is_true(
    math.abs(expected - actual) <= WIDTH_TOLERANCE,
    (msg or "") .. " expected ~" .. expected .. " got " .. actual
  )
end

-- Create a mock session in lifecycle so layout.arrange() can read it
local function create_mock_session(tabpage, opts)
  -- Directly inject into lifecycle's active_diffs
  local session_mod = require("codediff.ui.lifecycle.session")
  local active_diffs = session_mod.get_active_diffs()
  active_diffs[tabpage] = {
    mode = opts.mode or "standalone",
    original_win = opts.original_win,
    modified_win = opts.modified_win,
    result_win = opts.result_win,
    explorer = opts.panel,
    original_bufnr = opts.original_bufnr,
    modified_bufnr = opts.modified_bufnr,
  }
end

local function cleanup_mock_session(tabpage)
  local session_mod = require("codediff.ui.lifecycle.session")
  local active_diffs = session_mod.get_active_diffs()
  active_diffs[tabpage] = nil
end

-- Create a panel-like object mimicking explorer/history split
local function create_panel_split(position, size)
  local Split = require("codediff.ui.lib.split")
  local split = Split({
    position = position,
    size = size,
    buf_options = { modifiable = false, readonly = true },
    win_options = { number = false, signcolumn = "no" },
  })
  split:mount()
  return {
    winid = split.winid,
    split = split,
    is_hidden = false,
  }
end

describe("Layout Manager", function()
  local saved_config

  before_each(function()
    -- Save and reset config to defaults
    saved_config = vim.deepcopy(config.options)
  end)

  after_each(function()
    -- Restore config
    config.options = saved_config
    -- Close all extra tabs
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    -- Close all extra windows in remaining tab
    while vim.fn.winnr("$") > 1 do
      vim.cmd("only!")
    end
  end)

  -- =========================================================================
  -- Case 1: No panel, no result — [orig | mod]
  -- =========================================================================
  it("Case 1: Two panes without panel get equal widths", function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    create_mock_session(tabpage, {
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
    })

    layout.arrange(tabpage)

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)
    assert_width_near(orig_w, mod_w, "Both panes should be equal width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 1b: Standalone + result bottom — [orig | mod] / [result]
  -- =========================================================================
  it("Case 1b: Standalone + result bottom — diff panes equal, result height set", function()
    config.options.diff.conflict_result_position = "bottom"
    config.options.diff.conflict_result_height = 25

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    -- Create result window below (mimicking real create_bottom_layout)
    local scratch = vim.api.nvim_create_buf(false, true)
    local result_win = vim.api.nvim_open_win(scratch, true, { split = "below", win = mod_win })
    vim.fn.win_splitmove(orig_win, mod_win, { vertical = true, rightbelow = false })

    create_mock_session(tabpage, {
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
    })

    layout.arrange(tabpage)

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)
    local result_h = vim.api.nvim_win_get_height(result_win)
    local expected_h = math.floor(vim.o.lines * 25 / 100)

    assert_width_near(orig_w, mod_w, "Diff panes should be equal:")
    assert_width_near(expected_h, result_h, "Result height should match configured %:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 1c: Standalone + result center — [orig | result | mod]
  -- =========================================================================
  it("Case 1c: Standalone + result center — 3 panes follow ratio, no panel", function()
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 1, 1 }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    -- Create result window between orig and mod
    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
    })

    layout.arrange(tabpage)

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local result_w = vim.api.nvim_win_get_width(result_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert_width_near(orig_w, result_w, "All three panes should be similar (1:1:1):")
    assert_width_near(result_w, mod_w, "All three panes should be similar (1:1:1):")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 2: Explorer left, no result — [expl | orig | mod]
  -- =========================================================================
  it("Case 2: Explorer left — panel gets configured width, diff panes split remainder", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_w = vim.api.nvim_win_get_width(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_width, panel_w, "Panel should be configured width")
    assert_width_near(orig_w, mod_w, "Diff panes should be equal width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 3: Explorer bottom, no result — [orig | mod] / [expl]
  -- =========================================================================
  it("Case 3: Explorer bottom — panel gets configured height, diff panes split full width", function()
    local panel_height = 12
    config.options.explorer = { position = "bottom", height = panel_height }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("bottom", panel_height)

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_h = vim.api.nvim_win_get_height(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_height, panel_h, "Panel should be configured height")
    assert_width_near(orig_w, mod_w, "Diff panes should be equal width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 4: History left, no result — [hist | orig | mod]
  -- =========================================================================
  it("Case 4: History left — panel gets configured width, diff panes split remainder", function()
    local panel_width = 30
    config.options.history = { position = "left", width = panel_width }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    create_mock_session(tabpage, {
      mode = "history",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_w = vim.api.nvim_win_get_width(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_width, panel_w, "History panel should be configured width")
    assert_width_near(orig_w, mod_w, "Diff panes should be equal width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 5: History bottom, no result — [orig | mod] / [hist]
  -- =========================================================================
  it("Case 5: History bottom — panel gets configured height, diff panes split full width", function()
    local panel_height = 10
    config.options.history = { position = "bottom", height = panel_height }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("bottom", panel_height)

    create_mock_session(tabpage, {
      mode = "history",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_h = vim.api.nvim_win_get_height(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_height, panel_h, "History panel should be configured height")
    assert_width_near(orig_w, mod_w, "Diff panes should be equal width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 6: Explorer left + result bottom — [expl | orig | mod] / [result]
  -- =========================================================================
  it("Case 6: Explorer left + result bottom — panel width preserved, diff panes equal", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }
    config.options.diff.conflict_result_position = "bottom"
    config.options.diff.conflict_result_height = 30

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    -- Create result window below (mimicking real create_bottom_layout)
    local scratch = vim.api.nvim_create_buf(false, true)
    local result_win = vim.api.nvim_open_win(scratch, true, { split = "below", win = mod_win })
    vim.fn.win_splitmove(orig_win, mod_win, { vertical = true, rightbelow = false })

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_w = vim.api.nvim_win_get_width(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_width, panel_w, "Panel width should be preserved")
    assert_width_near(orig_w, mod_w, "Diff panes should be equal width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 7: Explorer left + result center — [expl | orig | result | mod]
  -- =========================================================================
  it("Case 7: Explorer left + result center — panel width preserved, 3 panes follow ratio", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 1, 1 }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    -- Create result window between orig and mod (split right of orig)
    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_w = vim.api.nvim_win_get_width(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local result_w = vim.api.nvim_win_get_width(result_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_width, panel_w, "Panel width should be preserved")
    -- With 1:1:1 ratio, all three should be approximately equal
    assert_width_near(orig_w, result_w, "Orig and result should be similar (1:1:1):")
    assert_width_near(result_w, mod_w, "Result and mod should be similar (1:1:1):")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 7b: Explorer left + result center with custom ratio (1, 2, 1)
  -- =========================================================================
  it("Case 7b: Explorer left + result center — custom ratio 1:2:1 honored", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 2, 1 }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_w = vim.api.nvim_win_get_width(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local result_w = vim.api.nvim_win_get_width(result_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_width, panel_w, "Panel width should be preserved")
    -- With 1:2:1 ratio, result should be ~2x the side panes
    assert_width_near(orig_w, mod_w, "Side panes should be equal (1:_:1):")
    assert.is_true(
      result_w >= orig_w * 1.5,
      "Result should be ~2x side panes (1:2:1): result=" .. result_w .. " side=" .. orig_w
    )

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 8: Explorer bottom + result bottom — [orig | mod] / [result] / [expl]
  -- =========================================================================
  it("Case 8: Explorer bottom + result bottom — both heights correct, diff panes equal", function()
    local panel_height = 12
    config.options.explorer = { position = "bottom", height = panel_height }
    config.options.diff.conflict_result_position = "bottom"
    config.options.diff.conflict_result_height = 25

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("bottom", panel_height)

    -- Create result window below (mimicking real create_bottom_layout)
    local scratch = vim.api.nvim_create_buf(false, true)
    local result_win = vim.api.nvim_open_win(scratch, true, { split = "below", win = mod_win })
    vim.fn.win_splitmove(orig_win, mod_win, { vertical = true, rightbelow = false })

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_h = vim.api.nvim_win_get_height(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_height, panel_h, "Panel height should be preserved")
    assert_width_near(orig_w, mod_w, "Diff panes should be equal width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Case 9: Explorer bottom + result center — [orig | result | mod] / [expl]
  -- =========================================================================
  it("Case 9: Explorer bottom + result center — panel height preserved, 3 panes follow ratio", function()
    local panel_height = 12
    config.options.explorer = { position = "bottom", height = panel_height }
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 1, 1 }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("bottom", panel_height)

    -- Create result window between orig and mod
    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel = panel,
    })

    layout.arrange(tabpage)

    local panel_h = vim.api.nvim_win_get_height(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local result_w = vim.api.nvim_win_get_width(result_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_height, panel_h, "Panel height should be preserved")
    assert_width_near(orig_w, result_w, "All three panes should be similar (1:1:1):")
    assert_width_near(result_w, mod_w, "All three panes should be similar (1:1:1):")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Idempotency: calling arrange() twice produces the same result
  -- =========================================================================
  it("Idempotent: calling arrange twice produces same widths", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 2, 1 }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel = panel,
    })

    layout.arrange(tabpage)

    local first_panel_w = vim.api.nvim_win_get_width(panel.winid)
    local first_orig_w = vim.api.nvim_win_get_width(orig_win)
    local first_result_w = vim.api.nvim_win_get_width(result_win)
    local first_mod_w = vim.api.nvim_win_get_width(mod_win)

    layout.arrange(tabpage)

    local second_panel_w = vim.api.nvim_win_get_width(panel.winid)
    local second_orig_w = vim.api.nvim_win_get_width(orig_win)
    local second_result_w = vim.api.nvim_win_get_width(result_win)
    local second_mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(first_panel_w, second_panel_w, "Panel width should be stable")
    assert.are.equal(first_orig_w, second_orig_w, "Original width should be stable")
    assert.are.equal(first_result_w, second_result_w, "Result width should be stable")
    assert.are.equal(first_mod_w, second_mod_w, "Modified width should be stable")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- No session: arrange should be a no-op
  -- =========================================================================
  it("No-op when no session exists for tabpage", function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    -- Should not error
    layout.arrange(tabpage)
  end)

  -- =========================================================================
  -- Hidden panel: diff panes should use full width
  -- =========================================================================
  it("Hidden panel: diff panes use full width when panel is hidden", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)
    -- Hide the panel
    panel.split:hide()
    panel.is_hidden = true

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      panel = panel,
    })

    layout.arrange(tabpage)

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert_width_near(orig_w, mod_w, "Diff panes should be equal when panel hidden:")
    -- With panel hidden, each pane should be roughly half of total columns
    local expected_half = math.floor(vim.o.columns / 2)
    assert_width_near(expected_half, orig_w, "Each pane should be ~half of total width:")

    cleanup_mock_session(tabpage)
  end)

  -- =========================================================================
  -- Hidden panel + center result: 3 panes use full width
  -- =========================================================================
  it("Hidden panel + center result: 3 panes use full width when panel is hidden", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 1, 1 }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)
    panel.split:hide()
    panel.is_hidden = true

    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      mode = "explorer",
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel = panel,
    })

    layout.arrange(tabpage)

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local result_w = vim.api.nvim_win_get_width(result_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    -- All three should be ~1/3 of total columns
    assert_width_near(orig_w, result_w, "All three panes equal (1:1:1):")
    assert_width_near(result_w, mod_w, "All three panes equal (1:1:1):")
    local expected_third = math.floor(vim.o.columns / 3)
    assert_width_near(expected_third, orig_w, "Each pane should be ~1/3 of total:")

    cleanup_mock_session(tabpage)
  end)
end)
