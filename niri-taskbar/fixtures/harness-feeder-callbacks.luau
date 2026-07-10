for _, line in ipairs(FIXTURE_LINES) do
  CAPTURED_ONLINE(line)
end

assert(type(env.focusWin_86) == "function", "focusWin_86 callback missing")
env.focusWin_86()
assert(HARNESS_ASYNC[#HARNESS_ASYNC].cmd == "niri msg action focus-window --id 86", "bad focus-window command")

assert(type(env.focusWs_1) == "function", "focusWs_1 callback missing")
env.focusWs_1()
assert(HARNESS_ASYNC[#HARNESS_ASYNC].cmd == "niri msg action focus-workspace 2", "bad same-output focus-workspace command")

for _, id in ipairs({ 140, 141, 93 }) do
  local name = "focusWin_" .. id
  env[name] = function() end
  registeredWindowCallbacks[id] = name
end

pruneCallbackEnv()

for _, id in ipairs({ 140, 141, 93 }) do
  assert(env["focusWin_" .. id] == nil, "closed window callback survived prune: " .. id)
end
