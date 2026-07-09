## Summary
Three additive, default-off plugin UI capabilities, plus two bugfixes found
while exercising them from a real plugin:
- input `submitOnEnter` prop: Enter submits, Shift+Enter inserts a newline,
  Ctrl+Enter still submits (existing behavior unchanged when off)
- scroll `stickToBottom` / `onScroll(offset, maxOffset)` / `scrollToBottomRev`
  props for follow-scroll, scroll observation, and an explicit jump-to-bottom
- `ui.markdown` node type registering the existing md4c MarkdownView, with the
  source cached per slot so streaming re-renders only re-parse on change
- fix: `runStream` slots (cap 4/host) were only reclaimed on host teardown, so
  four short-lived streams permanently exhausted the cap; exited processes now
  mark their cancel token and `startStream` sweeps them
- fix: MarkdownView measured labels unwrapped, under-allocating its height and
  overlapping sibling rows when used alongside other children in a flex

## Motivation
Plugin panels that stream content (chat-style UIs) currently can't offer
Enter-to-send composers, can't follow or observe scroll position, and can only
render plain labels. All three are small exposures of capability the codebase
already has. Developed for and exercised by a real plugin (a Claude chat
panel: https://github.com/gegnep/noctalia-plugins); happy to adjust naming or
semantics to fit the project's direction.

## Type of Change
- [x] New feature
- [x] Bug fix

## Related Issue
—

## Testing
- Rebased onto current main; `just format` clean on every commit (applied
  per-commit via `rebase --exec`).
- Full nix build including all test targets; `ui_tree_reconciler_test` links
  the markdown control (its source list gained markdown_view/builders/md4c —
  caught by a real build, not hypothetically).
- Live-tested extensively via the chat panel plugin on Niri: all three
  Enter-key behaviors; follow-scroll during streaming; scroll-up disengages
  the stick and onScroll reports offset/max; scrollToBottomRev snaps back;
  markdown (headings/lists/inline code) streaming without re-parse churn;
  >4 sequential runStream invocations keep working; markdown views mixed with
  sibling rows lay out without overlap.
- Note: `scrollToBottomRev` applies once on the first reconcile that sees it
  (a fresh scroll starts at the bottom when the prop is present).

## Manual Coverage
- [x] Tested on Niri

## Screenshots / Videos
(attach: markdown-rendered answer, follow-scroll mid-stream, jump affordance)

## Checklist
- [x] This PR is ready for review, or it is marked as Draft.
- [x] I read and followed the relevant guidance in `CONTRIBUTING.md`.
- [x] I ran `just format` with clang-format v22+ installed.
- [x] I ran the relevant build or test commands.
- [x] I self-reviewed the changes.
- [x] I checked for new warnings or errors.
- [x] I will update end-user documentation after merge (plugin-prop docs live
      on the external docs site; nothing in-repo to update).
- [x] I added or updated `assets/translations/en.json`, or this PR adds no
      new user-facing strings. (No new strings.)
- [x] I did not edit non-English translation files.
- [x] I used the existing canonical names for config keys, IPC names, paths,
      and identifiers.

## Additional Notes
Two pieces of plugin-API feedback from building against it, offered for the
docs or as follow-ups rather than included here:
1. Retained nodes keep props the new tree doesn't specify, and unkeyed
   siblings re-match by (type, order). Five separate plugin bugs during
   development traced to this one semantic; a paragraph in the declarative-ui
   docs (or a reconciler-side reset of unspecified common props) would save
   plugin authors the same tour.
2. Manifest select options with an empty `value` are silently dropped
   (`plugin_manifest.cpp`), and `noctalia plugins lint` doesn't flag the
   now-unselectable declared default — a lint warning candidate.

Portions of these patches were implemented with AI assistance under human
review and testing; the repo has no stated policy on this, so disclosing
rather than assuming.
