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
local COLLAPSE_GRACE_MS = 1250 -- ~1.25s, was 5 ticks at the 250ms update interval; readSettings() overwrites from collapse_delay_ms
local collapsePending = false
local graceMs = 0

-- Per-workspace expand/collapse fade, driven from update() ticks. opacity is
-- the CURRENT rendered value (0..1), target is where it's heading; a row
-- stays mounted+visible while opacity > 0 OR target == 1 (fading in), and
-- only drops to visible=false once a closing row's opacity reaches 0 exactly
-- (see stepRowAnims). Lazily populated per workspace id by ensureRowAnim.
local rowAnim = {}
local FADE_TAU_MS = 65 -- exponential ease-out time constant; ~3*tau (~195ms) to settle — softer tail than the initial 50ms tuning; readSettings() overwrites from expand_speed (fast=40/normal=65/slow=100)
local FADE_SNAP_EPS = 0.02

-- Update interval: 250ms at rest, dropped to 16ms while any rowAnim is
-- mid-flight so the fade steps smoothly, restored once all are settled.
-- currentIntervalMs mirrors the interval actually in effect (only call
-- noctalia.setUpdateInterval when it changes) and doubles as the per-tick
-- elapsed-time estimate for the grace/resync ms accumulators below.
local currentIntervalMs = 250
local RESYNC_MS = 30000 -- was resyncTicks < 120 at the 250ms interval

-- Per-chip hover (0008 host patch): latched true by the first per-node
-- hover event, which switches the widget from expand-all to per-workspace
-- expansion (the v4 behavior). Unpatched hosts never fire it, so the
-- widget-level onHover fallback above keeps working unchanged.
local perChipHover = false
local expandedWsId = nil

local workspacesById = {}
local windowsById = {}
local stateGeneration = 0
local activeStreamToken = ""
local resyncMs = 0
local fallbackTokenCounter = 0

-- P2 settings cache (read via barWidget.getConfig, refreshed by onConfigChanged).
-- Defaults here match the manifest's `default` so the harness (which stubs
-- getConfig to return nil for every key) exercises the same fallback path as
-- an unset setting on a live host.
local settingFocusedOutputOnly = false
local settingShowEmptyWorkspaces = true
local settingDisplay = "id" -- "id" | "name" | "none" (mirrors the native widget)
local settingShowWindowTitles = false
local settingMaxWindowsPerWorkspace = 10
-- P2.5 native-parity settings. Defaults/min/max mirror the native
-- workspaces/taskbar widgets exactly (see readSettings below for citations).
local settingLabelsOnlyWhenOccupied = false
local settingMaxLabelChars = 1
local settingOnlyActiveWorkspace = false
local settingIconSize = 16
-- P4 visual-tweak settings (chip geometry/spacing/timing/tint). Defaults here
-- match the manifest's `default`, same rationale as the block above.
local settingChipSize = 16
local settingChipRatio = 140 -- idle width:height %, 100 = circle .. 400 = line
local settingChipSpacing = 3
local settingShowFocusDot = true
local settingPillTint = 30

-- P3 icon resolver state. false is a cached miss so unresolved apps do not
-- repeatedly cross the host boundary.
local iconCache = {}

-- The monitor this widget instance sits on. Needs the 0006 host patch
-- (barWidget.outputName binding); on an unpatched host the accessor is
-- absent and we degrade to showing every output's workspaces.
local ownOutput = nil
if type(barWidget.outputName) == "function" then
  local ok, name = pcall(barWidget.outputName)
  if ok and type(name) == "string" and name ~= "" then
    ownOutput = name
  end
end

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

-- Re-read [[widget.setting]] values (verified via barWidget.getConfig, see
-- noctalia.d.luau:190) into locals. Called once at startup and again from
-- onConfigChanged. getConfig returns nil for an unset key, so every branch
-- below has an explicit default matching the manifest.
local function readSettings()
  settingFocusedOutputOnly = barWidget.getConfig("focused_output_only") == true

  local showEmpty = barWidget.getConfig("show_empty_workspaces")
  settingShowEmptyWorkspaces = showEmpty ~= false

  local display = barWidget.getConfig("display")
  if display == "name" or display == "none" then
    settingDisplay = display
  else
    settingDisplay = "id"
  end

  settingShowWindowTitles = barWidget.getConfig("show_window_titles") == true

  local maxWindows = barWidget.getConfig("max_windows_per_workspace")
  if type(maxWindows) == "number" and maxWindows >= 1 then
    settingMaxWindowsPerWorkspace = math.floor(maxWindows)
  else
    settingMaxWindowsPerWorkspace = 10
  end

  -- native default false (widget_settings_registry.cpp:1032, "workspaces").
  settingLabelsOnlyWhenOccupied = barWidget.getConfig("labels_only_when_occupied") == true

  -- native intSpec("max_label_chars", 1, 1.0, 20.0, 1.0) — default 1, min 1,
  -- max 20 (widget_settings_registry.cpp:1043; default explained as "v4
  -- behavior" at widget_factory.cpp:667).
  local maxLabelChars = barWidget.getConfig("max_label_chars")
  if type(maxLabelChars) == "number" and maxLabelChars >= 1 and maxLabelChars <= 20 then
    settingMaxLabelChars = math.floor(maxLabelChars)
  else
    settingMaxLabelChars = 1
  end

  -- native default false (widget_settings_registry.cpp:868, "taskbar").
  settingOnlyActiveWorkspace = barWidget.getConfig("only_active_workspace") == true

  local iconSize = barWidget.getConfig("icon_size")
  if type(iconSize) == "number" and iconSize >= 12 and iconSize <= 32 then
    settingIconSize = math.floor(iconSize)
  else
    settingIconSize = 16
  end

  local chipSize = barWidget.getConfig("chip_size")
  if type(chipSize) == "number" and chipSize >= 12 and chipSize <= 24 then
    settingChipSize = math.floor(chipSize)
  else
    settingChipSize = 16
  end

  local chipRatio = barWidget.getConfig("chip_ratio")
  if type(chipRatio) == "number" and chipRatio >= 100 and chipRatio <= 400 then
    settingChipRatio = math.floor(chipRatio)
  else
    settingChipRatio = 140
  end

  local chipSpacing = barWidget.getConfig("chip_spacing")
  if type(chipSpacing) == "number" and chipSpacing >= 0 and chipSpacing <= 12 then
    settingChipSpacing = math.floor(chipSpacing)
  else
    settingChipSpacing = 3
  end

  local collapseDelay = barWidget.getConfig("collapse_delay_ms")
  if type(collapseDelay) == "number" and collapseDelay >= 250 and collapseDelay <= 5000 then
    COLLAPSE_GRACE_MS = math.floor(collapseDelay)
  else
    COLLAPSE_GRACE_MS = 1250
  end

  local expandSpeed = barWidget.getConfig("expand_speed")
  if expandSpeed == "fast" then
    FADE_TAU_MS = 40
  elseif expandSpeed == "slow" then
    FADE_TAU_MS = 100
  else
    FADE_TAU_MS = 65
  end

  settingShowFocusDot = barWidget.getConfig("show_focus_dot") ~= false

  local pillTint = barWidget.getConfig("pill_tint")
  if type(pillTint) == "number" and pillTint >= 0 and pillTint <= 60 then
    settingPillTint = math.floor(pillTint)
  else
    settingPillTint = 30
  end
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

local function resolveWindowIcon(appId)
  local id = tostring(appId or "")
  if id == "" then
    return nil
  end
  local cached = iconCache[id]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  if type(noctalia.appIconPath) ~= "function" then
    iconCache[id] = false
    return nil
  end

  local path = noctalia.appIconPath(id, settingIconSize * 2)
  if type(path) == "string" and path ~= "" then
    iconCache[id] = path
    return path
  end

  iconCache[id] = false
  return nil
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
    isUrgent = item.is_urgent == true,
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
    isUrgent = item.is_urgent == true,
    -- {x, y} array from niri's scrolling-layout column/row, or nil for a
    -- window with no layout info yet (e.g. floating). Used for ordering
    -- only (windowsForWorkspace); WindowLayoutsChanged updates this
    -- in-place on the retained window record (see handleLine).
    pos = item.layout and item.layout.pos_in_scrolling_layout or nil,
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

  -- Layout position order (matches niri's own scrolling-layout column/row
  -- order, niri_workspace_backend.cpp:467-513): nil-pos windows (no layout
  -- seen yet) sort last, by id.
  table.sort(out, function(a, b)
    local ap, bp = a.pos, b.pos
    if ap == nil or bp == nil then
      if ap == nil and bp == nil then
        return (a.id or 0) < (b.id or 0)
      end
      return bp == nil -- a has a pos, b doesn't -> a first
    end
    if ap[1] ~= bp[1] then
      return ap[1] < bp[1]
    end
    if ap[2] ~= bp[2] then
      return ap[2] < bp[2]
    end
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

local function ensureRowAnim(wsId)
  local anim = rowAnim[wsId]
  if anim == nil then
    anim = { opacity = 0, target = 0 }
    rowAnim[wsId] = anim
  end
  return anim
end

-- Exponential ease-out step: closes the opacity/target gap by a fraction of
-- dt/FADE_TAU_MS each tick (clamped to [0,1] so a large dt — e.g. the first
-- tick after an idle 250ms period, before the interval drops to 16ms —
-- snaps straight to target instead of overshooting). A row within
-- FADE_SNAP_EPS of its target snaps exactly onto it so fades terminate at a
-- clean 0/1 rather than approaching asymptotically forever. Returns
-- (animating, changed): animating is true if any row is still mid-flight
-- after this step (interval should stay at 16ms); changed is true if any
-- opacity value moved at all this tick (including the final snap-to-target
-- frame), meaning a render is needed to show it.
local function stepRowAnims(dt)
  local animating = false
  local changed = false
  for _, anim in pairs(rowAnim) do
    if anim.opacity ~= anim.target then
      changed = true
      local factor = dt / FADE_TAU_MS
      if factor > 1 then
        factor = 1
      elseif factor < 0 then
        factor = 0
      end
      anim.opacity = anim.opacity + (anim.target - anim.opacity) * factor
      if math.abs(anim.target - anim.opacity) < FADE_SNAP_EPS then
        anim.opacity = anim.target
      end
    end
    if anim.opacity ~= anim.target then
      animating = true
    end
  end
  return animating, changed
end

-- Drop the tick interval to 16ms the instant any row's target and opacity
-- disagree (called from render(), so a target flip is caught the same tick
-- it happens — not one update() cycle later — avoiding a cold-start tick at
-- the old 250ms interval that would otherwise snap the fade in one frame);
-- restores to the 250ms rest interval once every row is settled. Guarded so
-- noctalia.setUpdateInterval is only called when the desired value changes.
local function syncUpdateInterval()
  local animating = false
  for _, anim in pairs(rowAnim) do
    if anim.opacity ~= anim.target then
      animating = true
      break
    end
  end
  local desired = animating and 16 or 250
  if desired ~= currentIntervalMs then
    currentIntervalMs = desired
    noctalia.setUpdateInterval(desired)
  end
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

  -- Per-chip hover (0008 host patch): chip AND its window tiles share one
  -- callback name, so mousing from chip to tile keeps the group alive. The
  -- arg arrives as the string "true"/"false" (toggle onChange convention).
  -- First event latches perChipHover — on an unpatched host the prop is
  -- ignored and the widget-level expand-all fallback keeps working.
  env["hoverWs_" .. workspace.id] = function(state)
    perChipHover = true
    if state == "true" then
      -- Chip-to-chip SWITCH: snap the old row shut in the SAME render as
      -- the new one appears. Letting the old row fade out (~195ms) while
      -- the new one is already open produced two staggered width jumps per
      -- switch — visible stutter, worse in a centered bar section where
      -- every width change re-centers the widget. One swap = one jump.
      -- The full fade-out is kept for the leave-to-nothing path (grace
      -- expiry in update()), where no second jump follows.
      local previous = expandedWsId
      if previous ~= nil and previous ~= workspace.id then
        local old = rowAnim[previous]
        if old ~= nil then
          old.opacity = 0
          old.target = 0
        end
      end
      -- expandedWsId flips here; buildWorkspaceGroup derives every row's
      -- rowAnim.target from it on the render() below.
      expandedWsId = workspace.id
      collapsePending = false
      graceMs = 0
      render()
    else
      collapsePending = true
      graceMs = 0
    end
  end

  env[wsName] = function()
    graceMs = 0 -- click proves the pointer is inside the widget

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
    graceMs = 0
    noctalia.runAsync("niri msg action focus-window --id " .. tostring(window.id))
  end
  return winName
end

pruneCallbackEnv = function()
  for id, name in pairs(registeredWorkspaceCallbacks) do
    if workspacesById[id] == nil then
      env[name] = nil
      env["hoverWs_" .. id] = nil
      registeredWorkspaceCallbacks[id] = nil
    end
  end

  for id, name in pairs(registeredWindowCallbacks) do
    if windowsById[id] == nil then
      env[name] = nil
      registeredWindowCallbacks[id] = nil
    end
  end

  for id, anim in pairs(rowAnim) do
    -- Only drop a fully-settled entry for a gone workspace (opacity ==
    -- target == 0) — a workspace that vanishes mid-fade keeps animating so
    -- an in-flight closing transition still finishes smoothly.
    if workspacesById[id] == nil and anim.opacity == 0 and anim.target == 0 then
      rowAnim[id] = nil
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
    return
  end

  if type(event.WindowLayoutsChanged) == "table" then
    -- Array of [id, {pos_in_scrolling_layout:[x,y], ...}] pairs (see
    -- fixtures/parser-spec.md and niri_workspace_backend.cpp:467-513).
    -- Update positions on retained window records only (unknown ids
    -- skipped, matching the native consumer); other layout fields
    -- (tile_size, window_offset_in_tile, ...) are unused here.
    local changes = event.WindowLayoutsChanged.changes
    if type(changes) ~= "table" then
      return
    end

    local changed = false
    for _, change in ipairs(changes) do
      if type(change) == "table" then
        local id = change[1]
        local layout = change[2]
        if id ~= nil and type(layout) == "table" then
          local window = windowsById[id]
          if window ~= nil then
            local pos = layout.pos_in_scrolling_layout
            if type(pos) == "table" then
              window.pos = pos
              changed = true
            end
          end
        end
      end
    end

    if changed then
      bumpAndRender()
    end
  end
end

-- Settings changed in the widget's config editor (noctalia.d.luau:263).
function onConfigChanged()
  local previousIconSize = settingIconSize
  readSettings()
  if previousIconSize ~= settingIconSize then
    iconCache = {}
  end
  render()
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
  if perChipHover then
    -- Per-chip mode: the widget-level signal only smooths gap-crossings
    -- (enter cancels the pending collapse without changing which group is
    -- open) and starts the countdown when the pointer truly leaves.
    if state then
      collapsePending = false
    else
      collapsePending = true
      graceMs = 0
    end
    return
  end
  if state then
    collapsePending = false
    if not expanded then
      expanded = true
      render() -- buildWorkspaceGroup derives every row's target = 1 (fallback mode: shared)
    end
  else
    collapsePending = true
    graceMs = 0
  end
end

-- Widget tick (noctalia.setUpdateInterval below): drives the grace-period
-- countdown, the per-workspace fade, and the niri liveness/resync pass.
-- dt is the elapsed time this tick represents — currentIntervalMs, the
-- interval actually in effect when the host scheduled this call (NOT the
-- interval this same tick may switch to for the future, which only takes
-- effect on the NEXT call). Both the grace and resync accumulators use ms,
-- not tick counts, so alternating between the 250ms rest interval and the
-- 16ms mid-fade interval never shortens their real-time behavior.
function update()
  local dt = currentIntervalMs

  -- Step any ALREADY mid-flight rows first, using dt = the interval that
  -- was actually in effect for the time that just elapsed. This must run
  -- BEFORE the grace check below: if grace fires this same tick, it flips
  -- a row's target for the first time just now — that row hasn't accrued
  -- any elapsed fade time yet, so it must NOT be stepped with this tick's
  -- (possibly large, 250ms) dt or it would snap straight to the new target
  -- instead of beginning a smooth fade next tick.
  local _, changed = stepRowAnims(dt)
  if changed then
    render()
  end

  if collapsePending then
    graceMs = graceMs + dt
    if graceMs >= COLLAPSE_GRACE_MS then
      collapsePending = false
      graceMs = 0
      if perChipHover then
        expandedWsId = nil
      else
        expanded = false
      end
      render() -- derives every row's target = 0; syncUpdateInterval below queues 16ms for the fade starting next tick
    end
  else
    graceMs = 0
  end

  syncUpdateInterval()

  resyncMs = resyncMs + dt
  if resyncMs < RESYNC_MS then
    return
  end
  resyncMs = 0

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

-- First character of the LAST dot-segment of an appId, uppercased. Empty/nil
-- appId falls back to "?". This is the P3 icon's placeholder — the tile
-- geometry below is sized to swap label->image without a layout jump.
local function windowInitial(appId)
  local text = tostring(appId or "")
  if text == "" then
    return "?"
  end
  local lastSegment = text
  for segment in string.gmatch(text, "[^%.]+") do
    lastSegment = segment
  end
  local first = string.sub(lastSegment, 1, 1)
  if first == "" then
    return "?"
  end
  return string.upper(first)
end

-- Native workspaces_widget fill roles (workspaces_widget.cpp:883-899): active
-- -> primary, urgent -> error, occupied -> secondary, empty -> muted. Button
-- is the only clickable+labeled control the reconciler exposes (box is a
-- leaf with no children — ui_tree_reconciler.cpp:195-197 drops children on
-- any non-flex/non-scroll control, kBox has no text-related prop at all), so
-- role fill/label-color combos are approximated via ButtonVariant, whose
-- built-in palettes (button.cpp:32-176) already resolve to the matching
-- on_* label color per state.
local function chipVariant(workspace, occupied)
  if workspace.isUrgent then
    return "destructive" -- fill=error, label=on_error
  elseif workspace.isActive then
    return "primary" -- fill=primary, label=on_primary
  elseif occupied then
    return "secondary" -- fill=secondary, label=on_secondary
  end
  return "default" -- fill=surface_variant, label=on_surface (closest empty preset)
end

-- Numeric workspace labels (index-based) are never truncated, matching the
-- native isNumericLabel guard (workspaces_widget.cpp:36-40).
local function isNumericLabel(text)
  return text ~= "" and string.match(text, "^%d+$") ~= nil
end

-- Byte-length truncation (native truncates by UTF-8 codepoint via
-- StringUtils::truncateUtf8CodePoints, workspaces_widget.cpp:849 — no
-- ellipsis appended, e.g. "VESKTOP" -> "VE"). Byte truncation is an
-- accepted simplification here; ASCII workspace names are the common case
-- and this is pure display text, not the source of truth.
local function truncateLabel(text)
  if isNumericLabel(text) or settingMaxLabelChars <= 0 then
    return text
  end
  if string.len(text) <= settingMaxLabelChars then
    return text
  end
  return string.sub(text, 1, settingMaxLabelChars)
end

local function workspaceLabel(workspace, windowCount)
  if settingDisplay == "none" then
    return nil
  end
  if settingDisplay == "windows" then
    return tostring(windowCount or 0)
  end
  if settingDisplay == "name" and workspace.name ~= nil and workspace.name ~= "" then
    return truncateLabel(workspace.name)
  end
  return tostring(workspace.idx)
end

-- Chip text: display "none" keeps a single space so the capsule body has
-- content height (chipWidth/chipHeight then render it as a bare circle/oval
-- per chip_ratio).
-- labels_only_when_occupied (native workspaces_widget.cpp:59-66): hide the
-- label for a non-active, unoccupied workspace even when a display mode is
-- selected, rendering a bare pill instead.
local function chipText(workspace, occupied, windowCount)
  if settingLabelsOnlyWhenOccupied and not occupied and not workspace.isActive then
    return " "
  end
  local label = workspaceLabel(workspace, windowCount)
  if label == nil then
    return " "
  end
  return label
end

-- utf8-aware codepoint count for chip width, falling back to byte length if
-- the utf8 library or a given string isn't well-formed (pcall guards a
-- malformed sequence throwing inside utf8.len).
local function textLength(text)
  if type(utf8) == "table" and type(utf8.len) == "function" then
    local ok, len = pcall(utf8.len, text)
    if ok and type(len) == "number" then
      return len
    end
  end
  return string.len(text)
end

-- Chip diameter: settingChipSize (default 16, matches both
-- Style::baseGlyphSize — the native workspaces pill height basis — and the
-- default icon_size) so the chip, its symmetric dot slot, and a window tile
-- all share one vertical rhythm by default. The indicator column's own
-- spacer/dot stay fixed-size regardless (rhythm, not content).

-- Chip height: chip_ratio stretches the IDLE chip — width grows and height
-- shrinks reciprocally, so 100% is a circle, ~140% the compact oval, and
-- 300-400% approaches a line (height floors at 3px). Once its group is
-- expanded (or fading in — the caller passes rowOpen from anim.target == 1)
-- the chip snaps to the full circle regardless of ratio.
local function chipHeight(rowOpen)
  if settingChipRatio > 100 and not rowOpen then
    return math.max(3, math.floor(settingChipSize * 100 / settingChipRatio + 0.5))
  end
  return settingChipSize
end

-- Perfect-circle/oval chips: a single-character label (digit, bare space for
-- display "none") gets width == chipHeight for oval-expanded/circle (a true
-- circle), or the compact 1.4x-wide oval width when idle+collapsed under
-- chip_style "oval". Anything longer (workspace names, two-digit ids) always
-- uses the capsule formula (6px per extra character on top of chip_size),
-- regardless of style — long labels never go oval, only the chip's height
-- follows the style/rowOpen rule via chipHeight. Width is ALWAYS computed
-- and set (footgun #1) — geometry no longer comes from paddingH, so there is
-- no "unset" fallback to fall back to. The active workspace uses this same
-- formula: the primary-fill variant is the whole active cue, not extra
-- width.
local function chipWidth(text, rowOpen)
  local len = textLength(text)
  if len <= 1 then
    if settingChipRatio > 100 and not rowOpen then
      return math.floor(settingChipSize * settingChipRatio / 100 + 0.5)
    end
    return settingChipSize
  end
  return settingChipSize + 6 * (len - 1)
end

local function windowTileText(window, showTitles)
  local initial = windowInitial(window.appId)
  if showTitles then
    return initial .. " " .. truncateTitle(window.title)
  end
  return initial
end

-- Symmetric indicator column: [top spacer, content, dot], gaps 1. The
-- spacer mirrors the dot slot exactly (2px + 1px gap each side) so the
-- content's visual center IS the column center — without it the dot slot
-- pushed content up ~2.5px, crowding the pill's top edge (seen live as
-- top-clipped circles). Both chips and window tiles use this, so all
-- content shares one centerline. Total height: 2+1+16+1+2 = 22, which fits
-- the ~23px bar content slot that clamped taller layouts into ovals.
-- Spacer/dot fills are ALWAYS present (footgun #1); the spacer is never lit.
-- show_focus_dot gates ONLY the lit fill below, never the geometry — the dot
-- and its mirror spacer are rhythm (fixed-size, always mounted) regardless of
-- the setting, so toggling it never shifts layout.
-- dotFill: role string for the dot ("primary" focused, "error" urgent,
-- "primary/0" inert) — always a present fill (footgun #1). show_focus_dot
-- gates lighting only; geometry never changes with it (no layout jump).
local function withIndicator(key, content, dotFill)
  local spacer = ui.row({
    key = key .. "-pad",
    width = 4,
    height = 2,
    radius = 1,
    fill = "primary/0",
  })
  local dot = ui.row({
    key = key .. "-dot",
    width = 4,
    height = 2,
    radius = 1,
    fill = settingShowFocusDot and dotFill or "primary/0",
  })
  return ui.column({
    key = key,
    align = "center",
    gap = 1,
  }, { spacer, content, dot })
end

-- Window tile: a keyed column ("win-<id>", stable across icon/fallback/
-- titled variants so the reconciler retains it) wrapping the interactive
-- content (button or image[+label]) and a focused-window dot. The dot
-- replaces the old border-cue-on-image / variant-cue-on-button focus
-- indicators entirely — it is the ONE focus cue now, always mounted, fill
-- explicit both ways (footgun #1). onClick/onHover live on the content leaf
-- (columns/rows aren't in kFlex's onClick/onHover set) — the dot is inert.
local function buildWindowTile(window, showTitles, hoverName)
  local onClick = registerWindowCallback(window)
  local iconPath = resolveWindowIcon(window.appId)
  local content

  if iconPath == nil then
    -- No icon resolved: letter-tile fallback. variant is ALWAYS "ghost" now
    -- (the focused cue moved to the dot below).
    content = ui.button({
      key = "win-" .. window.id .. "-fallback",
      text = windowTileText(window, showTitles),
      fontSize = 11,
      variant = "ghost",
      selected = false,
      height = 22,
      radius = 8,
      paddingH = 5,
      paddingV = 2,
      onClick = onClick,
      onHover = hoverName,
    })
  else
    local iconSize = settingIconSize
    local icon = ui.image({
      key = "win-" .. window.id .. "-icon",
      path = iconPath,
      width = iconSize,
      height = iconSize,
      radius = 4,
      fit = "contain",
      onClick = onClick,
      onHover = hoverName,
    })

    if showTitles then
      content = ui.row({
        key = "win-" .. window.id .. "-body",
        gap = 4,
        align = "center",
      }, {
        icon,
        ui.label({
          key = "win-" .. window.id .. "-title",
          text = truncateTitle(window.title),
          fontSize = 11,
          color = "on_surface",
        }),
      })
    else
      content = icon
    end
  end

  -- Focused wins over urgent (a focused window is being dealt with).
  local dotFill = "primary/0"
  if window.isFocused == true then
    dotFill = "primary"
  elseif window.isUrgent == true then
    dotFill = "error"
  end
  return withIndicator("win-" .. window.id, content, dotFill)
end

-- windowCount is the TRUE window count for the workspace (display "windows"
-- label) — `windows` may be an emptied tile list under only_active_workspace.
local function buildWorkspaceGroup(workspace, windows, occupied, showTitles, windowCount)
  -- This workspace's row is open when per-chip hover (0008 patch) has this
  -- group hovered, or — fallback mode — when the whole widget is hovered.
  local rowOpen
  if perChipHover then
    rowOpen = expandedWsId == workspace.id
  else
    rowOpen = expanded
  end

  -- Derive this row's fade target straight from rowOpen every render — the
  -- single source of truth is the expandedWsId/expanded booleans above, not
  -- imperative pokes from the hover callbacks. That makes a hover-triggered
  -- switch self-healing: the previously-open group is rebuilt in this same
  -- render() pass with rowOpen now false, so its rowAnim.target flips to 0
  -- and it starts fading out immediately — no separate "close the old one"
  -- bookkeeping, and re-opening mid-fade just flips target back without a
  -- restart pop (opacity keeps animating from wherever it currently is).
  local anim = ensureRowAnim(workspace.id)
  anim.target = rowOpen and 1 or 0

  -- Chip: variant/selected/onClick always explicitly set (footgun #1 —
  -- absent props never clear on a retained node). Width is ALWAYS computed
  -- (perfect-circle for 1-char labels, capsule beyond that) — geometry now
  -- comes entirely from width, not paddingH.
  -- radius/width need the 0007 host patch, onHover the 0008 patch; an
  -- unpatched reconciler logs "has no prop, ignored" and degrades to the
  -- square look / widget-level expand-all.
  local hoverName = "hoverWs_" .. workspace.id
  local chipTextValue = chipText(workspace, occupied, windowCount)
  local chipHeightValue = chipHeight(rowOpen)
  -- A squashed idle chip (high chip_ratio) can't fit its 11px label —
  -- suppress it rather than clip it; the label reappears on the expanded
  -- circle. Width still derives from the suppressed (single-space) text,
  -- i.e. the full ratio width.
  if chipHeightValue < 10 then
    chipTextValue = " "
  end
  local chip = ui.button({
    key = "ws-" .. workspace.id,
    text = chipTextValue,
    fontSize = 11,
    variant = chipVariant(workspace, occupied),
    selected = false,
    -- height beats Button's 32px minHeight floor (style.h controlHeightSm);
    -- radius = height/2 + contentAlign=center makes a true circle/oval for a
    -- 1-char label, capsule beyond that. settingChipSize (default 16)
    -- matches Style::baseGlyphSize, the actual height basis the bar's
    -- content slot clamps to — a hardcoded 22 rendered as an oval. width/
    -- height/radius are ALWAYS explicitly set (footgun #1) even though the
    -- shape can change between renders on this same retained keyed button
    -- (oval collapsed <-> circle expanded).
    height = chipHeightValue,
    width = chipWidth(chipTextValue, rowOpen),
    radius = chipHeightValue / 2,
    contentAlign = "center",
    onClick = registerWorkspaceCallback(workspace),
    onHover = hoverName,
  })

  -- Same symmetric indicator column as window tiles (spacer/content/dot) so
  -- every piece of content in the pill shares one exact centerline; the
  -- chip's dot is never lit (reserved — the active cue is the primary fill).
  local chipColumn = withIndicator("ws-chipcol-" .. workspace.id, chip, "primary/0")

  -- Windows row: always mounted (even with zero children for an empty
  -- workspace); `visible` and `opacity` both track the fade (footgun #3 —
  -- recreating this subtree on expand/collapse would read as a flash).
  -- visible stays true for the whole fade-out (opacity carries the actual
  -- disappearance) and only drops once a closing row's opacity reaches 0.
  local windowButtons = {}
  local cap = settingMaxWindowsPerWorkspace
  local shown = 0
  for _, window in ipairs(windows) do
    if shown >= cap then
      break
    end
    shown += 1
    table.insert(windowButtons, buildWindowTile(window, showTitles, hoverName))
  end
  if #windows > cap then
    table.insert(windowButtons, ui.label({
      key = "more-" .. workspace.id,
      text = "+" .. tostring(#windows - cap),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end
  local windowsRow = ui.row({
    key = "wins-" .. workspace.id,
    visible = anim.opacity > 0 or anim.target == 1,
    opacity = anim.opacity,
    align = "center",
    gap = 3, -- tightened from 4 alongside the group row's own gap = 3 below
  }, windowButtons)

  -- Group capsule (native group-by-workspace look, taskbar_widget.cpp:~640):
  -- wrap chip+windows in one filled/rounded row so the chip reads as
  -- GROWING INTO a pill that contains its windows, not a row appearing
  -- next to the chip. fill is explicit BOTH ways (footgun #1 — absent
  -- props never clear on a retained node) and tied to the row's own fade
  -- opacity, not a two-state snap, so the pill tint grows/decays in step
  -- with the icons it contains. An unoccupied workspace never tints, even
  -- mid-fade — an empty expanded row has no icons to contain.
  local tintOpacity = occupied and anim.opacity or 0
  local pillTintFraction = settingPillTint / 100
  local capsuleFill = "surface_variant/" .. string.format("%.2f", pillTintFraction * tintOpacity)
  -- "Apps inside the pill with a highlight around it": a primary-tinted
  -- hairline that fades in step with the tint (explicit both ways — alpha 0
  -- when closed, never an absent prop). Border tracks pill_tint (+0.05 fixed
  -- offset) so it stays proportionally a touch stronger than the fill,
  -- matching the old fixed 0.30 fill / 0.35 border relationship at defaults.
  local capsuleBorder = "primary/" .. string.format("%.2f", (pillTintFraction + 0.05) * tintOpacity)

  return ui.row({
    key = "ws-group-" .. workspace.id,
    gap = 3,
    align = "center",
    paddingH = 3,
    paddingV = 0,
    fill = capsuleFill,
    border = capsuleBorder,
    borderWidth = 1,
    radius = 11,
  }, { chipColumn, windowsRow })
end

render = function()
  -- Own monitor by default (nil = all outputs on an unpatched host);
  -- focused_output_only follows keyboard focus via stream state instead
  -- (WorkspaceActivated re-renders keep it live as focus moves).
  local outputFilter = ownOutput
  if settingFocusedOutputOnly then
    outputFilter = focusedOutput()
  end
  local vertical = barWidget.isVertical() == true
  -- Vertical bars force titles off regardless of the setting (narrow column
  -- has no room for a title next to the initial tile).
  local showTitles = settingShowWindowTitles and not vertical

  local groups = {}
  for _, workspace in ipairs(sortedWorkspaces(outputFilter)) do
    local windows = windowsForWorkspace(workspace.id)
    local occupied = #windows > 0
    -- Urgent workspaces stay visible even when empties are hidden,
    -- matching the native widget's empty logic (workspaces_widget.cpp:21).
    if settingShowEmptyWorkspaces or occupied or workspace.isActive or workspace.isUrgent then
      -- only_active_workspace (native taskbar_widget.cpp:1881): chips for
      -- every workspace stay, but window tiles only build for each
      -- output's active workspace — `occupied` above still reflects real
      -- window counts (unaffected; that drives chip color/show-empty
      -- logic, not tile visibility), only the tile list handed to the
      -- group is emptied.
      local tileWindows = windows
      if settingOnlyActiveWorkspace and not workspace.isActive then
        tileWindows = {}
      end
      table.insert(groups, buildWorkspaceGroup(workspace, tileWindows, occupied, showTitles, #windows))
    end
  end

  if #groups == 0 then
    -- Quiet, non-interactive affordance: ui.row (Flex) supports fill/radius/
    -- padding + a label child (verified: official-plugins/example/
    -- declarative.luau:21-23 uses this exact row+label pill pattern); no
    -- click needed here so the box leaf-node constraint doesn't apply.
    table.insert(groups, ui.row({
      key = "empty-niri",
      fill = "surface_variant/0.25",
      radius = 8,
      paddingH = 6,
      paddingV = 2,
      align = "center",
    }, {
      ui.label({ text = "niri?", fontSize = 11, color = "on_surface_variant" }),
    }))
  end

  -- Root container direction: the host's m_uiHost wrapper auto-flips, but
  -- that only affects the single child we hand it (plugin_widget.cpp:298-
  -- 306) — our own top-level row must pick vertical/horizontal itself to
  -- actually stack chips in a side bar, same pattern as official-plugins/
  -- example/declarative.luau:15.
  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = settingChipSpacing, align = "center" }, groups))

  -- Every workspace's rowAnim.target was just set above (buildWorkspaceGroup);
  -- sync the tick interval to whether any row is now mid-flight so a
  -- hover-triggered target flip drops to 16ms this same render, not one
  -- update() tick later.
  syncUpdateInterval()
end

-- ============================================================
-- Top-level setup (mirrors example/declarative.luau)
-- ============================================================

noctalia.setUpdateInterval(250)
readSettings()
startStream()
render()
