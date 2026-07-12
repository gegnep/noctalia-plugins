# claude-launcher

A streaming chat panel for [Claude](https://claude.com), backed by the
`claude` CLI (Claude Code) running in print mode. It shells out to your own
`claude` login, so usage bills against your Pro/Max subscription. The
plugin never talks to the Anthropic API directly and never holds an API
key.

![claude-launcher empty panel with the model pill and composer](./screenshots/empty-state.png)
![claude-launcher streaming a markdown reply](./screenshots/chat.png)

*Not affiliated with, endorsed by, or sponsored by Anthropic. Claude is a
trademark of Anthropic PBC.*

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [Settings](#settings)
- [Notes and Limitations](#notes-and-limitations)
- [Development](#development)
- [License](#license)

## Features

- Streaming markdown responses (headings, lists, code, etc, via Noctalia's
  markdown control)
- Chat-style composer keybinds: Enter sends, Shift+Enter inserts a newline,
  Ctrl+Enter also sends
- Follow-scroll while a response grows, with a jump-to-latest pill once you
  scroll away from the bottom
- Claude.ai-style inline model picker: per-model reasoning controls (level
  select for Sonnet/Opus/Fable, an extended-thinking toggle for Haiku)
- Model and reasoning effort are locked once a conversation starts and
  restored automatically when you reopen it later
- Chat history: rename (renamed chats carry a small pencil marker), delete
  with a two-step confirm, and continue any past chat in a terminal via
  `claude --resume`
- Past conversations reload their transcript from disk, so history isn't
  just a title list
- Queued send: submit while a response is still streaming and it sends the
  moment the current one finishes, with cancel/send-now controls
- Retry on a failed message, stop mid-stream, and a login affordance that
  opens a terminal for one-time `/login` when the CLI reports it isn't
  authenticated
- Tool use is off by default (the CLI is invoked with an empty tool set); an
  opt-in setting hands the model its normal tool behavior

## Requirements

- A Noctalia v5 build that includes the plugin-UI patches from
  [noctalia-dev/noctalia#3327](https://github.com/noctalia-dev/noctalia/pull/3327)
  (in review). Until that lands, apply them locally; see
  [`../noctalia-patches/`](../noctalia-patches) for what each patch adds and
  how to apply them.
- The `claude` CLI (Claude Code), logged into a Pro/Max subscription.

Auth follows whatever `claude_command` actually runs. If you point it at a
sandboxed or bwrapped `claude` wrapper, that's fine, but you must set the
**Transcripts directory** setting explicitly (sandboxed processes don't
share a home directory with the one Noctalia derives from) and log in
interactively inside that same sandbox once, before first use.

## Install

**As a plugin source** (Noctalia clones and manages the repo itself, no
local checkout needed):

```sh
noctalia msg plugins source add gegnep-plugins git https://github.com/gegnep/noctalia-plugins
noctalia msg plugins enable gegnep/claude-launcher
```

**Symlink** into Noctalia's local plugin directory (for local development or
if you'd rather manage the checkout yourself):

```sh
git clone https://github.com/gegnep/noctalia-plugins
cd noctalia-plugins
ln -sfn "$PWD/claude-launcher" ~/.local/share/noctalia/plugins/claude-launcher
```

## Usage

Bind a key to toggle the panel via IPC:

```sh
noctalia msg panel-toggle gegnep/claude-launcher:chat
```

In-panel: type in the composer and send, switch model/reasoning before your
first message (locked afterward), open History from the header to reload,
rename, delete, or continue a past chat in a terminal, and use New Chat to
start fresh.

![claude-launcher model and reasoning picker open](./screenshots/model-picker.png)
![claude-launcher chat history with rename, delete, and terminal actions](./screenshots/history.png)

| Key | Action |
|---|---|
| Enter | Send |
| Shift+Enter | New line |
| Ctrl+Enter | Send |

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `claude_command` | string | `claude` | Path or name of the claude binary (point at a wrapper to sandbox it) |
| `transcripts_dir` | folder | *(empty)* | Claude projects dir used to reload past conversations; empty auto-derives from the workspace path (sandboxed claude wrappers must set this explicitly) |
| `model` | select | `auto` (first in list) | Model new chats start with: `auto`, `sonnet`, `opus`, `haiku`, `fable` |
| `models` | string_list | `["sonnet", "opus", "haiku", "fable"]` | Model aliases offered by the in-panel switcher |
| `effort` | select | `auto` (default/high) | Default reasoning level for new chats: `auto`, `low`, `medium`, `high`, `xhigh`, `max` |
| `allow_tools` | bool | `false` | Off: claude runs with all tools disabled. On: claude's default tool behavior |

## Notes and Limitations

- Thinking text only streams for Haiku. Other models send encrypted
  reasoning at the API level; the plugin has no visibility into it, so the
  extended-thinking toggle only has an effect on Haiku.
- Markdown links render underlined but aren't clickable; the markdown
  control has no click API yet.
- Model and effort are fixed for the lifetime of a conversation; switch by
  starting a new chat.
- No usage/quota display. Pro/Max rate-limit windows are server-side and
  opaque, so this plugin doesn't attempt to estimate "percent of limit."

## Development

```sh
nix develop   # or let direnv load it automatically
```

The devshell provides `luau`, `jq`, `fd`, and `ripgrep`, everything the
fixture harness needs, no running Noctalia instance required.

```sh
noctalia plugins lint claude-launcher   # lint the manifest and Luau sources
./claude-launcher/fixtures/dry-run.sh   # run the fixture-driven parser tests
```

The fixture harness feeds real captured `claude --output-format stream-json`
output (with and without `--include-partial-messages`) plus a sample
transcript file through `panel.luau`'s parser and transcript loader outside
of Noctalia. See [`fixtures/parser-spec.md`](./fixtures/parser-spec.md) for
the full state machine the parser implements.

Everything lives in a single `panel.luau` (no separate service yet). Claude
runs with its working directory pinned to a dedicated workspace under
`$XDG_STATE_HOME/noctalia-claude-launcher/workspace` rather than your home
directory.

## License

[MIT](../LICENSE).
