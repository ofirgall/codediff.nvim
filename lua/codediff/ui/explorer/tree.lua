-- Tree data structure building for explorer
-- Handles creating the tree hierarchy from git status
local M = {}

local Tree = require("codediff.ui.lib.tree")
local config = require("codediff.config")
local filter = require("codediff.ui.explorer.filter")
local nodes = require("codediff.ui.explorer.nodes")
local grouping = require("codediff.review.grouping")

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
local function filter_files(files)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local ignore_patterns = file_filter.ignore or {}

  return filter.apply(files, ignore_patterns)
end

-- Build review group nodes (revision mode with a review context).
-- With no rules (no valid config, no generated files) a single `Changes` group is built.
-- Each file node gets `review_group` and `viewed`; group nodes get `data.review`:
--   { name, auto_viewed, total, viewed, ins, del, default_collapsed }
-- (ins/del sum the unviewed files' line stats as known at build time.)
local function create_review_nodes(unstaged, git_root, review_ctx, view_mode)
  local pr = (config.options.explorer or {}).pr_review or {}
  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes

  local buckets
  if review_ctx.has_rules then
    buckets = grouping.order(unstaged, review_ctx.compiled).groups
  else
    buckets = { { name = "Changes", auto_viewed = false, files = unstaged, single = true } }
  end

  local result = {}
  for _, bucket in ipairs(buckets) do
    if #bucket.files > 0 or bucket.single then
      local review = {
        name = bucket.name,
        auto_viewed = bucket.auto_viewed,
        total = #bucket.files,
        viewed = 0,
        ins = 0,
        del = 0,
        default_collapsed = not bucket.single and (bucket.auto_viewed or pr.collapse_groups == true),
      }
      local viewed_by_path = {}
      for _, file in ipairs(bucket.files) do
        local v = review_ctx.is_viewed(file.path, bucket)
        viewed_by_path[file.path] = v
        if v then
          review.viewed = review.viewed + 1
        else
          review.ins = review.ins + math.max(file.insertions or 0, 0)
          review.del = review.del + math.max(file.deletions or 0, 0)
        end
      end

      local group_key = "review:" .. bucket.name
      local file_nodes = create_nodes(bucket.files, git_root, "unstaged", {
        file_data = function(file)
          return { review_group = bucket.name, viewed = viewed_by_path[file.path] }
        end,
        dir_data = function(dir_path)
          -- Directory nodes have no path; give refresh a key that is distinct per group
          return { collapse_key = group_key .. "/" .. dir_path }
        end,
      })

      local text, name
      if bucket.single then
        text = string.format("Changes (%d)", review.total)
        name = "unstaged" -- keeps today's group identity for the plain case
      else
        text = string.format("%s %d/%d", bucket.name, review.viewed, review.total)
        name = group_key
      end
      result[#result + 1] = Tree.Node({
        text = text,
        data = { type = "group", name = name, review = review },
      }, file_nodes)
    end
  end
  return result
end

-- Create tree data structure from git status result
-- review_ctx (optional): review context (revision mode only), see review/context.lua
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode, visible_groups, review_ctx)
  local explorer_config = config.options.explorer or {}
  local view_mode = explorer_config.view_mode or "list"
  visible_groups = visible_groups or explorer_config.visible_groups or {}

  -- Filter merge artifacts and apply file filter
  local unstaged = nodes.filter_merge_artifacts(filter_files(status_result.unstaged))
  local staged = nodes.filter_merge_artifacts(filter_files(status_result.staged))
  local conflicts = status_result.conflicts and nodes.filter_merge_artifacts(filter_files(status_result.conflicts)) or {}

  if review_ctx and base_revision and not is_dir_mode then
    return create_review_nodes(unstaged, git_root, review_ctx, view_mode)
  end

  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes
  local unstaged_nodes = create_nodes(unstaged, git_root, "unstaged")
  local staged_nodes = create_nodes(staged, git_root, "staged")
  local conflict_nodes = create_nodes(conflicts, git_root, "conflicts")

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes
    return {
      Tree.Node({
        text = string.format("Changes (%d)", #unstaged),
        data = { type = "group", name = "unstaged" },
      }, unstaged_nodes),
    }
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}

    -- Conflicts first (most important)
    if #conflict_nodes > 0 and visible_groups.conflicts ~= false then
      table.insert(
        tree_nodes,
        Tree.Node({
          text = string.format("Merge Changes (%d)", #conflicts),
          data = { type = "group", name = "conflicts" },
        }, conflict_nodes)
      )
    end

    -- Unstaged changes
    if visible_groups.unstaged ~= false then
      table.insert(
        tree_nodes,
        Tree.Node({
          text = string.format("Changes (%d)", #unstaged),
          data = { type = "group", name = "unstaged" },
        }, unstaged_nodes)
      )
    end

    -- Staged changes
    if visible_groups.staged ~= false then
      table.insert(
        tree_nodes,
        Tree.Node({
          text = string.format("Staged Changes (%d)", #staged),
          data = { type = "group", name = "staged" },
        }, staged_nodes)
      )
    end

    return tree_nodes
  end
end

return M
