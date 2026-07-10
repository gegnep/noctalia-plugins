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
  readSettings()
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

local function workspaceLabel(workspace)
  if settingDisplay == "none" then
    return nil
  end
  if settingDisplay == "name" and workspace.name ~= nil and workspace.name ~= "" then
    return truncateLabel(workspace.name)
  end
  return tostring(workspace.idx)
end

-- Chip width: native active pills are ~2.2x wider; with the 0007 host patch
-- (button radius/padding props) this is a real paddingH inset. Display
-- "none" keeps a single space so the capsule body has content height.
-- labels_only_when_occupied (native workspaces_widget.cpp:59-66): hide the
-- label for a non-active, unoccupied workspace even when a display mode is
-- selected, rendering a bare pill instead.
local function chipText(workspace, occupied)
  if settingLabelsOnlyWhenOccupied and not occupied and not workspace.isActive then
    return " "
  end
  local label = workspaceLabel(workspace)
  if label == nil then
    return " "
  end
  return label
end

local function chipPaddingH(workspace)
  if workspace.isActive then
    return 14
  end
  return 7
end

local function windowTileText(window, showTitles)
  local initial = windowInitial(window.appId)
  if showTitles then
    return initial .. " " .. truncateTitle(window.title)
  end
  return initial
end

local function buildWorkspaceGroup(workspace, windows, occupied, showTitles)
  -- Chip: variant/selected/onClick always explicitly set (footgun #1 —
  -- absent props never clear on a retained node).
  -- radius/paddingH need the 0007 host patch; an unpatched reconciler logs
  -- "has no prop, ignored" and renders the default square-ish button.
  local chip = ui.button({
    key = "ws-" .. workspace.id,
    text = chipText(workspace, occupied),
    fontSize = 11,
    variant = chipVariant(workspace, occupied),
    selected = false,
    radius = 12,
    paddingH = chipPaddingH(workspace),
    paddingV = 2,
    onClick = registerWorkspaceCallback(workspace),
  })

  -- Windows row: always mounted (even with zero children for an empty
  -- workspace), only `visible` flips. Recreating this subtree on
  -- expand/collapse would read as a visible flash (footgun #3).
  local windowButtons = {}
  local cap = settingMaxWindowsPerWorkspace
  local shown = 0
  for _, window in ipairs(windows) do
    if shown >= cap then
      break
    end
    shown += 1
    -- Focused-window cue (P2.5): "secondary" (colored fill=secondary,
    -- label=on_secondary) rather than the plain "default" preset — a flat
    -- surface_variant fill read too close to an unfocused/ghost tile at a
    -- glance. "secondary" is already the palette's occupied-chip color
    -- (chipVariant above), so reusing it here stays inside the existing
    -- two-tier vocabulary (primary = active workspace, secondary = "has
    -- attention") instead of introducing a third color. unfocused stays
    -- ghost (transparent) — no ButtonVariant exposes an alpha-blended
    -- surface_variant fill, see report.
    table.insert(windowButtons, ui.button({
      key = "win-" .. window.id,
      text = windowTileText(window, showTitles),
      fontSize = 11,
      variant = window.isFocused == true and "secondary" or "ghost",
      selected = false,
      radius = 8,
      paddingH = 5,
      paddingV = 2,
      onClick = registerWindowCallback(window),
    }))
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
    visible = expanded,
    gap = 4,
  }, windowButtons)

  -- Group capsule (native group-by-workspace look, taskbar_widget.cpp:~640):
  -- wrap chip+windows in one filled/rounded row so an expanded, occupied
  -- workspace reads as a single capsule. fill is explicit BOTH ways
  -- (footgun #1 — absent props never clear on a retained node): a
  -- collapsed or empty group gets a fully transparent fill of the same
  -- role so the prop is always present, never omitted.
  local capsuleFill = "surface_variant/0"
  if expanded and occupied then
    capsuleFill = "surface_variant/0.15"
  end

  return ui.row({
    key = "ws-group-" .. workspace.id,
    gap = 4,
    fill = capsuleFill,
    radius = 14,
    padding = 2,
  }, { chip, windowsRow })
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
      table.insert(groups, buildWorkspaceGroup(workspace, tileWindows, occupied, showTitles))
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
  barWidget.render(container({ gap = 6, align = "center" }, groups))
end

-- ============================================================
-- Top-level setup (mirrors example/declarative.luau)
-- ============================================================

noctalia.setUpdateInterval(250)
readSettings()
startStream()
render()
