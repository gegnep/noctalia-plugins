-- Test harness feeder: replays FIXTURE_LINES (injected by dry-run.sh between
-- panel.luau and this file) through the runStream callback captured by the
-- prelude stub, then asserts the parser's end state.

onSubmit("count to five")
assert(CAPTURED_ONLINE ~= nil, "doSubmit never called runStream")
assert(streaming == true, "streaming flag not set after submit")

local expectedText = nil
for _, line in ipairs(FIXTURE_LINES) do
  local ev = HARNESS_JSON_DECODE(line)
  if type(ev) == "table" and ev.type == "result" and type(ev.result) == "string" then
    expectedText = ev.result
  end
  CAPTURED_ONLINE(line)
end

assert(streaming == false, "streaming flag still set after result")
local msg = messages[#messages]
assert(msg ~= nil and msg.role == "assistant", "no assistant message")
assert(msg.status == "done", "unexpected status: " .. tostring(msg.status))
assert(expectedText ~= nil, "fixture has no result line")
assert(msg.text == expectedText,
  "reconciliation mismatch:\n  got:      " .. string.format("%q", msg.text)
  .. "\n  expected: " .. string.format("%q", expectedText))

-- Late buffered line after finalize must be dropped by the stale guard.
local before = msg.text
CAPTURED_ONLINE('{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"STALE"}}}')
assert(msg.text == before, "stale-stream guard failed")

-- Regression: per-message callback factories must bind the render local (a
-- factory defined before the forward declaration binds a nil global instead
-- and blows up on click — the thinking-toggle bug).
msg.thinking = "some thinking"
local toggleName = thinkingToggleCallback(msg)
local toggleFn = getfenv()[toggleName]
assert(type(toggleFn) == "function", "thinking toggle callback not registered")
toggleFn()
assert(msg.thinkingOpen == true, "thinking toggle did not flip (or render errored)")

print("DRY-RUN OK  messages=" .. #messages
  .. "  text=" .. string.format("%q", msg.text)
  .. "  logs=" .. #HARNESS_LOGS)
