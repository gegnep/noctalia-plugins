local answers = {
  firefox = "/tmp/noctalia-taskbar-firefox.svg",
  Slack = "/tmp/noctalia-taskbar-slack.svg",
  ["org.noctalia.NoSuchApp"] = nil,
}

local calls = {}
noctalia.appIconPath = function(appId, sizePx)
  table.insert(calls, { appId = appId, sizePx = sizePx })
  return answers[appId]
end

local function expectPath(label, actual, expected)
  assert(actual == expected, label .. " mismatch:\nexpected " .. tostring(expected) .. "\nactual   " .. tostring(actual))
end

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

local function callsFor(appId)
  local out = {}
  for _, call in ipairs(calls) do
    if call.appId == appId then
      table.insert(out, call)
    end
  end
  return out
end

settingIconSize = 18
iconCache = {}
calls = {}

expectPath("resolved icon", resolveWindowIcon("firefox"), answers.firefox)
assert(iconCache.firefox == answers.firefox, "resolved icon should cache path")
expectPath("cached icon", resolveWindowIcon("firefox"), answers.firefox)
assert(#callsFor("firefox") == 1, "resolved icon should be called once")
assert(callsFor("firefox")[1].sizePx == 36, "resolved icon should request icon_size * 2")

assert(resolveWindowIcon("org.noctalia.NoSuchApp") == nil, "miss should not resolve")
assert(iconCache["org.noctalia.NoSuchApp"] == false, "miss should cache false")
assert(resolveWindowIcon("org.noctalia.NoSuchApp") == nil, "cached miss should stay nil")
assert(#callsFor("org.noctalia.NoSuchApp") == 1, "miss should be called once")
assert(callsFor("org.noctalia.NoSuchApp")[1].sizePx == 36, "miss should request icon_size * 2")

workspacesById = {
  [1] = { id = 1, idx = 1, name = "1", output = "DP-3", isActive = true, isFocused = true, isUrgent = false },
}
windowsById = {
  [10] = { id = 10, title = "Firefox", appId = "firefox", workspaceId = 1, isFocused = false },
  [12] = { id = 12, title = "Unknown", appId = "org.noctalia.NoSuchApp", workspaceId = 1, isFocused = false },
}
expanded = true
perChipHover = false
settingShowWindowTitles = false
iconCache = {}
calls = {}
HARNESS_RENDERS = {}
render()

local tile10 = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-10")
assert(tile10 ~= nil and tile10.type == "column", "resolved tile outer node should be a keyed column")
assert(tile10.props.align == "center", "tile column should center its content+dot")

local icon = findNode(tile10, "win-10-icon")
assert(icon ~= nil and icon.type == "image", "resolved tile content should render as image")
assert(icon.props.path == answers.firefox, "icon path mismatch")
assert(icon.props.onClick == "focusWin_10", "icon onClick changed")
assert(icon.props.onHover == "hoverWs_1", "icon onHover changed")
assert(icon.props.width == 18 and icon.props.height == 18, "icon size mismatch")
assert(icon.props.border == nil, "icon focus-border cue should be removed entirely")

local dot10 = findNode(tile10, "win-10-dot")
assert(dot10 ~= nil and dot10.type == "row", "dot should be a row")
assert(dot10.props.width == 4 and dot10.props.height == 2 and dot10.props.radius == 1, "dot geometry mismatch")
assert(dot10.props.fill == "primary/0", "unfocused dot should be transparent")

local tile12 = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-12")
assert(tile12 ~= nil and tile12.type == "column", "unresolved tile outer node should be a keyed column")
local fallback = findNode(tile12, "win-12-fallback")
assert(fallback ~= nil and fallback.type == "button", "unresolved tile content should render as button")
assert(fallback.props.text == "N", "fallback text mismatch")
assert(fallback.props.variant == "ghost", "fallback variant should always be ghost")
assert(fallback.props.onClick == "focusWin_12", "fallback onClick changed")
assert(fallback.props.onHover == "hoverWs_1", "fallback onHover changed")
assert(callsFor("firefox")[1].sizePx == 36, "rendered resolved icon should request icon_size * 2")
assert(callsFor("org.noctalia.NoSuchApp")[1].sizePx == 36, "rendered miss should request icon_size * 2")

-- isFocused = true here to also cover the dot's focused-fill branch (spec
-- verification item (e): dot fill is "primary" for the focused window).
windowsById = {
  [11] = { id = 11, title = "Slack workspace", appId = "Slack", workspaceId = 1, isFocused = true },
}
settingShowWindowTitles = true
iconCache = {}
calls = {}
HARNESS_RENDERS = {}
render()

local tile11 = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-11")
assert(tile11 ~= nil and tile11.type == "column", "titled tile outer node should keep the column key")
local titled = findNode(tile11, "win-11-body")
assert(titled ~= nil and titled.type == "row", "titled icon content should be a row under the outer column")
local titledIcon = findNode(titled, "win-11-icon")
assert(titledIcon ~= nil and titledIcon.type == "image", "titled icon child missing")
assert(titledIcon.props.path == answers.Slack, "titled icon path mismatch")
assert(titledIcon.props.onClick == "focusWin_11", "titled icon onClick changed")
assert(titledIcon.props.onHover == "hoverWs_1", "titled icon onHover changed")
assert(titledIcon.props.border == nil, "titled icon focus-border cue should be removed entirely")
assert(callsFor("Slack")[1].sizePx == 36, "titled icon should request icon_size * 2")

local dot11 = findNode(tile11, "win-11-dot")
assert(dot11 ~= nil and dot11.props.fill == "primary", "focused dot should be filled primary")

noctalia.appIconPath = nil
windowsById = {
  [13] = { id = 13, title = "Firefox", appId = "firefox", workspaceId = 1, isFocused = false },
  [14] = { id = 14, title = "Slack", appId = "Slack", workspaceId = 1, isFocused = false },
}
settingShowWindowTitles = false
iconCache = {}
HARNESS_RENDERS = {}
render()

local absentFirefox = findNode(findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-13"), "win-13-fallback")
local absentSlack = findNode(findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-14"), "win-14-fallback")
assert(absentFirefox ~= nil and absentFirefox.type == "button", "absent binding should fallback for firefox")
assert(absentSlack ~= nil and absentSlack.type == "button", "absent binding should fallback for Slack")
assert(iconCache.firefox == false and iconCache.Slack == false, "absent binding should cache misses")
