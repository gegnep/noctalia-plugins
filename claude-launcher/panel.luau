--!nonstrict
-- Claude chat panel: message list + composer. Phase 4 streams real claude CLI
-- JSON events through the parser, watchdog, and resumable sessions.

-- ── STATE ─────────────────────────────────────────────────────────────────

local MAX_VISIBLE_MESSAGES = 100

-- messages[i] = {
--   role = "user" | "assistant",
--   text = string,
--   thinking = string?,
--   thinkingOpen = boolean,
--   status = "done" | "streaming" | "thinking" | "stopped" | "error",
--   needsLogin = boolean?,       -- error was the CLI's not-authenticated error
--   key = string,
-- }
local messages = {}
local msgCounter = 0

-- sessionId is the claude session uuid for the current chat (phase 4 adds
-- --resume); it doubles as the pkill target since it appears in claude's argv.
local sessionId = nil
local streaming = false
local activeStreamId = 0
local deltaCount = 0
local diagBuffer = {}
local lastLineAt = 0
local currentUuid = nil
local hasSession = false
local watchdogInFlight = false
local seenUnknownTypes = {}
local messageStartSeen = false

-- Bumped whenever the composer needs to be cleared: ui.input is uncontrolled,
-- so the only way to reset its buffer is to recreate it under a new key.
local inputRev = 0

-- Mirrors the composer's live text so the send button (which cannot read the
-- input's own buffer) has something to submit on click.
local composerBuffer = ""

-- ── HELPERS ───────────────────────────────────────────────────────────────

local env = getfenv()

local function shellQuote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function newUuid()
  local text, err = noctalia.readFile("/proc/sys/kernel/random/uuid")
  if text ~= nil then
    local uuid = noctalia.string.trim(text)
    if uuid ~= "" then
      return uuid
    end
  end
  noctalia.log("Claude launcher: failed to read uuid: " .. tostring(err))
  return tostring(os.time()) .. "-" .. tostring(msgCounter)
end

local function statePath()
  local xdgState = noctalia.getenv("XDG_STATE_HOME")
  if type(xdgState) ~= "string" or noctalia.string.trim(xdgState) == "" then
    xdgState = noctalia.expandPath("~/.local/state")
  end
  return xdgState .. "/noctalia-claude-launcher"
end

local function persistSessionId(uuid)
  local dir = statePath()
  local ok, err = noctalia.mkdirAll(dir)
  if not ok then
    noctalia.log("Claude launcher: failed to create state dir: " .. tostring(err))
    return
  end
  ok, err = noctalia.writeFile(dir .. "/last-session", tostring(uuid))
  if not ok then
    noctalia.log("Claude launcher: failed to persist session id: " .. tostring(err))
  end
end

local function loadPersistedSessionId()
  local text = noctalia.readFile(statePath() .. "/last-session")
  if type(text) ~= "string" then
    return nil
  end
  local uuid = noctalia.string.trim(text)
  if uuid == "" then
    return nil
  end
  return uuid
end

local function clearPersistedSessionId()
  if type(noctalia.removeFile) == "function" then
    noctalia.removeFile(statePath() .. "/last-session")
  else
    noctalia.writeFile(statePath() .. "/last-session", "")
  end
end

local persistedId = loadPersistedSessionId()

local function pushDiag(line)
  table.insert(diagBuffer, line)
  while #diagBuffer > 20 do
    table.remove(diagBuffer, 1)
  end
end

local function diagTail(maxLines)
  local lines = {}
  local first = math.max(1, #diagBuffer - maxLines + 1)
  for i = first, #diagBuffer do
    table.insert(lines, diagBuffer[i])
  end
  return table.concat(lines, "\n")
end

local function claudeCommand()
  local cmd = noctalia.getConfig("claude_command")
  if type(cmd) ~= "string" or noctalia.string.trim(cmd) == "" then
    return "claude"
  end
  return cmd
end

-- Flags verified against claude --help 2026-07-07 (CLI v2.1.201); re-verify
-- after CLI upgrades.
local function buildCommand(prompt, uuid, resume)
  local cmd = claudeCommand()
    .. " -p " .. shellQuote(prompt)
    .. " --output-format stream-json"
    .. " --verbose"
    .. " --include-partial-messages"

  if resume then
    cmd ..= " --resume " .. tostring(uuid)
  else
    cmd ..= " --session-id " .. tostring(uuid)
  end

  local model = noctalia.getConfig("model")
  if type(model) == "string" and model ~= "" then
    cmd ..= " --model " .. shellQuote(model)
  end

  local effort = noctalia.getConfig("effort")
  if type(effort) == "string" and effort ~= "" then
    cmd ..= " --effort " .. shellQuote(effort)
  end

  local allowTools = noctalia.getConfig("allow_tools")
  if allowTools ~= true then
    cmd ..= " --tools ''"
  end

  return cmd .. " 2>&1"
end

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

local function thinkingToggleCallback(message)
  local name = "onToggleThinking_" .. message.key:gsub("%W", "_")
  env[name] = function()
    message.thinkingOpen = not message.thinkingOpen
    render()
  end
  return name
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

  local content = {}
  if message.status == "thinking" then
    table.insert(content, ui.label({
      text = "thinking\226\128\166",
      color = "on_surface_variant",
      fontSize = 11,
      maxWidth = 280,
    }))
  end
  if message.thinking ~= nil and message.thinking ~= "" then
    table.insert(content, ui.button({
      text = message.thinkingOpen and "hide thinking" or "show thinking",
      variant = "ghost",
      onClick = thinkingToggleCallback(message),
    }))
    if message.thinkingOpen then
      table.insert(content, ui.label({
        text = message.thinking,
        color = "on_surface_variant/0.8",
        fontSize = 12,
        maxWidth = 280,
      }))
    end
  end
  table.insert(content, ui.label({ text = message.text, color = textColor, fontSize = 13, maxWidth = 280 }))
  if message.needsLogin then
    table.insert(content, ui.button({
      text = "Log in in a terminal",
      variant = "outline",
      onClick = "onLoginTerminal",
    }))
    table.insert(content, ui.label({
      text = "runs your configured claude command interactively; use /login there once",
      color = "on_surface_variant",
      fontSize = 11,
      maxWidth = 280,
    }))
  end

  local bubble = ui.column({
    fill = isUser and "surface_variant" or nil,
    radius = isUser and 10 or 0,
    paddingH = isUser and 10 or 0,
    paddingV = isUser and 8 or 0,
    align = "start",
    gap = 4,
  }, content)

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

local function resumeAffordance()
  if #messages ~= 0 or streaming or persistedId == nil or sessionId ~= nil then
    return nil
  end
  return ui.row({ align = "center", gap = 8 }, {
    ui.button({ text = "Resume last chat", variant = "ghost", onClick = "onResumeLast" }),
    ui.label({
      text = "continues your previous conversation",
      color = "on_surface_variant",
      fontSize = 11,
    }),
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
  local children = {
    header(),
  }
  local resumeRow = resumeAffordance()
  if resumeRow ~= nil then
    table.insert(children, resumeRow)
  end
  table.insert(children, messageList())
  table.insert(children, composer())
  panel.render(ui.column({ flexGrow = 1, padding = 12, gap = 10, align = "stretch" }, children))
end

-- ── CALLBACKS ─────────────────────────────────────────────────────────────

-- Called from the runStream closure (not by name from UI). The streamId guard
-- drops buffered lines that arrive after a stop or a newer send.
local function handleLine(streamId, line, wasResume)
  local ok, perr = pcall(function()
    if streamId ~= activeStreamId or not streaming then
      return
    end
    lastLineAt = os.time()

    local ev, err = noctalia.json.decode(line)
    if type(ev) ~= "table" then
      pushDiag(line)
      noctalia.log(line)
      return
    end

    if ev.type == "system" then
      if ev.subtype == "init" and ev.session_id ~= currentUuid then
        noctalia.log("Claude launcher: session_id mismatch: " .. tostring(ev.session_id) .. " != " .. tostring(currentUuid))
      end
      return
    elseif ev.type == "rate_limit_event" or ev.type == "assistant" then
      return
    elseif ev.type == "stream_event" then
      local msg = messages[#messages]
      if msg == nil or msg.role ~= "assistant" then
        noctalia.log("Claude launcher: stream_event without open assistant message")
        return
      end
      local event = ev.event
      if type(event) ~= "table" then
        return
      end
      if event.type == "message_start" then
        if messageStartSeen then
          noctalia.log("Claude launcher: duplicate message_start")
        end
        messageStartSeen = true
      elseif event.type == "content_block_start" then
        local block = event.content_block
        if type(block) == "table" then
          if block.type == "thinking" then
            msg.status = "thinking"
            msg.thinking = msg.thinking or ""
          elseif block.type == "text" then
            msg.status = "streaming"
          end
        end
        deltaCount = 0
        render()
      elseif event.type == "content_block_delta" then
        local delta = event.delta
        if type(delta) ~= "table" then
          return
        end
        deltaCount += 1
        local shouldRender = false
        if delta.type == "text_delta" then
          msg.text ..= delta.text or ""
          shouldRender = deltaCount % 3 == 0
        elseif delta.type == "thinking_delta" then
          msg.thinking = msg.thinking or ""
          msg.thinking ..= delta.thinking or ""
          shouldRender = deltaCount % 3 == 0
        end
        if shouldRender then
          render()
        end
      elseif event.type == "content_block_stop" then
        render()
      elseif event.type == "message_delta" or event.type == "message_stop" then
        return
      end
    elseif ev.type == "result" then
      local msg = messages[#messages]
      streaming = false
      panel.setWantsSecondTicks(false)
      if msg ~= nil and msg.role == "assistant" then
        local resultText = ""
        if type(ev.result) == "string" then
          resultText = ev.result
        end
        if ev.is_error == true or ev.subtype ~= "success" then
          msg.status = "error"
          -- The CLI's not-authenticated error mentions /login; auth lives in
          -- whatever home the configured claude_command uses, so the fix is a
          -- one-time interactive login with that exact command (see
          -- onLoginTerminal), never injecting HOME/env from the plugin.
          if string.find(resultText, "/login", 1, true) ~= nil
            or string.find(resultText, "Invalid API key", 1, true) ~= nil then
            msg.needsLogin = true
          end
          if resultText ~= "" then
            if msg.text ~= "" then
              msg.text ..= "\n"
            end
            msg.text ..= resultText
          end
          if #diagBuffer > 0 then
            if msg.text ~= "" then
              msg.text ..= "\n"
            end
            msg.text ..= diagTail(5)
          end
          if wasResume then
            sessionId = nil
            hasSession = false
            clearPersistedSessionId()
            if msg.text ~= "" then
              msg.text ..= "\n"
            end
            msg.text ..= "Session could not be resumed - starting a new chat on next send."
          end
        else
          msg.status = "done"
          if resultText ~= "" then
            msg.text = resultText
          end
          hasSession = true
          persistSessionId(currentUuid)
        end
      end
      render()
    else
      if seenUnknownTypes[ev.type] ~= true then
        seenUnknownTypes[ev.type] = true
        noctalia.log("Claude launcher: unknown event type: " .. tostring(ev.type))
      end
    end
  end)
  if not ok then
    noctalia.log("Claude launcher: stream parser error: " .. tostring(perr))
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
  local uuid
  local resume = false
  if sessionId ~= nil and hasSession then
    uuid = sessionId
    resume = true
  else
    uuid = newUuid()
    sessionId = uuid
    hasSession = false
  end
  currentUuid = uuid
  diagBuffer = {}
  lastLineAt = os.time()
  messageStartSeen = false
  streaming = true
  activeStreamId += 1
  local streamId = activeStreamId
  composerBuffer = ""
  inputRev += 1
  panel.setWantsSecondTicks(true)
  render()

  local ok = noctalia.runStream(buildCommand(trimmed, uuid, resume), function(line)
    handleLine(streamId, line, resume)
  end)
  if not ok then
    assistantMessage.status = "error"
    assistantMessage.text = "failed to start stream"
    streaming = false
    panel.setWantsSecondTicks(false)
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
  if currentUuid ~= nil then
    noctalia.runAsync("pkill -TERM -f " .. shellQuote(currentUuid))
  end
  streaming = false
  activeStreamId += 1
  local message = messages[#messages]
  if message ~= nil then
    message.status = "stopped"
  end
  panel.setWantsSecondTicks(false)
  render()
end

function onLoginTerminal()
  if not noctalia.runInTerminal(claudeCommand()) then
    noctalia.notifyError("Claude launcher", "could not open a terminal")
  end
end

function onResumeLast()
  sessionId = persistedId
  hasSession = true
  render()
end

function onNewChat()
  messages = {}
  msgCounter = 0
  sessionId = nil
  hasSession = false
  currentUuid = nil
  persistedId = nil
  diagBuffer = {}
  streaming = false
  activeStreamId += 1
  deltaCount = 0
  composerBuffer = ""
  inputRev += 1
  panel.setWantsSecondTicks(false)
  render()
end

function update()
  if not streaming or watchdogInFlight or currentUuid == nil then
    return
  end
  if os.time() - lastLineAt <= 20 then
    return
  end
  watchdogInFlight = true
  local streamId = activeStreamId
  local uuid = currentUuid
  local ok = noctalia.runAsync("pgrep -f " .. shellQuote(uuid), function(result)
    watchdogInFlight = false
    if not streaming or streamId ~= activeStreamId then
      return
    end
    local stdout = ""
    if result ~= nil and type(result.stdout) == "string" then
      stdout = noctalia.string.trim(result.stdout)
    end
    if stdout == "" then
      local message = messages[#messages]
      if message ~= nil then
        message.status = "error"
        if message.text ~= "" then
          message.text ..= "\n"
        end
        message.text ..= "claude exited without a result"
        if #diagBuffer > 0 then
          message.text ..= "\n" .. diagTail(5)
        end
      end
      streaming = false
      panel.setWantsSecondTicks(false)
      render()
    end
  end)
  if not ok then
    watchdogInFlight = false
  end
end

function onOpen(_context)
  render()
end

function onClose()
end

render()
