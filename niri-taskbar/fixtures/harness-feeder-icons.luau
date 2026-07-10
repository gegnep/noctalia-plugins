local root = FIXTURE_ROOT
local dataHome = root .. "/icon-theme/data-home"
local dataSystem = root .. "/icon-theme/data-system"
local home = root .. "/icon-theme/home"

HARNESS_ENV = {
  XDG_DATA_HOME = dataHome,
  XDG_DATA_DIRS = dataSystem,
  HOME = home,
}

iconScanRoots = { root .. "/desktop-files" }
desktopIndexBuilt = false
desktopScanStats.files = 0
desktopFileIcons = {}
desktopFileIconsLower = {}
startupWmClassIcons = {}
iconCache = {}
gsettingsIconTheme = nil
settingIconThemeOverride = ""
settingIconSize = 16

local function expectPath(label, actual, expected)
  assert(actual == expected, label .. " mismatch:\nexpected " .. tostring(expected) .. "\nactual   " .. tostring(actual))
end

local hicolor = dataHome .. "/icons/hicolor/scalable/apps/"
expectPath("exact file-id", resolveWindowIcon("firefox"), hicolor .. "firefox.svg")
expectPath("case-insensitive file-id", resolveWindowIcon("FIREFOX"), hicolor .. "firefox.svg")
expectPath("StartupWMClass", resolveWindowIcon("Slack"), hicolor .. "slack.svg")
expectPath("reversed-DNS suffix", resolveWindowIcon("org.mozilla.firefox"), hicolor .. "firefox.svg")

assert(resolveWindowIcon("org.noctalia.NoSuchApp") == nil, "miss should not resolve")
assert(iconCache["org.noctalia.NoSuchApp"] == false, "miss should cache false")
assert(desktopScanStats.files == 5, "desktop scan file count mismatch: " .. tostring(desktopScanStats.files))

HARNESS_FILES["/tmp/noctalia-taskbar-absolute.svg"] = "<svg/>"
expectPath("absolute icon", resolveWindowIcon("/tmp/noctalia-taskbar-absolute.svg"), "/tmp/noctalia-taskbar-absolute.svg")

settingIconThemeOverride = "TestTheme"
iconCache = {}
expectPath("theme override direct", resolveWindowIcon("Vesktop"), dataHome .. "/icons/TestTheme/48x48/apps/vesktop.svg")
expectPath("theme inherits", resolveIconName("inherited-icon"), dataSystem .. "/icons/ParentTheme/scalable/apps/inherited-icon.svg")

workspacesById = {
  [1] = { id = 1, idx = 1, name = "1", output = "DP-3", isActive = true, isFocused = true, isUrgent = false },
}
windowsById = {
  [10] = { id = 10, title = "Firefox", appId = "firefox", workspaceId = 1, isFocused = false },
}
expanded = true
perChipHover = false
settingShowWindowTitles = false
settingIconThemeOverride = ""
iconCache = {}
HARNESS_RENDERS = {}
render()

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

local icon = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-10")
assert(icon ~= nil and icon.type == "image", "icon tile should render as image")
assert(icon.props.path == hicolor .. "firefox.svg", "icon path mismatch")
assert(icon.props.onClick == "focusWin_10", "icon onClick changed")
assert(icon.props.onHover == "hoverWs_1", "icon onHover changed")
assert(icon.props.width == 16 and icon.props.height == 16, "icon size mismatch")

windowsById = {
  [11] = { id = 11, title = "Slack workspace", appId = "Slack", workspaceId = 1, isFocused = false },
}
settingShowWindowTitles = true
HARNESS_RENDERS = {}
render()

local titled = findNode(HARNESS_RENDERS[#HARNESS_RENDERS], "win-11")
assert(titled ~= nil and titled.type == "row", "titled icon tile should keep outer row key")
local titledIcon = findNode(titled, "win-11-icon")
assert(titledIcon ~= nil and titledIcon.type == "image", "titled icon child missing")
assert(titledIcon.props.onClick == "focusWin_11", "titled icon onClick changed")
assert(titledIcon.props.onHover == "hoverWs_1", "titled icon onHover changed")
