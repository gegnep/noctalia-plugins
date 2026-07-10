# noctalia patches — plugin host additions for this monorepo's plugins

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
| 0006 barWidget.outputName | Binds the per-instance output connector name (already carried in every ScriptSnapshot) so a bar widget can scope its content to the monitor it is placed on; nil when unknown. Needed by niri-taskbar's own-output workspace filtering. NOT part of PR #3327 (pushed to `gegnep/noctalia` branch `plugin-output-name` for a future PR); developed on `cachix` @ `3137323`. |
| 0007 button radius/padding | Exposes `radius`/`padding`/`paddingH`/`paddingV` on declarative `button` nodes (Button already inherits Flex's setters; only the allowlist was missing). Lets niri-taskbar render capsule workspace chips with a real active-pill inset. NOT part of PR #3327; branch-per-patch like 0006. |

Upstream status: **submitted —
[noctalia-dev/noctalia#3327](https://github.com/noctalia-dev/noctalia/pull/3327)**,
awaiting review. These patch files match the PR branch exactly (rebased onto
upstream main, clang-formatted per-commit).

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
