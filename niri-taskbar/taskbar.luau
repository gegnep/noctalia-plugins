--!nonstrict
-- niri taskbar: workspace chips that expand on hover to show each
-- workspace's windows. P1 wires the UI to niri IPC while preserving the P0
-- hover grace-period behavior.

-- ============================================================
-- STATE
-- ============================================================

local expanded = false

-- Hover grace period. The host's input dispatcher tracks ONE hovered
-- InputArea — the innermost under the pointer (input_dispatcher.cpp:
-- updateHover/findInputAreaAt) — so moving onto any chip/window button
-- fires onHover(false) on the widget even though the pointer is still
-- inside it. Collapse therefore runs on a countdown: onHover(true) (fires
-- again whenever the pointer crosses a gap between buttons) or any click
-- cancels it. Cost: resting motionless on a button collapses after the
-- grace period — fixed properly by the v2 per-node-hover host patch.
local COLLAPSE_GRACE_TICKS = 5 -- ~1.25s at the 250ms update interval
local collapsePending = false
local collapseTicks = 0

local workspacesById = {}
local windowsById = {}
local stateGeneration = 0
local activeStreamToken = ""
local resyncTicks = 0
local fallbackTokenCounter = 0

-- Callback env for the getfenv per-item-callback idiom (see claude-launcher
-- panel.luau: env[name] = function ... end, names keyed by stable ids).
local env = getfenv()
local registeredWorkspaceCallbacks = {}
local registeredWindowCallbacks = {}

-- Forward declarations: closures below capture these locals. The local must
-- exist BEFORE those closures are created, or a closure created earlier
-- silently binds the nil GLOBAL instead — that trips the host's health breaker
-- (5 hard errors/60s) and disables the plugin.
local render
local handleLine
local startStream
local requestSnapshot
local pruneCallbackEnv
local sortedWorkspaces
local windowsForWorkspace
local focusedOutput

-- ============================================================
-- HELPERS
-- ============================================================

local function trim(s)
  return (string.gsub(tostring(s or ""), "^%s*(.-)%s*$", "%1"))
end

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value or ""), "'", "'\\''") .. "'"
end

local function commandStdout(result)
  if type(result) == "table" then
    return tostring(result.stdout or "")
  end
  return tostring(result or "")
end

local function generateStreamToken()
  local raw = noctalia.readFile("/proc/sys/kernel/random/uuid")
  if type(raw) == "string" then
    local id = string.sub(trim(raw), 1, 8)
    if id ~= "" then
      return "ntb-" .. id
    end
  end

  fallbackTokenCounter = fallbackTokenCounter + 1
  return "ntb-fb" .. tostring(fallbackTokenCounter)
end

local function normalizeWorkspace(item)
  if type(item) ~= "table" or item.id == nil then
    return nil
  end

  return {
    id = item.id,
    idx = item.idx or 0,
    name = item.name,
    output = item.output or "",
    isActive = item.is_active == true,
    isFocused = item.is_focused == true,
  }
end

local function normalizeWindow(item, previous)
  if type(item) ~= "table" or item.id == nil then
    return nil
  end

  local workspaceId = item.workspace_id
  if workspaceId == nil and previous ~= nil then
    workspaceId = previous.workspaceId
  end

  return {
    id = item.id,
    title = item.title or "",
    appId = item.app_id or item.class or "",
    workspaceId = workspaceId,
    isFocused = item.is_focused == true,
  }
end

local function replaceWorkspaces(items)
  local nextWorkspaces = {}
  if type(items) == "table" then
    for _, item in ipairs(items) do
      local workspace = normalizeWorkspace(item)
      if workspace ~= nil then
        nextWorkspaces[workspace.id] = workspace
      end
    end
  end
  workspacesById = nextWorkspaces
end

local function replaceWindows(items)
  local previousWindows = windowsById
  local nextWindows = {}
  if type(items) == "table" then
    for _, item in ipairs(items) do
      local previous = nil
      if type(item) == "table" and item.id ~= nil then
        previous = previousWindows[item.id]
      end

      local window = normalizeWindow(item, previous)
      if window ~= nil then
        nextWindows[window.id] = window
      end
    end
  end
  windowsById = nextWindows
end

local function decodeJson(text)
  local ok, decoded = pcall(noctalia.json.decode, text)
  if not ok then
    return nil
  end
  return decoded
end

sortedWorkspaces = function(outputFilter)
  local out = {}
  for _, workspace in pairs(workspacesById) do
    if outputFilter == nil or workspace.output == outputFilter then
      table.insert(out, workspace)
    end
  end

  table.sort(out, function(a, b)
    if a.output ~= b.output then
      return tostring(a.output) < tostring(b.output)
    end
    if a.idx ~= b.idx then
      return (a.idx or 0) < (b.idx or 0)
    end
    return (a.id or 0) < (b.id or 0)
  end)

  return out
end

windowsForWorkspace = function(wsId)
  local out = {}
  for _, window in pairs(windowsById) do
    if window.workspaceId == wsId then
      table.insert(out, window)
    end
  end

  table.sort(out, function(a, b)
    return (a.id or 0) < (b.id or 0)
  end)

  return out
end

focusedOutput = function()
  for _, workspace in pairs(workspacesById) do
    if workspace.isFocused then
      return workspace.output
    end
  end
  return nil
end

local function bumpAndRender()
  stateGeneration = stateGeneration + 1
  render()
end

local function windowClosedId(payload)
  if type(payload) == "number" then
    return payload
  end
  if type(payload) == "table" then
    return payload.id or payload.window_id
  end
  return nil
end

local function splitSnapshot(stdout)
  local sepStart, sepEnd = string.find(stdout, "---NTB-SEP", 1, true)
  if sepStart == nil then
    return nil, nil
  end

  return trim(string.sub(stdout, 1, sepStart - 1)), trim(string.sub(stdout, sepEnd + 1))
end

-- ============================================================
-- CALLBACKS
-- ============================================================

local function registerWorkspaceCallback(workspace)
  local wsName = "focusWs_" .. workspace.id
  registeredWorkspaceCallbacks[workspace.id] = wsName
  env[wsName] = function()
    collapseTicks = 0 -- click proves the pointer is inside the widget

    local current = workspacesById[workspace.id]
    if current == nil then
      return
    end

    local cmd
    local output = focusedOutput()
    if output == nil or output == current.output then
      cmd = "niri msg action focus-workspace " .. tostring(current.idx)
    else
      cmd = "niri msg action focus-monitor " .. shellQuote(current.output)
        .. " ; niri msg action focus-workspace " .. tostring(current.idx)
    end

    noctalia.runAsync(cmd)
  end
  return wsName
end

local function registerWindowCallback(window)
  local winName = "focusWin_" .. window.id
  registeredWindowCallbacks[window.id] = winName
  env[winName] = function()
    collapseTicks = 0
    noctalia.runAsync("niri msg action focus-window --id " .. tostring(window.id))
  end
  return winName
end

pruneCallbackEnv = function()
  for id, name in pairs(registeredWorkspaceCallbacks) do
    if workspacesById[id] == nil then
      env[name] = nil
      registeredWorkspaceCallbacks[id] = nil
    end
  end

  for id, name in pairs(registeredWindowCallbacks) do
    if windowsById[id] == nil then
      env[name] = nil
      registeredWindowCallbacks[id] = nil
    end
  end
end

handleLine = function(line)
  local event = decodeJson(line)
  if type(event) ~= "table" then
    return
  end

  if type(event.WorkspacesChanged) == "table" then
    replaceWorkspaces(event.WorkspacesChanged.workspaces)
    bumpAndRender()
    return
  end

  if type(event.WorkspaceActivated) == "table" then
    local id = event.WorkspaceActivated.id
    if id == nil then
      return
    end

    local workspace = workspacesById[id]
    if workspace == nil then
      return
    end

    local output = workspace.output
    for _, item in pairs(workspacesById) do
      if item.output == output then
        item.isActive = item.id == id
      end
      if event.WorkspaceActivated.focused == true then
        item.isFocused = item.id == id
      end
    end
    bumpAndRender()
    return
  end

  if type(event.WindowsChanged) == "table" then
    replaceWindows(event.WindowsChanged.windows)
    bumpAndRender()
    return
  end

  if type(event.WindowOpenedOrChanged) == "table" then
    local incoming = event.WindowOpenedOrChanged.window
    if type(incoming) ~= "table" or incoming.id == nil then
      return
    end

    local window = normalizeWindow(incoming, windowsById[incoming.id])
    if window == nil then
      return
    end
    windowsById[window.id] = window

    if window.isFocused then
      for _, item in pairs(windowsById) do
        item.isFocused = item.id == window.id
      end
    end
    bumpAndRender()
    return
  end

  if event.WindowClosed ~= nil then
    local id = windowClosedId(event.WindowClosed)
    if id == nil then
      return
    end

    windowsById[id] = nil
    local name = registeredWindowCallbacks[id]
    if name ~= nil then
      env[name] = nil
      registeredWindowCallbacks[id] = nil
    end
    bumpAndRender()
    return
  end

  if type(event.WindowFocusChanged) == "table" then
    local id = event.WindowFocusChanged.id
    for _, item in pairs(windowsById) do
      item.isFocused = item.id == id
    end
    bumpAndRender()
  end
end

startStream = function()
  local token = generateStreamToken()
  activeStreamToken = token
  noctalia.runStream("niri msg --json event-stream || true # " .. token, function(line)
    if token ~= activeStreamToken then
      return
    end
    handleLine(line)
  end)
end

requestSnapshot = function()
  local gen = stateGeneration
  noctalia.runAsync("niri msg --json workspaces; echo ---NTB-SEP; niri msg --json windows", function(result)
    if stateGeneration ~= gen then
      return
    end

    local workspacesText, windowsText = splitSnapshot(commandStdout(result))
    if workspacesText == nil or windowsText == nil then
      return
    end

    local workspaces = decodeJson(workspacesText)
    local windows = decodeJson(windowsText)
    if type(workspaces) ~= "table" or type(windows) ~= "table" then
      return
    end

    replaceWorkspaces(workspaces)
    replaceWindows(windows)
    render()
  end)
end

-- Widget-level callback: fires on pointer enter/leave of the whole capsule
-- (InputArea onEnter/onLeave in plugin_widget.cpp). Always passes an
-- explicit boolean per reconciler footgun #3 (visible must always be set,
-- never conditionally omitted).
function onHover(state)
  if state then
    collapsePending = false
    if not expanded then
      expanded = true
      render()
    end
  else
    collapsePending = true
    collapseTicks = 0
  end
end

-- Widget tick (noctalia.setUpdateInterval below): drives the grace-period
-- countdown and the niri liveness/resync pass.
function update()
  if collapsePending then
    collapseTicks = collapseTicks + 1
    if collapseTicks >= COLLAPSE_GRACE_TICKS then
      collapsePending = false
      expanded = false
      render()
    end
  end

  resyncTicks = resyncTicks + 1
  if resyncTicks < 120 then
    return
  end
  resyncTicks = 0

  local checkedToken = activeStreamToken
  -- Bracket trick: the probe runs under /bin/sh -c whose own argv contains
  -- this pattern, and pgrep -f excludes only itself, not its parent shell.
  -- '[n]tb-…' matches the stream wrapper's literal 'ntb-…' but not the
  -- probe's own '[n]tb-…' — without it the probe always reports alive.
  local pattern = "[" .. string.sub(checkedToken, 1, 1) .. "]" .. string.sub(checkedToken, 2)
  noctalia.runAsync("pgrep -f '" .. pattern .. "' >/dev/null && echo alive || echo dead", function(result)
    if checkedToken == activeStreamToken and trim(commandStdout(result)) == "dead" then
      startStream()
    end
  end)

  requestSnapshot()
  pruneCallbackEnv()
end

-- ============================================================
-- UI
-- ============================================================

local function truncateTitle(title)
  local text = tostring(title or "")
  if string.len(text) > 12 then
    return string.sub(text, 1, 12) .. "…"
  end
  return text
end

local function buildWorkspaceGroup(workspace)
  local windows = windowsForWorkspace(workspace.id)

  -- Chip: selected always explicitly true/false (footgun #1 — absent props
  -- never clear on a retained node).
  local chip = ui.button({
    key = "ws-" .. workspace.id,
    text = workspace.name or tostring(workspace.idx),
    selected = workspace.isActive == true,
    onClick = registerWorkspaceCallback(workspace),
  })

  -- Windows row: always mounted (even with zero children for an empty
  -- workspace), only `visible` flips. Recreating this subtree on
  -- expand/collapse would read as a visible flash (footgun #3).
  local windowButtons = {}
  for _, window in ipairs(windows) do
    table.insert(windowButtons, ui.button({
      key = "win-" .. window.id,
      text = truncateTitle(window.title),
      selected = window.isFocused == true,
      onClick = registerWindowCallback(window),
    }))
  end
  local windowsRow = ui.row({
    key = "wins-" .. workspace.id,
    visible = expanded,
    gap = 4,
  }, windowButtons)

  return ui.row({ key = "ws-group-" .. workspace.id, gap = 4 }, { chip, windowsRow })
end

render = function()
  local groups = {}
  for _, workspace in ipairs(sortedWorkspaces(nil)) do
    table.insert(groups, buildWorkspaceGroup(workspace))
  end

  if #groups == 0 then
    table.insert(groups, ui.button({
      key = "empty-niri",
      text = "niri?",
      selected = false,
    }))
  end

  barWidget.render(ui.row({ gap = 6, align = "center" }, groups))
end

-- ============================================================
-- Top-level setup (mirrors example/declarative.luau)
-- ============================================================

noctalia.setUpdateInterval(250)
startStream()
render()
