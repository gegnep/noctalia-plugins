-- Expected values computed while writing this feeder:
-- jq 'select(.WorkspacesChanged)|.WorkspacesChanged.workspaces|length' event-stream.jsonl
--   => 9
-- jq 'select(.WorkspacesChanged)|.WorkspacesChanged.workspaces|map(.output)|group_by(.)|map({(.[0]):length})|add' event-stream.jsonl
--   => {"DP-3":7,"HDMI-A-1":2}
-- jq -s '[.[]|select(.WorkspaceActivated.focused == true)|.WorkspaceActivated.id][-1]' event-stream.jsonl
--   => 1
-- jq -s '[.[]|if .WindowsChanged then .WindowsChanged.windows[]|select(.id==86)|.workspace_id elif .WindowOpenedOrChanged and .WindowOpenedOrChanged.window.id==86 then .WindowOpenedOrChanged.window.workspace_id else empty end][-1]' event-stream.jsonl
--   => 1
-- jq -r 'select(.WindowClosed)|.WindowClosed|if type=="number" then . elif has("id") then .id else .window_id end' event-stream.jsonl
--   => 140, 141, 93

local function countMap(t)
  local n = 0
  for _ in pairs(t) do
    n += 1
  end
  return n
end

local function perOutput()
  local counts = {}
  for _, workspace in pairs(workspacesById) do
    counts[workspace.output] = (counts[workspace.output] or 0) + 1
  end
  return counts
end

local function focusedWorkspaceId()
  for _, workspace in pairs(workspacesById) do
    if workspace.isFocused then
      return workspace.id
    end
  end
  return nil
end

assert(HARNESS_INTERVAL_MS == 250, "update interval not set")
assert(CAPTURED_ONLINE ~= nil, "taskbar did not start a stream")
assert(CAPTURED_STREAMS[1].cmd == "niri msg --json event-stream || true # ntb-12345678", "bad stream command")

for _, line in ipairs(FIXTURE_LINES) do
  CAPTURED_ONLINE(line)
end

local counts = perOutput()
assert(countMap(workspacesById) == 9, "workspace count mismatch")
assert(counts["DP-3"] == 7, "DP-3 workspace count mismatch")
assert(counts["HDMI-A-1"] == 2, "HDMI-A-1 workspace count mismatch")
assert(focusedWorkspaceId() == 1, "focused workspace mismatch")
assert(windowsById[86] ~= nil and windowsById[86].workspaceId == 1, "window 86 workspace mismatch")

for _, id in ipairs({ 140, 141, 93 }) do
  assert(windowsById[id] == nil, "closed window still present: " .. id)
end
