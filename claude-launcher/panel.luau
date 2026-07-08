--!nonstrict
-- Claude chat panel: message list + composer. Phase 1 is a static shell —
-- messages are seeded dummy data, submitting just echoes the text back into
-- the list. No claude subprocess yet (that's phase 3).

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

-- DUMMY SEED, removed in phase 2
appendMessage("user", "What's the weather like on Mars?")
appendMessage("assistant", "Cold, dusty, and thin on air: about -60C on average with a CO2 atmosphere less than 1% of Earth's pressure.")
appendMessage("user", "Can you write me a haiku about it?")
appendMessage("assistant", "claude exited without a result (dummy error)", "error")

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
  return ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "composer-" .. inputRev,
      placeholder = "Ask Claude\226\128\166",
      flexGrow = 1,
      onChange = "onComposerChanged",
      onSubmit = "onSubmit",
    }),
    ui.button({ text = "Send", variant = "primary", onClick = "onSendClick" }),
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

-- Shared by Enter-to-submit (onSubmit, value passed directly by the host —
-- verified against notes.luau's onEdited/onFlushNow/onRename, which all take
-- the input's committed value as their first argument, not a mirror) and the
-- send button (which mirrors the buffer via onComposerChanged instead, since
-- a button click carries no value of its own).
local function doSubmit(text)
  local trimmed = noctalia.string.trim(text or "")
  if trimmed == "" then
    return
  end
  appendMessage("user", trimmed)
  composerBuffer = ""
  inputRev += 1
  render()
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

function onNewChat()
  messages = {}
  msgCounter = 0
  sessionId = nil
  streaming = false
  activeStreamId = 0
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
