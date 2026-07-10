-- Covers the expand/collapse fade + ms-based tick accumulators (visual-
-- polish pass): grace/resync accumulators under alternating 250ms/16ms
-- ticks, a full open fade settling at opacity 1 + interval 250, a close
-- fade reaching opacity 0 + visible=false, a mid-fade reversal staying
-- within [0,1] with no restart pop, dot fill per focus state, and chip
-- width for a 1-char vs 3-char label.
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
HARNESS_RENDERS = {}
render()
local chip1ByIdx = findNode(lastTree(), "ws-1")
assert(chip1ByIdx ~= nil, "chip node missing")
assert(chip1ByIdx.props.width == 22, "1-char label chip should be a 22px circle, got " .. tostring(chip1ByIdx.props.width))
assert(chip1ByIdx.props.paddingH == nil, "chipPaddingH geometry should be gone")
assert(chip1ByIdx.props.contentAlign == "center", "chip should center its text now that width owns geometry")

settingDisplay = "name" -- name "abc" -> 3 chars
settingMaxLabelChars = 20 -- default is 1 (v4 parity); widen so "abc" isn't truncated to "a"
HARNESS_RENDERS = {}
render()
local chip1ByName = findNode(lastTree(), "ws-1")
assert(chip1ByName.props.width == 22 + 7 * 2, "3-char label chip width mismatch, got " .. tostring(chip1ByName.props.width))
assert(chip1ByName.props.width > 22, "3-char label chip should be wider than the bare circle")
settingDisplay = "id"
settingMaxLabelChars = 1

-- ---- fixture (e): dot fill per focus state (also covered from a
-- different angle in harness-feeder-icons.luau) ---------------------------

HARNESS_RENDERS = {}
render()
local dot100 = findNode(lastTree(), "win-100-dot")
assert(dot100 ~= nil, "dot node missing")
assert(dot100.props.fill == "primary", "focused window's dot should be filled primary, got " .. tostring(dot100.props.fill))

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

assert(type(env.hoverWs_1) == "function", "hoverWs_1 callback missing")

-- Open: the hover callback itself renders, which should set the row's
-- target to 1 and — since opacity (0) now disagrees with target — drop the
-- interval to 16ms THIS render, not one update() tick later.
env.hoverWs_1("true")
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

-- ---- fixture (a): grace accumulator fires at exactly COLLAPSE_GRACE_MS,
-- driven purely by 250ms ticks (idle -> no animation in flight) ----------

env.hoverWs_1("false")
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

-- ---- fixture (d): reversal mid-fade never leaves [0,1], no restart pop -

env.hoverWs_1("true") -- re-open: renders, target -> 1, opacity starts at 0 again
assert(rowAnim[1].target == 1 and rowAnim[1].opacity == 0)

update() -- one 16ms step partway open
local midOpacity = rowAnim[1].opacity
assert(midOpacity > 0 and midOpacity < 1, "expected a partial step mid-fade, got " .. tostring(midOpacity))

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

env.hoverWs_1("true")
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
