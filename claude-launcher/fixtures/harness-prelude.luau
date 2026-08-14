-- Test harness prelude: stubs the noctalia plugin environment so panel.luau
-- can run under the standalone luau CLI. Concatenated with ../panel.luau and
-- harness-feeder.luau by dry-run.sh into a single chunk (locals flow through).

CAPTURED_ONLINE = nil
HARNESS_LOGS = {}

-- Minimal JSON decoder (objects, arrays, strings, numbers, true/false/null).
-- Covers exactly the shapes in the fixture dumps; null decodes to nil.
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
        pos += 1 -- colon
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

panel = {
  render = function(tree)
    assert(type(tree) == "table" and tree.type ~= nil, "panel.render: bad tree")
  end,
  setWantsSecondTicks = function(_) end,
  getConfig = function(_) return nil end,
  close = function() end,
}

noctalia = {
  log = function(msg)
    table.insert(HARNESS_LOGS, tostring(msg))
  end,
  notifyError = function(title, body)
    table.insert(HARNESS_LOGS, "notifyError: " .. tostring(title) .. ": " .. tostring(body))
  end,
  runStream = function(cmd, onLine)
    CAPTURED_ONLINE = onLine
    return true
  end,
  runAsync = function(cmd, cb, timeoutMs)
    return true -- watchdog pgrep never answers in the harness
  end,
  readFile = function(path)
    return nil, "harness: no filesystem"
  end,
  readFileAsync = function(path, cb)
    -- Host contract: callback gets (contents, nil) or (nil, err) on the
    -- runtime thread. The harness delivers synchronously.
    cb(nil, "harness: no filesystem")
    return true
  end,
  writeFile = function(path, contents)
    return true
  end,
  mkdirAll = function(path)
    return true
  end,
  fileExists = function(path)
    return false
  end,
  getenv = function(name)
    return nil
  end,
  expandPath = function(path)
    return path
  end,
  fileInfo = function(path)
    return nil -- no filesystem, matches the readFile stub
  end,
  formatTime = function(fmt, ts)
    return "Jan 01 00:00"
  end,
  copyToClipboard = function(text)
    return true
  end,
  removeFile = function(path)
    return true
  end,
  runInTerminal = function(cmd)
    return true
  end,
  getConfig = function(key)
    return nil
  end,
  json = { decode = jsonDecode, encode = function(v) return "{}" end },
  string = {
    trim = function(s)
      return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
    end,
    urlEncode = function(s) return s end,
    urlDecode = function(s) return s end,
  },
}
