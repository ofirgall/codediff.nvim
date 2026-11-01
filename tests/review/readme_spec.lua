local review_config = require("codediff.review.config")
local grouping = require("codediff.review.grouping")

local function read(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("README review groups example", function()
  it("parses and compiles with review/config.lua", function()
    local readme = read("README.md")
    local section = readme:match("### PR Review Groups\n(.-)\n### ")
    assert.is_not_nil(section, "README has a PR Review Groups section")
    local json = section:match("```json\n(.-)\n```")
    assert.is_not_nil(json, "section has a json example")

    local res = review_config.parse(json)
    assert.is_true(res.ok, res.error)
    assert.equals(4, #res.config.groups)

    local compiled, err = review_config.compile(res.config, function(p)
      return p:match("%.pb%.go$") ~= nil
    end)
    assert.is_nil(err)
    local out = grouping.order({ "server/a.go", "web/x.ts", "a_test.go", "go.sum", "api.pb.go", "README.md" }, compiled)
    local assignment = out.assignment
    assert.equals("Backend", assignment["server/a.go"])
    assert.equals("Tests", assignment["a_test.go"])
    assert.equals("Lockfiles", assignment["go.sum"])
    assert.equals("Generated", assignment["api.pb.go"])
    assert.equals("Ungrouped", assignment["README.md"])
    assert.equals("Ungrouped", out.groups[1].name) -- promoted by "ungrouped": { "viewPriority": 5 }
  end)

  it("parses the Lua setup override example", function()
    local readme = read("README.md")
    local section = readme:match("### PR Review Groups\n(.-)\n### ")
    local lua_src = section:match("```lua\n(.-)\n```")
    assert.is_not_nil(lua_src)
    local captured
    local fake = { setup = function(opts) captured = opts end }
    local saved = package.loaded["codediff"]
    package.loaded["codediff"] = fake
    local ok, e = pcall(load(lua_src))
    package.loaded["codediff"] = saved
    assert.is_true(ok, e)
    local res = review_config.parse(captured.explorer.pr_review.groups)
    assert.is_true(res.ok, res.error)
    assert.is_not_nil(review_config.compile(res.config))
  end)
end)
