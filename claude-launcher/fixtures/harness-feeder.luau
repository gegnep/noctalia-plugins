-- Test harness feeder: replays FIXTURE_LINES (injected by dry-run.sh between
-- panel.luau and this file) through the runStream callback, then walks the
-- Desktop handoff: xdg-open, panel close, niri window focus.

local function lastAsync()
  return HARNESS_ASYNC[#HARNESS_ASYNC]
end

local function argvEquals(cmd, expected)
  if type(cmd) ~= "table" or #cmd ~= #expected then
    return false
  end
  for i, value in ipairs(expected) do
    if cmd[i] ~= value then
      return false
    end
  end
  return true
end

local function describe(cmd)
  if type(cmd) == "table" then
    return "{" .. table.concat(cmd, ", ") .. "}"
  end
  return tostring(cmd)
end

local function okResult(stdout)
  return { exitCode = 0, stdout = stdout or "", stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false }
end

-- 1. Load-time cleanup removed both legacy files.
assert(#HARNESS_REMOVED == 2, "legacy cleanup removed " .. #HARNESS_REMOVED .. " files, expected 2")

-- 2. Submit builds the exact command.
onSubmit("count to five")
assert(CAPTURED_ONLINE ~= nil, "submit never called runStream")
assert(phase == "running", "phase after submit: " .. tostring(phase))
assert(HARNESS_SECOND_TICKS == true, "submit must request second ticks for the watchdog")
local cmd = HARNESS_STREAM_CMD
local function has(fragment)
  return string.find(cmd, fragment, 1, true) ~= nil
end
assert(string.find(cmd, "cd '~/.local/state/noctalia-claude-launcher/workspace' && claude -p 'count to five'", 1, true) == 1,
  "cwd or prompt wrong: " .. cmd)
assert(has(" --output-format stream-json --verbose --include-partial-messages"), "stream flags missing: " .. cmd)
assert(has(" --session-id '" .. HARNESS_UUID .. "'"), "missing session id: " .. cmd)
assert(has(" --model 'claude-fable-5-1'"), "default model must be Fable 5.1: " .. cmd)
assert(has(" --effort 'high'"), "default effort must be high: " .. cmd)
assert(not has("--tools"), "tools are allowed by default: " .. cmd)
assert(string.sub(cmd, -5) == " 2>&1", "stderr must be merged for diagnostics: " .. cmd)

-- 3. Replay the fixture; block starts drive the status phase.
local sawThinking, sawWriting = false, false
for _, line in ipairs(FIXTURE_LINES) do
  local ev = HARNESS_JSON_DECODE(line)
  CAPTURED_ONLINE(line)
  if type(ev) == "table" and ev.type == "stream_event" and type(ev.event) == "table"
    and ev.event.type == "content_block_start" and type(ev.event.content_block) == "table" then
    local blockType = ev.event.content_block.type
    if blockType == "thinking" then
      assert(activity == "Thinking", "a thinking block must show Thinking, got " .. tostring(activity))
      sawThinking = true
    elseif blockType == "text" then
      assert(activity == "Writing", "a text block must show Writing, got " .. tostring(activity))
      sawWriting = true
    end
  end
end

-- 4. The success result starts the handoff; the panel stays open until xdg-open answers.
assert(phase == "handoff", "a success result must start the handoff, phase=" .. tostring(phase))
local open = lastAsync()
assert(open ~= nil and argvEquals(open.cmd, { "xdg-open", "claude://resume?session=" .. HARNESS_UUID }),
  "expected xdg-open of the resume link, got " .. describe(open and open.cmd))
assert(type(open.cb) == "function", "xdg-open needs a result callback to detect failure")
assert(HARNESS_PANEL_CLOSED == 0, "the panel must stay open until xdg-open succeeds")

-- 5. A late line after the result is dropped.
local activityBefore = activity
CAPTURED_ONLINE('{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}')
assert(activity == activityBefore, "stale-stream guard failed")

-- 6. No watchdog probe once the result arrived (the CLI exits right after it).
local asyncBefore = #HARNESS_ASYNC
lastLineAt = 0
update()
assert(#HARNESS_ASYNC == asyncBefore, "watchdog probed after the result")

-- 7. xdg-open succeeded: clear, close, poll niri, focus the personal window.
open.cb(okResult())
assert(phase == "idle", "phase after handoff: " .. tostring(phase))
assert(HARNESS_PANEL_CLOSED == 1, "the panel must close after a successful handoff")
assert(composerBuffer == "", "the composer must be empty after a handoff")
local poll = lastAsync()
assert(argvEquals(poll.cmd, { "niri", "msg", "--json", "windows" }), "expected a niri window poll, got " .. describe(poll.cmd))
HARNESS_FILES["/proc/111/cmdline"] = "claude-desktop\0--user-data-dir=/home/u/.config/Claude-work\0"
HARNESS_FILES["/proc/222/cmdline"] = "claude-desktop\0"
poll.cb(okResult('[{"id":5,"app_id":"com.anthropic.Claude","pid":111,"title":"Claude"},'
  .. '{"id":6,"app_id":"org.gnome.Nautilus","pid":333,"title":"Files"},'
  .. '{"id":7,"app_id":"com.anthropic.Claude","pid":222,"title":"Claude"}]'))
local focus = lastAsync()
assert(argvEquals(focus.cmd, { "niri", "msg", "action", "focus-window", "--id", "7" }),
  "must focus the personal Desktop window (id 7), got " .. describe(focus.cmd))

print("DRY-RUN OK  thinking=" .. tostring(sawThinking) .. "  writing=" .. tostring(sawWriting)
  .. "  async=" .. #HARNESS_ASYNC .. "  logs=" .. #HARNESS_LOGS)
