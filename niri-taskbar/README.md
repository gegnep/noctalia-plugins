# niri-taskbar

A bar widget for [Noctalia](https://noctalia.dev) v5 that combines
[niri](https://github.com/YaLTeR/niri) workspaces and a taskbar. It renders compact workspace
chips colored like Noctalia's native workspaces widget: active is primary,
occupied is secondary, urgent is error, empty is muted. On hover, a chip
rounds out and grows into a tinted pill containing real app-icon tiles for
every window on that workspace.

![niri-taskbar default bar strip, all chips collapsed](./screenshots/bar-strip.png)
![niri-taskbar chip expanded on hover, showing window icon tiles](./screenshots/expanded-chip.png)

The widget targets niri only. It drives itself entirely off `niri msg
--json event-stream`.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Settings](#settings)
- [Notes and Limitations](#notes-and-limitations)
- [Development](#development)
- [License](#license)

## Features

- Workspace chips match the native workspaces widget's palette: active is
  primary, occupied is secondary, urgent is error, empty is muted
- Idle chips stretch via `chip_ratio`, from a 100% circle to a 400% line
  (default 140%, a compact oval). They always round back into a circle on
  hover.
- Hover a chip to expand it into a tinted pill with a primary hairline
  border. The pill holds app-icon tiles for every window on that workspace,
  and fades in and out at a configurable speed (`expand_speed`). Click a
  tile to focus that window.
- The focused window's tile gets a primary dot underneath it; an urgent
  window gets an error-colored dot instead (`show_focus_dot`)
- Four label modes (`display`): workspace id, name (falls back to id),
  window count, or a bare pill with no label
- Per-workspace hover: hovering one chip expands only that chip, not every
  chip on the bar (needs a current Noctalia build; see Requirements)
- Click a chip to focus its workspace. On a multi-monitor setup, this
  chains a focus-monitor call first, so cross-monitor chip clicks land
  correctly.
- Windows within an expanded chip sort by niri's own scrolling-layout
  column and window position, not arrival order
- Scoped to its own monitor by default. Optionally scopes to the
  compositor's focused monitor instead, regardless of which bar instance
  you're looking at (`focused_output_only`, needs `barWidget.outputName`,
  shipped upstream; see Requirements)
- Live via `niri msg --json event-stream`. The widget also resyncs every
  30 seconds to recover from any missed event.
- Real app icons resolved through Noctalia's own icon machinery (needs
  `noctalia.appIconPath`, shipped upstream), falling back to an
  initial-letter tile otherwise

## Requirements

- niri as the compositor.
- A Noctalia v5 build from 2026-07-21 or later. Every capability the
  widget uses now ships on upstream `main`; no local patch is needed. An
  older build still runs the widget, degrading as the table describes.

  | Capability | Adds | On an older build without it |
  |---|---|---|
  | `barWidget.outputName` (merged [#3352](https://github.com/noctalia-dev/noctalia/pull/3352)) | Scopes the widget to its own monitor | Every instance shows all outputs' workspaces |
  | `noctalia.appIconPath` (merged [#3356](https://github.com/noctalia-dev/noctalia/pull/3356)) | Native icon resolution for window tiles | Tiles fall back to an initial-letter glyph |
  | row/column `onClick`/`onHover` (merged [#3470](https://github.com/noctalia-dev/noctalia/pull/3470), 2026-07-21) | Workspace chips become clickable and hoverable: click to switch, hover to expand per workspace | Chips still render fully styled; row supports the chip geometry natively. They emit no click or hover of their own. The widget-level expand-all fallback still works. |
  | `onHover` on button/box/image (merged [#3470](https://github.com/noctalia-dev/noctalia/pull/3470), 2026-07-21) | Window-tile hover: grey hover dot, per-tile group-keep-alive | Window tiles lose their grey hover dot; chip hover (above) is unaffected |

  The workspace chip used to be a `ui.button`, and needed a since-rejected
  patch (button radius/padding) for its shape. It's now a `ui.row` plus
  `ui.label`, which has always supported that geometry natively. Its
  clickability rides the merged #3470 capabilities above.

## Install

**As a plugin source.** Noctalia clones and manages the repo itself; you
need no local checkout.

```sh
noctalia msg plugins source add gegnep-plugins git https://github.com/gegnep/noctalia-plugins
noctalia msg plugins enable gegnep/niri-taskbar
```

Or add the repo as a plugin source in Settings, Plugins, and install
**Niri Taskbar** from the plugin browser.

**Symlink** into Noctalia's local plugin directory. Use this for local
development, or if you'd rather manage the checkout yourself.

```sh
git clone https://github.com/gegnep/noctalia-plugins
cd noctalia-plugins
ln -sfn "$PWD/niri-taskbar" ~/.local/share/noctalia/plugins/niri-taskbar
```

Then add the **Niri Taskbar** widget from Settings, Bar, like any other bar
widget.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `focused_output_only` | bool | `false` | Show only the focused monitor's workspaces instead of this monitor's |
| `show_empty_workspaces` | bool | `true` | Show chips for workspaces with no windows (the active workspace is always shown) |
| `display` | select | `id` | What each chip shows: the workspace index (`id`), its name falling back to the index (`name`), its window count (`windows`), or a bare pill (`none`) |
| `window_titles` | select | `off` | Truncated window title next to tiles: `off`, `hover` (only the tile under the pointer), or `always` (forced off in a vertical/side bar) |
| `max_windows_per_workspace` | int | `10` | Cap on expanded window tiles per workspace before collapsing the rest into a `+N` label. Range 1-30. |
| `labels_only_when_occupied` | bool | `false` | Hide the label on empty, inactive workspace chips, leaving a bare pill |
| `max_label_chars` | int | `1` | Truncate workspace name labels to this many characters (purely numeric labels are never truncated). Range 1-20. |
| `only_active_workspace` | bool | `false` | Show window tiles only for each monitor's active workspace; other workspace chips still render |
| `icon_size` | int | `16` | Window app icon size in pixels. Range 12-32. |
| `chip_size` | int | `16` | Workspace chip diameter. Range 12-24. |
| `chip_ratio` | int | `140` | Idle chip width-to-height ratio in percent. 100 is a circle, 140 a compact oval, 300+ approaches a line. Chips always round into circles on expand; labels hide when the chip is too flat to fit them. Range 100-400. |
| `chip_spacing` | int | `3` | Spacing between workspaces. Range 0-12. |
| `collapse_delay_ms` | int | `1250` | Hover linger before collapse, in milliseconds. Range 250-5000. |
| `expand_speed` | select | `normal` | Expand animation speed: `fast`, `normal`, or `slow` |
| `show_focus_dot` | bool | `true` | Show a dot under the focused (primary) and urgent (error-colored) windows' tiles |
| `pill_tint` | int | `30` | Expanded pill tint strength, as a percentage. Range 0-60. |

## Notes and Limitations

- Labels auto-hide on very flat idle chips (high `chip_ratio`), since there
  is no room to render text.
- On a Noctalia build older than 2026-07-21 (no row/column `onClick`/
  `onHover`), hovering any chip expands all of them, with a short
  collapse-grace fallback instead of true per-workspace hover.
- The 30-second resync only replaces state if nothing changed while it was
  in flight. A live event always wins over a stale snapshot.

## Development

```sh
nix develop   # or let direnv load it automatically
```

Linting the manifest and settings wiring does not parse Luau. The fixture
harness below is the real code gate.

Lint the manifest and settings wiring:

```sh
noctalia plugins lint niri-taskbar
```

Run the offline fixture harness:

```sh
./niri-taskbar/fixtures/dry-run.sh
```

The fixture harness feeds `taskbar.luau`'s parser and render logic with
captured `niri msg --json event-stream` output, workspace and window
snapshots, and icon-resolution scenarios. It checks the resulting state
against expectations. See [`fixtures/parser-spec.md`](./fixtures/parser-spec.md)
for the event state machine.

If niri changes its IPC event shape in a future release, re-derive the
fixtures and spec from a live session:

```sh
./niri-taskbar/fixtures/capture-dumps.sh
```

Everything lives in a single `taskbar.luau` file, with no separate service.
It holds workspace and window state in memory, keyed by niri's own ids,
and reconciles on every IPC event plus the periodic resync.

## License

[MIT](../LICENSE).
