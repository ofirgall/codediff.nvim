-- Viewed state for the revision-mode explorer: group aggregates and toggling.
-- Everything here is a no-op without explorer.review_ctx (status and directory mode).
local M = {}

--- Collect the file nodes at or under `node`, expanded or not.
---@return table[] file nodes
function M.collect_files(tree, node)
  local files = {}
  local function walk(n)
    if not n.data then
      return
    end
    if not n.data.type then
      files[#files + 1] = n
      return
    end
    for _, id in ipairs(n:get_child_ids()) do
      local child = tree:get_node(id)
      if child then
        walk(child)
      end
    end
  end
  walk(node)
  return files
end

--- Recompute review group aggregates (viewed count, ins/del of unviewed files) from the file nodes.
--- Call after any change to `data.viewed` or to line stats. Does not render.
function M.recompute(tree)
  for _, root in ipairs(tree:get_nodes()) do
    local review = root.data and root.data.review
    if review then
      review.viewed, review.ins, review.del = 0, 0, 0
      for _, file in ipairs(M.collect_files(tree, root)) do
        if file.data.viewed then
          review.viewed = review.viewed + 1
        else
          review.ins = review.ins + math.max(file.data.insertions or 0, 0)
          review.del = review.del + math.max(file.data.deletions or 0, 0)
        end
      end
      review.total = #M.collect_files(tree, root)
      if root.data.name ~= "unstaged" then
        root.text = string.format("%s %d/%d", review.name, review.viewed, review.total)
      end
    end
  end
end

-- Render while keeping the explorer cursor where it was
local function render_keep_cursor(explorer)
  local win = explorer.winid
  local cursor
  if win and vim.api.nvim_win_is_valid(win) then
    cursor = vim.api.nvim_win_get_cursor(win)
  end
  explorer.tree:render()
  if cursor then
    local count = vim.api.nvim_buf_line_count(explorer.tree._bufnr)
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], count), cursor[2] })
  end
end

--- Re-render after aggregate changes (numstat patches, toggles).
function M.refresh_view(explorer)
  M.recompute(explorer.tree)
  render_keep_cursor(explorer)
end

--- Set the viewed state of the given file nodes, persist, re-render, and emit CodeDiffViewedChange.
--- Files without a known diff blob cannot be persisted and are skipped with a warning.
---@return string[] paths that changed
function M.set_viewed(explorer, file_nodes, viewed)
  local ctx = explorer.review_ctx
  if not ctx then
    return {}
  end
  local list, paths, missing = {}, {}, {}
  for _, node in ipairs(file_nodes) do
    local path = node.data.path
    local blob = ctx.blobs[path]
    if blob then
      list[#list + 1] = { path = path, old = blob.old, new = blob.new, viewed = viewed }
      paths[#paths + 1] = path
      node.data.viewed = viewed
    else
      missing[#missing + 1] = path
    end
  end
  if #missing > 0 then
    vim.notify("codediff: cannot track viewed state (no diff blob): " .. table.concat(missing, ", "), vim.log.levels.WARN)
  end
  if #list == 0 then
    return {}
  end
  ctx.store:set_many(list)
  M.refresh_view(explorer)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffViewedChange",
    modeline = false,
    data = { tabpage = explorer.tabpage, paths = paths, viewed = viewed },
  })
  return paths
end

--- Toggle viewed on a file, directory or group node: any unviewed -> mark all, else unmark all.
function M.toggle_node(explorer, node)
  if not explorer.review_ctx or not node or not node.data then
    return
  end
  local files = M.collect_files(explorer.tree, node)
  if #files == 0 then
    return
  end
  local any_unviewed = false
  for _, f in ipairs(files) do
    if not f.data.viewed then
      any_unviewed = true
      break
    end
  end
  M.set_viewed(explorer, files, any_unviewed)
end

--- Toggle viewed on the file shown in the diff panes.
function M.toggle_current(explorer)
  if not explorer or not explorer.review_ctx or not explorer.current_file_path then
    return
  end
  local refresh = require("codediff.ui.explorer.refresh")
  for _, f in ipairs(refresh.get_all_files(explorer.tree, { include_collapsed = true })) do
    if f.data.path == explorer.current_file_path and f.data.group == explorer.current_file_group then
      M.toggle_node(explorer, f.node)
      return
    end
  end
end

return M
