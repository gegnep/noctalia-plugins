-- Expected values computed while writing this feeder:
-- jq '{workspace_count:length, per_output:(map(.output)|group_by(.)|map({(.[0]):length})|add), focused_ws:(map(select(.is_focused))[0].id)}' workspaces.json
--   => {"workspace_count":9,"per_output":{"DP-3":7,"HDMI-A-1":2},"focused_ws":1}
-- jq '{window_count:length, win86_ws:(map(select(.id==86))[0].workspace_id), focused_win:(map(select(.is_focused))[0].id)}' windows.json
--   => {"window_count":18,"win86_ws":1,"focused_win":86}

local function countMap(t)
  local n = 0
  for _ in pairs(t) do
    n += 1
  end
  return n
end

local function snapshotRequestAfterTicking()
  local before = #HARNESS_ASYNC
  for _ = 1, 120 do
    update()
  end
  for i = before + 1, #HARNESS_ASYNC do
    if string.find(HARNESS_ASYNC[i].cmd, "---NTB%-SEP") then
      return HARNESS_ASYNC[i]
    end
  end
  error("snapshot request not issued")
end

local function deliver(req)
  req.cb({
    exitCode = 0,
    stdout = WORKSPACES_JSON .. "\n---NTB-SEP\n" .. WINDOWS_JSON,
    stderr = "",
    timedOut = false,
    stdoutTruncated = false,
    stderrTruncated = false,
  })
end

local function focusedWorkspaceId()
  for _, workspace in pairs(workspacesById) do
    if workspace.isFocused then
      return workspace.id
    end
  end
  return nil
end

local function focusedWindowId()
  for _, window in pairs(windowsById) do
    if window.isFocused then
      return window.id
    end
  end
  return nil
end

local guarded = snapshotRequestAfterTicking()
stateGeneration += 1
deliver(guarded)
assert(countMap(workspacesById) == 0, "generation guard allowed stale snapshot")
assert(countMap(windowsById) == 0, "generation guard allowed stale windows")

local fresh = snapshotRequestAfterTicking()
deliver(fresh)

local dp3 = 0
local hdmi = 0
for _, workspace in pairs(workspacesById) do
  if workspace.output == "DP-3" then
    dp3 += 1
  elseif workspace.output == "HDMI-A-1" then
    hdmi += 1
  end
end

assert(countMap(workspacesById) == 9, "snapshot workspace count mismatch")
assert(dp3 == 7, "snapshot DP-3 count mismatch")
assert(hdmi == 2, "snapshot HDMI-A-1 count mismatch")
assert(focusedWorkspaceId() == 1, "snapshot focused workspace mismatch")
assert(countMap(windowsById) == 18, "snapshot window count mismatch")
assert(windowsById[86] ~= nil and windowsById[86].workspaceId == 1, "snapshot window 86 workspace mismatch")
assert(focusedWindowId() == 86, "snapshot focused window mismatch")
