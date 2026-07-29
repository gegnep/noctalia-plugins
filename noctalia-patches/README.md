# Noctalia Patches

Small host patches to [Noctalia](https://noctalia.dev) that
[claude-launcher](../claude-launcher) relies on. Three add default-off
props or new bindings. One (0005) fixes a MarkdownView measurement bug in
the host. One (0006) declares plugin API 20 for the new surface.
niri-taskbar no longer needs any patch: its capabilities merged
upstream on 2026-07-21 ([#3470](https://github.com/noctalia-dev/noctalia/pull/3470)).

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
per-node hover events, and native icon resolution. Most of those gaps have
since shipped upstream. The remaining patches add the rest.

All patch branches track upstream `main`. Branch `plugin-ui-props` covers
0001-0003, 0005 and 0006, the whole remaining set.

Five of the original capabilities have already shipped upstream, most
recently 0008 and 0009 (merged 2026-07-21 as #3470). One, 0007 (button
radius/padding), was rejected in review and replaced by 0009. All are
documented below, but none are patch files in this directory anymore.

## Patch List

| Patch | Adds | Plugin |
|---|---|---|
| `0001` input `submitOnEnter` | Opt-in chat-style submit: Enter sends, Shift+Enter inserts a newline, Ctrl+Enter still sends. Default off, so existing behavior is unchanged. | claude-launcher |
| `0002` scroll `stickToBottom` / `onScroll` / `scrollToBottomRev` | Follow-scroll while content grows, an `onScroll(offset, maxOffset)` callback, and an explicit jump-to-bottom trigger. The jump is deferred: `ScrollView` consumes a pending flag in its own `doLayout`, after the new scroll extent exists (PR review fix, 2026-07-29). | claude-launcher |
| `0003` `ui.markdown` node | Registers the existing md4c `MarkdownView` control for plugin trees. Caches the `text` prop per slot keyed on (text, scale), so streaming re-renders don't re-parse unchanged text and a surface rescale re-renders it (PR review fix, 2026-07-29). | claude-launcher |
| `0005` MarkdownView measure fix | Bugfix: measure skipped the wrap width, under-allocating height and overlapping sibling rows. | claude-launcher |
| `0006` plugin API 20 | Declares `kPluginUiPropsPluginApiVersion = 20` and retargets `kCurrentPluginApiVersion`, so plugins that need this surface can declare `plugin_api = 20` (PR review fix, 2026-07-29). | claude-launcher |

The numbering gap (0004 missing) is intentional. 0004 shipped upstream,
as did the former 0006 (outputName, merged; the number is reused for the
API 20 patch), 0008, and 0009; 0007 was rejected (see below). Keeping the
numbers stable keeps the remaining files matched to their history and
branch names. The local sequence is 0001, 0002, 0003, 0005, 0006,
applied in that order.

## Upstream Status

This table records the status as tracked in this repository. Verify live
GitHub status before rebasing or submitting a patch.

| Patch(es) | PR | Status |
|---|---|---|
| 0001-0003, 0005, 0006 | [#3327](https://github.com/noctalia-dev/noctalia/pull/3327) | Open. First review (ItsLemmy, 2026-07-29) requested three fixes, all addressed on 2026-07-29: 0002's `scrollToBottomRev` now defers the jump to `ScrollView::doLayout` via a pending flag (the old pre-layout `setScrollOffset` clamped against the stale extent); 0003's parse cache keys on (text, scale) with the scale check hoisted outside the text-presence gate; new 0006 introduces plugin API 20. Rebased onto `main` `624363e30` the same day, conflict-free. The branch needs a `--force-with-lease` push before the PR diff matches these files again. |
| 0004 stream slot reaping | N/A | **Shipped upstream independently on 2026-07-20.** Commit `3065b0567` closes upstream [#3517](https://github.com/noctalia-dev/noctalia/issues/3517) and frees dead slots lazily at `startStream`, via an `alive` flag set by `onExit`. This is functionally equivalent for the plugins. Patch file deleted; commit dropped from #3327. |
| 0007 button radius/padding | [#3355](https://github.com/noctalia-dev/noctalia/pull/3355) | **Rejected on 2026-07-14.** Maintainer feedback: buttons should stay cohesive; pills should be built from box/row. Patch file deleted; capability replaced by 0009. |
| 0008 + 0009 | [#3470](https://github.com/noctalia-dev/noctalia/pull/3470) | **Merged on 2026-07-21** (squash `f7ff72f31`). Review changed the submission: the triplicated wrapper onClick/onHover wiring was deduplicated into one `syncWrapperCallbacks`, and hover got balance bookkeeping — the reconciler now closes an open hover itself (fires `"false"`) when the hovered node is dropped, rewired, or reset, and buttons clear stale hover handlers on removal. A same-day follow-up (`0898220c4`) tracks hover by node instead of callback name and passes the node's `key` to `onHover` as a second argument, so one handler can serve a whole keyed list. Patch files deleted. |
| `barWidget.outputName` (was 0006) | [#3352](https://github.com/noctalia-dev/noctalia/pull/3352) | Merged on 2026-07-11. |
| `noctalia.appIconPath` (was 0009) | [#3356](https://github.com/noctalia-dev/noctalia/pull/3356) | Merged on 2026-07-11. Review added thread-safety fixes beyond what was submitted: a mutex around `IconResolver`'s shared theme-plan state, and a `shared_ptr` desktop-entry snapshot instead of a per-call copy. |

**Verification target is `main`, not `cachix`.** `main` is what the open
PRs are actually based against. Checking against `cachix` once let a real
conflict slide. An unrelated upstream addition to `meson.build`'s test
sources broke 0003's plain `git apply` context match. `git rebase`
resolved it as a clean 3-way merge, with no manual work. The full sequence
(0001-0003, 0005, 0006, in that order) was last verified on 2026-07-29
against `main` at `624363e30`. Verification used GNU `patch -p1 --fuzz=0`
in filename order, mirroring the nix patchPhase, in a throwaway worktree;
the result matched the rebased branch tree byte for byte.

## Patch Application

Add the patches to the Noctalia package in a NixOS flake:

```nix
(noctalia-pkg.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./noctalia-patches/0001-feat-plugin-ui-add-input-submitOnEnter-prop-for-chat.patch
    ./noctalia-patches/0002-feat-plugin-ui-add-scroll-stickToBottom-onScroll-and.patch
    ./noctalia-patches/0003-feat-plugin-ui-register-markdown-node-type-backed-by.patch
    ./noctalia-patches/0005-fix-ui-measure-MarkdownView-with-wrapped-label-sizes.patch
    ./noctalia-patches/0006-feat-plugins-introduce-plugin-API-20-for-new-ui-surf.patch
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
  Later snaps only happen when the value changes. The jump lands in the
  next layout pass, after the new scroll extent is computed, and cancels
  an in-flight fling so the animation cannot yank the view back.
- The stick-to-bottom `onScroll` fires from layout when the stick moves the
  offset. Plain in-layout clamping (no stick) doesn't fire it, matching the
  pre-existing clamp-path behavior.

Behavior notes for the merged 0008/0009 capabilities (container
`onClick`/`onHover`, keyboard activation, hover balance) now live in
upstream Noctalia itself; see the #3470 discussion and
`src/ui/ui_tree_reconciler.cpp`.
