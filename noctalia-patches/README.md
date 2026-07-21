# Noctalia Patches

Small host patches to [Noctalia](https://noctalia.dev) that this repo's
plugins rely on. Five add default-off props or new bindings; 0009 also
extends existing box and image clickables with keyboard activation. One
(0005) fixes a MarkdownView measurement bug in the host.

## Table of Contents

- [Purpose](#purpose)
- [Patch List](#patch-list)
- [Upstream Status](#upstream-status)
- [Patch Application](#patch-application)
- [Behavior Notes](#behavior-notes)

## Purpose

The Noctalia v5 plugin API is still in beta. It didn't expose everything
[claude-launcher](../claude-launcher) and [niri-taskbar](../niri-taskbar)
need: chat-style Enter-to-submit, follow-scroll, a markdown control,
per-monitor bar-widget scoping, clickable and hoverable containers,
per-node hover events, and native icon resolution. Two of those gaps
(bar-widget scoping, icon resolution) have since shipped upstream. The
remaining patches add the rest.

All patch branches track upstream `main`. Branch
`plugin-ui-props` covers 0001-0003 and 0005. Branch `plugin-hover-prop`
covers 0008, with `plugin-clickable-containers` stacking 0009 on top.

Three of the original capabilities have already shipped upstream. One,
0007 (button radius/padding), was rejected in review and replaced by 0009.
All four are documented below, but none are patch files in this directory
anymore.

## Patch List

| Patch | Adds | Plugin |
|---|---|---|
| `0001` input `submitOnEnter` | Opt-in chat-style submit: Enter sends, Shift+Enter inserts a newline, Ctrl+Enter still sends. Default off, so existing behavior is unchanged. | claude-launcher |
| `0002` scroll `stickToBottom` / `onScroll` / `scrollToBottomRev` | Follow-scroll while content grows, an `onScroll(offset, maxOffset)` callback, and an explicit jump-to-bottom trigger. | claude-launcher |
| `0003` `ui.markdown` node | Registers the existing md4c `MarkdownView` control for plugin trees. Caches the `text` prop per slot, so streaming re-renders don't re-parse unchanged text. | claude-launcher |
| `0005` MarkdownView measure fix | Bugfix: measure skipped the wrap width, under-allocating height and overlapping sibling rows. | claude-launcher |
| `0008` `onHover` on button/box/image | Delivers pointer enter/leave as an `onHover("true")` or `onHover("false")` callback. Standalone since 2026-07-15; it used to stack on the rejected 0007. | niri-taskbar |
| `0009` `onClick`/`onHover` on row/column | Adds clickable, hoverable flex containers. The reconciler wraps them in a measure-forwarding InputArea; clickable wrappers are also keyboard-activatable. Replaces 0007: chips are now `ui.row`+`ui.label` pills instead of restyled buttons. Depends on 0008; both patch `src/ui/ui_tree_reconciler.cpp`. | niri-taskbar |

The numbering gaps (0004, 0006, 0007 missing) are intentional. 0004 and
0006 shipped upstream; 0007 was rejected (see below). Keeping the numbers
stable keeps the remaining files matched to their history and branch
names. The local sequence is 0001, 0002, 0003, 0005, 0008, 0009, applied
in that order.

## Upstream Status

This table records the status as tracked in this repository. Verify live
GitHub status before rebasing or submitting a patch.

| Patch(es) | PR | Status |
|---|---|---|
| 0001-0003, 0005 | [#3327](https://github.com/noctalia-dev/noctalia/pull/3327) | Open, awaiting review. Rebased onto `main` twice on 2026-07-20: first over the drag_source/drop_zone merge, where 0002's kScroll allowlist hunk conflicted, then over `3065b0567`, which obsoleted 0004. The branch is now four commits. It needs a `--force-with-lease` push before the PR diff matches these files again. |
| 0004 stream slot reaping | N/A | **Shipped upstream independently on 2026-07-20.** Commit `3065b0567` closes upstream [#3517](https://github.com/noctalia-dev/noctalia/issues/3517) and frees dead slots lazily at `startStream`, via an `alive` flag set by `onExit`. This is functionally equivalent for the plugins. Patch file deleted; commit dropped from #3327. |
| 0007 button radius/padding | [#3355](https://github.com/noctalia-dev/noctalia/pull/3355) | **Rejected on 2026-07-14.** Maintainer feedback: buttons should stay cohesive; pills should be built from box/row. Patch file deleted; capability replaced by 0009. |
| 0008 + 0009 | [#3470](https://github.com/noctalia-dev/noctalia/pull/3470) | Open since 2026-07-15, awaiting review. One PR, two commits, from branch `plugin-clickable-containers`: 0008 regenerated standalone off `main`, 0009 stacked on top. Rebased onto `main` on 2026-07-20, where 0009's childContainer and flex-apply regions conflicted with drag_source/drop_zone. Drag types stay unwrapped; `controlFromSlot<Flex>` now serves all four flex types. Needs the same `--force-with-lease` push. |
| `barWidget.outputName` (was 0006) | [#3352](https://github.com/noctalia-dev/noctalia/pull/3352) | Merged on 2026-07-11. |
| `noctalia.appIconPath` (was 0009) | [#3356](https://github.com/noctalia-dev/noctalia/pull/3356) | Merged on 2026-07-11. Review added thread-safety fixes beyond what was submitted: a mutex around `IconResolver`'s shared theme-plan state, and a `shared_ptr` desktop-entry snapshot instead of a per-call copy. |

**Verification target is `main`, not `cachix`.** `main` is what the open
PRs are actually based against. Checking against `cachix` once let a real
conflict slide. An unrelated upstream addition to `meson.build`'s test
sources broke 0003's plain `git apply` context match. `git rebase`
resolved it as a clean 3-way merge, with no manual work. The full sequence
(0001-0003, 0005, 0008, 0009, in that order; 0009 needs 0008) was last
verified against `main` at `32c608f7d` on 2026-07-20. Verification used
GNU `patch -p1` in filename order, mirroring the nix patchPhase, in a
throwaway worktree.

## Patch Application

Add the patches to the Noctalia package in a NixOS flake:

```nix
(noctalia-pkg.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./noctalia-patches/0001-feat-plugin-ui-add-input-submitOnEnter-prop-for-chat.patch
    ./noctalia-patches/0002-feat-plugin-ui-add-scroll-stickToBottom-onScroll-and.patch
    ./noctalia-patches/0003-feat-plugin-ui-register-markdown-node-type-backed-by.patch
    ./noctalia-patches/0005-fix-ui-measure-MarkdownView-with-wrapped-label-sizes.patch
    ./noctalia-patches/0008-feat-plugins-expose-onHover-callback-on-button-box-a.patch
    ./noctalia-patches/0009-feat-plugins-expose-onClick-and-onHover-on-row-and-c.patch
  ];
}))
```

Or apply them with git. From a Noctalia checkout on `main`, run:

```sh
git apply /path/to/noctalia-plugins/noctalia-patches/000*.patch
```

## Behavior Notes

- `scrollToBottomRev` applies once, on the first reconcile that sees it: a
  freshly created scroll starts at the bottom when the prop is present.
  Later snaps only happen when the value changes.
- The stick-to-bottom `onScroll` fires from layout when the stick moves the
  offset. Plain in-layout clamping (no stick) doesn't fire it, matching the
  pre-existing clamp-path behavior.
- 0009's wrapper handlers deliberately deviate from the reconciler's
  retain-absent-props default. An empty callback name counts as unset.
  When one callback disappears while the other keeps the wrapper alive,
  the wrapper drops the stale handler, its button mask, and its
  focusability. A retained handler would leave an invisible node that
  swallows clicks and sits in tab order as a keyboard-activatable ghost.
- A container's `onHover` fires only while the container itself is the
  innermost hovered input area. Interactive descendants (buttons,
  clickable images) receive enter/leave instead of the container.
- Clickable wrappers are focusable, and the Validate keybind fires
  `onClick`. Box and image clickables share this activation behavior since
  0009; they now use the same wrapper path.
