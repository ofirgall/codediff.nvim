local config = require("codediff.review.config")

describe("review.config strip_jsonc", function()
  it("removes line and block comments", function()
    local r = config.parse('// top\n{ /* c */ "groups": [ // x\n {"name":"A","paths":["a"]} ] }')
    assert.is_true(r.ok, r.error)
    assert.equals("A", r.config.groups[1].name)
  end)

  it("keeps // and /* inside strings", function()
    local r = config.parse('{"groups":[{"name":"A // b","paths":["https?://x", "/\\\\* y"]}]}')
    assert.is_true(r.ok, r.error)
    assert.equals("A // b", r.config.groups[1].name)
    assert.equals("https?://x", r.config.groups[1].paths[1])
  end)

  it("drops trailing commas in arrays and objects", function()
    local r = config.parse('{"groups":[{"name":"A","paths":["a","b",],},],}')
    assert.is_true(r.ok, r.error)
    assert.equals(2, #r.config.groups[1].paths)
  end)

  it("keeps commas inside strings", function()
    assert.equals('{"a":"x,]"}', config.strip_jsonc('{"a":"x,]"}'))
  end)

  it("preserves length and newlines", function()
    local t = '{ // c\n"a":1, /* x\ny */ }'
    local s = config.strip_jsonc(t)
    assert.equals(#t, #s)
    assert.is_nil(s:find("//", 1, true))
  end)
end)

describe("review.config parse", function()
  local function err(text)
    local r = config.parse(text)
    assert.is_false(r.ok)
    return r.error
  end

  it("parses full config", function()
    local r = config.parse([[{
      "groups": [
        {"name":"Backend","paths":["^server/"],"matchPriority":2,"viewPriority":3},
        {"name":"Lock","paths":["\\.lock$"],"autoViewed":true}
      ],
      "generated": {"viewPriority": -5},
      "ungrouped": {"viewPriority": 5}
    }]])
    assert.is_true(r.ok, r.error)
    local c = r.config
    assert.equals(2, #c.groups)
    assert.is_false(c.groups[1].autoViewed)
    assert.is_true(c.groups[2].autoViewed)
    assert.equals(2, c.groups[1].matchPriority)
    assert.equals(-5, c.generated.viewPriority)
    assert.equals(5, c.ungrouped.viewPriority)
  end)

  it("accepts empty groups array", function()
    local r = config.parse('{"groups":[]}')
    assert.is_true(r.ok)
    assert.equals(0, #r.config.groups)
  end)

  it("accepts a decoded lua table", function()
    local r = config.parse({ groups = { { name = "A", paths = { "^a" }, autoViewed = true } } })
    assert.is_true(r.ok, r.error)
    assert.is_true(r.config.groups[1].autoViewed)
  end)

  it("validates lua tables too", function()
    local r = config.parse({ groups = { { name = "A", paths = {} } } })
    assert.is_false(r.ok)
    assert.equals('Group "A" needs a non-empty "paths" array', r.error)
  end)

  it("reports bad json", function()
    assert.matches("^Invalid JSON: ", err("{ nope"))
  end)

  it("reports non-object config", function()
    assert.equals('Config must be a JSON object with a "groups" array', err("5"))
    assert.equals('Config must be a JSON object with a "groups" array', err('[{"name":"a"}]'))
  end)

  it("reports missing groups", function()
    assert.equals('Config is missing the "groups" array', err("{}"))
    assert.equals('Config is missing the "groups" array', err('{"groups":{}}'))
    assert.equals('Config is missing the "groups" array', err('{"groups":"x"}'))
  end)

  it("reports non-object group", function()
    assert.equals("Group #2 must be an object", err('{"groups":[{"name":"A","paths":["a"]}, 3]}'))
  end)

  it("reports missing or empty name", function()
    assert.equals('Group #1 needs a non-empty string "name"', err('{"groups":[{"paths":["a"]}]}'))
    assert.equals('Group #1 needs a non-empty string "name"', err('{"groups":[{"name":"  ","paths":["a"]}]}'))
    assert.equals('Group #1 needs a non-empty string "name"', err('{"groups":[{"name":3,"paths":["a"]}]}'))
  end)

  it("reports missing or empty paths", function()
    local want = 'Group "A" needs a non-empty "paths" array'
    assert.equals(want, err('{"groups":[{"name":"A"}]}'))
    assert.equals(want, err('{"groups":[{"name":"A","paths":[]}]}'))
    assert.equals(want, err('{"groups":[{"name":"A","paths":"a"}]}'))
    assert.equals(want, err('{"groups":[{"name":"A","paths":{}}]}'))
  end)

  it("reports non-string path", function()
    assert.equals('Group "A": every entry in "paths" must be a string', err('{"groups":[{"name":"A","paths":["a",1]}]}'))
  end)

  it("reports non-boolean autoViewed", function()
    assert.equals('Group "A": "autoViewed" must be a boolean', err('{"groups":[{"name":"A","paths":["a"],"autoViewed":"yes"}]}'))
  end)

  it("reports invalid pattern naming group and pattern", function()
    local e = err('{"groups":[{"name":"A","paths":["(unclosed"]}]}')
    assert.matches('^Group "A": invalid regex "%(unclosed": ', e)
    e = err('{"groups":[{"name":"A","paths":["(?i)x"]}]}')
    assert.matches('^Group "A": invalid regex "%(%?i%)x": ', e)
  end)

  it("reports non-number priorities", function()
    assert.equals('Group "A": "matchPriority" must be a number', err('{"groups":[{"name":"A","paths":["a"],"matchPriority":"1"}]}'))
    assert.equals('Group "A": "viewPriority" must be a number', err('{"groups":[{"name":"A","paths":["a"],"viewPriority":true}]}'))
    assert.equals('"generated": "viewPriority" must be a number', err('{"groups":[],"generated":{"viewPriority":"x"}}'))
    assert.equals('"ungrouped": "viewPriority" must be a number', err('{"groups":[],"ungrouped":{"viewPriority":[]}}'))
  end)

  it("reports non-object generated/ungrouped", function()
    assert.equals('"generated" must be an object', err('{"groups":[],"generated":[1]}'))
    assert.equals('"ungrouped" must be an object', err('{"groups":[],"ungrouped":5}'))
  end)

  it("ignores null fields", function()
    local r = config.parse('{"groups":[{"name":"A","paths":["a"],"matchPriority":null}],"ungrouped":null}')
    assert.is_true(r.ok, r.error)
    assert.is_nil(r.config.groups[1].matchPriority)
  end)
end)

describe("review.config compile", function()
  local function compile(text, gen)
    local r = config.parse(text)
    assert.is_true(r.ok, r.error)
    local c, e = config.compile(r.config, gen)
    assert.is_truthy(c, e)
    return c
  end

  it("applies default priorities", function()
    local c = compile('{"groups":[{"name":"A","paths":["a"]},{"name":"B","paths":["b"],"autoViewed":true}]}')
    assert.equals(0, c.groups[1].match_priority)
    assert.equals(0, c.groups[1].view_priority)
    assert.equals(1, c.groups[2].match_priority)
    assert.equals(-2, c.groups[2].view_priority)
    assert.equals(-1, c.ungrouped_view_priority)
    assert.is_true(c.groups[1].match("xa"))
    assert.is_false(c.groups[1].match("xb"))
  end)

  it("explicit priorities override defaults", function()
    local c = compile('{"groups":[{"name":"A","paths":["a"],"matchPriority":4,"viewPriority":7}],"ungrouped":{"viewPriority":9}}')
    assert.equals(4, c.groups[1].match_priority)
    assert.equals(7, c.groups[1].view_priority)
    assert.equals(9, c.ungrouped_view_priority)
  end)

  it("appends Generated when a predicate is given", function()
    local c = compile('{"groups":[{"name":"A","paths":["a"]}]}', function(p)
      return p:match("%.pb%.go$") ~= nil
    end)
    assert.equals(2, #c.groups)
    local g = c.groups[2]
    assert.equals("Generated", g.name)
    assert.is_true(g.auto_viewed)
    assert.equals(2, g.index)
    assert.equals(1, g.match_priority)
    assert.equals(-2, g.view_priority)
    assert.is_true(g.match("x.pb.go"))
  end)

  it("uses top-level generated priorities", function()
    local c = compile('{"groups":[],"generated":{"matchPriority":5,"viewPriority":6}}', function()
      return true
    end)
    assert.equals(5, c.groups[1].match_priority)
    assert.equals(6, c.groups[1].view_priority)
  end)

  it("compiles nil config with only Generated", function()
    local c = config.compile(nil, function()
      return true
    end)
    assert.equals(1, #c.groups)
    assert.equals("Generated", c.groups[1].name)
    local c2 = config.compile(nil, nil)
    assert.equals(0, #c2.groups)
  end)
end)
