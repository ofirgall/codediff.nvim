-- Assign files to review groups and order them. Port of github-fast-pr src/core/grouping.ts.
local M = {}

M.UNGROUPED = "Ungrouped"

--- The matching group with the highest match priority; ties go to the earliest.
---@param path string
---@param groups ReviewCompiledGroup[]
---@return ReviewCompiledGroup|nil
function M.assign(path, groups)
  local best = nil
  for _, g in ipairs(groups) do
    if g.match(path) and (not best or g.match_priority > best.match_priority) then
      best = g
    end
  end
  return best
end

---@class ReviewGroupResult
---@field name string
---@field auto_viewed boolean
---@field files any[] original file items (strings or tables with .path), original order

--- Group and order files. `files` items are path strings or tables with a `path` field.
---@param files any[]
---@param compiled ReviewCompiled
---@return { groups: ReviewGroupResult[], assignment: table<string, string>, ordered: {file: any, group: string}[] }
function M.order(files, compiled)
  local groups = compiled.groups
  local ungrouped_view = compiled.ungrouped_view_priority
  local entries = {}
  for i, f in ipairs(files) do
    local path = type(f) == "string" and f or f.path
    entries[i] = { file = f, path = path, group = M.assign(path, groups), i = i }
  end
  local function view(g)
    return g and g.view_priority or ungrouped_view
  end
  local function sort_key(g)
    return g and g.index or (#groups + 1)
  end
  table.sort(entries, function(a, b)
    local va, vb = view(a.group), view(b.group)
    if va ~= vb then
      return va > vb
    end
    local ka, kb = sort_key(a.group), sort_key(b.group)
    if ka ~= kb then
      return ka < kb
    end
    return a.i < b.i
  end)
  local result = { groups = {}, assignment = {}, ordered = {} }
  local by_name = {}
  for _, e in ipairs(entries) do
    local name = e.group and e.group.name or M.UNGROUPED
    local key = e.group or by_name -- by_name doubles as the Ungrouped key
    local bucket = by_name[key]
    if not bucket then
      bucket = { name = name, auto_viewed = e.group and e.group.auto_viewed or false, files = {} }
      by_name[key] = bucket
      result.groups[#result.groups + 1] = bucket
    end
    bucket.files[#bucket.files + 1] = e.file
    result.assignment[e.path] = name
    result.ordered[#result.ordered + 1] = { file = e.file, group = name }
  end
  return result
end

return M
