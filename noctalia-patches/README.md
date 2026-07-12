# noctalia patches — plugin host additions for this monorepo's plugins

Seven additive patches to noctalia (developed on and rebased onto upstream
`main`, branch `plugin-ui-props` — with `plugin-button-shape` and
`plugin-hover-prop` stacked for 0007/0008 — in the local clone; last
rebased and verified 2026-07-11): 0001–0005 back claude-launcher's
streaming chat UI, 0007–0008 back niri-taskbar's workspace/window widget.
All default-off / purely additive — native noctalia surfaces are unaffected.

Verification target is `main`, not `cachix` — `main` is what the open PRs
are actually based against, and checking against `cachix` once let a real
conflict slide (an unrelated upstream addition to `meson.build`'s test
sources broke 0003's `git apply` context; `git rebase` resolved it as a
clean 3-way merge with no manual intervention). `cachix` and `main`
happen to point at the same commit as of this rebase, but that's
incidental — don't rely on it going forward.

Patches 0006 (`barWidget.outputName`) and 0009 (`noctalia.appIconPath`) have
since merged upstream —
[noctalia-dev/noctalia#3352](https://github.com/noctalia-dev/noctalia/pull/3352)
and
[noctalia-dev/noctalia#3356](https://github.com/noctalia-dev/noctalia/pull/3356),
2026-07-11 — and are no longer carried here. The `cachix` branch this repo's
nix consumption targets already contains both (verified: its HEAD *is* the
#3356 merge commit, with #3352 as an ancestor), so niri-taskbar just needs a
build no older than that. The gap in the numbering below (0006, 0009
missing) is intentional, kept so the remaining files still match their PR
branch names.

| Patch | What it adds |
|---|---|
| 0001 input submitOnEnter | Opt-in chat-style submit for multiline inputs: Enter submits, Shift+Enter inserts a newline, Ctrl+Enter still submits. Default off → existing behavior unchanged. |
| 0002 scroll stickToBottom / onScroll / scrollToBottomRev | Follow-scroll while content grows (stops when the user scrolls up), an `onScroll(offset, maxOffset)` plugin callback, and a rev-counter prop that snaps to the bottom when its value changes. |
| 0003 markdown node type | Registers the existing md4c `MarkdownView` control as `ui.markdown` with a `text` prop; source cached per slot so streaming re-renders only re-parse on change. Links render underlined but are not clickable (no click API in the control). |
| 0004 stream slot reaping | Bugfix: `runStream` slots (cap 4 per host) were only released on host teardown — a plugin running short-lived streaming commands hit the cap after four runs and every later `runStream` returned false. Exited processes now mark their cancel token and the next `startStream` sweeps them. |
| 0005 MarkdownView measure fix | Bugfix: the control only applied its wrap width to labels in `doLayout`, so measure reported single-line sizes and parent flexes under-allocated its height — sibling rows overlapped it (visible as garbled stacked text). Wrap width now also applied from measure constraints. |
| 0007 button radius/padding | Exposes `radius`/`padding`/`paddingH`/`paddingV` on declarative `button` nodes (Button already inherits Flex's setters; only the allowlist was missing). Lets a plugin shape button chrome directly — niri-taskbar uses `radius`/`height` to render circle/oval workspace chips. Upstream: [noctalia-dev/noctalia#3355](https://github.com/noctalia-dev/noctalia/pull/3355) (branch `plugin-button-shape`). |
| 0008 onHover on button/box/image | Delivers pointer enter/leave to plugin UI trees as an `onHover` callback with a `"true"`/`"false"` arg (toggle onChange convention). Buttons reuse their enter/leave hooks; box/image reuse the click wrapper (empty button mask when hover-only, so clicks pass through to ancestors). Enables niri-taskbar's per-workspace hover expansion. Depends on 0007 textually (same file) — apply in order. |

Upstream status:

- 0001–0005 (claude-launcher's UI needs): submitted as
  [noctalia-dev/noctalia#3327](https://github.com/noctalia-dev/noctalia/pull/3327),
  awaiting review. Rebased onto upstream `main` and re-verified 2026-07-11
  (clang-format v22 clean, no diff); the branch `plugin-ui-props` on the
  fork hasn't been force-pushed with this rebase yet — do that before
  relying on the PR diff matching these files.
- 0007 (button radius/padding): submitted as
  [noctalia-dev/noctalia#3355](https://github.com/noctalia-dev/noctalia/pull/3355),
  awaiting review. Same rebase/re-verify as above; `plugin-button-shape`
  also needs a force-push.
- 0008 (per-node `onHover`): no PR yet — it stacks on 0007 (same file, must
  apply after it), and will go up once #3355 merges. `plugin-hover-prop`
  was rebased onto the new `plugin-button-shape` tip in the same pass.
- `barWidget.outputName` (was 0006) and `noctalia.appIconPath` (was 0009):
  merged —
  [noctalia-dev/noctalia#3352](https://github.com/noctalia-dev/noctalia/pull/3352)
  and
  [noctalia-dev/noctalia#3356](https://github.com/noctalia-dev/noctalia/pull/3356).
  Note the merged `appIconPath` differs from what we submitted: review added
  a mutex around `IconResolver`'s shared theme-plan state (our thread_local
  resolver-per-worker still read/wrote that state unguarded — a latent
  race) and switched the desktop-entry snapshot from a per-call vector copy
  to a shared `shared_ptr`, plus an eager cache-prime in
  `DesktopEntryPollSource` so worker threads never see the cache empty on
  first read.

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
    ./noctalia-patches/0007-feat-plugins-expose-radius-and-padding-on-button-nod.patch
    ./noctalia-patches/0008-feat-plugins-expose-onHover-callback-on-button-box-a.patch
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
