local config = require("codediff.review.config")
local grouping = require("codediff.review.grouping")

local function compile(text, gen)
  local r = config.parse(text)
  assert.is_true(r.ok, r.error)
  return assert(config.compile(r.config, gen))
end

local function names(res)
  local t = {}
  for _, g in ipairs(res.groups) do
    t[#t + 1] = g.name
  end
  return t
end

describe("review.grouping", function()
  it("auto-viewed group wins by default", function()
    local c = compile([[{"groups":[
      {"name":"Frontend","paths":["^web/"]},
      {"name":"Lockfiles","paths":["package-lock\\.json$"],"autoViewed":true}]}]])
    assert.equals("Lockfiles", grouping.assign("web/package-lock.json", c.groups).name)
    assert.equals("Frontend", grouping.assign("web/a.ts", c.groups).name)
    assert.is_nil(grouping.assign("other.txt", c.groups))
  end)

  it("explicit matchPriority overrides", function()
    local c = compile([[{"groups":[
      {"name":"Backend","paths":["\\.go$"]},
      {"name":"Tests","paths":["_test\\.go$"],"matchPriority":2}]}]])
    assert.equals("Tests", grouping.assign("a_test.go", c.groups).name)
  end)

  it("ties go to the earliest group", function()
    local c = compile([[{"groups":[
      {"name":"One","paths":["a"]},{"name":"Two","paths":["a"]}]}]])
    assert.equals("One", grouping.assign("a", c.groups).name)
  end)

  it("default order: normal, Ungrouped, auto-viewed", function()
    local c = compile([[{"groups":[
      {"name":"Lockfiles","paths":["\\.lock$"],"autoViewed":true},
      {"name":"Backend","paths":["^server/"]}]}]])
    local res = grouping.order({ "x.lock", "misc.md", "server/a.go" }, c)
    assert.same({ "Backend", "Ungrouped", "Lockfiles" }, names(res))
  end)

  it("promoted Ungrouped goes first", function()
    local c = compile([[{"groups":[{"name":"Backend","paths":["^server/"]}],"ungrouped":{"viewPriority":5}}]])
    local res = grouping.order({ "server/a.go", "misc.md" }, c)
    assert.same({ "Ungrouped", "Backend" }, names(res))
  end)

  it("Ungrouped is after groups at equal priority", function()
    local c = compile([[{"groups":[{"name":"B","paths":["^b"]}],"ungrouped":{"viewPriority":0}}]])
    local res = grouping.order({ "x", "b1" }, c)
    assert.same({ "B", "Ungrouped" }, names(res))
  end)

  it("keeps original order within a group and hides empty groups", function()
    local c = compile([[{"groups":[{"name":"A","paths":["a"]},{"name":"Empty","paths":["zzz"]}]}]])
    local res = grouping.order({ "a3", "a1", "a2" }, c)
    assert.same({ "A" }, names(res))
    assert.same({ "a3", "a1", "a2" }, res.groups[1].files)
  end)

  it("orders by viewPriority desc then config order", function()
    local c = compile([[{"groups":[
      {"name":"A","paths":["^a"]},
      {"name":"B","paths":["^b"],"viewPriority":3},
      {"name":"C","paths":["^c"]}]}]])
    local res = grouping.order({ "a", "c", "b" }, c)
    assert.same({ "B", "A", "C" }, names(res))
  end)

  it("Generated comes after config groups on ties and is auto-viewed", function()
    local c = compile(
      [[{"groups":[{"name":"Lock","paths":["\\.lock$"],"autoViewed":true}]}]],
      function(p)
        return p:match("%.pb%.go$") ~= nil
      end
    )
    local res = grouping.order({ "x.pb.go", "y.lock", "z.go" }, c)
    assert.same({ "Ungrouped", "Lock", "Generated" }, names(res))
    assert.is_true(res.groups[3].auto_viewed)
    assert.is_false(res.groups[1].auto_viewed)
  end)

  it("works without config and with generated only", function()
    local c = config.compile(nil, function(p)
      return p:match("%.pb%.go$") ~= nil
    end)
    local res = grouping.order({ "a.pb.go", "b.go" }, c)
    assert.same({ "Ungrouped", "Generated" }, names(res))
  end)

  it("supports table files and returns assignment", function()
    local c = compile([[{"groups":[{"name":"A","paths":["^a"]}]}]])
    local f1, f2 = { path = "a/x", status = "M" }, { path = "b/y", status = "A" }
    local res = grouping.order({ f2, f1 }, c)
    assert.equals(f1, res.groups[1].files[1])
    assert.equals("A", res.assignment["a/x"])
    assert.equals("Ungrouped", res.assignment["b/y"])
    assert.equals(2, #res.ordered)
    assert.equals(f1, res.ordered[1].file)
  end)

  it("same-named groups stay separate buckets", function()
    local c = compile([[{"groups":[{"name":"A","paths":["^a"]},{"name":"A","paths":["^b"]}]}]])
    local res = grouping.order({ "a", "b" }, c)
    assert.equals(2, #res.groups)
  end)
end)
