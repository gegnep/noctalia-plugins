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
follow-scroll, a markdown control, per-monitor bar-widget scoping, capsule
button styling, per-node hover events, and native icon resolution. These
patches add exactly those bindings.

Developed and rebased against upstream `main` (branch `plugin-ui-props`,
with `plugin-button-shape` and `plugin-hover-prop` stacked for 0007/0008).
Two of the original nine capabilities have already shipped upstream; they
are documented below but are no longer patch files in this directory.

## Patch List

| Patch | Adds | Plugin |
|---|---|---|
| `0001` input `submitOnEnter` | Opt-in chat-style submit: Enter sends, Shift+Enter inserts a newline, Ctrl+Enter still sends. Default off, so existing behavior is unchanged. | claude-launcher |
| `0002` scroll `stickToBottom` / `onScroll` / `scrollToBottomRev` | Follow-scroll while content grows, an `onScroll(offset, maxOffset)` callback, and an explicit jump-to-bottom trigger. | claude-launcher |
| `0003` `ui.markdown` node | Registers the existing md4c `MarkdownView` control for plugin trees, with a `text` prop cached per slot so streaming re-renders don't re-parse unchanged text. | claude-launcher |
| `0004` stream slot reaping | Bugfix: `runStream` slots (cap 4 per host) were only freed on host teardown, so short-lived streams could exhaust the cap after four runs. | claude-launcher |
| `0005` MarkdownView measure fix | Bugfix: wrap width wasn't applied at measure time, under-allocating height and overlapping sibling rows. | claude-launcher |
| `0007` button radius/padding | Exposes `radius`, `padding`, `paddingH`, and `paddingV` on declarative `button` nodes. | niri-taskbar |
| `0008` `onHover` on button/box/image | Pointer enter/leave delivered as an `onHover("true"` or `"false")` callback. Depends on 0007 (same file). | niri-taskbar |

The numbering gap (0006, 0009 missing) is intentional; it's kept so the
remaining files still match their PR branch names.

## Upstream Status

| Patch(es) | PR | Status |
|---|---|---|
| 0001-0005 | [#3327](https://github.com/noctalia-dev/noctalia/pull/3327) | Open, awaiting review. Rebased onto `main` 2026-07-11. |
| 0007 | [#3355](https://github.com/noctalia-dev/noctalia/pull/3355) | Open, awaiting review. Rebased onto `main` 2026-07-11. |
| 0008 | not submitted yet | Stacks on 0007; opens once #3355 merges. |
| `barWidget.outputName` (was 0006) | [#3352](https://github.com/noctalia-dev/noctalia/pull/3352) | Merged 2026-07-11. |
| `noctalia.appIconPath` (was 0009) | [#3356](https://github.com/noctalia-dev/noctalia/pull/3356) | Merged 2026-07-11. Review added thread-safety fixes beyond what was submitted: a mutex around `IconResolver`'s shared theme-plan state, and a `shared_ptr` desktop-entry snapshot instead of a per-call copy. |

**Verification target is `main`, not `cachix`.** `main` is what the open PRs
are actually based against. Checking against `cachix` once let a real
conflict slide: an unrelated upstream addition to `meson.build`'s test
sources broke 0003's plain `git apply` context match, but `git rebase`
resolved it as a clean 3-way merge with no manual intervention. `cachix` and
`main` happen to point at the same commit as of this writing, but that's
incidental.

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
    ./noctalia-patches/0007-feat-plugins-expose-radius-and-padding-on-button-nod.patch
    ./noctalia-patches/0008-feat-plugins-expose-onHover-callback-on-button-box-a.patch
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
