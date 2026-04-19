-- vscode-diff main API
local M = {}

-- Configuration setup
function M.setup(opts)
  local config = require("codediff.config")
  config.setup(opts)

  local render = require("codediff.ui")
  render.setup_highlights()
end

-- Navigate to next hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.next_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_hunk()
end

-- Navigate to previous hunk in the current diff view
-- Returns true if navigation succeeded, false otherwise
function M.prev_hunk()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_hunk()
end

-- Navigate to next file in explorer/history mode
-- In single-file history mode, navigates to next commit instead
-- Returns true if navigation succeeded, false otherwise
function M.next_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.next_file()
end

-- Navigate to previous file in explorer/history mode
-- In single-file history mode, navigates to previous commit instead
-- Returns true if navigation succeeded, false otherwise
function M.prev_file()
  local navigation = require("codediff.ui.view.navigation")
  return navigation.prev_file()
end

-- ============================================================================
-- Hunk info API
-- ============================================================================

-- Cache for async staged hunk count computation
-- { [tabpage] = { path, count, diff_ref } }
local _staged_cache = {}

-- Compute staged hunk count for a file (HEAD vs index)
-- Returns cached count, or nil if still computing (triggers async computation)
local function _compute_staged_count(tabpage, session)
  local lifecycle = require("codediff.ui.lifecycle")
  local file_path = session.original_path or session.modified_path
  local git_root = session.git_root
  if not git_root or not file_path then
    return nil
  end

  local cache = _staged_cache[tabpage]

  -- Return cached value if valid (same file + same diff generation)
  if cache and cache.path == file_path and cache.diff_ref == session.stored_diff_result then
    return cache.count -- nil means still computing
  end

  -- Quick check: does file have staged changes in explorer status?
  local explorer = lifecycle.get_explorer(tabpage)
  if explorer and explorer.status_result then
    local has_staged = false
    for _, f in ipairs(explorer.status_result.staged or {}) do
      if f.path == file_path then
        has_staged = true
        break
      end
    end
    if not has_staged then
      _staged_cache[tabpage] = { path = file_path, count = 0, diff_ref = session.stored_diff_result }
      return 0
    end
  end

  -- Start async computation
  local diff_ref = session.stored_diff_result
  _staged_cache[tabpage] = { path = file_path, count = nil, diff_ref = diff_ref }

  local git = require("codediff.core.git")

  git.get_file_content("HEAD", git_root, file_path, function(err1, head_lines)
    head_lines = head_lines or {}

    git.get_file_content(":0", git_root, file_path, function(err2, index_lines)
      vim.schedule(function()
        local c = _staged_cache[tabpage]
        if not c or c.path ~= file_path or c.diff_ref ~= diff_ref then
          return -- cache was invalidated while we were computing
        end

        if err2 then
          c.count = 0
        else
          local diff = require("codediff.core.diff")
          local config = require("codediff.config")
          local result = diff.compute_diff(head_lines, index_lines, {
            ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
            max_computation_time_ms = config.options.diff.max_computation_time_ms,
          })
          c.count = result and result.changes and #result.changes or 0
        end

        pcall(vim.cmd, "redrawstatus")
      end)
    end)
  end)

  return nil -- not ready yet
end

-- Get hunk information for the current diff view
-- Returns nil if no active diff session, otherwise a table:
--   total: number of hunks in the current diff
--   current: 1-based index of hunk at cursor (0 if cursor is not inside a hunk)
--   staged_total: number of staged hunks for this file, or nil if not applicable/not yet computed
function M.get_hunk_info()
  local lifecycle = require("codediff.ui.lifecycle")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or not session.stored_diff_result then
    return nil
  end

  local diff_result = session.stored_diff_result
  local total = diff_result.changes and #diff_result.changes or 0

  -- Find current hunk index from cursor position
  local current = 0
  if total > 0 then
    local current_buf = vim.api.nvim_get_current_buf()
    local is_inline = session.layout == "inline"
    local is_original = not is_inline and current_buf == session.original_bufnr
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
    if ok then
      local cursor_line = cursor[1]
      for i, mapping in ipairs(diff_result.changes) do
        local start_line = is_original and mapping.original.start_line or mapping.modified.start_line
        local end_line = is_original and mapping.original.end_line or mapping.modified.end_line
        if cursor_line >= start_line and cursor_line < end_line then
          current = i
          break
        end
        if start_line == end_line and cursor_line == start_line then
          current = i
          break
        end
      end
    end
  end

  -- Staged hunk count
  local staged_total = nil
  if session.modified_revision == ":0" then
    -- Viewing staged changes: all shown hunks are staged
    staged_total = total
  elseif session.git_root and session.modified_revision == nil then
    -- Viewing unstaged changes: compute staged count async
    staged_total = _compute_staged_count(tabpage, session)
  end

  return {
    total = total,
    current = current,
    staged_total = staged_total,
  }
end

return M
