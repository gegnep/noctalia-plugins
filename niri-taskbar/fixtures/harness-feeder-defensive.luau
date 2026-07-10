windowsById = {
  [201] = { id = 201, title = "A", appId = "a", workspaceId = 1, isFocused = false },
  [202] = { id = 202, title = "B", appId = "b", workspaceId = 1, isFocused = false },
  [203] = { id = 203, title = "C", appId = "c", workspaceId = 1, isFocused = false },
}

for _, id in ipairs({ 201, 202, 203 }) do
  local name = "focusWin_" .. id
  registeredWindowCallbacks[id] = name
  env[name] = function() end
end

local before = stateGeneration
CAPTURED_ONLINE('{"WindowClosed":201}')
CAPTURED_ONLINE('{"WindowClosed":{"id":202}}')
CAPTURED_ONLINE('{"WindowClosed":{"window_id":203}}')
CAPTURED_ONLINE('{"FutureNiriEvent":{"shape":"ignored"}}')
CAPTURED_ONLINE('not json at all')

assert(windowsById[201] == nil, "bare WindowClosed id not removed")
assert(windowsById[202] == nil, "{id} WindowClosed not removed")
assert(windowsById[203] == nil, "{window_id} WindowClosed not removed")
assert(env.focusWin_201 == nil, "bare WindowClosed callback not pruned")
assert(env.focusWin_202 == nil, "{id} WindowClosed callback not pruned")
assert(env.focusWin_203 == nil, "{window_id} WindowClosed callback not pruned")
assert(stateGeneration == before + 3, "unknown/garbage events changed generation")
