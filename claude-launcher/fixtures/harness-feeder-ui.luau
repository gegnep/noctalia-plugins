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

-- Count by KIND, not by "has an id": a header or separator that grew an id
-- must not be mistaken for an enabled action. The prelude stub already
-- enforces the host's own validation rules, so a malformed request raises
-- before it gets here.
local ids, enabledActions, headers = {}, 0, 0
for _, item in ipairs(request.items) do
  local kind = item.kind or "item"
  if kind == "item" then
    assert(type(item.label) == "string" and item.label ~= "",
      "action '" .. tostring(item.id) .. "' has no label")
    assert(ids[item.id] == nil, "duplicate action id: " .. tostring(item.id))
    ids[item.id] = true
    if item.enabled ~= false then
      enabledActions += 1
    end
  elseif kind == "header" then
    headers += 1
  end
end
assert(ids.rename and ids.terminal and ids.delete,
  "menu must offer rename, terminal and delete")
assert(enabledActions >= 1, "openContextMenu raises unless one action is enabled")
assert(headers == 1, "the menu should name the chat exactly once")

-- 5. Menu actions drive the EXISTING state machine: rename opens the inline
--    editor, delete only ARMS the two-step confirm (never deletes outright),
--    and each CLEARS the other's pending state. Dispatch the way the host
--    does, through the global named by onActivate with the request's context,
--    so a renamed callback or a wrong context is caught here.
local activate = getfenv()[request.onActivate]
assert(type(activate) == "function", "onActivate names an unregistered global")

-- Rename while a delete is already armed: the confirm must be disarmed, or the
-- row would render an editor and a "delete?" prompt at the same time.
pendingDeleteChatId = chat.id
renamingChatId = nil
renameBuffer = ""
activate("rename", request.context)
assert(renamingChatId == chat.id, "rename action did not open the inline editor")
assert(renameBuffer == chat.title, "rename action did not seed the rename buffer")
assert(pendingDeleteChatId == nil, "rename must disarm a pending delete confirm")

-- Delete while a rename editor is open: the editor must close.
activate("delete", request.context)
assert(pendingDeleteChatId == chat.id, "delete action did not arm the inline confirm")
assert(renamingChatId == nil, "delete must close an open rename editor")
assert(#historyIndex.chats == 1, "delete action must not remove the chat outright")

-- Repeating the menu action still only ARMS it; only onConfirmDeleteChat
-- actually deletes.
activate("delete", request.context)
assert(#historyIndex.chats == 1, "a repeated delete action must not delete")
pendingDeleteChatId = nil
renamingChatId = nil
renameBuffer = ""

activate("no-such-action", request.context)
activate("delete", "no-such-chat")
assert(pendingDeleteChatId == nil, "an unknown chat id must be a no-op")

-- 6. Every string the host validates must be clamped: openContextMenu raises
--    on an empty label or one over 512 bytes, and a raise in a pointer
--    callback feeds the host's 5-errors/60s health breaker. Derived titles are
--    capped at 60 chars, but renames and titles loaded from index.json are not.
local function headerLabelFor(title)
  chat.title = title
  HARNESS_CONTEXT_MENU = nil
  menuFn()
  for _, item in ipairs(HARNESS_CONTEXT_MENU.items) do
    if item.kind == "header" then
      return item.label
    end
  end
  return nil
end

local longLabel = headerLabelFor(string.rep("x", 900))
assert(type(longLabel) == "string" and #longLabel <= 512,
  "header label must be clamped to 512 bytes, got " .. tostring(longLabel and #longLabel))
local emptyLabel = headerLabelFor("   ")
assert(type(emptyLabel) == "string" and #emptyLabel >= 1,
  "a blank title must fall back to a non-empty header label")

-- The host counts BYTES, so a naive cut splits a multibyte character: 171 "€"
-- is 513 bytes, and cutting at 512 leaves two orphaned continuation bytes.
-- Every byte of the clamped label must belong to a complete sequence.
local euro = "\226\130\172" -- U+20AC, 3 bytes
local multibyteLabel = headerLabelFor(string.rep(euro, 171))
assert(type(multibyteLabel) == "string" and #multibyteLabel <= 512,
  "multibyte header label must be clamped to 512 bytes")
assert(#multibyteLabel % 3 == 0,
  "clamped label split a 3-byte character: " .. #multibyteLabel .. " bytes")
local trailing = string.byte(multibyteLabel, #multibyteLabel)
assert(trailing ~= nil and trailing >= 128 and trailing < 192,
  "the clamped label should end on a continuation byte of a COMPLETE sequence")
-- And the cut must not be so eager that it throws the label away.
assert(#multibyteLabel >= 510, "clamp discarded more than one character")

print("UI DRY-RUN OK  models=" .. #models .. "  menuItems=" .. #request.items)
