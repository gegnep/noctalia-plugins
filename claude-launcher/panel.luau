--!nonstrict
-- Claude chat panel: message list + composer. Phase 2 wires streaming through
-- a fake shell producer (5 ticks) to prove the runStream plumbing; the real
-- claude subprocess arrives in phase 3.

-- ── STATE ─────────────────────────────────────────────────────────────────

local MAX_VISIBLE_MESSAGES = 100

-- messages[i] = {
--   role = "user" | "assistant",
--   text = string,
--   thinking = string?,
--   thinkingOpen = boolean,
--   status = "done" | "streaming" | "thinking" | "stopped" | "error",
--   key = string,
-- }
local messages = {}
local msgCounter = 0

-- Unused yet (later phases), carried now so the shape doesn't change under us.
local sessionId = nil
local streaming = false
local activeStreamId = 0
local deltaCount = 0

-- Bumped whenever the composer needs to be cleared: ui.input is uncontrolled,
-- so the only way to reset its buffer is to recreate it under a new key.
local inputRev = 0

-- Mirrors the composer's live text so the send button (which cannot read the
-- input's own buffer) has something to submit on click.
local composerBuffer = ""

-- ── HELPERS ───────────────────────────────────────────────────────────────

local function appendMessage(role, text, status)
  msgCounter += 1
  local message = {
    role = role,
    text = text,
    thinking = "",
    thinkingOpen = false,
    status = status or "done",
    key = "msg-" .. msgCounter,
  }
  table.insert(messages, message)
  return message
end

-- Caps the rendered list at the most recent MAX_VISIBLE_MESSAGES entries.
local function visibleMessages()
  local total = #messages
  if total <= MAX_VISIBLE_MESSAGES then
    return messages, false
  end
  local visible = {}
  for i = total - MAX_VISIBLE_MESSAGES + 1, total do
    table.insert(visible, messages[i])
  end
  return visible, true
end

-- ── UI ────────────────────────────────────────────────────────────────────

local render

local function messageRow(message)
  local isUser = message.role == "user"
  local textColor = "on_surface"
  if message.status == "error" then
    textColor = "error"
  elseif isUser then
    textColor = "on_surface_variant"
  end

  local bubble = ui.row({
    fill = isUser and "surface_variant" or nil,
    radius = isUser and 10 or 0,
    paddingH = isUser and 10 or 0,
    paddingV = isUser and 8 or 0,
    align = "start",
  }, {
    ui.label({ text = message.text, color = textColor, fontSize = 13, maxWidth = 280 }),
  })

  return ui.row({
    key = message.key,
    justify = isUser and "end" or "start",
  }, { bubble })
end

local function messageList()
  local visible, hasHidden = visibleMessages()
  local rows = {}
  if hasHidden then
    table.insert(rows, ui.label({
      key = "hidden-notice",
      text = "\226\128\166 earlier messages hidden",
      color = "on_surface_variant",
      fontSize = 11,
    }))
  end
  for _, message in ipairs(visible) do
    table.insert(rows, messageRow(message))
  end
  return ui.scroll({ flexGrow = 1, gap = 8 }, rows)
end

local function header()
  return ui.row({ align = "center", gap = 8 }, {
    ui.label({ text = "Claude", fontSize = 16, fontWeight = "semibold", color = "on_surface" }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ text = "New chat", glyph = "plus", variant = "ghost", onClick = "onNewChat" }),
  })
end

local function composer()
  local buttonText = "Send"
  local buttonVariant = "primary"
  local buttonClick = "onSendClick"
  if streaming then
    buttonText = "Stop"
    buttonVariant = "destructive"
    buttonClick = "onStop"
  end

  return ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "composer-" .. inputRev,
      placeholder = "Ask Claude\226\128\166",
      flexGrow = 1,
      enabled = not streaming,
      onChange = "onComposerChanged",
      onSubmit = "onSubmit",
    }),
    ui.button({ text = buttonText, variant = buttonVariant, onClick = buttonClick }),
  })
end

render = function()
  panel.render(ui.column({ flexGrow = 1, padding = 12, gap = 10, align = "stretch" }, {
    header(),
    messageList(),
    composer(),
  }))
end

-- ── CALLBACKS ─────────────────────────────────────────────────────────────

-- Called from the runStream closure (not by name from UI). The streamId guard
-- drops buffered lines that arrive after a stop or a newer send.
local function onStreamLine(streamId, line)
  if streamId ~= activeStreamId or not streaming then
    return
  end

  local obj, err = noctalia.json.decode(line)
  if obj == nil then
    noctalia.log(line)
    return
  end

  if obj.type == "tick" then
    local message = messages[#messages]
    if message == nil then
      return
    end
    message.text ..= "tick " .. tostring(obj.n) .. "\n"
    if obj.n == 5 then
      message.status = "done"
      streaming = false
    end
    render()
  end
end

-- Shared by Enter-to-submit (onSubmit, value passed directly by the host —
-- verified against notes.luau's onEdited/onFlushNow/onRename, which all take
-- the input's committed value as their first argument, not a mirror) and the
-- send button (which mirrors the buffer via onComposerChanged instead, since
-- a button click carries no value of its own).
local function doSubmit(text)
  if streaming then
    return
  end

  local trimmed = noctalia.string.trim(text or "")
  if trimmed == "" then
    return
  end
  appendMessage("user", trimmed)
  local assistantMessage = appendMessage("assistant", "", "streaming")
  streaming = true
  activeStreamId += 1
  local streamId = activeStreamId
  composerBuffer = ""
  inputRev += 1
  render()

  -- for i in 1 2 3 4 5; do printf '{"type":"tick","n":%d}\n' "$i"; sleep 1; done
  local cmd = "for i in 1 2 3 4 5; do printf '{\"type\":\"tick\",\"n\":%d}\\n' \"$i\"; sleep 1; done"
  local ok = noctalia.runStream(cmd, function(line)
    onStreamLine(streamId, line)
  end)
  if not ok then
    assistantMessage.status = "error"
    assistantMessage.text = "failed to start stream"
    streaming = false
    render()
    noctalia.notifyError("Claude launcher", "failed to start stream")
  end
end

function onSubmit(text)
  doSubmit(text)
end

function onComposerChanged(value)
  composerBuffer = value
end

function onSendClick()
  doSubmit(composerBuffer)
end

function onStop()
  -- Real process kill arrives in phase 3.
  streaming = false
  activeStreamId += 1
  local message = messages[#messages]
  if message ~= nil then
    message.status = "stopped"
  end
  render()
end

function onNewChat()
  messages = {}
  msgCounter = 0
  sessionId = nil
  streaming = false
  activeStreamId += 1
  deltaCount = 0
  composerBuffer = ""
  inputRev += 1
  render()
end

function onOpen(_context)
  render()
end

function onClose()
end

render()
