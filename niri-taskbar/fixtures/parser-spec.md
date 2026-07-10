# niri IPC parser spec (empirical)

Derived from dumps captured 2026-07-09 on `niri unstable 2026-07-08
(commit 0777769e)`, two outputs (DP-3, HDMI-A-1). Ground truth is the
fixture files in this directory (window titles sanitized, structure
untouched) — never extend this spec from assumed schema; re-dump after
niri upgrades (`./capture-dumps.sh`).

## Stream

`niri msg --json event-stream` emits one JSON object per line; each object
has exactly ONE key = the event name.

**Initial burst (verified)**: on connect the stream always opens with a
full `WorkspacesChanged` (line 1) then `WindowsChanged` (line 2). The
stream is therefore the single source of truth — no separate snapshot
calls needed at startup.

## Events handled

### WorkspacesChanged — full replace
```json
{"WorkspacesChanged":{"workspaces":[{"id":1,"idx":2,"name":null,
 "output":"DP-3","is_urgent":false,"is_active":true,"is_focused":true,
 "active_window_id":86}, …]}}
```
- `id` global stable id; `idx` 1-based position on its output; `name`
  string or null; `output` connector name.
- `is_active`: the visible workspace on its own output (one true per
  output). `is_focused`: globally focused (at most one true overall).
- `active_window_id`: int or null.
- Replace the whole workspace map.

### WorkspaceActivated — incremental
```json
{"WorkspaceActivated":{"id":11,"focused":true}}
```
Workspace `id` becomes `is_active` on ITS output (look the output up in
current state); every other workspace on the same output becomes
inactive. If `focused` is true it also becomes the globally focused
workspace (clear `is_focused` everywhere else).

### WindowsChanged — full replace (with merge rule)
```json
{"WindowsChanged":{"windows":[{"id":7,"title":"…","app_id":"firefox",
 "pid":1234,"workspace_id":12,"is_focused":false,"is_floating":false,
 "is_urgent":false,"layout":{…},"focus_timestamp":{…}}, …]}}
```
- Keep: `id`, `title`, `app_id`, `workspace_id`, `is_focused`.
- **`workspace_id` may be null** (window mid-move): when null, merge the
  previous state's `workspace_id` for that window id before replacing the
  map — a naive replace silently drops the window from every group.
- `app_id` may be absent → fall back to `class` if present, else `""`
  (defensive; not observed in this dump but matches noctalia's own
  consumer, `niri_workspace_backend.cpp:584-591`).
- Ignore `layout`, `focus_timestamp`, `pid`, `is_floating`.

### WindowOpenedOrChanged — incremental upsert
```json
{"WindowOpenedOrChanged":{"window":{"id":140,"title":"Ghostty",
 "app_id":"com.mitchellh.ghostty","workspace_id":1,"is_focused":true,…}}}
```
Payload nests under `"window"`. Upsert by id; same null-`workspace_id`
merge rule. `is_focused:true` here implies every other window loses focus.

### WindowClosed
```json
{"WindowClosed":{"id":140}}
```
This build emits `{id}`. Accept all three shapes defensively (bare int,
`{id}`, `{window_id}` — noctalia's consumer handles all three,
`niri_workspace_backend.cpp:515-532`). Remove the window; prune its
callback env entry.

### WindowFocusChanged
```json
{"WindowFocusChanged":{"id":22}}
```
Window `id` gains focus, all others lose it. Treat `id:null`/absent as
"nothing focused" (defensive). Not needed for v1 rendering; track the
boolean anyway (cheap, enables the active-window ring later).

## Events ignored (observed in dump, skip silently)

`WindowFocusTimestampChanged`, `WindowLayoutsChanged`,
`WorkspaceActiveWindowChanged`, `OverviewOpenedOrClosed`, `ConfigLoaded`,
`KeyboardLayoutsChanged`, `CastsChanged` — and ANY unrecognized event name
(forward compatibility; never error on unknown keys).

## Snapshots (resync path)

`niri msg --json workspaces` / `--json windows` return bare arrays with
exactly the same item shapes as the corresponding Changed events (verified
against `workspaces.json` / `windows.json`).

## Actions (verified against `niri msg action … --help`)

- Focus window (global, any output): `niri msg action focus-window --id <id>`
- Focus workspace: `focus-workspace <REFERENCE>` where REFERENCE is
  index-or-name, resolved on the FOCUSED monitor. Cross-output therefore
  chains: `niri msg action focus-monitor <output> ; niri msg action
  focus-workspace <idx>` (single `sh -c`). Same-output clicks use the
  plain form.
