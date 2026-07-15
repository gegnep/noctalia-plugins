# Noctalia Patches

Small, additive host patches to [Noctalia](https://noctalia.dev) that this
repo's plugins rely on. All are default-off or new bindings; none change
existing behavior for anyone not opting in.

## Table of Contents

- [Why These Exist](#why-these-exist)
- [Patch List](#patch-list)
- [Upstream Status](#upstream-status)
- [Applying the Patches](#applying-the-patches)
- [Behavior Notes](#behavior-notes)

## Why These Exist

The Noctalia v5 plugin API is still in beta and doesn't yet expose
everything [claude-launcher](../claude-launcher) and
[niri-taskbar](../niri-taskbar) need: chat-style Enter-to-submit,
follow-scroll, a markdown control, per-monitor bar-widget scoping,
clickable/hoverable containers, per-node hover events, and native icon
resolution. These patches add exactly those bindings.

Developed and rebased against upstream `main` (branch `plugin-ui-props`
for 0001-0005; `plugin-hover-prop` for 0008 with
`plugin-clickable-containers` stacking 0009 on top). Two of the original
capabilities have already shipped upstream, and one (0007, button
radius/padding) was rejected in review and replaced by 0009; all three are
documented below but are no longer patch files in this directory.

## Patch List

| Patch | Adds | Plugin |
|---|---|---|
| `0001` input `submitOnEnter` | Opt-in chat-style submit: Enter sends, Shift+Enter inserts a newline, Ctrl+Enter still sends. Default off, so existing behavior is unchanged. | claude-launcher |
| `0002` scroll `stickToBottom` / `onScroll` / `scrollToBottomRev` | Follow-scroll while content grows, an `onScroll(offset, maxOffset)` callback, and an explicit jump-to-bottom trigger. | claude-launcher |
| `0003` `ui.markdown` node | Registers the existing md4c `MarkdownView` control for plugin trees, with a `text` prop cached per slot so streaming re-renders don't re-parse unchanged text. | claude-launcher |
| `0004` stream slot reaping | Bugfix: `runStream` slots (cap 4 per host) were only freed on host teardown, so short-lived streams could exhaust the cap after four runs. | claude-launcher |
| `0005` MarkdownView measure fix | Bugfix: wrap width wasn't applied at measure time, under-allocating height and overlapping sibling rows. | claude-launcher |
| `0008` `onHover` on button/box/image | Pointer enter/leave delivered as an `onHover("true"` or `"false")` callback. Standalone since 2026-07-15 (used to stack on the rejected 0007). | niri-taskbar |
| `0009` `onClick`/`onHover` on row/column | Clickable, hoverable flex containers (the reconciler wraps them in a measure-forwarding InputArea; clickable wrappers are also keyboard-activatable). Replaces 0007: chips are now `ui.row`+`ui.label` pills instead of restyled buttons. Depends on 0008 (same file). | niri-taskbar |

The numbering gaps (0006, 0007 missing) are intentional: 0006 shipped
upstream and 0007 was rejected (see below); keeping the numbers stable
means the remaining files still match their history and branch names.

## Upstream Status

| Patch(es) | PR | Status |
|---|---|---|
| 0001-0005 | [#3327](https://github.com/noctalia-dev/noctalia/pull/3327) | Open, awaiting review. Rebased onto `main` 2026-07-15 (0001/0003 picked up upstream's new `controlSize` allowlist entries); fork branch `plugin-ui-props` needs a force-push before the PR diff matches these files again. |
| 0007 button radius/padding | [#3355](https://github.com/noctalia-dev/noctalia/pull/3355) | **Rejected 2026-07-14** — maintainer: buttons stay cohesive, pills should be built from box/row. Patch file deleted; capability replaced by 0009. |
| 0008 + 0009 | not submitted yet | One PR, two commits, from branch `plugin-clickable-containers` (0008 regenerated standalone off `main`, 0009 stacked on it). Framed as the follow-up to the #3355 review guidance. |
| `barWidget.outputName` (was 0006) | [#3352](https://github.com/noctalia-dev/noctalia/pull/3352) | Merged 2026-07-11. |
| `noctalia.appIconPath` (was 0009) | [#3356](https://github.com/noctalia-dev/noctalia/pull/3356) | Merged 2026-07-11. Review added thread-safety fixes beyond what was submitted: a mutex around `IconResolver`'s shared theme-plan state, and a `shared_ptr` desktop-entry snapshot instead of a per-call copy. |

**Verification target is `main`, not `cachix`.** `main` is what the open PRs
are actually based against. Checking against `cachix` once let a real
conflict slide: an unrelated upstream addition to `meson.build`'s test
sources broke 0003's plain `git apply` context match, but `git rebase`
resolved it as a clean 3-way merge with no manual intervention. The full
sequence (0001-0005, 0008, 0009 — in that order; 0009 needs 0008) was last
verified against `main` (`4bf957f4c`) on 2026-07-15 via `git am --3way` in
a throwaway worktree.

## Applying the Patches

As a nixos flake overlay on the noctalia package:

```nix
(noctalia-pkg.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./noctalia-patches/0001-feat-plugin-ui-add-input-submitOnEnter-prop-for-chat.patch
    ./noctalia-patches/0002-feat-plugin-ui-add-scroll-stickToBottom-onScroll-and.patch
    ./noctalia-patches/0003-feat-plugin-ui-register-markdown-node-type-backed-by.patch
    ./noctalia-patches/0004-fix-plugins-reclaim-stream-slots-when-the-process-ex.patch
    ./noctalia-patches/0005-fix-ui-measure-MarkdownView-with-wrapped-label-sizes.patch
    ./noctalia-patches/0008-feat-plugins-expose-onHover-callback-on-button-box-a.patch
    ./noctalia-patches/0009-feat-plugins-expose-onClick-and-onHover-on-row-and-c.patch
  ];
}))
```

Or directly with git, from a noctalia checkout on `main`:

```sh
git apply /path/to/noctalia-plugins/noctalia-patches/000*.patch
```

## Behavior Notes

- `scrollToBottomRev` applies once on the first reconcile that sees it: a
  freshly created scroll starts at the bottom when the prop is present.
  Later snaps only happen when the value changes.
- The stick-to-bottom `onScroll` fires from layout when the stick moves the
  offset. Plain in-layout clamping (no stick) doesn't fire it, matching the
  pre-existing clamp-path behavior.
- 0009's callback semantics deliberately match the existing box/image
  clickables: removing `onClick`/`onHover` from a retained node does not
  clear the old handler (absent props never clear, reconciler-wide), and a
  container's `onHover` only fires while the container itself is the
  innermost hovered input area — interactive descendants (buttons, clickable
  images) receive enter/leave instead. Clickable wrappers are focusable and
  the Validate keybind fires `onClick`; this also applies to clickable
  box/image now (strictly additive).
