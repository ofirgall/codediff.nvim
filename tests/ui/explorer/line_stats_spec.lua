-- Test: Explorer line stats (show_line_stats feature)
-- Validates numstat parsing, merging, and node rendering

local config = require("codediff.config")

describe("Explorer line stats", function()
  local saved_config

  before_each(function()
    saved_config = vim.deepcopy(config.options)
  end)

  after_each(function()
    config.options = saved_config
  end)

  describe("numstat parsing via merge_numstat", function()
    local refresh = require("codediff.ui.explorer.refresh")

    it("merges unstaged stats into status_result files", function()
      local status_result = {
        unstaged = {
          { path = "src/init.lua", status = "M" },
          { path = "README.md", status = "M" },
        },
        staged = {},
      }
      local numstat = {
        unstaged = {
          ["src/init.lua"] = { insertions = 10, deletions = 3 },
          ["README.md"] = { insertions = 2, deletions = 0 },
        },
        staged = {},
      }

      refresh.merge_numstat(status_result, numstat)

      assert.equals(10, status_result.unstaged[1].insertions)
      assert.equals(3, status_result.unstaged[1].deletions)
      assert.equals(2, status_result.unstaged[2].insertions)
      assert.equals(0, status_result.unstaged[2].deletions)
    end)

    it("merges staged stats into status_result files", function()
      local status_result = {
        unstaged = {},
        staged = {
          { path = "lib/utils.lua", status = "A" },
        },
      }
      local numstat = {
        unstaged = {},
        staged = {
          ["lib/utils.lua"] = { insertions = 45, deletions = 0 },
        },
      }

      refresh.merge_numstat(status_result, numstat)

      assert.equals(45, status_result.staged[1].insertions)
      assert.equals(0, status_result.staged[1].deletions)
    end)

    it("marks binary files", function()
      local status_result = {
        unstaged = {
          { path = "image.png", status = "M" },
        },
        staged = {},
      }
      local numstat = {
        unstaged = {
          ["image.png"] = { insertions = -1, deletions = -1, binary = true },
        },
        staged = {},
      }

      refresh.merge_numstat(status_result, numstat)

      assert.is_true(status_result.unstaged[1].binary)
    end)

    it("leaves files without numstat data unchanged", function()
      local status_result = {
        unstaged = {
          { path = "untracked.txt", status = "??" },
        },
        staged = {},
      }
      local numstat = { unstaged = {}, staged = {} }

      refresh.merge_numstat(status_result, numstat)

      assert.is_nil(status_result.unstaged[1].insertions)
      assert.is_nil(status_result.unstaged[1].deletions)
    end)
  end)

  describe("prepare_node rendering", function()
    local nodes_module = require("codediff.ui.explorer.nodes")
    local Tree = require("codediff.ui.lib.tree")

    local function make_file_node(data)
      return Tree.Node({ text = data.path, data = data })
    end

    it("renders status symbol when show_line_stats is disabled", function()
      config.options.explorer.show_line_stats = false

      local node = make_file_node({
        path = "foo.lua",
        status = "M",
        icon = "",
        icon_color = "Normal",
        status_symbol = "M",
        status_color = "CodeDiffStatusModified",
        group = "unstaged",
        insertions = 5,
        deletions = 2,
      })

      local line = nodes_module.prepare_node(node, 40, nil, nil)
      local text = line:content()
      -- Should show M, not +5 -2
      assert.is_truthy(text:match("M%s*$"))
      assert.is_falsy(text:match("%+5"))
    end)

    it("renders +N -M when show_line_stats is enabled", function()
      config.options.explorer.show_line_stats = true

      local node = make_file_node({
        path = "foo.lua",
        status = "M",
        icon = "",
        icon_color = "Normal",
        status_symbol = "M",
        status_color = "CodeDiffStatusModified",
        group = "unstaged",
        insertions = 5,
        deletions = 2,
      })

      local line = nodes_module.prepare_node(node, 40, nil, nil)
      local text = line:content()
      assert.is_truthy(text:match("%+5"), "Should contain +5, got: " .. text)
      assert.is_truthy(text:match("%-2"), "Should contain -2, got: " .. text)
    end)

    it("omits +0 and -0 from display", function()
      config.options.explorer.show_line_stats = true

      local node_add = make_file_node({
        path = "new.lua",
        status = "A",
        icon = "",
        icon_color = "Normal",
        status_symbol = "A",
        status_color = "CodeDiffStatusAdded",
        group = "staged",
        insertions = 10,
        deletions = 0,
      })

      local line = nodes_module.prepare_node(node_add, 40, nil, nil)
      local text = line:content()
      assert.is_truthy(text:match("%+10"), "Should contain +10, got: " .. text)
      assert.is_falsy(text:match("%-0"), "Should NOT contain -0, got: " .. text)

      local node_del = make_file_node({
        path = "old.lua",
        status = "D",
        icon = "",
        icon_color = "Normal",
        status_symbol = "D",
        status_color = "CodeDiffStatusDeleted",
        group = "unstaged",
        insertions = 0,
        deletions = 7,
      })

      line = nodes_module.prepare_node(node_del, 40, nil, nil)
      text = line:content()
      assert.is_truthy(text:match("%-7"), "Should contain -7, got: " .. text)
      assert.is_falsy(text:match("%+0"), "Should NOT contain +0, got: " .. text)
    end)

    it("renders BIN for binary files when show_line_stats is enabled", function()
      config.options.explorer.show_line_stats = true

      local node = make_file_node({
        path = "image.png",
        status = "M",
        icon = "",
        icon_color = "Normal",
        status_symbol = "M",
        status_color = "CodeDiffStatusModified",
        group = "unstaged",
        insertions = -1,
        deletions = -1,
        binary = true,
      })

      local line = nodes_module.prepare_node(node, 40, nil, nil)
      local text = line:content()
      assert.is_truthy(text:match("BIN"), "Should contain BIN, got: " .. text)
    end)

    it("falls back to status symbol when no stats available", function()
      config.options.explorer.show_line_stats = true

      local node = make_file_node({
        path = "untracked.txt",
        status = "??",
        icon = "",
        icon_color = "Normal",
        status_symbol = "??",
        status_color = "CodeDiffStatusUntracked",
        group = "unstaged",
      })

      local line = nodes_module.prepare_node(node, 40, nil, nil)
      local text = line:content()
      assert.is_truthy(text:match("%?%?"), "Should show ?? status, got: " .. text)
    end)
  end)
end)
