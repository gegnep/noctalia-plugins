# noctalia patches — plugin host additions for this monorepo's plugins

Nine additive patches to noctalia (developed on `main`, branch
`plugin-ui-props` in the local clone; verified to apply in sequence to the
`cachix` branch that nix builds consume): 0001–0005 back claude-launcher's
streaming chat UI, 0006–0009 back niri-taskbar's workspace/window widget.
All default-off / purely additive — native noctalia surfaces are unaffected.

| Patch | What it adds |
|---|---|
| 0001 input submitOnEnter | Opt-in chat-style submit for multiline inputs: Enter submits, Shift+Enter inserts a newline, Ctrl+Enter still submits. Default off → existing behavior unchanged. |
| 0002 scroll stickToBottom / onScroll / scrollToBottomRev | Follow-scroll while content grows (stops when the user scrolls up), an `onScroll(offset, maxOffset)` plugin callback, and a rev-counter prop that snaps to the bottom when its value changes. |
| 0003 markdown node type | Registers the existing md4c `MarkdownView` control as `ui.markdown` with a `text` prop; source cached per slot so streaming re-renders only re-parse on change. Links render underlined but are not clickable (no click API in the control). |
| 0004 stream slot reaping | Bugfix: `runStream` slots (cap 4 per host) were only released on host teardown — a plugin running short-lived streaming commands hit the cap after four runs and every later `runStream` returned false. Exited processes now mark their cancel token and the next `startStream` sweeps them. |
| 0005 MarkdownView measure fix | Bugfix: the control only applied its wrap width to labels in `doLayout`, so measure reported single-line sizes and parent flexes under-allocated its height — sibling rows overlapped it (visible as garbled stacked text). Wrap width now also applied from measure constraints. |
| 0006 barWidget.outputName | Binds the per-instance output connector name (already carried in every ScriptSnapshot) so a bar widget can scope its content to the monitor it is placed on; nil when unknown. Needed by niri-taskbar's own-output workspace filtering. Upstream: [noctalia-dev/noctalia#3352](https://github.com/noctalia-dev/noctalia/pull/3352) (branch `plugin-output-name`). |
| 0007 button radius/padding | Exposes `radius`/`padding`/`paddingH`/`paddingV` on declarative `button` nodes (Button already inherits Flex's setters; only the allowlist was missing). Lets a plugin shape button chrome directly — niri-taskbar uses `radius`/`height` to render circle/oval workspace chips. Upstream: [noctalia-dev/noctalia#3355](https://github.com/noctalia-dev/noctalia/pull/3355) (branch `plugin-button-shape`). |
| 0008 onHover on button/box/image | Delivers pointer enter/leave to plugin UI trees as an `onHover` callback with a `"true"`/`"false"` arg (toggle onChange convention). Buttons reuse their enter/leave hooks; box/image reuse the click wrapper (empty button mask when hover-only, so clicks pass through to ancestors). Enables niri-taskbar's per-workspace hover expansion. Depends on 0007 textually (same file) — apply in order. |
| 0009 noctalia.appIconPath | Binding that resolves an app id (or raw icon name) to an icon file path with the native taskbar's own machinery: `app_identity::findDesktopEntry` over a new mutex-guarded desktop-entry snapshot accessor + a thread_local `IconResolver`. Gives plugins the exact icons noctalia itself shows. Independent of 0007/0008 (different files). Upstream: [noctalia-dev/noctalia#3356](https://github.com/noctalia-dev/noctalia/pull/3356) (branch `plugin-app-icon`). |

Upstream status:

- 0001–0005 (claude-launcher's UI needs): submitted as
  [noctalia-dev/noctalia#3327](https://github.com/noctalia-dev/noctalia/pull/3327),
  awaiting review. These patch files match the PR branch exactly (rebased
  onto upstream main, clang-formatted per-commit).
- 0006 (`barWidget.outputName`): submitted as
  [noctalia-dev/noctalia#3352](https://github.com/noctalia-dev/noctalia/pull/3352).
- 0007 (button radius/padding): submitted as
  [noctalia-dev/noctalia#3355](https://github.com/noctalia-dev/noctalia/pull/3355).
- 0009 (`noctalia.appIconPath`): submitted as
  [noctalia-dev/noctalia#3356](https://github.com/noctalia-dev/noctalia/pull/3356).
- 0008 (per-node `onHover`): no PR yet — it stacks on 0007 (same file, must
  apply after it), and will go up once #3355 merges.

Consuming in a nixos flake (overlay on the noctalia package):

```nix
# wherever the noctalia package is taken from its flake input:
(noctalia-pkg.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./noctalia-patches/0001-feat-plugin-ui-add-input-submitOnEnter-prop-for-chat.patch
    ./noctalia-patches/0002-feat-plugin-ui-add-scroll-stickToBottom-onScroll-and.patch
    ./noctalia-patches/0003-feat-plugin-ui-register-markdown-node-type-backed-by.patch
    ./noctalia-patches/0004-fix-plugins-reclaim-stream-slots-when-the-process-ex.patch
    ./noctalia-patches/0005-fix-ui-measure-MarkdownView-with-wrapped-label-sizes.patch
    ./noctalia-patches/0006-feat-plugins-expose-barWidget.outputName-to-bar-widg.patch
    ./noctalia-patches/0007-feat-plugins-expose-radius-and-padding-on-button-nod.patch
    ./noctalia-patches/0008-feat-plugins-expose-onHover-callback-on-button-box-a.patch
    ./noctalia-patches/0009-feat-plugins-add-noctalia.appIconPath-icon-resolutio.patch
  ];
}))
```

Behavior notes for 0001–0005 (also used in the #3327 PR body):
- `scrollToBottomRev` applies once on the first reconcile that sees it —
  i.e. a freshly created scroll starts at the bottom when the prop is
  present. Subsequent snaps happen only when the value changes.
- The stick-to-bottom `onScroll` fires from layout when the stick moves the
  offset; plain in-layout clamping (no stick) does not fire it, matching the
  pre-existing behavior of the clamp path.
