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

-- Collapse key of a group/directory node (same key refresh uses to keep collapsed state)
local function container_key(node)
  return node.data and (node.data.collapse_key or node.data.name)
end

-- Whether a container holds files with a viewed state (review mode)
local function nodes_has_review(n)
  return require("codediff.ui.explorer.nodes").aggregate(n).review
end

--- Keys of the review groups/directories whose files are all viewed.
---@return table<string, boolean>
function M.done_keys(tree)
  local nodes = require("codediff.ui.explorer.nodes")
  local done = {}
  local function walk(n)
    local d = n.data or {}
    if d.type ~= "group" and d.type ~= "directory" then
      return
    end
    local agg = nodes.aggregate(n)
    local key = container_key(n)
    if key and agg.review and agg.total > 0 and agg.viewed == agg.total then
      done[key] = true
    end
    for _, child in ipairs(n._children or {}) do
      walk(child)
    end
  end
  for _, root in ipairs(tree:get_nodes()) do
    walk(root)
  end
  return done
end

--- Open or close review groups/directories as their viewed state changes (as fast-pr does):
--- one that became fully viewed since `before` collapses; one that was fully viewed in `before`
--- and now has unviewed files expands, with its ancestors so it is visible.
--- Unchanged ones keep whatever state the user left them in. Does not render.
---@param before table<string, boolean> done_keys() from earlier
---@return boolean changed
function M.sync_collapsed(tree, before)
  local changed = false
  local done = M.done_keys(tree)
  local function expand_with_ancestors(n)
    while n do
      if not n:is_expanded() then
        n:expand()
        changed = true
      end
      n = n._parent_id and tree:get_node(n._parent_id) or nil
    end
  end
  local function walk(n)
    local d = n.data or {}
    if d.type ~= "group" and d.type ~= "directory" then
      return
    end
    local key = container_key(n)
    if key and done[key] and not before[key] and n:is_expanded() then
      n:collapse()
      changed = true
    elseif key and before[key] and not done[key] and nodes_has_review(n) then
      expand_with_ancestors(n)
    end
    for _, child in ipairs(n._children or {}) do
      walk(child)
    end
  end
  for _, root in ipairs(tree:get_nodes()) do
    walk(root)
  end
  return changed
end

-- Render while keeping the explorer cursor on the same node; when that node got hidden
-- by a collapse, the cursor moves to its closest visible ancestor.
local function render_keep_cursor(explorer)
  local tree = explorer.tree
  local win = explorer.winid
  local cursor, cursor_node
  if win and vim.api.nvim_win_is_valid(win) then
    cursor = vim.api.nvim_win_get_cursor(win)
    cursor_node = tree:get_node(cursor[1])
  end
  tree:render()
  if not cursor then
    return
  end
  local target = cursor_node
  while target and not target._line do
    target = target._parent_id and tree:get_node(target._parent_id) or nil
  end
  local count = vim.api.nvim_buf_line_count(tree._bufnr)
  local line = target and target._line or math.min(cursor[1], count)
  pcall(vim.api.nvim_win_set_cursor, win, { line, cursor[2] })
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
  local done_before = M.done_keys(explorer.tree)
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
  M.sync_collapsed(explorer.tree, done_before)
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
