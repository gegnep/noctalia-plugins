--!nonstrict
-- Claude launcher: a thin prompt panel with model and effort pickers. Enter
-- runs the first turn through the claude CLI in print mode. When it finishes,
-- the session moves to Claude Desktop (claude://resume?session=<uuid>), the
-- panel closes and the Desktop window takes focus.

-- ── STATE ─────────────────────────────────────────────────────────────────

-- Composer auto-grow: base control height plus a per-extra-line increment,
-- capped so the input fits the 170 px panel.
local COMPOSER_BASE_HEIGHT = 34
local COMPOSER_LINE_HEIGHT = 20
local COMPOSER_WRAP_WIDTH = 38
local COMPOSER_MAX_LINES = 3
-- Panel width 420 minus 12 px padding on each side.
local CONTENT_WIDTH = 396

-- Desktop handoff. Both Desktop instances share this app id; the work one
-- runs with --user-data-dir=~/.config/Claude-work, which its cmdline shows.
local DESKTOP_APP_ID = "com.anthropic.Claude"
local DESKTOP_WORK_MARKER = "Claude-work"
-- 30 polls, 0.5 s apart: 15 s for a cold start.
local FOCUS_POLL_ATTEMPTS = 30
local FOCUS_POLL_DELAY = "0.5"
local XDG_OPEN_TIMEOUT_MS = 10000

-- phase: "idle" (composer), "running" (first turn streaming), "handoff"
-- (result in, xdg-open pending), "error" (banner over the composer).
local phase = "idle"
local panelOpen = false
-- uuid of the current or last turn. It is also the pkill/pgrep needle: it
-- appears in claude's argv.
local sessionId = nil
local activeStreamId = 0
local startedAt = 0
local lastLineAt = 0
local elapsedShown = 0
local watchdogInFlight = false
local activity = "Working"
local sentPrompt = ""
local errorText = ""
local errorNeedsLogin = false
local errorCanResume = false
local diagBuffer = {}
local seenUnknownTypes = {}

-- Picker choices. "" falls back to the settings default. Memory only.
local overrideModel = ""
local overrideEffort = ""

-- ui.input is uncontrolled, and `value` and `focus` apply only when the
-- control is created. A new key (inputRev) is the only way to reset, refill
-- or refocus it; composerSeed is the value the next instance starts with.
local inputRev = 0
local composerSeed = ""
local composerBuffer = ""
local composerLines = 1

-- ── HELPERS ───────────────────────────────────────────────────────────────

-- Forward declaration: the turn functions below call render, so the local
-- must exist BEFORE they are defined. A closure created earlier would bind a
-- nil global, and the host's health breaker would disable the panel.
local render

local function shellQuote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function newUuid()
  local text, err = noctalia.readFile("/proc/sys/kernel/random/uuid")
  if type(text) == "string" then
    local uuid = noctalia.string.trim(text)
    if uuid ~= "" then
      return uuid
    end
  end
  noctalia.log("Claude launcher: failed to read uuid: " .. tostring(err))
  return nil
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

local function configuredFolder()
  local cfg = noctalia.getConfig("folder")
  if type(cfg) ~= "string" then
    return ""
  end
  return noctalia.string.trim(cfg)
end

-- Where the turn runs. Claude Desktop reads the cwd from the transcript and
-- trusts that folder when it imports the session.
local function sessionFolder()
  local folder = configuredFolder()
  if folder ~= "" then
    return noctalia.expandPath(folder)
  end
  return workspaceDir()
end

-- 0.1.x kept chat history in these files. Claude Desktop owns history now.
local function removeLegacyState()
  for _, name in ipairs({ "index.json", "last-session" }) do
    local path = statePath() .. "/" .. name
    if noctalia.fileExists(path) then
      local ok, err = noctalia.removeFile(path)
      if not ok then
        noctalia.log("Claude launcher: could not remove " .. path .. ": " .. tostring(err))
      end
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

local function indexOf(list, value)
  for i, item in ipairs(list) do
    if item == value then
      return i
    end
  end
  return nil
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

-- Current models, biggest first. Ids outside this table (custom entries in
-- the Models setting) show their raw id.
local MODEL_INFO = {
  ["claude-fable-5-1"] = { label = "Fable 5.1" },
  ["claude-opus-5-5"] = { label = "Opus 5.5" },
  ["claude-sonnet-5-5"] = { label = "Sonnet 5.5" },
  ["claude-haiku-5-5"] = { label = "Haiku 5.5" },
}
local DEFAULT_MODELS = { "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5" }
-- Every model takes the same five levels: --effort accepts them for any model.
local EFFORT_LEVELS = { "low", "medium", "high", "xhigh", "max" }
local EFFORT_LABELS = { "Low", "Medium", "High", "X-High", "Max" }

local function modelLabel(alias)
  local info = MODEL_INFO[alias]
  if info ~= nil then
    return info.label
  end
  return alias
end

local function availableModels()
  return validStringList(noctalia.getConfig("models"), DEFAULT_MODELS)
end

-- Override, then the settings default ("auto" = first in list), then the
-- first in list. A value missing from the current list never reaches the CLI.
local function effectiveModel()
  local models = availableModels()
  if overrideModel ~= "" and indexOf(models, overrideModel) ~= nil then
    return overrideModel
  end
  local configured = noctalia.getConfig("model")
  if type(configured) == "string" and configured ~= "auto" and indexOf(models, configured) ~= nil then
    return configured
  end
  return models[1]
end

local function effectiveEffort()
  if overrideEffort ~= "" then
    return overrideEffort
  end
  local configured = noctalia.getConfig("effort")
  if type(configured) == "string" and indexOf(EFFORT_LEVELS, configured) ~= nil then
    return configured
  end
  return "high"
end

-- Flags verified against claude --help (CLI v2.1.278 and v2.1.302).
-- --session-id fixes the uuid that the Desktop resume link names.
local function buildCommand(prompt, uuid)
  local cmd = claudeCommand()
    .. " -p " .. shellQuote(prompt)
    .. " --output-format stream-json --verbose --include-partial-messages"
    .. " --session-id " .. shellQuote(uuid)
    .. " --model " .. shellQuote(effectiveModel())
    .. " --effort " .. shellQuote(effectiveEffort())
  -- Tools stay on unless the setting is explicitly off (the default is on).
  if noctalia.getConfig("allow_tools") == false then
    cmd ..= " --tools ''"
  end
  return "cd " .. shellQuote(sessionFolder()) .. " && " .. cmd .. " 2>&1"
end

-- Estimates the wrapped-line count of composer text: one line per newline
-- segment, plus extra lines for segments that would wrap at a rough width.
-- Coarse on purpose: it only grows and shrinks the input's height prop.
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
  return math.max(1, math.min(COMPOSER_MAX_LINES, lines))
end

-- ── UI ────────────────────────────────────────────────────────────────────
-- All three regions stay mounted and collapse with an explicit `visible`
-- (recreating them reads as a flash). Every conditional prop is passed both
-- ways: the reconciler never clears a prop the new tree omits.

local function errorView(visible)
  return ui.column({ key = "error-view", gap = 6, align = "stretch", visible = visible }, {
    ui.label({
      key = "error-text",
      text = errorText,
      color = "error",
      fontSize = 12,
      maxWidth = CONTENT_WIDTH,
      maxLines = 2,
    }),
    ui.row({ key = "error-actions", gap = 6, align = "center" }, {
      ui.button({
        key = "error-login",
        text = "Log in in a terminal",
        variant = "outline",
        visible = errorNeedsLogin,
        onClick = "onLoginTerminal",
      }),
      ui.button({
        key = "error-terminal",
        text = "Continue in terminal",
        variant = "outline",
        visible = errorCanResume,
        onClick = "onResumeInTerminal",
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ key = "error-dismiss", glyph = "close", variant = "ghost", onClick = "onDismissError" }),
    }),
  })
end

local function runningView(visible)
  return ui.column({ key = "running-view", gap = 8, align = "stretch", visible = visible }, {
    ui.label({
      key = "running-prompt",
      text = sentPrompt,
      color = "on_surface_variant",
      fontSize = 12,
      maxWidth = CONTENT_WIDTH,
      maxLines = 2,
    }),
    ui.row({ key = "running-row", gap = 8, align = "center" }, {
      ui.label({
        key = "running-status",
        text = activity .. "\226\128\166 " .. tostring(elapsedShown) .. "s",
        color = "on_surface",
        fontSize = 13,
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({
        key = "stop",
        glyph = "player-stop",
        variant = "outline",
        enabled = phase == "running",
        onClick = "onStop",
      }),
    }),
    ui.label({
      key = "running-hint",
      text = "Opens in Claude Desktop when the first reply is done",
      color = "on_surface_variant/0.8",
      fontSize = 11,
      maxWidth = CONTENT_WIDTH,
      maxLines = 1,
    }),
  })
end

local function composerView(visible)
  local models = availableModels()
  local modelLabels = {}
  for _, alias in ipairs(models) do
    table.insert(modelLabels, modelLabel(alias))
  end
  return ui.column({ key = "composer-view", gap = 8, align = "stretch", visible = visible }, {
    ui.row({ key = "composer-row", gap = 8, align = "center" }, {
      ui.input({
        key = "prompt-" .. inputRev,
        value = composerSeed,
        placeholder = "Ask Claude\226\128\166",
        flexGrow = 1,
        multiline = true,
        submitOnEnter = true,
        focus = true,
        height = COMPOSER_BASE_HEIGHT + (composerLines - 1) * COMPOSER_LINE_HEIGHT,
        enabled = true,
        -- API 27. Stated explicitly: the reconciler applies frameVisible only
        -- when present, so an omitted value would let a retained input keep a
        -- stale frame.
        frameVisible = true,
        onChange = "onComposerChanged",
        onSubmit = "onSubmit",
      }),
      ui.button({ key = "send", glyph = "send", variant = "primary", onClick = "onSendClick" }),
    }),
    -- ui.select, not a pill plus context menu: a left-click onClick carries no
    -- pointer context on this host, so panel.openContextMenu would refuse it.
    ui.row({ key = "picker-row", gap = 8, align = "center" }, {
      ui.select({
        key = "model-select",
        options = modelLabels,
        selectedIndex = (indexOf(models, effectiveModel()) or 1) - 1,
        enabled = true,
        controlSize = "sm",
        onChange = "onModelChanged",
      }),
      ui.select({
        key = "effort-select",
        options = EFFORT_LABELS,
        selectedIndex = (indexOf(EFFORT_LEVELS, effectiveEffort()) or 3) - 1,
        enabled = true,
        controlSize = "sm",
        onChange = "onEffortChanged",
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({
        key = "newline-hint",
        text = "Shift+Enter \194\183 new line",
        color = "on_surface_variant",
        fontSize = 11,
        maxWidth = 120,
        maxLines = 1,
      }),
    }),
  })
end

render = function()
  panel.render(ui.column({ flexGrow = 1, padding = 12, gap = 8, align = "stretch" }, {
    errorView(phase == "error"),
    runningView(phase == "running" or phase == "handoff"),
    composerView(phase == "idle" or phase == "error"),
  }))
end

-- ── TURN ──────────────────────────────────────────────────────────────────

local function resetComposer(text)
  composerSeed = text
  composerBuffer = text
  composerLines = estimateComposerLines(text)
  inputRev += 1
end

-- Ends the turn as an error: banner over the composer, prompt restored so
-- Enter retries as a fresh session. A closed panel gets a notification.
local function failTurn(message, opts)
  activeStreamId += 1
  phase = "error"
  errorText = message
  errorNeedsLogin = opts ~= nil and opts.needsLogin == true
  errorCanResume = opts ~= nil and opts.canResume == true
  resetComposer(sentPrompt)
  panel.setWantsSecondTicks(false)
  if not panelOpen then
    noctalia.notifyError("Claude launcher", string.sub(message, 1, 300))
  end
  render()
end

local function isWorkInstance(pid)
  local cmdline = noctalia.readFile("/proc/" .. tostring(pid) .. "/cmdline")
  return type(cmdline) == "string" and string.find(cmdline, DESKTOP_WORK_MARKER, 1, true) ~= nil
end

local function personalDesktopWindowId(windowsJson)
  local windows = noctalia.json.decode(windowsJson)
  if type(windows) ~= "table" then
    return nil
  end
  for _, window in ipairs(windows) do
    if type(window) == "table" and window.app_id == DESKTOP_APP_ID and type(window.id) == "number" then
      if type(window.pid) ~= "number" or not isWorkInstance(window.pid) then
        return window.id
      end
    end
  end
  return nil
end

-- Polls niri until the personal Desktop window exists (a cold start takes a
-- few seconds), then focuses it. runAsync callbacks keep arriving after the
-- panel closes, unlike update() ticks, so `sleep` paces the loop.
local function focusDesktopWindow(attempt)
  noctalia.runAsync({ "niri", "msg", "--json", "windows" }, function(result)
    local id = nil
    if result ~= nil and result.exitCode == 0 and type(result.stdout) == "string" then
      id = personalDesktopWindowId(result.stdout)
    end
    if id ~= nil then
      noctalia.runAsync({ "niri", "msg", "action", "focus-window", "--id", tostring(id) })
      return
    end
    if attempt >= FOCUS_POLL_ATTEMPTS then
      noctalia.log("Claude launcher: no Claude Desktop window to focus after " .. attempt .. " polls")
      return
    end
    noctalia.runAsync({ "sleep", FOCUS_POLL_DELAY }, function()
      focusDesktopWindow(attempt + 1)
    end)
  end)
end

-- The CLI has written the whole first turn: hand the session to Desktop.
-- The panel closes only once xdg-open reports success, so a missing handler
-- keeps it up with the terminal fallback.
local function handOff()
  phase = "handoff"
  activity = "Opening Claude Desktop"
  panel.setWantsSecondTicks(false)
  render()
  local started = noctalia.runAsync({ "xdg-open", "claude://resume?session=" .. sessionId }, function(result)
    if phase ~= "handoff" then
      return
    end
    if result == nil or result.exitCode ~= 0 or result.timedOut == true then
      local detail = ""
      if result ~= nil and type(result.stderr) == "string" then
        detail = noctalia.string.trim(result.stderr)
      end
      local message = "Could not open Claude Desktop"
      if detail ~= "" then
        message ..= ": " .. detail
      end
      failTurn(message, { canResume = true })
      return
    end
    phase = "idle"
    resetComposer("")
    -- The host drops this tree: a close request is handled before the UI
    -- patch. Keep it anyway; onOpen re-keys and re-renders from this state.
    render()
    panel.close()
    if noctalia.commandExists("niri") then
      focusDesktopWindow(1)
    end
  end, XDG_OPEN_TIMEOUT_MS)
  if not started then
    failTurn("Could not run xdg-open", { canResume = true })
  end
end

-- Called from the runStream closure. The streamId and phase guards drop lines
-- that arrive after a stop, an error or the result.
local function handleLine(streamId, line)
  local ok, perr = pcall(function()
    if streamId ~= activeStreamId or phase ~= "running" then
      return
    end
    lastLineAt = os.time()

    local ev = noctalia.json.decode(line)
    if type(ev) ~= "table" then
      -- Not JSON: stderr from claude or its wrapper (the command merges 2>&1).
      pushDiag(line)
      noctalia.log(line)
      return
    end

    if ev.type == "system" then
      if ev.subtype == "init" and ev.session_id ~= sessionId then
        noctalia.log("Claude launcher: session_id mismatch: " .. tostring(ev.session_id) .. " != " .. tostring(sessionId))
      end
    elseif ev.type == "stream_event" then
      local event = ev.event
      if type(event) == "table" and event.type == "content_block_start" and type(event.content_block) == "table" then
        local blockType = event.content_block.type
        local nextActivity = "Working"
        if blockType == "thinking" then
          nextActivity = "Thinking"
        elseif blockType == "text" then
          nextActivity = "Writing"
        end
        if nextActivity ~= activity then
          activity = nextActivity
          render()
        end
      end
    elseif ev.type == "result" then
      local resultText = type(ev.result) == "string" and ev.result or ""
      if ev.is_error == true or ev.subtype ~= "success" then
        local message = resultText
        if #diagBuffer > 0 then
          if message ~= "" then
            message ..= "\n"
          end
          message ..= diagTail(3)
        end
        if message == "" then
          message = "claude returned an error"
        end
        -- The CLI's not-authenticated error mentions /login. Auth lives in
        -- whatever home claude_command uses, so the fix is one interactive
        -- login with that exact command.
        local needsLogin = string.find(resultText, "/login", 1, true) ~= nil
          or string.find(resultText, "Invalid API key", 1, true) ~= nil
        failTurn(message, { needsLogin = needsLogin })
      else
        handOff()
      end
    elseif ev.type ~= "assistant" and ev.type ~= "rate_limit_event" then
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

local function startTurn(prompt)
  sentPrompt = prompt
  local uuid = newUuid()
  if uuid == nil then
    failTurn("Could not create a session id: /proc/sys/kernel/random/uuid is unreadable")
    return
  end
  sessionId = uuid
  phase = "running"
  activity = "Working"
  errorText = ""
  errorNeedsLogin = false
  errorCanResume = false
  diagBuffer = {}
  startedAt = os.time()
  lastLineAt = startedAt
  elapsedShown = 0
  activeStreamId += 1
  local streamId = activeStreamId
  panel.setWantsSecondTicks(true)
  render()

  if configuredFolder() == "" then
    local made, mkErr = noctalia.mkdirAll(workspaceDir())
    if not made then
      noctalia.log("Claude launcher: failed to create workspace dir: " .. tostring(mkErr))
    end
  end

  local ok = noctalia.runStream(buildCommand(prompt, uuid), function(line)
    handleLine(streamId, line)
  end)
  if not ok then
    failTurn("Could not start claude")
  end
end

-- ── CALLBACKS ─────────────────────────────────────────────────────────────

local function doSubmit(text)
  if phase == "running" or phase == "handoff" then
    return
  end
  local trimmed = noctalia.string.trim(text or "")
  if trimmed == "" then
    return
  end
  startTurn(trimmed)
end

-- Enter: the host passes the input's committed value.
function onSubmit(text)
  doSubmit(text)
end

-- The send button carries no value; composerBuffer mirrors the input.
function onSendClick()
  doSubmit(composerBuffer)
end

function onComposerChanged(value)
  composerBuffer = value or ""
  local estimated = estimateComposerLines(composerBuffer)
  if estimated ~= composerLines then
    composerLines = estimated
    render()
  end
end

-- ui.select passes a 0-based index (possibly as a string) and the label.
function onModelChanged(index, _label)
  local alias = availableModels()[(tonumber(index) or 0) + 1]
  if alias ~= nil then
    overrideModel = alias
  end
  render()
end

function onEffortChanged(index, _label)
  local level = EFFORT_LEVELS[(tonumber(index) or 0) + 1]
  if level ~= nil then
    overrideEffort = level
  end
  render()
end

function onStop()
  if phase ~= "running" then
    return
  end
  if sessionId ~= nil then
    noctalia.runAsync({ "pkill", "-TERM", "-f", sessionId })
  end
  activeStreamId += 1
  phase = "idle"
  resetComposer(sentPrompt)
  panel.setWantsSecondTicks(false)
  render()
end

function onDismissError()
  phase = "idle"
  errorText = ""
  errorNeedsLogin = false
  errorCanResume = false
  render()
end

function onLoginTerminal()
  if not noctalia.runInTerminal(claudeCommand()) then
    noctalia.notifyError("Claude launcher", "could not open a terminal")
  end
end

function onResumeInTerminal()
  if sessionId == nil then
    return
  end
  local cmd = "cd " .. shellQuote(sessionFolder()) .. " && " .. claudeCommand() .. " --resume " .. shellQuote(sessionId)
  if not noctalia.runInTerminal(cmd) then
    noctalia.notifyError("Claude launcher", "could not open a terminal")
  end
end

-- Second ticks (requested only while running) drive the elapsed counter and
-- the watchdog. The host stops ticks while the panel is closed; a turn that
-- ends meanwhile still hands off through the runStream callback.
function update()
  if phase ~= "running" then
    return
  end
  local elapsed = os.time() - startedAt
  if elapsed ~= elapsedShown then
    elapsedShown = elapsed
    render()
  end
  -- 5 s of silence only triggers a pgrep liveness probe. The argv form runs
  -- pgrep directly, so no sh wrapper carrying the uuid can match itself.
  if watchdogInFlight or sessionId == nil or os.time() - lastLineAt <= 5 then
    return
  end
  watchdogInFlight = true
  local streamId = activeStreamId
  local ok = noctalia.runAsync({ "pgrep", "-f", sessionId }, function(result)
    watchdogInFlight = false
    if phase ~= "running" or streamId ~= activeStreamId then
      return
    end
    local stdout = ""
    if result ~= nil and type(result.stdout) == "string" then
      stdout = noctalia.string.trim(result.stdout)
    end
    if stdout == "" then
      local message = "claude exited without a result"
      if #diagBuffer > 0 then
        message ..= "\n" .. diagTail(3)
      end
      failTurn(message)
    end
  end)
  if not ok then
    watchdogInFlight = false
  end
end

function onOpen(_context)
  panelOpen = true
  -- `focus` applies once per control and this VM outlives the panel, so
  -- re-key the composer on every open, seeded with the current draft.
  if phase == "idle" or phase == "error" then
    composerSeed = composerBuffer
    inputRev += 1
  end
  render()
end

function onClose()
  panelOpen = false
end

removeLegacyState()
render()
