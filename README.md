# noctalia-plugins

Plugins for [Noctalia](https://noctalia.dev) v5. Currently one plugin:

## claude-launcher

A streaming chat panel for [Claude](https://claude.com), backed by the `claude`
CLI (Claude Code) running in print mode. It shells out to your own `claude`
login, so usage bills against your Pro/Max subscription — the plugin never
talks to the Anthropic API directly and never holds an API key.

<!-- screenshot: empty-state panel with the model pill and composer -->
<!-- screenshot: a streaming assistant reply with markdown rendering -->
<!-- screenshot: the claude.ai-style model/reasoning picker open -->
<!-- screenshot: chat history list with rename/delete/terminal actions -->

### Features

- Streaming markdown responses (headings, lists, code, etc. via Noctalia's
  markdown control)
- Chat-style composer keybinds: Enter sends, Shift+Enter inserts a newline,
  Ctrl+Enter also sends
- Follow-scroll while a response grows, with a jump-to-latest pill once you
  scroll away from the bottom
- claude.ai-style inline model picker: per-model reasoning controls (level
  select for Sonnet/Opus/Fable, an extended-thinking toggle for Haiku)
- Model and reasoning effort are locked once a conversation starts and
  restored automatically when you reopen it later
- Chat history: rename (renamed chats carry a small pencil marker), delete
  with a two-step confirm, and continue any past chat in a terminal via
  `claude --resume`
- Past conversations reload their transcript from disk so history isn't just
  a title list
- Queued send: submit while a response is still streaming and it sends the
  moment the current one finishes, with cancel/send-now controls
- Retry on a failed message, stop mid-stream, and a login affordance that
  opens a terminal for one-time `/login` when the CLI reports it isn't
  authenticated
- Tool use is off by default (the CLI is invoked with an empty tool set); an
  opt-in setting hands the model its normal tool behavior

### Requirements

- A Noctalia v5 build that includes the five patches in
  [`noctalia-patches/`](./noctalia-patches) — chat-style input submit,
  follow-scroll, markdown rendering, and two stream/measure bugfixes. They're
  additive and default-off, but claude-launcher depends on all five; an
  upstream PR is pending, see the [patch table](./noctalia-patches/README.md)
  for what each one adds.
- The `claude` CLI (Claude Code), logged into a Pro/Max subscription.

Auth follows whatever `claude_command` actually runs. If you point it at a
sandboxed or bwrapped `claude` wrapper, that's fine — but you must set the
**Transcripts directory** setting explicitly (sandboxed processes don't share
a home directory with the one Noctalia derives from) and log in interactively
inside that same sandbox once, before first use.

### Install

**As a path source** (tracks this repo, no copying):

```sh
noctalia msg plugins source add gegnep-plugins path /path/to/noctalia-plugins
noctalia msg plugins enable gegnep/claude-launcher
```

**Symlink** into Noctalia's local plugin directory:

```sh
ln -sfn "$PWD/claude-launcher" ~/.local/share/noctalia/plugins/claude-launcher
```

**Patches**, applied via a nix overlay on the noctalia package:

```nix
# wherever the noctalia package is taken from its flake input:
(noctalia-pkg.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./noctalia-patches/0001-feat-plugin-ui-add-input-submitOnEnter-prop-for-chat.patch
    ./noctalia-patches/0002-feat-plugin-ui-add-scroll-stickToBottom-onScroll-and.patch
    ./noctalia-patches/0003-feat-plugin-ui-register-markdown-node-type-backed-by.patch
    ./noctalia-patches/0004-fix-plugins-reclaim-stream-slots-when-the-process-ex.patch
    ./noctalia-patches/0005-fix-ui-measure-MarkdownView-with-wrapped-label-sizes.patch
  ];
}))
```

### Usage

Bind a key to toggle the panel via IPC:

```sh
noctalia msg panel-toggle gegnep/claude-launcher:chat
```

In-panel: type in the composer and send, switch model/reasoning before your
first message (locked afterward), open History from the header to reload,
rename, delete, or continue a past chat in a terminal, and use New Chat to
start fresh.

| Key | Action |
|---|---|
| Enter | Send |
| Shift+Enter | New line |
| Ctrl+Enter | Send |

### Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `claude_command` | string | `claude` | Path or name of the claude binary (point at a wrapper to sandbox it) |
| `transcripts_dir` | folder | *(empty)* | Claude projects dir used to reload past conversations; empty auto-derives from the workspace path (sandboxed claude wrappers must set this explicitly) |
| `model` | select | `auto` (First in list) | Model new chats start with: `auto`, `sonnet`, `opus`, `haiku`, `fable` |
| `models` | string_list | `["sonnet", "opus", "haiku", "fable"]` | Model aliases offered by the in-panel switcher |
| `effort` | select | `auto` (Default/High) | Default reasoning level for new chats: `auto`, `low`, `medium`, `high`, `xhigh`, `max` |
| `allow_tools` | bool | `false` | Off: claude runs with all tools disabled. On: claude's default tool behavior |

### Notes and limitations

- Thinking text only streams for Haiku. Other models send encrypted
  reasoning at the API level — the plugin has no visibility into it, so the
  extended-thinking toggle only has an effect on Haiku.
- Markdown links render underlined but aren't clickable; the markdown control
  has no click API yet (see patch 0003).
- Model and effort are fixed for the lifetime of a conversation — switch by
  starting a new chat.
- No usage/quota display. Pro/Max rate-limit windows are server-side and
  opaque; this plugin doesn't attempt to estimate "% of limit".

### Development

```sh
nix develop   # or let direnv load it automatically
```

The devshell provides `luau`, `jq`, `fd`, and `ripgrep` — everything the
fixture harness needs, no running Noctalia instance required.

Lint the manifest and Luau sources:

```sh
noctalia plugins lint
```

Run the fixture-driven parser tests:

```sh
./claude-launcher/fixtures/dry-run.sh
```

This feeds real captured `claude --output-format stream-json` output (with
and without `--include-partial-messages`) plus a sample transcript file
through `panel.luau`'s parser and transcript loader outside of Noctalia,
checking the resulting message state against expectations. See
[`fixtures/parser-spec.md`](./claude-launcher/fixtures/parser-spec.md) for the
full state machine the parser implements.

Plugin structure: a single `panel.luau` implements the whole panel (no
separate service yet). Claude runs with its working directory pinned to a
dedicated workspace under `$XDG_STATE_HOME/noctalia-claude-launcher/workspace`
(falls back to `~/.local/state` if unset) rather than the user's home. Chat
history is tracked in an index file under the same state directory, separate
from Claude's own transcript files.

History is commit-per-feature — see `git log` for how the panel evolved from
a static mockup to full streaming, multi-turn sessions, and history
management.

### License

[MIT](./LICENSE). Not affiliated with, endorsed by, or sponsored by
Anthropic. Claude is a trademark of Anthropic PBC.
