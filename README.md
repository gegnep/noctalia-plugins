# noctalia-plugins

Plugins for [Noctalia](https://noctalia.dev) v5, plus the small set of
additive host patches they ride on.

| Plugin | Description |
|---|---|
| [claude-launcher](./claude-launcher) | Streaming chat panel for Claude, backed by your own `claude` CLI login |
| [niri-taskbar](./niri-taskbar) | Combined niri workspace/taskbar widget: chips that expand on hover into app-icon window tiles |

See each plugin's own README for its full feature list, settings, and
requirements.

### Host patches

Both plugins lean on a handful of small, additive patches to Noctalia itself
— things like chat-style Enter-to-submit, follow-scroll, a markdown control
binding, per-monitor bar-widget scoping, capsule button styling, per-node
hover events, and native icon resolution. None of them change existing
behavior; they're all either default-off or new bindings a plugin has to
opt into.

See [`noctalia-patches/README.md`](./noctalia-patches/README.md) for the
full list, what each patch adds, and how to apply them to a Noctalia build.
Upstream status as of this writing:

- Patches 0001–0005 (claude-launcher's UI needs): submitted as
  [noctalia-dev/noctalia#3327](https://github.com/noctalia-dev/noctalia/pull/3327),
  awaiting review.
- Patch 0007 (button radius/padding — capsule chips): submitted as
  [noctalia-dev/noctalia#3355](https://github.com/noctalia-dev/noctalia/pull/3355),
  awaiting review.
- Patch 0008 (per-node `onHover` — per-workspace hover): stacks on 0007;
  its PR follows once #3355 merges. Apply locally from `noctalia-patches/`
  in the meantime.
- `barWidget.outputName` (needed by niri-taskbar) and `noctalia.appIconPath`
  (native icon resolution) merged upstream —
  [noctalia-dev/noctalia#3352](https://github.com/noctalia-dev/noctalia/pull/3352)
  and
  [noctalia-dev/noctalia#3356](https://github.com/noctalia-dev/noctalia/pull/3356)
  — and are no longer carried as local patches; any noctalia build off
  current `main` or the `cachix` branch already has them.

Each plugin runs on a stock Noctalia build too — see its README for exactly
how it degrades without its patches applied.

### Install

**As a path source**, tracking this repo without copying anything:

```sh
noctalia msg plugins source add gegnep-plugins path /path/to/noctalia-plugins
noctalia msg plugins enable gegnep/claude-launcher
noctalia msg plugins enable gegnep/niri-taskbar
```

**Symlink** a single plugin into Noctalia's local plugin directory:

```sh
ln -sfn "$PWD/claude-launcher" ~/.local/share/noctalia/plugins/claude-launcher
ln -sfn "$PWD/niri-taskbar" ~/.local/share/noctalia/plugins/niri-taskbar
```

### Development

```sh
nix develop   # or let direnv load it automatically
```

The devshell provides `luau`, `jq`, `fd`, and `ripgrep` — everything each
plugin's fixture harness needs, no running Noctalia instance required.

Lint all plugin manifests and Luau sources:

```sh
noctalia plugins lint
```

Each plugin has its own offline fixture harness under `<plugin>/fixtures/`
(`dry-run.sh`) — see the plugin's README for what it covers.

`catalog.toml` (required for consuming this repo as a git plugin source) is
auto-generated from `*/plugin.toml` — regenerate with
`python3 tools/update-catalog.py` (CI also does this on push to `main`).
Don't edit it by hand.

### License

[MIT](./LICENSE). Not affiliated with, endorsed by, or sponsored by
Anthropic. Claude is a trademark of Anthropic PBC.
