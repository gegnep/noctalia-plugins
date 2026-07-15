-- Covers the expand/collapse fade + ms-based tick accumulators (visual-
-- polish pass): grace/resync accumulators under alternating 250ms/16ms
-- ticks, a full open fade settling at opacity 1 + interval 250, a close
-- fade reaching opacity 0 + visible=false, a mid-fade reversal staying
-- within [0,1] with no restart pop, dot fill per focus state, and chip
-- width for a 1-char vs 3-char label. Also covers the ui.row/ui.label chip
-- (structure, fill/border/label-color per state, the outline hairline on
-- empty chips only) and the hoverChip_<id> callback (group open/grace
-- behavior + the hoveredWorkspaceChipId-driven hover fill/label swap).
--
-- currentIntervalMs/graceMs/resyncMs/rowAnim/COLLAPSE_GRACE_MS/RESYNC_MS/
-- FADE_TAU_MS are plugin locals, visible here because dry-run.sh
-- concatenates prelude + taskbar.luau + this feeder into one chunk.

local function findNode(node, key)
  if type(node) ~= "table" then
    return nil
  end
  if type(node.props) == "table" and node.props.key == key then
    return node
  end
  if type(node.children) == "table" then
    for _, child in ipairs(node.children) do
      local found = findNode(child, key)
      if found ~= nil then
        return found
      end
    end
  end
  return nil
end

local function lastTree()
  return HARNESS_RENDERS[#HARNESS_RENDERS]
end

-- ---- fixture (f): chip width -------------------------------------------

workspacesById = {
  [1] = { id = 1, idx = 1, name = "abc", output = "DP-3", isActive = false, isFocused = true, isUrgent = false },
}
windowsById = {
  [100] = { id = 100, title = "Term", appId = "firefox", workspaceId = 1, isFocused = true },
}
perChipHover = false
expanded = false
expandedWsId = nil
collapsePending = false
graceMs = 0
resyncMs = 0
rowAnim = {}
HARNESS_INTERVAL_CALLS = {}

settingDisplay = "id" -- idx "1" -> 1 char
settingChipSize = 16
settingChipRatio = 140
HARNESS_RENDERS = {}
render()
local chip1ByIdx = findNode(lastTree(), "ws-1")
assert(chip1ByIdx ~= nil, "chip node missing")
-- Idle (collapsed) at ratio 140: width = round(16*1.4) = 22,
-- height = round(16*100/140) = 11, radius = height/2 = 5.5.
assert(chip1ByIdx.props.width == 22, "1-char label idle oval chip width mismatch, got " .. tostring(chip1ByIdx.props.width))
assert(chip1ByIdx.props.height == 11, "1-char label idle oval chip height mismatch, got " .. tostring(chip1ByIdx.props.height))
assert(chip1ByIdx.props.radius == 5.5, "1-char label idle oval chip radius mismatch, got " .. tostring(chip1ByIdx.props.radius))
assert(chip1ByIdx.props.paddingH == nil, "chipPaddingH geometry should be gone")
assert(chip1ByIdx.type == "row", "chip should be a ui.row now that it's migrated off ui.button")
assert(chip1ByIdx.props.align == "center" and chip1ByIdx.props.justify == "center",
  "chip should center its label via align/justify now that width owns geometry")
assert(chip1ByIdx.props.onClick == "focusWs_1", "chip onClick missing/wrong")
assert(chip1ByIdx.props.onHover == "hoverChip_1", "chip onHover should be its own hoverChip_<id>, got " .. tostring(chip1ByIdx.props.onHover))
assert(chip1ByIdx.props.borderWidth == 1, "chip borderWidth should always be the constant 1")
-- Occupied (window 100), not active/urgent/hovered -> secondary fill/label,
-- and no outline (only the fully-empty state gets one).
assert(chip1ByIdx.props.fill == "secondary", "occupied chip should fill secondary, got " .. tostring(chip1ByIdx.props.fill))
assert(chip1ByIdx.props.border == "outline/0", "occupied chip should have no border, got " .. tostring(chip1ByIdx.props.border))
local chip1Label = findNode(chip1ByIdx, "ws-1-label")
assert(chip1Label ~= nil and chip1Label.type == "label", "chip label child missing")
assert(chip1Label.props.text == "1", "chip label text mismatch, got " .. tostring(chip1Label.props.text))
assert(chip1Label.props.color == "on_secondary", "occupied chip label should be on_secondary, got " .. tostring(chip1Label.props.color))
assert(chip1Label.props.fontSize == 11, "chip label fontSize mismatch")

-- ---- fixture (k): empty (unoccupied) chip gets the outline hairline,
-- active/urgent/hovered chips never do -------------------------------------
windowsById = {} -- workspace 1 now unoccupied
workspacesById[1].isActive = false
HARNESS_RENDERS = {}
render()
local chip1Empty = findNode(lastTree(), "ws-1")
assert(chip1Empty.props.fill == "surface_variant", "empty chip should fill surface_variant, got " .. tostring(chip1Empty.props.fill))
assert(chip1Empty.props.border == "outline", "empty chip should carry the outline hairline, got " .. tostring(chip1Empty.props.border))
local chip1EmptyLabel = findNode(chip1Empty, "ws-1-label")
assert(chip1EmptyLabel.props.color == "on_surface", "empty chip label should be on_surface, got " .. tostring(chip1EmptyLabel.props.color))

workspacesById[1].isActive = true
HARNESS_RENDERS = {}
render()
local chip1Active = findNode(lastTree(), "ws-1")
assert(chip1Active.props.fill == "primary", "active chip should fill primary, got " .. tostring(chip1Active.props.fill))
assert(chip1Active.props.border == "outline/0", "active chip should never show the outline, got " .. tostring(chip1Active.props.border))
local chip1ActiveLabel = findNode(chip1Active, "ws-1-label")
assert(chip1ActiveLabel.props.color == "on_primary", "active chip label should be on_primary, got " .. tostring(chip1ActiveLabel.props.color))

workspacesById[1].isUrgent = true
HARNESS_RENDERS = {}
render()
local chip1Urgent = findNode(lastTree(), "ws-1")
assert(chip1Urgent.props.fill == "error", "urgent should win over active for chip fill, got " .. tostring(chip1Urgent.props.fill))
local chip1UrgentLabel = findNode(chip1Urgent, "ws-1-label")
assert(chip1UrgentLabel.props.color == "on_error", "urgent chip label should be on_error, got " .. tostring(chip1UrgentLabel.props.color))
workspacesById[1].isUrgent = false
workspacesById[1].isActive = false

-- ---- fixture (l): chip hover cue — hoverChip_<id> latches
-- hoveredWorkspaceChipId, swaps a non-active/non-urgent chip to the
-- "hover"/"on_hover" role pair, and still drives the group open/grace
-- behavior the old shared hoverWs handler did ------------------------------
assert(type(env.hoverChip_1) == "function", "hoverChip_1 callback missing")
perChipHover = false
expandedWsId = nil
collapsePending = false
graceMs = 0
hoveredWorkspaceChipId = nil

env.hoverChip_1("true")
assert(hoveredWorkspaceChipId == 1, "hoverChip true should latch hoveredWorkspaceChipId")
assert(perChipHover == true, "hoverChip should latch perChipHover like the old hoverWs handler")
assert(expandedWsId == 1, "hoverChip true should open this workspace's group like the old hoverWs handler")
assert(collapsePending == false, "hoverChip true should cancel any pending collapse")
local chip1Hovered = findNode(lastTree(), "ws-1")
assert(chip1Hovered.props.fill == "hover", "hovered unoccupied/non-active chip should swap to the hover role fill, got " .. tostring(chip1Hovered.props.fill))
local chip1HoveredLabel = findNode(chip1Hovered, "ws-1-label")
assert(chip1HoveredLabel.props.color == "on_hover", "hovered chip label should swap to on_hover, got " .. tostring(chip1HoveredLabel.props.color))

env.hoverChip_1("false")
assert(hoveredWorkspaceChipId == nil, "hoverChip false should clear hoveredWorkspaceChipId")
assert(collapsePending == true, "hoverChip false should arm the same grace countdown the old hoverWs handler did")
local chip1Unhovered = findNode(lastTree(), "ws-1")
assert(chip1Unhovered.props.fill == "surface_variant", "chip fill should revert once hover clears, got " .. tostring(chip1Unhovered.props.fill))
collapsePending = false
graceMs = 0

-- Active chip: hover must NOT change its fill (already primary, urgency-
-- style cue wins over the hover swap).
workspacesById[1].isActive = true
HARNESS_RENDERS = {}
render()
env.hoverChip_1("true")
local chip1ActiveHovered = findNode(lastTree(), "ws-1")
assert(chip1ActiveHovered.props.fill == "primary", "hovering an active chip must not change its fill, got " .. tostring(chip1ActiveHovered.props.fill))
env.hoverChip_1("false")
workspacesById[1].isActive = false
collapsePending = false
graceMs = 0
hoveredWorkspaceChipId = nil
expandedWsId = nil
perChipHover = false

-- Restore window 100 (cleared for the fixture (k) empty-chip checks above) —
-- everything from here down through fixture (e) assumes it's present.
windowsById = {
  [100] = { id = 100, title = "Term", appId = "firefox", workspaceId = 1, isFocused = true },
}

-- Expanded (rowOpen true): oval snaps to the full circle regardless of style.
expanded = true
HARNESS_RENDERS = {}
render()
local chip1Expanded = findNode(lastTree(), "ws-1")
assert(chip1Expanded.props.width == 16, "expanded oval chip should be a 16px circle, got " .. tostring(chip1Expanded.props.width))
assert(chip1Expanded.props.height == 16, "expanded oval chip height should be 16, got " .. tostring(chip1Expanded.props.height))
assert(chip1Expanded.props.radius == 8, "expanded oval chip radius should be 8, got " .. tostring(chip1Expanded.props.radius))
expanded = false

-- chip_ratio 100: always the full circle, collapsed or expanded.
settingChipRatio = 100
HARNESS_RENDERS = {}
render()
local chip1Circle = findNode(lastTree(), "ws-1")
assert(chip1Circle.props.width == 16 and chip1Circle.props.height == 16 and chip1Circle.props.radius == 8,
  "ratio 100 should always render a 16px circle, got w=" .. tostring(chip1Circle.props.width)
    .. " h=" .. tostring(chip1Circle.props.height) .. " r=" .. tostring(chip1Circle.props.radius))

-- chip_ratio 400: line territory — width 64, height floors low, and the
-- 11px label no longer fits so it is suppressed (single space) while idle.
settingChipRatio = 400
HARNESS_RENDERS = {}
render()
local chip1Line = findNode(lastTree(), "ws-1")
assert(chip1Line.props.width == 64, "ratio 400 idle width mismatch, got " .. tostring(chip1Line.props.width))
assert(chip1Line.props.height == 4, "ratio 400 idle height mismatch, got " .. tostring(chip1Line.props.height))
local chip1LineLabel = findNode(chip1Line, "ws-1-label")
assert(chip1LineLabel.props.text == " ", "label should be suppressed when the idle chip is too flat, got " .. tostring(chip1LineLabel.props.text))

-- display "windows": label is the workspace's TRUE window count. The count
-- (2) deliberately differs from the idx (1) so an idx fallback fails loudly
-- (a count==idx fixture masked exactly that bug once). Also exercise the
-- readSettings path itself — "windows" must survive validation.
settingChipRatio = 100
windowsById[101] = { id = 101, title = "Two", appId = "kitty", workspaceId = 1, isFocused = false }
HARNESS_CONFIG = { display = "windows" }
readSettings()
assert(settingDisplay == "windows", "readSettings must accept display=windows, got " .. tostring(settingDisplay))
HARNESS_RENDERS = {}
render()
local chip1Count = findNode(lastTree(), "ws-1")
local chip1CountLabel = findNode(chip1Count, "ws-1-label")
assert(chip1CountLabel.props.text == "2", "display=windows should label the chip with its window count, got " .. tostring(chip1CountLabel.props.text))
windowsById[101] = nil
HARNESS_CONFIG = {}
settingDisplay = "id"
settingChipRatio = 140

local chipDot1 = findNode(lastTree(), "ws-chipcol-1-dot")
assert(chipDot1 ~= nil, "chip dot slot missing")
assert(chipDot1.props.width == 12 and chipDot1.props.height == 2 and chipDot1.props.radius == 1, "chip dot geometry mismatch")
assert(chipDot1.props.fill == "primary/0", "chip dot slot should always be reserved-but-unlit, got " .. tostring(chipDot1.props.fill))

local chipPad1 = findNode(lastTree(), "ws-chipcol-1-pad")
assert(chipPad1 ~= nil, "chip top spacer missing")
assert(chipPad1.props.height == 2 and chipPad1.props.fill == "primary/0", "chip top spacer must mirror the dot slot invisibly")

local chipCol1 = findNode(lastTree(), "ws-chipcol-1")
assert(chipCol1 ~= nil, "chip column wrapper missing")

local winPad100 = findNode(lastTree(), "win-100-pad")
assert(winPad100 ~= nil, "window tile top spacer missing (symmetry with chip column)")

settingDisplay = "name" -- name "abc" -> 3 chars
settingMaxLabelChars = 20 -- default is 1 (v4 parity); widen so "abc" isn't truncated to "a"
HARNESS_RENDERS = {}
render()
local chip1ByName = findNode(lastTree(), "ws-1")
assert(chip1ByName.props.width == 16 + 6 * 2, "3-char label chip width mismatch, got " .. tostring(chip1ByName.props.width))
assert(chip1ByName.props.width > 16, "3-char label chip should be wider than the bare circle")
settingDisplay = "id"
settingMaxLabelChars = 1

-- ---- fixture (e): dot fill per focus state (also covered from a
-- different angle in harness-feeder-icons.luau) ---------------------------

HARNESS_RENDERS = {}
render()
local dot100 = findNode(lastTree(), "win-100-dot")
assert(dot100 ~= nil, "dot node missing")
assert(dot100.props.fill == "primary", "focused window's dot should be filled primary, got " .. tostring(dot100.props.fill))
assert(dot100.props.height == 2 and dot100.props.radius == 1, "window dot geometry mismatch")

windowsById[100].isFocused = false
HARNESS_RENDERS = {}
render()
local dot100b = findNode(lastTree(), "win-100-dot")
assert(dot100b.props.fill == "primary/0", "unfocused window's dot should be primary/0, got " .. tostring(dot100b.props.fill))
windowsById[100].isFocused = true

-- ---- fixtures (a)+(b): open fade, grace-driven close, ms accumulators ---

perChipHover = true
expandedWsId = nil
collapsePending = false
graceMs = 0
rowAnim = {}
currentIntervalMs = 250
HARNESS_INTERVAL_MS = nil
HARNESS_INTERVAL_CALLS = {}

assert(type(env.hoverChip_1) == "function", "hoverChip_1 callback missing")

-- Open: the hover callback itself renders, which should set the row's
-- target to 1 and — since opacity (0) now disagrees with target — drop the
-- interval to 16ms THIS render, not one update() tick later.
env.hoverChip_1("true")
assert(rowAnim[1] ~= nil and rowAnim[1].target == 1, "open should set target 1")
assert(rowAnim[1].opacity == 0, "opacity should not jump on the render that flips target")
assert(currentIntervalMs == 16, "interval should drop to 16ms the same render a target flips")
assert(HARNESS_INTERVAL_CALLS[#HARNESS_INTERVAL_CALLS] == 16, "setUpdateInterval(16) should have been recorded")

-- Step the fade to completion. Each tick uses dt = currentIntervalMs (16
-- while mid-flight), so this should take a handful of ticks, never more
-- than a generous bound, and opacity must stay within [0, 1] throughout.
local guard = 0
while rowAnim[1].opacity ~= rowAnim[1].target do
  local before = rowAnim[1].opacity
  update()
  assert(rowAnim[1].opacity >= 0 and rowAnim[1].opacity <= 1, "opacity left [0,1] while opening")
  assert(rowAnim[1].opacity >= before, "opacity should move monotonically toward 1 while opening")
  guard += 1
  assert(guard < 100, "open fade did not settle in a reasonable number of ticks")
end
assert(rowAnim[1].opacity == 1, "open fade should settle exactly at 1")
assert(currentIntervalMs == 250, "interval should restore to 250ms once settled")
assert(HARNESS_INTERVAL_MS == 250, "noctalia.setUpdateInterval(250) should have been called on settle")

HARNESS_RENDERS = {}
render()
local windowsRowOpen = findNode(lastTree(), "wins-1")
assert(windowsRowOpen.props.visible == true, "fully open row should be visible")
assert(windowsRowOpen.props.opacity == 1, "fully open row should render at opacity 1")

local groupOpen = findNode(lastTree(), "ws-group-1")
assert(groupOpen.props.fill == "surface_variant/0.30", "settled open+occupied pill fill mismatch, got " .. tostring(groupOpen.props.fill))
assert(groupOpen.props.radius == 11, "pill radius mismatch, got " .. tostring(groupOpen.props.radius))
assert(groupOpen.props.paddingH == 3 and groupOpen.props.paddingV == 0, "pill padding mismatch")
assert(groupOpen.props.border == "primary/0.35" and groupOpen.props.borderWidth == 1, "settled-open pill should carry the primary hairline, got " .. tostring(groupOpen.props.border))

-- ---- fixture (a): grace accumulator fires at exactly COLLAPSE_GRACE_MS,
-- driven purely by 250ms ticks (idle -> no animation in flight) ----------

env.hoverChip_1("false")
assert(collapsePending == true, "leaving should arm the collapse countdown")
assert(graceMs == 0, "leaving should reset the grace accumulator")

for i = 1, 4 do
  update()
  assert(collapsePending == true, "grace should not fire before " .. tostring(COLLAPSE_GRACE_MS) .. "ms (tick " .. i .. ")")
  assert(rowAnim[1].target == 1, "row should stay open mid-grace (tick " .. i .. ")")
end
assert(graceMs == 1000, "grace accumulator should read 4*250=1000ms, got " .. tostring(graceMs))

-- 5th tick crosses 1250ms: grace fires, target flips to 0, and — since
-- opacity (1) now disagrees with the new target — the interval drops to
-- 16ms again within this same update() call (render() is called from the
-- grace-expiry branch itself).
update()
assert(collapsePending == false, "grace should fire at the 5th 250ms tick (1250ms)")
assert(expandedWsId == nil, "expandedWsId should clear once the grace period elapses")
assert(rowAnim[1].target == 0, "grace expiry should flip the row's target to 0")
assert(currentIntervalMs == 16, "interval should drop back to 16ms once the close fade starts")

-- ---- fixture (c): close fade reaches 0 then visible=false --------------

guard = 0
while rowAnim[1].opacity ~= rowAnim[1].target do
  local before = rowAnim[1].opacity
  update()
  assert(rowAnim[1].opacity >= 0 and rowAnim[1].opacity <= 1, "opacity left [0,1] while closing")
  assert(rowAnim[1].opacity <= before, "opacity should move monotonically toward 0 while closing")
  guard += 1
  assert(guard < 100, "close fade did not settle in a reasonable number of ticks")
end
assert(rowAnim[1].opacity == 0, "close fade should settle exactly at 0")
assert(currentIntervalMs == 250, "interval should restore to 250ms once the close fade settles")

HARNESS_RENDERS = {}
render()
local windowsRowClosed = findNode(lastTree(), "wins-1")
assert(windowsRowClosed.props.visible == false, "fully closed row should be visible=false")
assert(windowsRowClosed.props.opacity == 0, "fully closed row should render at opacity 0")

local groupClosed = findNode(lastTree(), "ws-group-1")
assert(groupClosed.props.fill == "surface_variant/0.00", "closed pill fill should be transparent, got " .. tostring(groupClosed.props.fill))

-- ---- fixture (d): reversal mid-fade never leaves [0,1], no restart pop -

env.hoverChip_1("true") -- re-open: renders, target -> 1, opacity starts at 0 again
assert(rowAnim[1].target == 1 and rowAnim[1].opacity == 0)

update() -- one 16ms step partway open
local midOpacity = rowAnim[1].opacity
assert(midOpacity > 0 and midOpacity < 1, "expected a partial step mid-fade, got " .. tostring(midOpacity))

-- Mid-fade frame: the pill tint should track opacity continuously, not snap
-- between the closed/settled extremes.
local groupMid = findNode(lastTree(), "ws-group-1")
local midFillAlpha = tonumber(string.match(groupMid.props.fill, "([%d%.]+)$"))
assert(midFillAlpha ~= nil, "mid-fade pill fill should still be a surface_variant/N string, got " .. tostring(groupMid.props.fill))
assert(midFillAlpha > 0 and midFillAlpha < 0.30, "mid-fade pill alpha should sit strictly between closed and settled-open, got " .. tostring(midFillAlpha))

-- Simulate the grace period having already elapsed mid-fade (the real
-- 5-tick countdown is exercised separately above) by applying exactly what
-- update()'s grace-expiry branch does: clear expandedWsId and render(). That
-- flips this row's target to 0 without touching its in-flight opacity.
expandedWsId = nil
HARNESS_RENDERS = {}
render()
assert(rowAnim[1].target == 0, "reversal setup: row should now be targeting closed")
assert(rowAnim[1].opacity == midOpacity, "flipping target must not reset opacity (no restart pop)")

-- Reverse again mid-flight: re-open before it reaches 0.
update()
local afterOneCloseStep = rowAnim[1].opacity
assert(afterOneCloseStep >= 0 and afterOneCloseStep <= 1, "opacity left [0,1] mid close step")
assert(afterOneCloseStep < midOpacity, "one close step should have reduced opacity")

env.hoverChip_1("true")
assert(rowAnim[1].target == 1, "re-opening mid-close should flip target back to 1")
assert(rowAnim[1].opacity == afterOneCloseStep, "re-opening must resume from the current opacity, not restart from 0")

guard = 0
local minSeen, maxSeen = rowAnim[1].opacity, rowAnim[1].opacity
while rowAnim[1].opacity ~= rowAnim[1].target do
  update()
  minSeen = math.min(minSeen, rowAnim[1].opacity)
  maxSeen = math.max(maxSeen, rowAnim[1].opacity)
  guard += 1
  assert(guard < 100, "reversed fade did not settle in a reasonable number of ticks")
end
assert(minSeen >= 0 and maxSeen <= 1, "reversed fade left [0,1] at some point")
assert(rowAnim[1].opacity == 1, "reversed fade should settle exactly back at 1")

-- ---- fixture (a): resync accumulator fires at exactly RESYNC_MS,
-- exercised across a MIX of 16ms and 250ms ticks to prove the accumulator
-- is genuinely ms-based, not a disguised tick count ----------------------

resyncMs = 0
local asyncBefore = #HARNESS_ASYNC

local function resyncFiredSince(markIndex)
  for i = markIndex + 1, #HARNESS_ASYNC do
    if string.find(HARNESS_ASYNC[i].cmd, "%-%-%-NTB%-SEP") then
      return true
    end
  end
  return false
end

-- 10 ticks manually forced to 16ms (160ms) then enough 250ms ticks to land
-- just under 30000ms.
for _ = 1, 10 do
  currentIntervalMs = 16
  update()
end
assert(resyncMs == 160, "expected 160ms accumulated after ten 16ms ticks, got " .. tostring(resyncMs))

for _ = 1, 119 do
  update() -- currentIntervalMs settles back to 250 once idle (asserted implicitly below)
end
assert(currentIntervalMs == 250, "interval should have settled back to 250ms while idle")
assert(resyncMs == 160 + 119 * 250, "resync accumulator mismatch before threshold: " .. tostring(resyncMs))
assert(not resyncFiredSince(asyncBefore), "resync fired before crossing " .. tostring(RESYNC_MS) .. "ms")

update() -- crosses 30000ms (160 + 120*250 = 30160)
assert(resyncFiredSince(asyncBefore), "resync did not fire once RESYNC_MS was crossed")
assert(resyncMs == 0, "resync accumulator should reset once it fires")

-- ---- switch handoff: hovering B while A is open snaps A shut in the same
-- render (one width jump per switch, not two staggered ones) --------------
workspacesById[2] = { id = 2, idx = 2, name = nil, output = "DP-3", isActive = false, isFocused = false, isUrgent = false }
render() -- registers hoverChip_2 for the new workspace
perChipHover = true
expandedWsId = 1
rowAnim[1] = { opacity = 1, target = 1 }
rowAnim[2] = { opacity = 0, target = 0 }
env["hoverChip_2"]("true")
assert(expandedWsId == 2, "switch should move expansion to workspace 2")
assert(rowAnim[1].opacity == 0 and rowAnim[1].target == 0, "old row must snap fully closed on switch, got opacity=" .. tostring(rowAnim[1].opacity))
local oldRow = findNode(lastTree(), "wins-1")
assert(oldRow.props.visible == false, "old row must be hidden in the same render as the switch")
assert(rowAnim[2].target == 1, "new row should be fading in after the switch")

-- ---- fixture (g): show_focus_dot gates only the lit fill, never geometry -

workspacesById = {
  [1] = { id = 1, idx = 1, name = "abc", output = "DP-3", isActive = false, isFocused = true, isUrgent = false },
}
windowsById = {
  [100] = { id = 100, title = "Term", appId = "firefox", workspaceId = 1, isFocused = true },
}
perChipHover = false
expanded = false
expandedWsId = nil
rowAnim = {}
settingShowFocusDot = false
HARNESS_RENDERS = {}
render()
local dotGated = findNode(lastTree(), "win-100-dot")
assert(dotGated.props.fill == "primary/0", "show_focus_dot=false must never light the dot even when focused, got " .. tostring(dotGated.props.fill))
assert(dotGated.props.width == 12 and dotGated.props.height == 2 and dotGated.props.radius == 1, "dot geometry must stay stable when show_focus_dot is off")
local padGated = findNode(lastTree(), "win-100-pad")
assert(padGated.props.width == 12 and padGated.props.height == 2, "spacer geometry must stay stable when show_focus_dot is off")
settingShowFocusDot = true
HARNESS_RENDERS = {}
render()
local dotUngated = findNode(lastTree(), "win-100-dot")
assert(dotUngated.props.fill == "primary", "show_focus_dot=true should light a focused window's dot again, got " .. tostring(dotUngated.props.fill))

-- ---- fixture (h): chip_spacing drives the root container gap -------------

HARNESS_RENDERS = {}
settingChipSpacing = 3
render()
assert(lastTree().props.gap == 3, "default chip_spacing should drive the root gap to 3, got " .. tostring(lastTree().props.gap))
settingChipSpacing = 9
HARNESS_RENDERS = {}
render()
assert(lastTree().props.gap == 9, "chip_spacing should drive the root container gap, got " .. tostring(lastTree().props.gap))
settingChipSpacing = 3

-- ---- fixture (i): collapse_delay_ms / expand_speed via readSettings -----

HARNESS_CONFIG = { collapse_delay_ms = 2000, expand_speed = "fast" }
readSettings()
assert(COLLAPSE_GRACE_MS == 2000, "collapse_delay_ms should overwrite COLLAPSE_GRACE_MS, got " .. tostring(COLLAPSE_GRACE_MS))
assert(FADE_TAU_MS == 40, "expand_speed=fast should set FADE_TAU_MS to 40, got " .. tostring(FADE_TAU_MS))

HARNESS_CONFIG = { expand_speed = "slow" }
readSettings()
assert(FADE_TAU_MS == 100, "expand_speed=slow should set FADE_TAU_MS to 100, got " .. tostring(FADE_TAU_MS))
assert(COLLAPSE_GRACE_MS == 1250, "an unset collapse_delay_ms should fall back to the 1250ms default, got " .. tostring(COLLAPSE_GRACE_MS))

HARNESS_CONFIG = {}
readSettings()
assert(FADE_TAU_MS == 65, "an unset expand_speed should fall back to normal (65ms), got " .. tostring(FADE_TAU_MS))
assert(COLLAPSE_GRACE_MS == 1250, "an unset collapse_delay_ms should fall back to the 1250ms default, got " .. tostring(COLLAPSE_GRACE_MS))

-- ---- fixture (j): pill_tint drives the fill/border formula ---------------

workspacesById = {
  [1] = { id = 1, idx = 1, name = "abc", output = "DP-3", isActive = false, isFocused = true, isUrgent = false },
}
windowsById = {
  [100] = { id = 100, title = "Term", appId = "firefox", workspaceId = 1, isFocused = true },
}
perChipHover = false
expanded = true -- fully open so anim.opacity settles to 1 in one bumpAndRender pass below
rowAnim = { [1] = { opacity = 1, target = 1 } }
settingPillTint = 50
HARNESS_RENDERS = {}
render()
local groupTinted = findNode(lastTree(), "ws-group-1")
assert(groupTinted.props.fill == "surface_variant/0.50", "pill_tint=50 should yield a 0.50 fill at settled open, got " .. tostring(groupTinted.props.fill))
assert(groupTinted.props.border == "primary/0.55", "pill_tint=50 should yield a 0.55 border ((50/100)+0.05), got " .. tostring(groupTinted.props.border))
settingPillTint = 30
expanded = false

-- ---- urgent-window dot: error fill when urgent and unfocused; focused
-- wins over urgent; show_focus_dot=false suppresses both ------------------
windowsById[100].isFocused = false
windowsById[100].isUrgent = true
HARNESS_RENDERS = {}
render()
local dotUrgent = findNode(lastTree(), "win-100-dot")
assert(dotUrgent.props.fill == "error", "urgent unfocused window's dot should be error, got " .. tostring(dotUrgent.props.fill))

windowsById[100].isFocused = true
HARNESS_RENDERS = {}
render()
local dotFocusedUrgent = findNode(lastTree(), "win-100-dot")
assert(dotFocusedUrgent.props.fill == "primary", "focused wins over urgent for the dot, got " .. tostring(dotFocusedUrgent.props.fill))

settingShowFocusDot = false
HARNESS_RENDERS = {}
render()
local dotSuppressed = findNode(lastTree(), "win-100-dot")
assert(dotSuppressed.props.fill == "primary/0", "show_focus_dot=false must suppress urgent dots too, got " .. tostring(dotSuppressed.props.fill))
assert(dotSuppressed.props.height == 2, "dot geometry must not change with show_focus_dot")
settingShowFocusDot = true
windowsById[100].isUrgent = false

-- ---- urgency events (docs-derived shape) + grey hover dot ---------------
workspacesById[1].isUrgent = false
handleLine('{"WorkspaceUrgencyChanged":{"id":1,"urgent":true}}')
assert(workspacesById[1].isUrgent == true, "WorkspaceUrgencyChanged should set isUrgent")
handleLine('{"WorkspaceUrgencyChanged":{"id":1,"urgent":false}}')
assert(workspacesById[1].isUrgent == false, "WorkspaceUrgencyChanged should clear isUrgent")
handleLine('{"WorkspaceUrgencyChanged":{"id":999,"urgent":true}}') -- unknown id: no error

windowsById[100].isUrgent = false
handleLine('{"WindowUrgencyChanged":{"id":100,"urgent":true}}')
assert(windowsById[100].isUrgent == true, "WindowUrgencyChanged should set isUrgent")
handleLine('{"WindowUrgencyChanged":{"id":100,"urgent":false}}')
assert(windowsById[100].isUrgent == false, "WindowUrgencyChanged should clear isUrgent")

-- Grey hover dot: hoverWin lights the hovered tile's dot unless focus or
-- urgency already claims it; leaving clears it.
windowsById[100].isFocused = false
assert(type(env.hoverWin_100) == "function", "hoverWin callback missing")
env.hoverWin_100("true")
assert(hoveredWindowId == 100, "hoverWin true should track the hovered window")
local dotHover = findNode(lastTree(), "win-100-dot")
assert(dotHover.props.fill == "on_surface_variant/0.6", "hovered unfocused tile should show the grey dot, got " .. tostring(dotHover.props.fill))
windowsById[100].isFocused = true
HARNESS_RENDERS = {}
render()
local dotHoverFocused = findNode(lastTree(), "win-100-dot")
assert(dotHoverFocused.props.fill == "primary", "focus wins over hover for the dot")
env.hoverWin_100("false")
assert(hoveredWindowId == nil, "hoverWin false should clear the hovered window")
collapsePending = false
