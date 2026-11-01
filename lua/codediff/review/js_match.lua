-- Native JavaScript regex matching for review groups, run through node (match.mjs).
local M = {}

local script = debug.getinfo(1, "S").source:sub(2):gsub("js_match%.lua$", "match.mjs")

--- Path to the node executable, or nil when it is not on PATH.
---@return string|nil
function M.node()
  local path = vim.fn.exepath("node")
  return path ~= "" and path or nil
end

--- Match every file against every group's patterns.
--- cb(err, result) runs on the main loop. err: node could not run or answered garbage.
--- result: { errors = { {group, pattern, message} }, matches = { [path] = { group_index, ... } } }
---@param node string node executable
---@param groups string[][] patterns per group, in config order
---@param files string[]
---@param cb fun(err: string|nil, result: table|nil)
function M.run(node, groups, files, cb)
  local stdin = vim.json.encode({ groups = groups, files = files })
  local ok, err = pcall(vim.system, { node, script }, { stdin = stdin, text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(string.format("node exited with %d: %s", res.code, vim.trim(res.stderr or "")), nil)
        return
      end
      local dok, decoded = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
      if not dok or type(decoded) ~= "table" then
        cb("node returned invalid output: " .. vim.trim(res.stdout or ""), nil)
        return
      end
      decoded.errors = decoded.errors or {}
      decoded.matches = decoded.matches or {}
      cb(nil, decoded)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb("failed to start node: " .. tostring(err), nil)
    end)
  end
end

M._script = script

return M
