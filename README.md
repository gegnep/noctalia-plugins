# noctalia-plugins

Personal plugins I built for my own [Noctalia](https://noctalia.dev) v5
setup: a streaming Claude chat panel and a niri workspace/taskbar widget,
written with the help of AI tooling. I use both daily; sharing them here in
case they're useful to you too.

## Table of Contents

- [Plugins](#plugins)
  - [claude-launcher](#claude-launcher)
  - [niri-taskbar](#niri-taskbar)
- [Host Patches](#host-patches)
- [Install](#install)
- [Development](#development)
- [Credits](#credits)
- [License \& Disclaimer](#license--disclaimer)

## Plugins

### claude-launcher

A streaming chat panel for Claude, backed by your own `claude` CLI login. No
API key; it bills against your Pro/Max subscription.

![claude-launcher streaming a markdown reply](./claude-launcher/screenshots/chat.png)

**[Full README](./claude-launcher)**

### niri-taskbar

A combined niri workspace/taskbar bar widget: stretchable idle chips that
expand on hover into a pill of real app-icon window tiles.

![niri-taskbar collapsed bar strip](./niri-taskbar/screenshots/bar-strip.png)

**[Full README](./niri-taskbar)**

## Host Patches

Both plugins lean on a small set of additive patches to Noctalia itself.
None change existing behavior; they're all either default-off or new
bindings a plugin has to opt into. Two of the original nine capabilities
have already shipped upstream (native to any current Noctalia build); the
remaining seven are open PRs or staged for submission.

See **[`noctalia-patches/README.md`](./noctalia-patches/README.md)** for the
full patch list, current upstream status, and how to apply them. Each
plugin's own README also documents exactly how it degrades on a stock,
unpatched Noctalia build.

## Install

**As a plugin source** (Noctalia clones and manages the repo itself, no
local checkout needed):

```sh
noctalia msg plugins source add gegnep-plugins git https://github.com/gegnep/noctalia-plugins
noctalia msg plugins enable gegnep/claude-launcher
noctalia msg plugins enable gegnep/niri-taskbar
```

**Symlink** a single plugin into Noctalia's local plugin directory (for
local development or if you'd rather manage the checkout yourself):

```sh
git clone https://github.com/gegnep/noctalia-plugins
cd noctalia-plugins
ln -sfn "$PWD/claude-launcher" ~/.local/share/noctalia/plugins/claude-launcher
ln -sfn "$PWD/niri-taskbar" ~/.local/share/noctalia/plugins/niri-taskbar
```

## Development

```sh
nix develop   # or let direnv load it automatically
```

The devshell provides `luau`, `jq`, `fd`, and `ripgrep`: everything each
plugin's fixture harness needs, no running Noctalia instance required.

```sh
noctalia plugins lint   # lint all plugin manifests and Luau sources
```

Each plugin has its own offline fixture harness under `<plugin>/fixtures/`
(`dry-run.sh`); see the plugin's README for what it covers.

`catalog.toml` (required for consuming this repo as a git plugin source) is
auto-generated from `*/plugin.toml`. Regenerate with
`python3 tools/update-catalog.py` (CI also does this on push to `main`).
Don't edit it by hand.

## Credits

Built on [Noctalia](https://noctalia.dev) by the
[noctalia-dev](https://github.com/noctalia-dev) team

## License & Disclaimer

[MIT](./LICENSE).
