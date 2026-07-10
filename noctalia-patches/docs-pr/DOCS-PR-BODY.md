# docs: document plugin-ui submitOnEnter, scroll follow/observe/jump, and markdown node

## Summary
Companion docs for the plugin-UI additions in
[noctalia-dev/noctalia#3327](https://github.com/noctalia-dev/noctalia/pull/3327).
Updates the `ui.*` control
reference in `v5/plugins/development/declarative-ui.mdx` — the single page
that documents every declarative control and its props — to cover the three
additive, default-off surfaces the PR adds:

- `ui.input` `submitOnEnter` prop: opt-in chat-style submit (Enter submits,
  Shift+Enter inserts a newline, Ctrl+Enter still submits either way).
- `ui.scroll` `stickToBottom` / `onScroll(offset, maxOffset)` /
  `scrollToBottomRev` props: follow-scroll while content grows, scroll
  position observation, and an explicit jump-to-bottom trigger (change the
  numeric value to jump to the current bottom).
- New `ui.markdown` node type with a `text` prop, rendering Markdown via the
  shell's built-in Markdown view; links are underlined but not clickable,
  and unchanged `text` is not re-parsed on later renders.

No new pages or sections — these are additions to the existing prop table
and its surrounding bullet notes, matching the page's existing style (prop
table row + a short bullet for any prop with non-obvious behavior).

## What's documented
- `ui.scroll` table row gains `stickToBottom`, `onScroll`,
  `scrollToBottomRev`.
- `ui.input` table row gains `submitOnEnter`.
- New `ui.markdown` table row with `text`.
- Callbacks bullet notes `onScroll(offset, maxOffset)`'s two-argument shape
  (existing callbacks in this doc are documented as single-value).
- Multiline input bullet extended with `submitOnEnter` semantics.
- New "Follow-scroll" bullet explaining `stickToBottom` / `onScroll` /
  `scrollToBottomRev` together, since they're one coherent feature.
- New "Markdown" bullet explaining what `ui.markdown` renders and its
  caching behavior.

## Not included
0004/0005 in the companion PR are internal bugfixes (`runStream` slot
reaping, `MarkdownView` measure) with no plugin-facing API surface — nothing
to document.

## Related
Companion code PR: noctalia-dev/noctalia#3327

Portions of this documentation were drafted with AI assistance under human
review; the repo has no stated policy on this, so disclosing rather than
assuming (matching the note in the companion code PR).
