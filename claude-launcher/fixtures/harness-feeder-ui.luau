-- Test harness feeder: drives render() directly (no stream fixture) and
-- asserts UI-tree facts the reconciler footguns depend on — model-picker
-- contents, the history row's context-menu wiring, and composer props.
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

local function findNode(tree, predicate)
  local found = nil
  walk(tree, function(node)
    if found == nil and predicate(node) then
      found = node
    end
  end)
  return found
end

local function indexOf(list, value)
  for i, item in ipairs(list) do
    if item == value then
      return i
    end
  end
  return nil
end

-- 1. MODEL_INFO / availableModels carry Fable 5.1, ordered ahead of Fable 5,
--    without displacing the "auto" fallback model.
local fable51 = MODEL_INFO["claude-fable-5-1"]
assert(type(fable51) == "table", "MODEL_INFO is missing claude-fable-5-1")
assert(fable51.label == "Fable 5.1", "unexpected Fable 5.1 label: " .. tostring(fable51.label))
assert(fable51.effortKind == "levels", "Fable 5.1 must use level-based effort")
assert(MODEL_INFO["claude-fable-5"] ~= nil, "claude-fable-5 must stay: chats lock their model")

local models = availableModels()
local i51 = indexOf(models, "claude-fable-5-1")
local i50 = indexOf(models, "claude-fable-5")
assert(i51 ~= nil, "availableModels() is missing claude-fable-5-1")
assert(i50 ~= nil, "availableModels() dropped claude-fable-5")
assert(i51 < i50, "Fable 5.1 must be offered before Fable 5")
assert(models[1] == "claude-sonnet-5", "the auto-fallback model must stay claude-sonnet-5")

-- 2. The open model picker renders a row for Fable 5.1.
onToggleModelPicker()
assert(HARNESS_LAST_TREE ~= nil, "render() never called panel.render")
local fableButton = findNode(HARNESS_LAST_TREE, function(node)
  return node.type == "button" and node.props.text == "Fable 5.1"
end)
assert(fableButton ~= nil, "model picker has no Fable 5.1 row")
onToggleModelPicker()

-- 3. The composer input pins its frame explicitly (the reconciler applies
--    frameVisible only when present, so it must never be omitted).
local composerInput = findNode(HARNESS_LAST_TREE, function(node)
  return node.type == "input" and node.props.placeholder ~= nil
end)
assert(composerInput ~= nil, "composer input not found in the tree")
assert(composerInput.props.frameVisible == true,
  "composer input must pass frameVisible explicitly, got " .. tostring(composerInput.props.frameVisible))

-- 4. A history row's title button wires onRightClick to a registered global
--    that opens a native context menu carrying the chat id as context.
historyIndex = { version = 1, chats = { {
  id = "11111111-2222-3333-4444-555555555555",
  title = "A past chat",
  renamed = false,
  model = "claude-sonnet-5",
  effort = "high",
  createdAt = 0,
  updatedAt = 0,
} } }
view = "history"
render()

local chat = historyIndex.chats[1]
local titleButton = findNode(HARNESS_LAST_TREE, function(node)
  return node.type == "button" and node.props.key == "title-" .. chat.id
end)
assert(titleButton ~= nil, "history row title button not found")
local menuName = titleButton.props.onRightClick
assert(type(menuName) == "string" and menuName ~= "",
  "history row title button has no onRightClick callback name")
local menuFn = getfenv()[menuName]
assert(type(menuFn) == "function", "onRightClick names an unregistered global: " .. menuName)

HARNESS_CONTEXT_MENU = nil
menuFn()
local request = HARNESS_CONTEXT_MENU
assert(type(request) == "table", "right-click did not call panel.openContextMenu")
assert(request.onActivate == "onChatMenuAction",
  "unexpected onActivate: " .. tostring(request.onActivate))
assert(request.context == chat.id, "context must carry the chat id")
assert(type(request.items) == "table" and #request.items >= 3, "menu needs at least three entries")

local ids, enabledCount = {}, 0
for _, item in ipairs(request.items) do
  if item.id ~= nil then
    ids[item.id] = true
    if item.enabled ~= false then
      enabledCount += 1
    end
  end
end
assert(ids.rename and ids.terminal and ids.delete,
  "menu must offer rename, terminal and delete")
assert(enabledCount >= 1, "openContextMenu raises unless one action is enabled")

-- 5. Menu actions drive the EXISTING state machine: rename opens the inline
--    editor, delete only ARMS the two-step confirm (never deletes outright).
onChatMenuAction("rename", chat.id)
assert(renamingChatId == chat.id, "rename action did not open the inline editor")
assert(renameBuffer == chat.title, "rename action did not seed the rename buffer")
renamingChatId = nil
renameBuffer = ""

onChatMenuAction("delete", chat.id)
assert(pendingDeleteChatId == chat.id, "delete action did not arm the inline confirm")
assert(#historyIndex.chats == 1, "delete action must not remove the chat outright")
pendingDeleteChatId = nil

onChatMenuAction("no-such-action", chat.id)

print("UI DRY-RUN OK  models=" .. #models .. "  menuItems=" .. #request.items)
