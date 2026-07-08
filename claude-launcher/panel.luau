--!nonstrict
-- Claude chat panel: message list + composer. Phase 4 streams real claude CLI
-- JSON events through the parser, watchdog, and resumable sessions.

-- ── STATE ─────────────────────────────────────────────────────────────────

local MAX_VISIBLE_MESSAGES = 100

-- Composer auto-grow: base control height plus a per-extra-line increment.
-- Tuned live against the real control; adjust here if it over/undershoots.
local COMPOSER_BASE_HEIGHT = 34
local COMPOSER_LINE_HEIGHT = 20

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
local lastSendWasResume = false
local openMessage = nil
local overrideModel = ""
local overrideEffort = ""
local queuedPrompt = nil
local queuedKey = nil
local view = "chat"
local renamingChatId = nil
local pendingDeleteChatId = nil

-- Bumped whenever the composer needs to be cleared: ui.input is uncontrolled,
-- so the only way to reset its buffer is to recreate it under a new key.
local inputRev = 0

-- Mirrors the composer's live text so the send button (which cannot read the
-- input's own buffer) has something to submit on click.
local composerBuffer = ""

-- Estimated wrapped-line count of the composer's current text, used to grow
-- ui.input's height prop live. Reset to 1 whenever the composer is cleared.
local composerLines = 1

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

local function workspaceDir()
  return statePath() .. "/workspace"
end

-- Verified against claude CLI v2.1.201 project dir naming; other special chars unverified - transcripts_dir setting is the escape hatch.
local function projectSlug(path)
  return tostring(path or ""):gsub("[/%.]", "-")
end

local function transcriptsDir()
  local cfg = noctalia.getConfig("transcripts_dir")
  if type(cfg) == "string" and noctalia.string.trim(cfg) ~= "" then
    return noctalia.expandPath(cfg)
  end
  return noctalia.expandPath("~/.claude/projects/") .. projectSlug(workspaceDir())
end

local function indexPath()
  return statePath() .. "/index.json"
end

local function removeLastSessionFile()
  if type(noctalia.removeFile) == "function" then
    noctalia.removeFile(statePath() .. "/last-session")
  else
    noctalia.writeFile(statePath() .. "/last-session", "")
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

local function normalizeIndex(value)
  local index = { version = 1, chats = {} }
  if type(value) ~= "table" or type(value.chats) ~= "table" then
    return index
  end
  for _, chat in ipairs(value.chats) do
    if type(chat) == "table" and type(chat.id) == "string" and chat.id ~= "" then
      table.insert(index.chats, {
        id = chat.id,
        title = type(chat.title) == "string" and chat.title or "Untitled chat",
        createdAt = type(chat.createdAt) == "number" and chat.createdAt or os.time(),
        updatedAt = type(chat.updatedAt) == "number" and chat.updatedAt or os.time(),
      })
    end
  end
  table.sort(index.chats, function(a, b)
    return a.updatedAt > b.updatedAt
  end)
  while #index.chats > 100 do
    table.remove(index.chats)
  end
  return index
end

local function loadIndex()
  local text = noctalia.readFile(indexPath())
  if type(text) ~= "string" or text == "" then
    return { version = 1, chats = {} }
  end
  local decoded, err = noctalia.json.decode(text)
  if type(decoded) ~= "table" then
    noctalia.log("Claude launcher: failed to decode history index: " .. tostring(err))
    return { version = 1, chats = {} }
  end
  return normalizeIndex(decoded)
end

local function saveIndex(index)
  local dir = statePath()
  local ok, err = noctalia.mkdirAll(dir)
  if not ok then
    noctalia.log("Claude launcher: failed to create state dir: " .. tostring(err))
    return false
  end
  local encoded
  encoded, err = noctalia.json.encode(index, true)
  if type(encoded) ~= "string" then
    noctalia.log("Claude launcher: failed to encode history index: " .. tostring(err))
    return false
  end
  ok, err = noctalia.writeFile(indexPath(), encoded)
  if not ok then
    noctalia.log("Claude launcher: failed to write history index: " .. tostring(err))
    return false
  end
  return true
end

local historyIndex = loadIndex()

local previousSessionId = loadPersistedSessionId()
if #historyIndex.chats == 0 and previousSessionId ~= nil then
  local now = os.time()
  table.insert(historyIndex.chats, {
    id = previousSessionId,
    title = "Previous chat",
    createdAt = now,
    updatedAt = now,
  })
  if saveIndex(historyIndex) then
    removeLastSessionFile()
  end
end

local function sortHistoryIndex()
  table.sort(historyIndex.chats, function(a, b)
    return a.updatedAt > b.updatedAt
  end)
  while #historyIndex.chats > 100 do
    table.remove(historyIndex.chats)
  end
end

local function upsertChat(id, title)
  local now = os.time()
  for _, chat in ipairs(historyIndex.chats) do
    if chat.id == id then
      chat.updatedAt = now
      sortHistoryIndex()
      saveIndex(historyIndex)
      return
    end
  end
  table.insert(historyIndex.chats, 1, {
    id = id,
    title = title,
    createdAt = now,
    updatedAt = now,
  })
  sortHistoryIndex()
  saveIndex(historyIndex)
end

local function renameChat(id, title)
  for _, chat in ipairs(historyIndex.chats) do
    if chat.id == id then
      chat.title = title
      saveIndex(historyIndex)
      return
    end
  end
end

local function deleteChat(id)
  for i, chat in ipairs(historyIndex.chats) do
    if chat.id == id then
      table.remove(historyIndex.chats, i)
      saveIndex(historyIndex)
      return
    end
  end
end

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

-- Flags verified against claude --help 2026-07-07 (CLI v2.1.201); dedicated
-- workspace cwd keeps Claude's per-project state out of the user's home.
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

  local model = overrideModel
  if model == "" then
    model = noctalia.getConfig("model")
  end
  if type(model) == "string" and model ~= "" then
    cmd ..= " --model " .. shellQuote(model)
  end

  local effort = overrideEffort
  if effort == "" then
    effort = noctalia.getConfig("effort")
  end
  if type(effort) == "string" and effort ~= "" then
    cmd ..= " --effort " .. shellQuote(effort)
  end

  local allowTools = noctalia.getConfig("allow_tools")
  if allowTools ~= true then
    cmd ..= " --tools ''"
  end

  return "cd " .. shellQuote(workspaceDir()) .. " && " .. cmd .. " 2>&1"
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

local function parseTranscript(text, keyPrefix)
  local result = {}
  local acc = { text = "", thinking = "" }
  local count = 0

  local function nextKey()
    count += 1
    return tostring(keyPrefix or "hist") .. "-" .. count
  end

  local function appendParsed(role, msgText, thinking)
    if msgText == "" and thinking == "" then
      return
    end
    table.insert(result, {
      role = role,
      text = msgText,
      thinking = thinking,
      thinkingOpen = false,
      status = "done",
      key = nextKey(),
    })
  end

  local function flushAssistant()
    appendParsed("assistant", acc.text, acc.thinking)
    acc = { text = "", thinking = "" }
  end

  for line in string.gmatch(tostring(text or "") .. "\n", "([^\n]*)\n") do
    local row = nil
    if line ~= "" then
      row = noctalia.json.decode(line)
    end

    if type(row) == "table" and row.type == "assistant" then
      local message = row.message
      local content = type(message) == "table" and message.content or nil
      if type(content) == "table" then
        for _, block in ipairs(content) do
          if type(block) == "table" then
            if block.type == "text" and type(block.text) == "string" then
              acc.text ..= block.text
            elseif block.type == "thinking" and type(block.thinking) == "string" then
              acc.thinking ..= block.thinking
            end
          end
        end
      else
        flushAssistant()
      end
    else
      flushAssistant()
      if type(row) == "table" and row.type == "user" then
        local message = row.message
        local content = type(message) == "table" and message.content or nil
        if type(content) == "string" then
          appendParsed("user", content, "")
        end
      end
    end
  end
  flushAssistant()

  while #result > 100 do
    table.remove(result, 1)
  end
  return result
end

local function sessionPolicy()
  if sessionId ~= nil and hasSession then
    return sessionId, true
  end
  local uuid = newUuid()
  sessionId = uuid
  hasSession = false
  return uuid, false
end

local function findMessageByKey(key)
  for i, message in ipairs(messages) do
    if message.key == key then
      return message, i
    end
  end
  return nil, nil
end

local function removeMessageByKey(key)
  local _, index = findMessageByKey(key)
  if index ~= nil then
    table.remove(messages, index)
  end
end

local function titleFromFirstUserMessage()
  for _, message in ipairs(messages) do
    if message.role == "user" and message.text ~= "" then
      return string.sub(noctalia.string.trim(message.text), 1, 60)
    end
  end
  return "Untitled chat"
end

local function isLastMessage(message)
  return #messages > 0 and messages[#messages] == message
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

local function copyCallback(message)
  local name = "onCopy_" .. message.key:gsub("%W", "_")
  env[name] = function()
    noctalia.copyToClipboard(message.text, "text/plain")
  end
  return name
end

local startStream

local function retryCallback(message)
  local name = "onRetry_" .. message.key:gsub("%W", "_")
  env[name] = function()
    if streaming or not isLastMessage(message) then
      return
    end
    local previous = messages[#messages - 1]
    if previous == nil or previous.role ~= "user" then
      return
    end
    table.remove(messages, #messages)
    local uuid, resume = sessionPolicy()
    startStream(previous.text, { uuid = uuid, resume = resume, appendUserRow = false })
  end
  return name
end

local function validStringList(value, fallback)
  if type(value) ~= "table" then
    return fallback
  end
  local result = {}
  for _, item in ipairs(value) do
    if type(item) == "string" and item ~= "" then
      table.insert(result, item)
    end
  end
  if #result == 0 then
    return fallback
  end
  return result
end

local function selectIndex(options, value)
  for i, option in ipairs(options) do
    if option == value then
      -- ui.select's selectedIndex is 0-based (verified: the reconciler feeds
      -- it straight into a size_t index over the options vector).
      return i - 1
    end
  end
  return 0
end

-- Estimates the wrapped-line count of composer text: one line per explicit
-- newline segment, plus extra lines for segments that would wrap at a rough
-- character width. Kept intentionally coarse - it only needs to grow/shrink
-- the input's height prop, not match the host's real text layout exactly.
local COMPOSER_WRAP_WIDTH = 38

local function estimateComposerLines(value)
  local text = value or ""
  local lines = 1
  local segmentStart = 1
  local len = #text
  local i = 1
  while i <= len do
    if text:sub(i, i) == "\n" then
      lines += 1
      local segment = text:sub(segmentStart, i - 1)
      lines += math.max(0, math.ceil(#segment / COMPOSER_WRAP_WIDTH) - 1)
      segmentStart = i + 1
    end
    i += 1
  end
  local lastSegment = text:sub(segmentStart, len)
  lines += math.max(0, math.ceil(#lastSegment / COMPOSER_WRAP_WIDTH) - 1)
  return math.max(1, math.min(6, lines))
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
    table.insert(content, ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = message.thinkingOpen and "chevron-down" or "chevron-right",
        glyphSize = 12,
        variant = "ghost",
        onClick = thinkingToggleCallback(message),
      }),
      ui.label({ text = "thinking", color = "on_surface_variant", fontSize = 11 }),
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
  if message.queued then
    table.insert(content, ui.label({
      text = "queued",
      color = "on_surface_variant",
      fontSize = 10,
      maxWidth = 280,
    }))
  end
  table.insert(content, ui.label({ text = message.text, color = textColor, fontSize = 13, maxWidth = 280 }))
  -- Per-message actions (copy / retry) only apply once the message has
  -- settled - not while it's actively streaming.
  if message.text ~= ""
    and (message.status == "done" or message.status == "stopped" or message.status == "error") then
    local actions = {
      ui.button({ glyph = "copy", variant = "ghost", onClick = copyCallback(message) }),
    }
    if not streaming
      and not isUser
      and isLastMessage(message)
      and (message.status == "stopped" or message.status == "error") then
      table.insert(actions, ui.button({ glyph = "repeat", variant = "ghost", onClick = retryCallback(message) }))
    end
    table.insert(content, ui.row({ gap = 4 }, actions))
  end
  if message.queued and not streaming then
    table.insert(content, ui.row({ gap = 6 }, {
      ui.button({ glyph = "check", variant = "ghost", onClick = "onSendQueued" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCancelQueued" }),
    }))
  end
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
    fill = message.queued and "secondary/0.25" or (isUser and "surface_variant" or nil),
    radius = message.queued and 8 or (isUser and 12 or 0),
    paddingH = message.queued and 6 or (isUser and 10 or 0),
    paddingV = message.queued and 4 or (isUser and 8 or 0),
    align = "start",
    gap = 4,
  }, content)

  return ui.row({
    key = message.key,
    justify = isUser and "end" or "start",
  }, { bubble })
end

-- TEMPORARY WORKAROUND: ui.scroll exposes no programmatic scroll-to-bottom
-- (or scroll-to-top) prop for plugins, so a normal oldest-first list leaves
-- new messages below the fold in a long chat. Render newest-first instead so
-- fresh content lands directly under the header, and move the "earlier
-- messages hidden" notice to the bottom (it now represents the oldest end of
-- the visible window). Revert to oldest-first once noctalia adds a scroll
-- control the plugin can drive.
local function messageList()
  local visible, hasHidden = visibleMessages()
  local rows = {}
  for i = #visible, 1, -1 do
    table.insert(rows, messageRow(visible[i]))
  end
  if hasHidden then
    table.insert(rows, ui.label({
      key = "hidden-notice",
      text = "\226\128\166 earlier messages hidden",
      color = "on_surface_variant",
      fontSize = 11,
    }))
  end
  return ui.scroll({ flexGrow = 1, gap = 8 }, rows)
end

local function openChatCallback(chat)
  local name = "onOpenChat_" .. chat.id:gsub("%W", "_")
  env[name] = function()
    if streaming then
      return
    end
    sessionId = chat.id
    hasSession = true
    currentUuid = chat.id
    messages = {}
    msgCounter = 0
    openMessage = nil
    queuedPrompt = nil
    queuedKey = nil
    overrideModel = ""
    overrideEffort = ""
    diagBuffer = {}
    view = "chat"
    renamingChatId = nil
    pendingDeleteChatId = nil
    local ok, err = pcall(function()
      local path = transcriptsDir() .. "/" .. chat.id .. ".jsonl"
      local info = noctalia.fileInfo(path)
      if info ~= nil and not info.isDir then
        if info.size < 131072 then
          local content = noctalia.readFile(path)
          if type(content) == "string" then
            local t0 = os.clock()
            messages = parseTranscript(content, "hist-" .. chat.id:sub(1, 8))
            msgCounter = #messages
            noctalia.log(string.format(
              "Claude launcher: transcript reload size=%d bytes parse_ms=%.3f",
              info.size,
              (os.clock() - t0) * 1000
            ))
          end
        else
          messages = {
            {
              role = "assistant",
              text = "(history too large to reload - the conversation continues from here)",
              thinking = "",
              thinkingOpen = false,
              status = "done",
              key = "hist-" .. chat.id:sub(1, 8) .. "-1",
            },
          }
          msgCounter = #messages
        end
      end
    end)
    if not ok then
      noctalia.log("Claude launcher: transcript reload failed: " .. tostring(err))
      messages = {}
      msgCounter = 0
    end
    render()
  end
  return name
end

local function renameChatCallback(chat)
  local name = "onRenameChat_" .. chat.id:gsub("%W", "_")
  env[name] = function()
    if streaming then
      return
    end
    renamingChatId = chat.id
    render()
  end
  return name
end

local function terminalChatCallback(chat)
  local name = "onTerminalChat_" .. chat.id:gsub("%W", "_")
  env[name] = function()
    if streaming then
      return
    end
    local cmd = "cd " .. shellQuote(workspaceDir()) .. " && " .. claudeCommand() .. " --resume " .. shellQuote(chat.id)
    if not noctalia.runInTerminal(cmd) then
      noctalia.notifyError("Claude launcher", "could not open a terminal")
    end
  end
  return name
end

-- Trash click only arms the two-step confirm (see pendingDeleteChatId); the
-- actual delete happens in the plain onConfirmDeleteChat global below.
local function deleteChatCallback(chat)
  local name = "onDeleteChat_" .. chat.id:gsub("%W", "_")
  env[name] = function()
    if streaming then
      return
    end
    pendingDeleteChatId = chat.id
    render()
  end
  return name
end

local function historyList()
  if #historyIndex.chats == 0 then
    return ui.scroll({ flexGrow = 1, gap = 6 }, {
      ui.column({ key = "history-empty", flexGrow = 1, gap = 12, align = "center", justify = "center" }, {
        ui.glyph({ name = "history", size = 48, color = "on_surface_variant" }),
        ui.label({ text = "No chats yet", color = "on_surface_variant", fontSize = 12 }),
      }),
    })
  end

  local rows = {}
  for _, chat in ipairs(historyIndex.chats) do
    local titleControl
    if renamingChatId == chat.id then
      titleControl = ui.input({
        key = "rename-" .. chat.id,
        value = chat.title,
        focus = true,
        flexGrow = 1,
        onSubmit = "onRenameSubmit",
      })
    else
      titleControl = ui.button({
        text = chat.title,
        variant = "ghost",
        flexGrow = 1,
        onClick = openChatCallback(chat),
      })
    end

    local row = {
      titleControl,
      ui.label({
        text = noctalia.formatTime("%b %d %H:%M", chat.updatedAt),
        color = "on_surface_variant",
        fontSize = 11,
      }),
    }
    if pendingDeleteChatId == chat.id then
      table.insert(row, ui.label({ text = "delete?", color = "error", fontSize = 12 }))
      table.insert(row, ui.button({ glyph = "check", variant = "primary", onClick = "onConfirmDeleteChat" }))
      table.insert(row, ui.button({ glyph = "close", variant = "ghost", onClick = "onCancelDeleteChat" }))
    else
      table.insert(row, ui.button({ glyph = "pencil", variant = "ghost", onClick = renameChatCallback(chat) }))
      table.insert(row, ui.button({ glyph = "terminal", variant = "ghost", onClick = terminalChatCallback(chat) }))
      table.insert(row, ui.button({ glyph = "trash", variant = "ghost", onClick = deleteChatCallback(chat) }))
    end

    table.insert(rows, ui.row({ key = "chat-" .. chat.id, align = "center", gap = 6 }, row))
  end
  return ui.scroll({ flexGrow = 1, gap = 6 }, rows)
end

local function header()
  if view == "history" then
    return ui.row({ align = "center", gap = 8 }, {
      ui.button({ glyph = "arrow-left", variant = "ghost", onClick = "onToggleHistory" }),
      ui.label({ text = "History", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.spacer({ flexGrow = 1 }),
    })
  end

  local children = {
    ui.label({ text = "Claude", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
  }
  if #messages > 0 then
    local segments = {}
    if overrideModel ~= "" then
      table.insert(segments, overrideModel)
    end
    if overrideEffort ~= "" then
      table.insert(segments, overrideEffort)
    end
    table.insert(segments, tostring(#messages) .. " msgs")
    table.insert(children, ui.label({
      text = table.concat(segments, " \194\183 "),
      fontSize = 12,
      color = "on_surface_variant",
    }))
  end
  table.insert(children, ui.spacer({ flexGrow = 1 }))
  table.insert(children, ui.button({ glyph = "history", variant = "ghost", onClick = "onToggleHistory" }))
  if #messages > 0 then
    table.insert(children, ui.button({ glyph = "copy", variant = "ghost", onClick = "onCopyChat" }))
  end
  table.insert(children, ui.button({ glyph = "plus", variant = "ghost", onClick = "onNewChat" }))
  return ui.row({ align = "center", gap = 8 }, children)
end

local function composer()
  local sendButton
  if streaming then
    sendButton = ui.button({ glyph = "player-stop", variant = "outline", onClick = "onStop" })
  else
    sendButton = ui.button({ glyph = "send", variant = "primary", onClick = "onSendClick" })
  end

  return ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "composer-" .. inputRev,
      placeholder = "Ask Claude\226\128\166 (Ctrl+Enter to send)",
      flexGrow = 1,
      multiline = true,
      height = COMPOSER_BASE_HEIGHT + (composerLines - 1) * COMPOSER_LINE_HEIGHT,
      enabled = true,
      onChange = "onComposerChanged",
      onSubmit = "onSubmit",
    }),
    sendButton,
  })
end

local function switchers()
  local configuredModels = validStringList(noctalia.getConfig("models"), { "sonnet", "opus", "haiku", "fable" })
  local modelOptions = { "default" }
  for _, model in ipairs(configuredModels) do
    table.insert(modelOptions, model)
  end
  local effortOptions = { "default", "low", "medium", "high", "xhigh", "max" }
  local selectedModel = overrideModel == "" and "default" or overrideModel
  local selectedEffort = overrideEffort == "" and "default" or overrideEffort
  return ui.row({ gap = 8, align = "center" }, {
    ui.select({
      options = modelOptions,
      selectedIndex = selectIndex(modelOptions, selectedModel),
      enabled = not streaming,
      onChange = "onModelChanged",
    }),
    ui.select({
      options = effortOptions,
      selectedIndex = selectIndex(effortOptions, selectedEffort),
      enabled = not streaming,
      onChange = "onEffortChanged",
    }),
  })
end

-- Shown in place of the message list before the first message exists; the
-- model/effort switchers live here instead of a permanent chrome row once a
-- chat has messages (the header caption reports their values then).
local function emptyState()
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, {
    ui.glyph({ name = "sparkles", size = 48, color = "on_surface_variant" }),
    ui.label({ text = "Ask Claude anything", color = "on_surface_variant", fontSize = 12 }),
    switchers(),
  })
end

render = function()
  local children = {
    header(),
  }
  if view == "history" then
    table.insert(children, historyList())
  else
    if #messages == 0 and not streaming then
      table.insert(children, emptyState())
    else
      table.insert(children, messageList())
    end
    table.insert(children, composer())
  end
  panel.render(ui.column({ flexGrow = 1, padding = 12, gap = 12, align = "stretch" }, children))
end

-- ── CALLBACKS ─────────────────────────────────────────────────────────────

local function dispatchQueued()
  if streaming or queuedPrompt == nil then
    return
  end
  local prompt = queuedPrompt
  local queuedMessage = nil
  if queuedKey ~= nil then
    queuedMessage = findMessageByKey(queuedKey)
  end
  if queuedMessage ~= nil then
    queuedMessage.queued = nil
  end
  queuedPrompt = nil
  queuedKey = nil
  local uuid, resume = sessionPolicy()
  startStream(prompt, { uuid = uuid, resume = resume, appendUserRow = false })
end

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
      local msg = openMessage
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
      local msg = openMessage
      local shouldDispatchQueued = false
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
            deleteChat(currentUuid)
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
          upsertChat(currentUuid, titleFromFirstUserMessage())
          shouldDispatchQueued = true
        end
      end
      openMessage = nil
      render()
      if shouldDispatchQueued and queuedPrompt ~= nil then
        dispatchQueued()
      end
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

startStream = function(prompt, opts)
  if opts.appendUserRow then
    appendMessage("user", prompt)
  end
  local assistantMessage = appendMessage("assistant", "", "streaming")
  openMessage = assistantMessage
  local uuid = opts.uuid
  local resume = opts.resume == true
  currentUuid = uuid
  lastSendWasResume = resume
  diagBuffer = {}
  lastLineAt = os.time()
  messageStartSeen = false
  streaming = true
  activeStreamId += 1
  local streamId = activeStreamId
  composerBuffer = ""
  composerLines = 1
  inputRev += 1
  panel.setWantsSecondTicks(true)
  render()

  local madeWorkspace, workspaceErr = noctalia.mkdirAll(workspaceDir())
  if not madeWorkspace then
    noctalia.log("Claude launcher: failed to create workspace dir: " .. tostring(workspaceErr))
  end

  local ok = noctalia.runStream(buildCommand(prompt, uuid, resume), function(line)
    handleLine(streamId, line, resume)
  end)
  if not ok then
    assistantMessage.status = "error"
    assistantMessage.text = "failed to start stream"
    streaming = false
    openMessage = nil
    panel.setWantsSecondTicks(false)
    render()
    noctalia.notifyError("Claude launcher", "failed to start stream")
  end
end

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

  if streaming then
    local queuedMessage = nil
    if queuedKey ~= nil then
      queuedMessage = findMessageByKey(queuedKey)
    end
    if queuedMessage == nil then
      queuedMessage = appendMessage("user", trimmed)
      queuedMessage.queued = true
      queuedKey = queuedMessage.key
    else
      queuedMessage.text = trimmed
      queuedMessage.queued = true
    end
    queuedPrompt = trimmed
    composerBuffer = ""
    composerLines = 1
    inputRev += 1
    render()
    return
  end

  local uuid, resume = sessionPolicy()
  startStream(trimmed, { uuid = uuid, resume = resume, appendUserRow = true })
end

function onSubmit(text)
  doSubmit(text)
end

function onComposerChanged(value)
  composerBuffer = value
  local estimated = estimateComposerLines(value)
  if estimated ~= composerLines then
    composerLines = estimated
    render()
  end
end

function onSendClick()
  doSubmit(composerBuffer)
end

function onModelChanged(_index, text)
  if text == "default" then
    overrideModel = ""
  elseif type(text) == "string" then
    overrideModel = text
  end
  render()
end

function onEffortChanged(_index, text)
  if text == "default" then
    overrideEffort = ""
  elseif type(text) == "string" then
    overrideEffort = text
  end
  render()
end

function onSendQueued()
  dispatchQueued()
end

function onCancelQueued()
  if queuedKey ~= nil then
    removeMessageByKey(queuedKey)
  end
  queuedPrompt = nil
  queuedKey = nil
  render()
end

function onStop()
  if currentUuid ~= nil then
    noctalia.runAsync("pkill -TERM -f " .. shellQuote(currentUuid))
  end
  streaming = false
  activeStreamId += 1
  local message = openMessage
  if message ~= nil then
    message.status = "stopped"
  end
  openMessage = nil
  panel.setWantsSecondTicks(false)
  render()
end

function onLoginTerminal()
  if not noctalia.runInTerminal(claudeCommand()) then
    noctalia.notifyError("Claude launcher", "could not open a terminal")
  end
end

function onCopyChat()
  local parts = {}
  for _, message in ipairs(messages) do
    if message.text ~= "" then
      local roleLabel = message.role == "user" and "User:" or "Claude:"
      table.insert(parts, roleLabel .. " " .. message.text)
    end
  end
  noctalia.copyToClipboard(table.concat(parts, "\n\n"), "text/plain")
end

function onToggleHistory()
  if streaming then
    return
  end
  if view == "chat" then
    view = "history"
  else
    view = "chat"
    renamingChatId = nil
  end
  pendingDeleteChatId = nil
  render()
end

function onConfirmDeleteChat()
  if streaming or pendingDeleteChatId == nil then
    return
  end
  deleteChat(pendingDeleteChatId)
  pendingDeleteChatId = nil
  render()
end

function onCancelDeleteChat()
  pendingDeleteChatId = nil
  render()
end

function onRenameSubmit(text)
  if streaming then
    return
  end
  if renamingChatId ~= nil then
    local title = noctalia.string.trim(text or "")
    if title ~= "" then
      renameChat(renamingChatId, title)
    end
  end
  renamingChatId = nil
  render()
end

function onNewChat()
  if streaming then
    return
  end
  messages = {}
  msgCounter = 0
  sessionId = nil
  hasSession = false
  currentUuid = nil
  diagBuffer = {}
  streaming = false
  openMessage = nil
  queuedPrompt = nil
  queuedKey = nil
  view = "chat"
  renamingChatId = nil
  overrideModel = ""
  overrideEffort = ""
  activeStreamId += 1
  deltaCount = 0
  composerBuffer = ""
  composerLines = 1
  inputRev += 1
  panel.setWantsSecondTicks(false)
  render()
end

function update()
  if not streaming or watchdogInFlight or currentUuid == nil then
    return
  end
  -- 5s of silence just triggers a pgrep liveness probe; a slow first token is
  -- harmless (the process is found and nothing happens). Only a vanished
  -- process finalizes as an error.
  if os.time() - lastLineAt <= 5 then
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
      local message = openMessage
      if message ~= nil then
        message.status = "error"
        if message.text ~= "" then
          message.text ..= "\n"
        end
        message.text ..= "claude exited without a result"
        if #diagBuffer > 0 then
          message.text ..= "\n" .. diagTail(5)
        end
        if lastSendWasResume then
          sessionId = nil
          hasSession = false
          deleteChat(currentUuid)
          message.text ..= "\nSession could not be resumed - starting a new chat on next send."
        end
      end
      streaming = false
      openMessage = nil
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
