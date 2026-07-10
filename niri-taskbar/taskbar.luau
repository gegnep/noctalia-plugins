--!nonstrict
-- P0 correctness spike: workspace chips that expand on hover to show each
-- workspace's windows. Fake/hardcoded data only — proves the platform
-- primitives (declarative render, per-item callbacks, visible-not-recreate
-- expand/collapse, widget-level onHover) before wiring real niri IPC.

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

local WORKSPACES = {
  { id = 101, idx = 1 },
  { id = 102, idx = 2 },
  { id = 103, idx = 3 },
}
local ACTIVE_WORKSPACE_ID = 102

local WINDOWS_BY_WORKSPACE = {
  [101] = {
    { id = 9001, label = "A" },
    { id = 9002, label = "B" },
  },
  [102] = {
    { id = 9003, label = "C" },
  },
  [103] = {},
}

-- Callback env for the getfenv per-item-callback idiom (see claude-launcher
-- panel.luau: env[name] = function ... end, names keyed by stable ids).
local env = getfenv()

-- Forward declaration: registerCallbacks/render below define closures over
-- `render`. The local must exist BEFORE those closures are created, or a
-- closure created earlier silently binds the nil GLOBAL `render` instead —
-- that trips the host's health breaker (5 hard errors/60s) and disables the
-- plugin. See claude-launcher panel.luau for the same pattern.
local render

-- ============================================================
-- CALLBACKS
-- ============================================================

-- Registers env["focusWs_<id>"] / env["focusWin_<id>"] for one workspace and
-- its windows. Called once per workspace at top-level render setup.
local function registerWorkspaceCallbacks(workspace)
  local wsName = "focusWs_" .. workspace.id
  env[wsName] = function()
    collapseTicks = 0 -- click proves the pointer is inside the widget
    noctalia.notify("niri-taskbar", "focus workspace " .. workspace.idx)
  end

  for _, window in ipairs(WINDOWS_BY_WORKSPACE[workspace.id] or {}) do
    local winName = "focusWin_" .. window.id
    env[winName] = function()
      collapseTicks = 0
      noctalia.notify("niri-taskbar", "focus window " .. window.id)
    end
  end
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

-- Widget tick (noctalia.setUpdateInterval below): drives only the
-- grace-period countdown in P0. P1 adds the niri resync pass here.
function update()
  if not collapsePending then
    return
  end
  collapseTicks = collapseTicks + 1
  if collapseTicks >= COLLAPSE_GRACE_TICKS then
    collapsePending = false
    expanded = false
    render()
  end
end

-- ============================================================
-- UI
-- ============================================================

local function buildWorkspaceGroup(workspace)
  local isActive = workspace.id == ACTIVE_WORKSPACE_ID
  local windows = WINDOWS_BY_WORKSPACE[workspace.id] or {}

  -- Chip: selected always explicitly true/false (footgun #1 — absent props
  -- never clear on a retained node).
  local chip = ui.button({
    key = "ws-" .. workspace.id,
    text = tostring(workspace.idx),
    selected = isActive,
    onClick = "focusWs_" .. workspace.id,
  })

  -- Windows row: always mounted (even with zero children for an empty
  -- workspace), only `visible` flips. Recreating this subtree on
  -- expand/collapse would read as a visible flash (footgun #3).
  local windowButtons = {}
  for _, window in ipairs(windows) do
    table.insert(windowButtons, ui.button({
      key = "win-" .. window.id,
      text = window.label,
      onClick = "focusWin_" .. window.id,
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
  for _, workspace in ipairs(WORKSPACES) do
    table.insert(groups, buildWorkspaceGroup(workspace))
  end
  barWidget.render(ui.row({ gap = 6, align = "center" }, groups))
end

-- ============================================================
-- Top-level setup (mirrors example/declarative.luau)
-- ============================================================

for _, workspace in ipairs(WORKSPACES) do
  registerWorkspaceCallbacks(workspace)
end

noctalia.setUpdateInterval(250)
render()
