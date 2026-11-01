-- Translate a JavaScript regex subset to a Vim very-magic pattern (\v\C).
-- Supported: ^ $ . [] () | * + ? {n} {n,} {n,m} \d \w \s \D \W \S \n \t \r and escaped punctuation,
-- (?:...), named groups (?<name>...), lookahead (?=...) (?!...) and lookbehind (?<=...) (?<!...).
-- Rejected with an error: \b, \B, backreferences, other letter escapes.
local M = {}

-- Characters that are special in very-magic mode but literal in JS.
local ESCAPE_LITERAL = {
  ["<"] = true, [">"] = true, ["="] = true, ["@"] = true,
  ["%"] = true, ["~"] = true, ["&"] = true, ["}"] = true,
}

local CLASS_ESCAPES = { d = "0-9", w = "0-9A-Za-z_", s = " \\t" }

--- Translate a JS pattern. Returns vim pattern (without the \v\C prefix) or nil, err.
---@param p string
---@return string|nil, string|nil
function M.translate(p)
  local out = {}
  local i, n = 1, #p
  local closers = {} -- per open group: the Vim suffix to emit at its ')'
  local can_quantify = false -- true right after an atom
  local after_quant = false -- true right after a quantifier

  local function put(s)
    out[#out + 1] = s
  end

  while i <= n do
    local c = p:sub(i, i)
    if c == "\\" then
      local d = p:sub(i + 1, i + 1)
      if d == "" then
        return nil, "pattern ends with a backslash"
      end
      if d == "b" or d == "B" then
        return nil, "word boundary \\" .. d .. " is not supported"
      elseif d:match("[1-9]") then
        return nil, "backreference \\" .. d .. " is not supported"
      elseif d == "0" then
        return nil, "\\0 is not supported"
      elseif d:match("[dDwWsSntr]") then
        put("\\" .. d)
      elseif d:match("[%a]") then
        return nil, "escape \\" .. d .. " is not supported"
      elseif d == "_" then
        put("_")
      else
        put("\\" .. d)
      end
      i = i + 2
      can_quantify, after_quant = true, false
    elseif c == "[" then
      local j = i + 1
      local cls = {}
      if p:sub(j, j) == "^" then
        cls[#cls + 1] = "^"
        j = j + 1
      end
      local items = 0
      local closed = false
      while j <= n do
        local ch = p:sub(j, j)
        if ch == "]" then
          closed = true
          break
        elseif ch == "\\" then
          local d = p:sub(j + 1, j + 1)
          if d == "" then
            return nil, "pattern ends with a backslash"
          end
          if CLASS_ESCAPES[d] then
            cls[#cls + 1] = CLASS_ESCAPES[d]
          elseif d:match("[DWS]") then
            return nil, "escape \\" .. d .. " inside a character class is not supported"
          elseif d == "b" then
            return nil, "\\b inside a character class is not supported"
          elseif d:match("[ntr]") then
            cls[#cls + 1] = "\\" .. d
          elseif d:match("[%w]") then
            return nil, "escape \\" .. d .. " is not supported"
          elseif d == "]" or d == "\\" or d == "^" or d == "-" then
            cls[#cls + 1] = "\\" .. d
          else
            cls[#cls + 1] = d
          end
          j = j + 2
        elseif ch == "[" and p:sub(j + 1, j + 1):match("[:.=]") then
          return nil, "'[' followed by ':', '.' or '=' inside a character class is not supported"
        else
          cls[#cls + 1] = ch
          j = j + 1
        end
        items = items + 1
      end
      if not closed then
        return nil, "unterminated character class"
      end
      if items == 0 then
        return nil, "empty character class is not supported"
      end
      put("[" .. table.concat(cls) .. "]")
      i = j + 1
      can_quantify, after_quant = true, false
    elseif c == "(" then
      -- Every group is non-capturing in Vim (%(...)); lookarounds add a suffix at ')'.
      local open_len, suffix = 1, ")"
      if p:sub(i + 1, i + 1) == "?" then
        local three, four = p:sub(i, i + 2), p:sub(i, i + 3)
        if three == "(?:" then
          open_len = 3
        elseif three == "(?=" then
          open_len, suffix = 3, ")@="
        elseif three == "(?!" then
          open_len, suffix = 3, ")@!"
        elseif four == "(?<=" then
          open_len, suffix = 4, ")@<="
        elseif four == "(?<!" then
          open_len, suffix = 4, ")@<!"
        else
          local name = p:match("^%(%?<([%a_][%w_]*)>", i)
          if not name then
            return nil, "group construct " .. (three:sub(3, 3) == "<" and four or three) .. " is not supported"
          end
          open_len = #name + 4
        end
      end
      closers[#closers + 1] = suffix
      put("%(")
      i = i + open_len
      can_quantify, after_quant = false, false
    elseif c == ")" then
      local suffix = table.remove(closers)
      if not suffix then
        return nil, "unmatched ')'"
      end
      put(suffix)
      i = i + 1
      -- A lookaround is an assertion: nothing to repeat after it.
      can_quantify, after_quant = suffix == ")", false
    elseif c == "|" then
      put("|")
      i = i + 1
      can_quantify, after_quant = false, false
    elseif c == "^" or c == "$" then
      put(c)
      i = i + 1
      can_quantify, after_quant = false, false
    elseif c == "*" or c == "+" or c == "?" or c == "{" then
      local q, len
      if c == "{" then
        q = p:match("^{%d+}", i) or p:match("^{%d+,}", i) or p:match("^{%d+,%d+}", i)
        len = q and #q
      else
        q, len = c, 1
      end
      if not q then
        -- Not a valid quantifier: literal brace (JS annex B).
        put("\\{")
        i = i + 1
        can_quantify, after_quant = true, false
      else
        if after_quant then
          return nil, "nothing to repeat before '" .. q .. "'"
        end
        if not can_quantify then
          return nil, "nothing to repeat before '" .. q .. "'"
        end
        put(q)
        i = i + len
        -- Lazy modifier does not change a boolean match; drop it
        -- (in very-magic '?' would mean "optional" and change semantics).
        if p:sub(i, i) == "?" then
          i = i + 1
        end
        can_quantify, after_quant = false, true
      end
    elseif ESCAPE_LITERAL[c] then
      put("\\" .. c)
      i = i + 1
      can_quantify, after_quant = true, false
    else
      put(c) -- includes '.' and plain characters
      i = i + 1
      can_quantify, after_quant = true, false
    end
  end
  if #closers ~= 0 then
    return nil, "unterminated group"
  end
  return table.concat(out)
end

--- Compile a JS pattern into a matcher: function(path) -> boolean (unanchored, case-sensitive).
---@param pattern string
---@return (fun(path: string): boolean)|nil, string|nil
function M.compile(pattern)
  local translated, err = M.translate(pattern)
  if not translated then
    return nil, err
  end
  local ok, re = pcall(vim.regex, "\\v\\C" .. translated)
  if not ok then
    return nil, tostring(re):gsub("^.-: ", "")
  end
  return function(path)
    return re:match_str(path) ~= nil
  end
end

return M
