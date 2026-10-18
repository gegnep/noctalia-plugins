-- Test harness feeder: drives render() and the callbacks directly (no stream
-- fixture) and asserts the UI tree and the turn state machine around it.
-- Concatenated after harness-prelude.luau + ../panel.luau by dry-run.sh.

local function walk(node, visit)
  if type(node) ~= "table" then
    return
  end
  if node.type ~= nil then
    visit(node)
  end
  for _, child in ipairs(node.children or {}) do
    walk(child, visit)
  end
end

local function findNode(predicate)
  local found = nil
  walk(HARNESS_LAST_TREE, function(node)
    if found == nil and predicate(node) then
      found = node
    end
  end)
  return found
end

local function findKey(key)
  local node = findNode(function(n)
    return n.props.key == key
  end)
  assert(node ~= nil, "no node keyed " .. key)
  return node
end

-- True when a node keyed `key` sits inside the subtree keyed `ancestorKey`.
local function within(key, ancestorKey)
  local inside = false
  walk(findKey(ancestorKey), function(n)
    if n.props.key == key then
      inside = true
    end
  end)
  return inside
end

local function promptInput()
  local node = findNode(function(n)
    return n.type == "input" and type(n.props.key) == "string" and string.sub(n.props.key, 1, 7) == "prompt-"
  end)
  assert(node ~= nil, "prompt input missing")
  return node
end

local function lastAsync()
  return HARNESS_ASYNC[#HARNESS_ASYNC]
end

local function argvEquals(cmd, expected)
  if type(cmd) ~= "table" or #cmd ~= #expected then
    return false
  end
  for i, value in ipairs(expected) do
    if cmd[i] ~= value then
      return false
    end
  end
  return true
end

local function registered(name)
  return type(name) == "string" and type(getfenv()[name]) == "function"
end

local function okResult(stdout)
  return { exitCode = 0, stdout = stdout or "", stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false }
end

local SUCCESS = '{"type":"result","subtype":"success","is_error":false,"result":"hi"}'
local WORKSPACE = "~/.local/state/noctalia-claude-launcher/workspace"

onOpen("")

-- 1. Models: exactly the four current ids, biggest first, all on Low..Max.
local expectedModels = { "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5" }
local expectedLabels = { "Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5" }
local models = availableModels()
assert(#models == 4, "default models: " .. #models)
for i, alias in ipairs(expectedModels) do
  assert(models[i] == alias, "model " .. i .. " is " .. tostring(models[i]))
  assert(MODEL_INFO[alias] ~= nil and MODEL_INFO[alias].label == expectedLabels[i], "label for " .. alias)
end
local infoCount = 0
for _ in pairs(MODEL_INFO) do
  infoCount += 1
end
assert(infoCount == 4, "MODEL_INFO must list only the four current models, has " .. infoCount)
assert(effectiveModel() == "claude-fable-5-1", "auto must pick the first model")
assert(effectiveEffort() == "high", "auto effort must be high")

-- 2. Idle tree: one thin row. Focused single-line composer, two selects in sync.
assert((HARNESS_LAST_TREE.props.padding or 0) == 0, "the host already pads the panel; the root must not add padding")
local input = promptInput()
assert(input.props.frameVisible == true, "frameVisible must be explicit")
assert(input.props.focus == true, "the composer must request focus")
assert(input.props.submitOnEnter == true and input.props.multiline == false, "single-line input, Enter sends")
assert(input.props.controlSize == "md" and input.props.height == nil, "the input keeps the md control height")
assert(findNode(function(n) return n.props.key == "newline-hint" end) == nil, "no Shift+Enter hint on a single line")
assert(registered(input.props.onSubmit) and registered(input.props.onChange), "composer callbacks unregistered")
assert(registered(findKey("send").props.onClick), "send callback unregistered")
local modelSelect = findKey("model-select")
local effortSelect = findKey("effort-select")
assert(modelSelect.type == "select" and effortSelect.type == "select", "pickers must be ui.select")
assert(#modelSelect.props.options == 4 and modelSelect.props.options[1] == "Fable 5.1", "model options")
assert(modelSelect.props.selectedIndex == 0, "model selectedIndex " .. tostring(modelSelect.props.selectedIndex))
assert(#effortSelect.props.options == 5 and effortSelect.props.options[5] == "Max", "effort options")
assert(effortSelect.props.selectedIndex == 2, "effort selectedIndex " .. tostring(effortSelect.props.selectedIndex))
assert(registered(modelSelect.props.onChange) and registered(effortSelect.props.onChange), "select callbacks unregistered")
assert(modelSelect.props.controlSize == "md" and effortSelect.props.controlSize == "md", "selects match the input height")
assert(type(modelSelect.props.width) == "number" and type(effortSelect.props.width) == "number",
  "fixed select widths keep the bar from jumping when a label changes")
assert(within("model-select", "composer-view") and within("error-view", "composer-view"),
  "pickers and the error share the composer row")
assert(findKey("picker-row").props.visible == true, "pickers visible when idle")
assert(findKey("composer-view").props.visible == true, "composer visible when idle")
assert(findKey("running-view").props.visible == false, "running view hidden when idle")
assert(findKey("error-view").props.visible == false, "error view hidden when idle")
assert(findKey("error-login").props.visible == false and findKey("error-terminal").props.visible == false,
  "error buttons must pass visible=false explicitly")

-- 3. Picker callbacks take the host's 0-based index, possibly as a string.
onModelChanged(2, "Sonnet 5.5")
assert(effectiveModel() == "claude-sonnet-5-5", "model pick")
assert(findKey("model-select").props.selectedIndex == 2, "model select did not follow the pick")
onEffortChanged("4", "Max")
assert(effectiveEffort() == "max", "effort pick")
assert(findKey("effort-select").props.selectedIndex == 4, "effort select did not follow the pick")

-- 4. Custom model list: unknown ids show raw; an override missing from the list falls back.
HARNESS_CONFIG.models = { "claude-opus-5-5", "my-alias" }
onModelChanged(0, "Opus 5.5")
onModelChanged(1, "my-alias")
assert(findKey("model-select").props.options[2] == "my-alias", "unknown ids must show their raw id")
assert(effectiveModel() == "my-alias", "a custom alias must be pickable")
HARNESS_CONFIG.models = nil
assert(effectiveModel() == "claude-fable-5-1", "an override missing from the list must fall back to the first model")
overrideModel = ""
overrideEffort = ""

-- 5. Reopen re-keys the composer (focus applies once per control) and keeps the draft.
onComposerChanged(string.rep("long draft ", 40))
assert(promptInput().props.height == nil, "a long draft must scroll sideways, not grow the input")
onComposerChanged("draft text")
local keyBefore = promptInput().props.key
onClose()
onOpen("")
local reopened = promptInput()
assert(reopened.props.key ~= keyBefore, "onOpen must re-key the composer")
assert(reopened.props.value == "draft text", "onOpen must keep the draft")
onComposerChanged("")

-- 6. Submit: running view, one turn at a time, blank prompts ignored.
onSubmit("   ")
assert(phase == "idle", "a blank prompt must not start a turn")
onSubmit("hello there")
assert(phase == "running", "submit must start a turn")
assert(findKey("running-view").props.visible == true, "running view visible while running")
assert(findKey("composer-view").props.visible == false, "composer hidden while running")
assert(findKey("running-prompt").props.text == "hello there", "the running view must echo the prompt")
assert(findKey("stop").props.enabled == true, "stop enabled while running")
assert(registered(findKey("stop").props.onClick), "stop callback unregistered")
local firstCmd = HARNESS_STREAM_CMD
onSubmit("second prompt")
onSendClick()
assert(HARNESS_STREAM_CMD == firstCmd, "a submit while running must be ignored")

-- 7. Elapsed seconds tick through update().
startedAt = os.time() - 7
update()
local status = findKey("running-status").props.text
assert(string.find(status, "7s", 1, true) ~= nil, "status must show elapsed seconds: " .. status)

-- 8. Stop kills by session id, discards the turn, restores the prompt.
onStop()
assert(argvEquals(lastAsync().cmd, { "pkill", "-TERM", "-f", HARNESS_UUID }), "stop must pkill the session id")
assert(phase == "idle", "phase after stop")
assert(promptInput().props.value == "hello there", "stop must restore the prompt")
assert(HARNESS_SECOND_TICKS == false, "stop must release second ticks")
CAPTURED_ONLINE(SUCCESS)
assert(phase == "idle", "a result after stop must be dropped")

-- 9. Error result: one inline line with the login button, prompt restored for retry.
onSubmit("hello there")
CAPTURED_ONLINE('not json: wrapper noise on stderr')
local logsBeforeError = #HARNESS_LOGS
CAPTURED_ONLINE('{"type":"result","subtype":"success","is_error":true,"result":"Not logged in. Please run /login"}')
assert(phase == "error", "an error result must not hand off")
assert(string.find(errorText, "/login", 1, true) ~= nil, "error text must carry the CLI message")
assert(string.find(errorText, "wrapper noise", 1, true) ~= nil, "error text must carry the stderr tail")
local loggedFull = false
for i = logsBeforeError + 1, #HARNESS_LOGS do
  if string.find(HARNESS_LOGS[i], "/login", 1, true) ~= nil and string.find(HARNESS_LOGS[i], "wrapper noise", 1, true) ~= nil then
    loggedFull = true
  end
end
assert(loggedFull, "the one-line banner hides the stderr tail, so the full error must be logged")
assert(findKey("error-view").props.visible == true, "error view visible")
assert(findKey("error-text").props.maxLines == 1, "the error is one line in the thin bar")
assert(findKey("picker-row").props.visible == false, "the error takes the pickers' place")
assert(findKey("composer-view").props.visible == true, "composer visible beside the error")
assert(findKey("error-login").props.visible == true, "a /login error offers the login button")
assert(findKey("error-terminal").props.visible == false, "no terminal resume for a CLI error")
assert(promptInput().props.value == "hello there", "an error must restore the prompt")
assert(registered(findKey("error-login").props.onClick) and registered(findKey("error-dismiss").props.onClick),
  "error callbacks unregistered")
onLoginTerminal()
assert(HARNESS_TERMINAL[#HARNESS_TERMINAL] == "claude", "login runs the claude command in a terminal")
onDismissError()
assert(phase == "idle" and findKey("error-view").props.visible == false, "dismiss clears the error")
assert(findKey("picker-row").props.visible == true, "dismiss brings the pickers back")

-- 10. xdg-open failure keeps the panel open and offers the terminal resume.
onSubmit("hello there")
CAPTURED_ONLINE(SUCCESS)
local open = lastAsync()
assert(open.cmd[1] == "xdg-open", "a success result must run xdg-open")
local closedBefore = HARNESS_PANEL_CLOSED
open.cb({ exitCode = 4, stdout = "", stderr = "no handler", timedOut = false, stdoutTruncated = false, stderrTruncated = false })
assert(phase == "error", "a failed xdg-open is an error")
assert(HARNESS_PANEL_CLOSED == closedBefore, "a failed xdg-open must not close the panel")
assert(findKey("error-terminal").props.visible == true, "an xdg-open failure offers Continue in terminal")
assert(registered(findKey("error-terminal").props.onClick), "terminal resume callback unregistered")
onResumeInTerminal()
assert(HARNESS_TERMINAL[#HARNESS_TERMINAL] == "cd '" .. WORKSPACE .. "' && claude --resume '" .. HARNESS_UUID .. "'",
  "terminal resume command: " .. tostring(HARNESS_TERMINAL[#HARNESS_TERMINAL]))
onDismissError()

-- 11. An error while the panel is closed surfaces as a notification.
onSubmit("hello there")
onClose()
local logsBefore = #HARNESS_LOGS
CAPTURED_ONLINE('{"type":"result","subtype":"error_during_execution","is_error":true,"result":"rate limited"}')
local notified = false
for i = logsBefore + 1, #HARNESS_LOGS do
  if string.find(HARNESS_LOGS[i], "notifyError: Claude launcher", 1, true) == 1 then
    notified = true
  end
end
assert(notified, "an error with the panel closed must notify")
onOpen("")
onDismissError()

-- 12. Watchdog: a live process is left alone; a vanished one fails the turn.
onSubmit("hello there")
lastLineAt = os.time() - 10
update()
local probe = lastAsync()
assert(argvEquals(probe.cmd, { "pgrep", "-f", HARNESS_UUID }), "the watchdog must pgrep the session id via argv")
probe.cb(okResult("4242\n"))
assert(phase == "running", "a live process must not fail the turn")
lastLineAt = os.time() - 10
update()
probe = lastAsync()
assert(probe.cmd[1] == "pgrep", "second probe missing")
probe.cb({ exitCode = 1, stdout = "", stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false })
assert(phase == "error" and string.find(errorText, "exited without a result", 1, true) ~= nil,
  "a vanished process must fail the turn")
onDismissError()

-- 13. Tools off and a custom folder change the command; the workspace is only made when used.
HARNESS_CONFIG.allow_tools = false
HARNESS_CONFIG.folder = "  /home/u/project  "
local mkdirsBefore = #HARNESS_MKDIRS
onSubmit("hello there")
assert(string.find(HARNESS_STREAM_CMD, "cd '/home/u/project' && ", 1, true) == 1, "custom folder: " .. HARNESS_STREAM_CMD)
assert(string.find(HARNESS_STREAM_CMD, " --tools ''", 1, true) ~= nil, "allow_tools=false must disable tools")
assert(#HARNESS_MKDIRS == mkdirsBefore, "a custom folder must not be created")
onStop()
HARNESS_CONFIG.allow_tools = nil
HARNESS_CONFIG.folder = nil

-- 14. Focus polling gives up after 30 polls and never focuses another app.
onSubmit("hello there")
CAPTURED_ONLINE(SUCCESS)
lastAsync().cb(okResult())
local polls = 0
local guard = 0
while guard < 200 do
  guard += 1
  local call = lastAsync()
  if argvEquals(call.cmd, { "niri", "msg", "--json", "windows" }) then
    polls += 1
    local before = #HARNESS_ASYNC
    call.cb(okResult('[{"id":6,"app_id":"org.gnome.Nautilus","pid":333,"title":"Files"}]'))
    if #HARNESS_ASYNC == before then
      break
    end
  elseif argvEquals(call.cmd, { "sleep", "0.5" }) then
    call.cb(okResult())
  else
    error("unexpected call while polling: " .. tostring(call.cmd[1]))
  end
end
assert(polls == 30, "focus must poll 30 times before giving up, polled " .. polls)

-- 15. Without niri there is no window polling at all.
HARNESS_COMMANDS.niri = false
onOpen("")
onSubmit("hello there")
CAPTURED_ONLINE(SUCCESS)
local beforeClose = #HARNESS_ASYNC
lastAsync().cb(okResult())
assert(#HARNESS_ASYNC == beforeClose, "without niri the handoff must not poll for windows")
HARNESS_COMMANDS.niri = true

print("UI DRY-RUN OK  async=" .. #HARNESS_ASYNC .. "  logs=" .. #HARNESS_LOGS)
