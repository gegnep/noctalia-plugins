# docs-pr notes

Base of `noctalia-docs` these patches apply to: `d3ceb1639eab6c614bd7382325e0da6ba97cf308`
(`main`, shallow clone taken 2026-07-09). Branch in the session-side clone:
`plugin-ui-props-docs`.

## Files touched
- `src/content/docs/v5/plugins/development/declarative-ui.mdx` — the only
  file touched. It's the single reference page for the shared `ui.*`
  declarative control vocabulary (used by desktop widgets, bar widgets, and
  panels alike), and already documents every other control's props plus
  behavior notes as bullets below the table. All three new surfaces
  (`submitOnEnter`, scroll follow/observe/jump, `ui.markdown`) are additions
  to that existing pattern — no new page or section needed.

Searched for other places that might duplicate this control/prop reference
(`runtime-api.mdx`, `manifest.mdx`, `panel.mdx`, the v4 legacy plugin docs)
and found no overlap — `declarative-ui.mdx` is the only page listing `ui.*`
props.

## Traceability
Every prop/behavior documented is traced directly to the three code patches
in `noctalia-patches/` (0001 input submitOnEnter, 0002 scroll stickToBottom/
onScroll/scrollToBottomRev, 0003 ui.markdown), not assumed:
- `submitOnEnter` Enter/Shift+Enter/Ctrl+Enter behavior — from `input.cpp`'s
  `handleKey` diff in 0001.
- `onScroll(offset, maxOffset)` two-argument shape — verified against
  `ScriptRuntime::enqueueCallStrings` / `callGlobalWithStringsAndBudget` in
  `../noctalia/src/scripting/script_runtime.cpp` (cloned session-side,
  `cachix` branch), which always calls the Luau global with exactly two
  string args (`arg1`/`arg2` from `UiTreeReconciler::ControlCallback`); 0002
  sets `arg1` = offset, `arg2` = maxScrollOffset.
- `scrollToBottomRev` is documented only as "jumps to the current bottom
  when the value changes". An earlier draft also claimed it snaps on first
  render; review (gpt-5.5) flagged that as not guaranteed by the 0002 diff —
  scroll props apply before children reconcile, so a first-render snap may
  target a stale maxScrollOffset — and the claim was dropped.
- `ui.markdown` behavior (links underlined not clickable, re-parse-on-change
  caching, `text`-only prop) — directly from 0003's reconciler diff and
  `README.md`/`PR-BODY.md` in `noctalia-patches/`.

## Uncertainties / judgment calls
- Whether `ui.markdown` is usable in bar widgets (the existing doc notes bar
  widgets skip `ui.input`/`ui.select`/`ui.scroll` "with a warning" — no
  keyboard). The companion patches don't touch bar-specific gating logic,
  and a source grep for that skip list came up empty (couldn't locate the
  bar-context check in the reconciler in the time available), so I did not
  add or remove `ui.markdown` from that constraints list — left the
  bar-specific-constraints section untouched rather than guess.
- Split into a single doc commit rather than three (one per prop/node): the
  edits interleave within one paragraph and one table in the same file, so
  three clean non-overlapping commits weren't cleanly separable without
  awkward hunk-splitting. Squashed into one commit describing all three,
  consistent with "one or a few clean commits."
- No screenshots/examples added beyond the existing prose style — the page's
  existing convention for props like these (e.g. `focus`, controlled vs.
  uncontrolled inputs) is a bullet explanation, not a runnable code sample,
  so followed that instead of adding a new Lua snippet.
