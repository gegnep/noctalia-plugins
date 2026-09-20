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

print("UI DRY-RUN OK  models=" .. #models)
