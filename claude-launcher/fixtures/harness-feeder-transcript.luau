-- Test harness feeder: parses TRANSCRIPT_TEXT (injected by dry-run.sh between
-- panel.luau and this file) and asserts transcript reload behavior.

local parsed = parseTranscript(TRANSCRIPT_TEXT, "test")

assert(#parsed == 5, "expected 5 transcript messages, got " .. tostring(#parsed))

assert(parsed[1].role == "user", "message 1 role")
assert(parsed[1].text == "first question", "message 1 text")

assert(parsed[2].role == "assistant", "message 2 role")
assert(parsed[2].text == "first answer part one. part two.", "message 2 text")
assert(parsed[2].thinking == "pondering the first question", "message 2 thinking")

assert(parsed[3].role == "assistant", "message 3 role")
assert(parsed[3].text == "answer after the tool row - must be a SEPARATE assistant message (flush on skipped row).", "message 3 text")

assert(parsed[4].role == "user", "message 4 role")
assert(parsed[4].text == "second question", "message 4 text")

assert(parsed[5].role == "assistant", "message 5 role")
assert(parsed[5].text == "second answer.", "message 5 text")

for i, message in ipairs(parsed) do
  assert(message.status == "done", "message " .. i .. " status")
  assert(type(message.key) == "string" and string.sub(message.key, 1, 5) == "test-", "message " .. i .. " key prefix")
end

print("TRANSCRIPT DRY-RUN OK  messages=" .. #parsed)
