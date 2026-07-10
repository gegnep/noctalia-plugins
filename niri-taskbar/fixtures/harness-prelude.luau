-- Test harness prelude: stubs the Noctalia plugin environment so
-- taskbar.luau can run under the standalone luau CLI. dry-run.sh
-- concatenates this file, ../taskbar.luau, fixture data, and one feeder into a
-- single chunk so plugin locals remain visible to the feeder.

CAPTURED_ONLINE = nil
CAPTURED_STREAMS = {}
HARNESS_ASYNC = {}
HARNESS_RENDERS = {}
HARNESS_NOTIFICATIONS = {}
HARNESS_INTERVAL_MS = nil

-- Minimal JSON decoder (objects, arrays, strings, numbers, true/false/null).
-- Covers exactly the shapes in the fixture dumps; null object fields decode as
-- absent/nil, matching the plugin's defensive nil handling.
local function jsonDecode(str)
  local pos = 1

  local function skipWs()
    local _, e = string.find(str, "^[ \t\r\n]*", pos)
    pos = e + 1
  end

  local decodeValue

  local function decodeString()
    pos += 1 -- opening quote
    local out = {}
    while true do
      local c = string.sub(str, pos, pos)
      if c == "" then
        return nil, "unterminated string"
      elseif c == '"' then
        pos += 1
        return table.concat(out)
      elseif c == "\\" then
        local esc = string.sub(str, pos + 1, pos + 1)
        pos += 2
        if esc == "n" then
          table.insert(out, "\n")
        elseif esc == "t" then
          table.insert(out, "\t")
        elseif esc == "r" then
          table.insert(out, "\r")
        elseif esc == "b" then
          table.insert(out, "\b")
        elseif esc == "f" then
          table.insert(out, "\f")
        elseif esc == "u" then
          local hex = string.sub(str, pos, pos + 3)
          pos += 4
          local code = tonumber(hex, 16) or 63
          table.insert(out, code < 128 and string.char(code) or "?")
        else
          table.insert(out, esc) -- \" \\ \/
        end
      else
        table.insert(out, c)
        pos += 1
      end
    end
  end

  local function decodeNumber()
    local s, e = string.find(str, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if s == nil then
      return nil, "bad number"
    end
    local num = tonumber(string.sub(str, s, e))
    pos = e + 1
    return num
  end

  decodeValue = function()
    skipWs()
    local c = string.sub(str, pos, pos)
    if c == '"' then
      return decodeString()
    elseif c == "{" then
      pos += 1
      local obj = {}
      skipWs()
      if string.sub(str, pos, pos) == "}" then
        pos += 1
        return obj
      end
      while true do
        skipWs()
        local key, kerr = decodeString()
        if key == nil then
          return nil, kerr
        end
        skipWs()
        if string.sub(str, pos, pos) ~= ":" then
          return nil, "missing colon"
        end
        pos += 1
        local value, verr = decodeValue()
        if verr then
          return nil, verr
        end
        obj[key] = value
        skipWs()
        local sep = string.sub(str, pos, pos)
        pos += 1
        if sep == "}" then
          return obj
        elseif sep ~= "," then
          return nil, "bad object separator"
        end
      end
    elseif c == "[" then
      pos += 1
      local arr = {}
      skipWs()
      if string.sub(str, pos, pos) == "]" then
        pos += 1
        return arr
      end
      while true do
        local value, verr = decodeValue()
        if verr then
          return nil, verr
        end
        table.insert(arr, value)
        skipWs()
        local sep = string.sub(str, pos, pos)
        pos += 1
        if sep == "]" then
          return arr
        elseif sep ~= "," then
          return nil, "bad array separator"
        end
      end
    elseif string.sub(str, pos, pos + 3) == "true" then
      pos += 4
      return true
    elseif string.sub(str, pos, pos + 4) == "false" then
      pos += 5
      return false
    elseif string.sub(str, pos, pos + 3) == "null" then
      pos += 4
      return nil
    elseif c == "-" or string.find(c, "%d") then
      return decodeNumber()
    end
    return nil, "unexpected character '" .. c .. "' at " .. pos
  end

  local value, err = decodeValue()
  if err then
    return nil, err
  end
  skipWs()
  if pos <= string.len(str) then
    return nil, "trailing data"
  end
  return value
end

HARNESS_JSON_DECODE = jsonDecode

local function uiCtor(t)
  return function(props, children)
    return { type = t, props = props or {}, children = children or {} }
  end
end

ui = {}
for _, name in ipairs({
  "column", "row", "box", "label", "glyph", "image", "separator", "spacer",
  "progress", "button", "graph", "input", "select", "slider", "toggle", "scroll", "markdown",
}) do
  ui[name] = uiCtor(name)
end

barWidget = {
  render = function(tree)
    assert(type(tree) == "table" and tree.type ~= nil, "barWidget.render: bad tree")
    table.insert(HARNESS_RENDERS, tree)
  end,
}

noctalia = {
  notify = function(title, body)
    table.insert(HARNESS_NOTIFICATIONS, { title = title, body = body })
  end,
  runStream = function(cmd, onLine)
    CAPTURED_ONLINE = onLine
    table.insert(CAPTURED_STREAMS, { cmd = cmd, onLine = onLine })
    return true
  end,
  runAsync = function(cmd, cb, timeoutMs)
    table.insert(HARNESS_ASYNC, { cmd = cmd, cb = cb, timeoutMs = timeoutMs })
    return true
  end,
  readFile = function(path)
    if path == "/proc/sys/kernel/random/uuid" then
      return "12345678-1234-1234-1234-123456789abc\n"
    end
    return nil, "harness: no filesystem"
  end,
  setUpdateInterval = function(ms)
    HARNESS_INTERVAL_MS = ms
  end,
  json = { decode = jsonDecode, encode = function(v) return "{}" end },
}
