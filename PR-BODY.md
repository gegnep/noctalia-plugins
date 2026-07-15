# PR body — plugin-clickable-containers (0008 + 0009)

Target: `noctalia-dev/noctalia`, base `main`, head `gegnep:plugin-clickable-containers`.
Two commits. Suggested title:

> feat(plugins): onHover on interactive nodes; onClick/onHover on row/column

(Metadata above is for us — the posted body starts below the rule.)

---

## Summary

This follows the direction from #3355: build pill-shaped plugin UI from
layout primitives rather than changing Button styling. The taskbar workspace
chips now use `ui.row` with a `ui.label` child, drawing on the row's existing
fill, radius, and padding.

This PR adds the missing interaction support:

- `onHover` for button, box, and image (commit 1)
- `onClick` and `onHover` for row and column (commit 2)

`onHover` receives `"true"` on pointer enter and `"false"` on leave, matching
the existing string-callback convention.

## Implementation

Rows and columns with a non-empty callback are wrapped in a reconciler-local
`ClickWrap` InputArea that forwards measurement and arrangement to the inner
Flex, so content-sized containers keep their natural size. Rows and columns
without callbacks remain plain Flex nodes.

Hover-only wrappers accept no pointer buttons and stay out of the tab order,
so clicks continue to an interactive ancestor. Clickable wrappers accept left
clicks, enter the tab order, and activate through the Validate keybind. The
same wrapper now backs clickable box/image, which gain the keyboard
activation as well. No visual focus state is drawn or exposed for containers
yet.

Wrapper input handlers deviate from the reconciler's retain-absent-props
default in two deliberate ways: an empty callback name counts as unset, and
removing `onClick` while `onHover` keeps the wrapper alive clears the
click/key handlers, button mask, focusability, and pointer cursor (removing
`onHover` while `onClick` remains clears the enter/leave handlers) — a
retained click handler would leave an invisible node that swallows clicks
and sits in tab order as a keyboard-activatable ghost.

I considered Button's internal non-layout InputArea pattern, but applying
that shape here would mean changing core `Flex`; `ClickWrap` keeps the
behavior inside the plugin reconciler and leaves non-interactive containers
untouched.

Container hover follows existing InputArea hit testing: the callback fires
while the container itself is the innermost hovered input area; interactive
descendants receive their own enter/leave events.

## Testing

Reconciler tests cover row/column child reconciliation, content-sized and
explicit-size measurement, click/hover dispatch, callback rewiring and
clearing (including the removed-while-hover-alive transition), hover-only
button masks and focusability, wrapper toggling, and empty callback names.

Manually exercised with a niri taskbar plugin:

- row/label workspace chips — click to switch workspace, hover to expand
  that workspace's window group
- image window tiles — click and hover callbacks

[Idle and hovered-expanded screenshots of the row/label chips]
