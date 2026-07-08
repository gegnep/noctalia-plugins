# noctalia patches — plugin UI props for claude-launcher

Three additive patches to noctalia (developed on `main` @ `099312d`, branch
`plugin-ui-props` in the local clone; verified to apply in sequence to the
`cachix` branch that nix builds consume). All default-off / purely additive —
native noctalia surfaces are unaffected.

| Patch | What it adds |
|---|---|
| 0001 input submitOnEnter | Opt-in chat-style submit for multiline inputs: Enter submits, Shift+Enter inserts a newline, Ctrl+Enter still submits. Default off → existing behavior unchanged. |
| 0002 scroll stickToBottom / onScroll / scrollToBottomRev | Follow-scroll while content grows (stops when the user scrolls up), an `onScroll(offset, maxOffset)` plugin callback, and a rev-counter prop that snaps to the bottom when its value changes. |
| 0003 markdown node type | Registers the existing md4c `MarkdownView` control as `ui.markdown` with a `text` prop; source cached per slot so streaming re-renders only re-parse on change. Links render underlined but are not clickable (no click API in the control). |
| 0004 stream slot reaping | Bugfix: `runStream` slots (cap 4 per host) were only released on host teardown — a plugin running short-lived streaming commands hit the cap after four runs and every later `runStream` returned false. Exited processes now mark their cancel token and the next `startStream` sweeps them. |
| 0005 MarkdownView measure fix | Bugfix: the control only applied its wrap width to labels in `doLayout`, so measure reported single-line sizes and parent flexes under-allocated its height — sibling rows overlapped it (visible as garbled stacked text). Wrap width now also applied from measure constraints. |

Upstream status: **local only — pending user review** (code + commit
messages), then push + PR per `.github/PULL_REQUEST_TEMPLATE.md`.

Consuming in a nixos flake (overlay on the noctalia package):

```nix
# wherever the noctalia package is taken from its flake input:
(noctalia-pkg.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./noctalia-patches/0001-feat-plugin-ui-add-input-submitOnEnter-prop-for-chat.patch
    ./noctalia-patches/0002-feat-plugin-ui-add-scroll-stickToBottom-onScroll-and.patch
    ./noctalia-patches/0003-feat-plugin-ui-register-markdown-node-type-backed-by.patch
  ];
}))
```

Behavior notes (also for the PR body):
- `scrollToBottomRev` applies once on the first reconcile that sees it —
  i.e. a freshly created scroll starts at the bottom when the prop is
  present. Subsequent snaps happen only when the value changes.
- The stick-to-bottom `onScroll` fires from layout when the stick moves the
  offset; plain in-layout clamping (no stick) does not fire it, matching the
  pre-existing behavior of the clamp path.
