-- Panel setup for explorer and history sidebars
-- Shared utility used by both side-by-side and inline view engines
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

-- Eagerly load explorer and history to avoid lazy require failures
-- when CWD changes in vim.schedule callbacks
local explorer_module = require("codediff.ui.explorer")
local history_module = require("codediff.ui.history")
local layout = require("codediff.ui.layout")

--- Invoke the diff.on_layout_change hook (if any) and merge the returned
--- override table into config.options. Shared by initial panel setup and by
--- the layout-toggle flow so the hook runs in both places.
---@param tabpage number
---@param previous string|nil  -- previous layout, or nil on first run
---@param current string       -- current layout
local function apply_layout_change_hook(tabpage, previous, current)
  local hook = config.options.diff and config.options.diff.on_layout_change
  if type(hook) ~= "function" then
    return
  end
  local ok, overrides = pcall(hook, { tabpage = tabpage, previous = previous, current = current })
  if not ok then
    vim.notify("codediff: on_layout_change hook error: " .. tostring(overrides), vim.log.levels.WARN)
  elseif type(overrides) == "table" then
    config.options = vim.tbl_deep_extend("force", config.options, overrides)
  end
end

M.apply_layout_change_hook = apply_layout_change_hook

--- Create explorer sidebar for a diff tabpage
---@param tabpage number
---@param session_config SessionConfig
---@param original_win number
---@param modified_win number
function M.setup_explorer(tabpage, session_config, original_win, modified_win)
  if not (session_config.mode == "explorer" and session_config.explorer_data) then
    return
  end

  local session = lifecycle.get_session(tabpage)
  apply_layout_change_hook(tabpage, nil, session and session.layout or config.options.diff.layout)

  local explorer_config = config.options.explorer or {}
  local status_result = session_config.explorer_data.status_result

  local explorer_opts = {}
  if not session_config.git_root then
    explorer_opts.dir1 = session_config.original_path
    explorer_opts.dir2 = session_config.modified_path
  end
  if session_config.explorer_data.focus_file then
    explorer_opts.focus_file = session_config.explorer_data.focus_file
  end

  local explorer_obj =
    explorer_module.create(status_result, session_config.git_root, tabpage, nil, session_config.original_revision, session_config.modified_revision, explorer_opts)

  lifecycle.set_explorer(tabpage, explorer_obj)

  local initial_focus = explorer_config.initial_focus or "explorer"
  if initial_focus == "explorer" and explorer_obj and explorer_obj.winid and vim.api.nvim_win_is_valid(explorer_obj.winid) then
    vim.api.nvim_set_current_win(explorer_obj.winid)
  elseif initial_focus == "original" and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  elseif initial_focus == "modified" and vim.api.nvim_win_is_valid(modified_win) then
    vim.api.nvim_set_current_win(modified_win)
  end

  layout.arrange(tabpage)
end

--- Create history panel for a diff tabpage
---@param tabpage number
---@param session_config SessionConfig
---@param original_win number
---@param modified_win number
---@param original_bufnr number
---@param modified_bufnr number
---@param setup_keymaps_fn function
function M.setup_history(tabpage, session_config, original_win, modified_win, original_bufnr, modified_bufnr, setup_keymaps_fn)
  if not (session_config.mode == "history" and session_config.history_data) then
    return
  end

  local session = lifecycle.get_session(tabpage)
  apply_layout_change_hook(tabpage, nil, session and session.layout or config.options.diff.layout)

  local history_config = config.options.history or {}
  local commits = session_config.history_data.commits

  local history_obj = history_module.create(commits, session_config.git_root, tabpage, nil, {
    range = session_config.history_data.range,
    file_path = session_config.history_data.file_path,
    base_revision = session_config.history_data.base_revision,
    line_range = session_config.history_data.line_range,
  })

  lifecycle.set_explorer(tabpage, history_obj)

  local initial_focus = history_config.initial_focus or "history"
  if initial_focus == "history" and history_obj and history_obj.winid and vim.api.nvim_win_is_valid(history_obj.winid) then
    vim.api.nvim_set_current_win(history_obj.winid)
  elseif initial_focus == "original" and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  elseif initial_focus == "modified" and vim.api.nvim_win_is_valid(modified_win) then
    vim.api.nvim_set_current_win(modified_win)
  end

  layout.arrange(tabpage)

  -- History mode needs keymaps set after session is created
  setup_keymaps_fn(tabpage, original_bufnr, modified_bufnr)
end

--- Rebuild the explorer/history panel from scratch so the new config values
--- (position, view_mode, width/height, etc.) take effect. Preserves selection
--- and group visibility across the rebuild. Safe to call unconditionally;
--- it's a no-op for standalone sessions.
---@param tabpage number
function M.rebuild(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end

  local panel = session.explorer
  if not panel or not panel.split then
    return
  end

  local mode = session.mode
  if mode ~= "explorer" and mode ~= "history" then
    return
  end

  local preserved_file = panel.current_file_path
  local preserved_visible_groups = panel.visible_groups and vim.deepcopy(panel.visible_groups) or nil

  -- Move focus off the panel window before tearing it down so nvim doesn't
  -- land in an unrelated window.
  local diff_win = (session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) and session.modified_win)
    or (session.original_win and vim.api.nvim_win_is_valid(session.original_win) and session.original_win)
  if diff_win then
    pcall(vim.api.nvim_set_current_win, diff_win)
  end

  -- Stop the old panel's auto-refresh timer / fs-watcher before tearing the
  -- window down, otherwise they linger and fire against a dead explorer.
  if type(panel._cleanup_auto_refresh) == "function" then
    pcall(panel._cleanup_auto_refresh)
  end

  local old_winid = panel.split.winid
  local old_bufnr = panel.split.bufnr
  if old_winid and vim.api.nvim_win_is_valid(old_winid) then
    pcall(vim.api.nvim_win_close, old_winid, true)
  end
  if old_bufnr and vim.api.nvim_buf_is_valid(old_bufnr) then
    pcall(vim.api.nvim_buf_delete, old_bufnr, { force = true })
  end

  local new_panel
  if mode == "explorer" then
    local opts = {
      dir1 = panel.dir1,
      dir2 = panel.dir2,
      focus_file = preserved_file,
    }
    new_panel =
      explorer_module.create(panel.status_result, panel.git_root, tabpage, nil, panel.base_revision, panel.target_revision, opts)
    if new_panel and preserved_visible_groups then
      new_panel.visible_groups = preserved_visible_groups
    end
  else
    new_panel = history_module.create(panel.commits, panel.git_root, tabpage, nil, panel.opts or {})
  end

  if new_panel then
    lifecycle.set_explorer(tabpage, new_panel)
  end

  layout.arrange(tabpage)
end

return M
