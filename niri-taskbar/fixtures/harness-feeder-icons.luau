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

local icon = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-10")
assert(icon ~= nil and icon.type == "image", "resolved tile should render as image")
assert(icon.props.path == answers.firefox, "icon path mismatch")
assert(icon.props.onClick == "focusWin_10", "icon onClick changed")
assert(icon.props.onHover == "hoverWs_1", "icon onHover changed")
assert(icon.props.width == 18 and icon.props.height == 18, "icon size mismatch")

local fallback = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-12")
assert(fallback ~= nil and fallback.type == "button", "unresolved tile should render as button")
assert(fallback.props.text == "N", "fallback text mismatch")
assert(fallback.props.onClick == "focusWin_12", "fallback onClick changed")
assert(fallback.props.onHover == "hoverWs_1", "fallback onHover changed")
assert(callsFor("firefox")[1].sizePx == 36, "rendered resolved icon should request icon_size * 2")
assert(callsFor("org.noctalia.NoSuchApp")[1].sizePx == 36, "rendered miss should request icon_size * 2")

windowsById = {
  [11] = { id = 11, title = "Slack workspace", appId = "Slack", workspaceId = 1, isFocused = false },
}
settingShowWindowTitles = true
iconCache = {}
calls = {}
HARNESS_RENDERS = {}
render()

local titled = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-11")
assert(titled ~= nil and titled.type == "row", "titled icon tile should keep outer row key")
local titledIcon = findNode(titled, "win-11-icon")
assert(titledIcon ~= nil and titledIcon.type == "image", "titled icon child missing")
assert(titledIcon.props.path == answers.Slack, "titled icon path mismatch")
assert(titledIcon.props.onClick == "focusWin_11", "titled icon onClick changed")
assert(titledIcon.props.onHover == "hoverWs_1", "titled icon onHover changed")
assert(callsFor("Slack")[1].sizePx == 36, "titled icon should request icon_size * 2")

noctalia.appIconPath = nil
windowsById = {
  [13] = { id = 13, title = "Firefox", appId = "firefox", workspaceId = 1, isFocused = false },
  [14] = { id = 14, title = "Slack", appId = "Slack", workspaceId = 1, isFocused = false },
}
settingShowWindowTitles = false
iconCache = {}
HARNESS_RENDERS = {}
render()

local absentFirefox = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-13")
local absentSlack = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-14")
assert(absentFirefox ~= nil and absentFirefox.type == "button", "absent binding should fallback for firefox")
assert(absentSlack ~= nil and absentSlack.type == "button", "absent binding should fallback for Slack")
assert(iconCache.firefox == false and iconCache.Slack == false, "absent binding should cache misses")
