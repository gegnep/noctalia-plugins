-- Test harness prelude: stubs the noctalia plugin environment so panel.luau
-- can run under the standalone luau CLI. Concatenated with ../panel.luau and
-- a feeder by dry-run.sh into a single chunk (locals flow through).

CAPTURED_ONLINE = nil
HARNESS_STREAM_CMD = nil
HARNESS_LOGS = {}
HARNESS_LAST_TREE = nil
HARNESS_SECOND_TICKS = false
HARNESS_PANEL_CLOSED = 0
-- Every runAsync call, in order. Feeders answer a call by invoking its cb.
HARNESS_ASYNC = {}
HARNESS_TERMINAL = {}
HARNESS_REMOVED = {}
HARNESS_MKDIRS = {}
HARNESS_CONFIG = {}
HARNESS_COMMANDS = { niri = true }
HARNESS_UUID = "0f0e0d0c-0b0a-4908-8706-050403020100"
-- Files that exist before panel.luau loads. expandPath is the identity here,
-- so statePath() is "~/.local/state/noctalia-claude-launcher". The two legacy
-- files let the feeders assert the load-time cleanup.
HARNESS_FILES = {
  ["/proc/sys/kernel/random/uuid"] = HARNESS_UUID .. "\n",
  ["~/.local/state/noctalia-claude-launcher/index.json"] = "{}",
  ["~/.local/state/noctalia-claude-launcher/last-session"] = "old-uuid\n",
}

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

-- No openContextMenu stub: the thin launcher must not call it (left-click
-- callbacks carry no pointer context on this host), so a call errors here.
panel = {
  render = function(tree)
    assert(type(tree) == "table" and tree.type ~= nil, "panel.render: bad tree")
    HARNESS_LAST_TREE = tree
  end,
  setWantsSecondTicks = function(wants)
    HARNESS_SECOND_TICKS = wants
  end,
  -- The host calls onClose after a close; mirror that.
  close = function()
    HARNESS_PANEL_CLOSED += 1
    if type(onClose) == "function" then
      onClose()
    end
  end,
}

noctalia = {
  log = function(msg)
    table.insert(HARNESS_LOGS, tostring(msg))
  end,
  notifyError = function(title, body)
    table.insert(HARNESS_LOGS, "notifyError: " .. tostring(title) .. ": " .. tostring(body))
  end,
  runStream = function(cmd, onLine)
    HARNESS_STREAM_CMD = cmd
    CAPTURED_ONLINE = onLine
    return true
  end,
  runAsync = function(cmd, cb, timeoutMs)
    table.insert(HARNESS_ASYNC, { cmd = cmd, cb = cb, timeoutMs = timeoutMs })
    return true
  end,
  runInTerminal = function(cmd)
    table.insert(HARNESS_TERMINAL, cmd)
    return true
  end,
  commandExists = function(name)
    return HARNESS_COMMANDS[name] == true
  end,
  readFile = function(path)
    local content = HARNESS_FILES[path]
    if content == nil then
      return nil, "harness: no such file"
    end
    return content
  end,
  fileExists = function(path)
    return HARNESS_FILES[path] ~= nil
  end,
  fileInfo = function(path)
    local content = HARNESS_FILES[path]
    if content == nil then
      return nil, "harness: no such file"
    end
    return { size = #content, mtime = 0, isDir = false }
  end,
  removeFile = function(path)
    table.insert(HARNESS_REMOVED, path)
    HARNESS_FILES[path] = nil
    return true
  end,
  writeFile = function(path, contents)
    HARNESS_FILES[path] = contents
    return true
  end,
  mkdirAll = function(path)
    table.insert(HARNESS_MKDIRS, path)
    return true
  end,
  getenv = function(name)
    return nil
  end,
  expandPath = function(path)
    return path
  end,
  getConfig = function(key)
    return HARNESS_CONFIG[key]
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
