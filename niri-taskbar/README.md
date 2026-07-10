# niri-taskbar

A combined workspace/taskbar bar widget for [niri](https://github.com/YaLTeR/niri),
built for [Noctalia](https://noctalia.dev) v5. It renders compact workspace
chips colored like Noctalia's native workspaces widget — active = primary,
occupied = secondary, urgent = error, empty = muted — and on hover a chip
rounds out and grows into a tinted pill containing real app-icon tiles for
every window on that workspace.

<!-- screenshot: default bar strip, all chips collapsed -->
<!-- screenshot: a chip expanded on hover showing window icon tiles -->
<!-- screenshot: an urgent workspace chip -->

niri only — it drives itself entirely off `niri msg --json event-stream`.

### Features

- Workspace chips matching the native workspaces widget's palette: active =
  primary, occupied = secondary, urgent = error, empty = muted; idle chips
  are compact ovals (or circles — configurable) that round out on hover
- Hover a chip to expand it into app-icon tiles for its windows; click a
  tile to focus that window
- Per-workspace hover: hovering one chip expands only that chip, not every
  chip on the bar (needs the 0008 host patch — see Requirements)
- Click a chip to focus its workspace; on a multi-monitor setup this chains
  a focus-monitor call first so cross-monitor chip clicks land correctly
- Windows within an expanded chip are ordered by niri's own scrolling-layout
  column/window position, not arrival order
- Live via `niri msg --json event-stream`, with a 30-second self-healing
  resync in case an event is ever missed
- Real app icons resolved through Noctalia's own icon machinery (needs the
  0009 host patch), falling back to an initial-letter tile otherwise

### Requirements

- niri as the compositor.
- A Noctalia v5 build. The widget runs on stock Noctalia but looks and
  behaves best with the host patches in
  [`../noctalia-patches/`](../noctalia-patches) applied — see that
  directory's README for what each one does and how to apply them. Specific
  patches this widget uses, and how it degrades without each:

  | Patch | Adds | Without it |
  |---|---|---|
  | 0006 `barWidget.outputName` | Scopes the widget to its own monitor | Every instance shows all outputs' workspaces |
  | 0007 button radius/padding | Capsule-shaped chips | Square chips |
  | 0008 `onHover` on button/box/image | Per-workspace hover (only the hovered chip expands) | Hovering any chip expands all of them (with a short collapse-grace fallback) |
  | 0009 `noctalia.appIconPath` | Native icon resolution for window tiles | Tiles fall back to an initial-letter glyph |

### Install

**As a path source** (tracks this repo, no copying):

```sh
noctalia msg plugins source add gegnep-plugins path /path/to/noctalia-plugins
noctalia msg plugins enable gegnep/niri-taskbar
```

(or add the repo as a plugin source in Settings → Plugins and install
**Niri Taskbar** from the plugin browser)

**Symlink** into Noctalia's local plugin directory:

```sh
ln -sfn "$PWD/niri-taskbar" ~/.local/share/noctalia/plugins/niri-taskbar
```

Then add the **Niri Taskbar** widget from Settings → Bar like any other bar
widget.

### Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `focused_output_only` | bool | `false` | Show only the focused monitor's workspaces instead of this monitor's |
| `show_empty_workspaces` | bool | `true` | Show chips for workspaces with no windows (the active workspace is always shown) |
| `display` | select | `id` | What each chip shows: the workspace index (`id`), its name falling back to the index (`name`), its window count (`windows`), or a bare pill (`none`) |
| `show_window_titles` | bool | `false` | Show a truncated window title next to each window tile (always off in a vertical/side bar) |
| `max_windows_per_workspace` | int | `10` | Cap on expanded window tiles per workspace before collapsing the rest into a `+N` label |
| `labels_only_when_occupied` | bool | `false` | Hide the label on empty, inactive workspace chips, leaving a bare pill |
| `max_label_chars` | int | `1` | Truncate workspace name labels to this many characters (purely numeric labels are never truncated) |
| `only_active_workspace` | bool | `false` | Show window tiles only for each monitor's active workspace; other workspace chips still render |
| `icon_size` | int | `16` | Window app icon size in pixels |
| `chip_size` | int | `16` | Workspace chip diameter |
| `chip_ratio` | int | `140` | Idle chip width-to-height ratio (%): 100 is a circle, 140 a compact oval, 300+ approaches a line; chips always round into circles on expand (labels hide when the chip is too flat to fit them) |
| `chip_spacing` | int | `3` | Spacing between workspaces |
| `collapse_delay_ms` | int | `1250` | Hover linger before collapse, in milliseconds |
| `expand_speed` | select | `normal` | Expand animation speed: `fast`, `normal`, or `slow` |
| `show_focus_dot` | bool | `true` | Show a dot under the focused (primary) and urgent (error-colored) windows' tiles |
| `pill_tint` | int | `30` | Expanded pill tint strength, as a percentage |

### Development

```sh
nix develop   # or let direnv load it automatically
```

Lint the manifest and settings wiring (note: this does not parse Luau —
the fixture harness below is the real code gate):

```sh
noctalia plugins lint niri-taskbar
```

Run the offline fixture harness (no running Noctalia or niri instance
needed):

```sh
./niri-taskbar/fixtures/dry-run.sh
```

This feeds captured `niri msg --json event-stream` output, workspace/window
snapshots, and icon-resolution scenarios through `taskbar.luau`'s parser and
render logic, checking the resulting state against expectations. See
[`fixtures/parser-spec.md`](./fixtures/parser-spec.md) for the event state
machine.

If niri changes its IPC event shape in a future release, re-derive the
fixtures and spec from a live session:

```sh
./niri-taskbar/fixtures/capture-dumps.sh
```

Plugin structure: a single `taskbar.luau` implements the whole widget (no
separate service). It holds workspace/window state in memory, keyed by
niri's own ids, and reconciles on every IPC event plus the periodic resync.

`catalog.toml` (required for consuming this repo as a git plugin source) is
auto-generated from `*/plugin.toml` — regenerate with
`python3 tools/update-catalog.py` (CI also does this on push to `main`).
Don't edit it by hand.

History is commit-per-feature — see `git log` for how the widget evolved
from a static hover-expand spike to live niri IPC wiring, native-parity
styling, and icon resolution.

### License

[MIT](../LICENSE).
