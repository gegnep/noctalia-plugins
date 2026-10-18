# handleLine parser spec

Contract for `handleLine(streamId, line)` in `panel.luau` (0.2.0, the thin
launcher). The parser no longer builds a chat message. It only drives the
status line, detects the end of the first turn, and decides between the
Desktop handoff and an error.

The fixture dumps in this directory were captured from `claude` CLI
v2.1.201 on 2026-07-07. The installed CLI is newer (v2.1.302 on
2026-10-18) and the dumps have NOT been re-captured against it. See repo
CLAUDE.md: never extend this parser from assumed schema; re-dump instead.

## Pending re-dump (doc-derived, UNVERIFIED)

The Anthropic docs describe three additions since v2.1.201. None of them is
confirmed against a real dump, so none of them has changed a line of parser
code. The parser already survives all three: `system` lines other than
`init` are ignored, and unknown top-level types are ignored with one log
line each. Treat every line here as a hypothesis until a dump proves it.

- `system` / `api_retry`: emitted before a retryable API failure is
  retried. Reported fields: `attempt`, `max_retries`, `retry_delay_ms`,
  `error_status`, `error` (a category string such as `rate_limit` or
  `overloaded`), `uuid`, `session_id`, plus an optional `no_response`
  object on v2.1.261+. Any line feeds the watchdog, so a retry notice
  would also keep a slow turn alive.
- `system` / `plugin_install`: only when `CLAUDE_CODE_SYNC_PLUGIN_INSTALL`
  is set. Not our case.
- `system` / `init` gained an optional `capabilities` array (v2.1.205+)
  for feature detection, plus `plugins`, `plugin_errors`, `mcp_servers`
  and `mcp_server_errors`.
- A dump that USES a tool. Tools are on by default since 0.2.0. Both
  fixtures had tools available (their `init` lists them), but the prompt
  used none, so neither holds a `tool_use` block. Capture one before any
  status line names a tool, to verify the block shape. Until then a
  `tool_use` block start shows as "Working".

Re-dump from a real, authenticated shell (this cannot run from an agent
sandbox: no credentials, no egress to the API):

```sh
claude -p 'say ok' --output-format stream-json --verbose \
  --include-partial-messages --model claude-sonnet-5-5 --tools '' \
  --max-turns 1 > dump.jsonl
```

For the tool dump, drop `--tools ''` and ask for something that needs a
tool, such as a file listing.
Replace the fixture dumps from that output, then update this spec from what
the dump actually contains.

## Contract

```lua
-- handleLine(streamId: number, line: string) -> ()
-- Called from the runStream onLine closure, which captures streamId when
-- the turn starts. The whole body runs inside pcall: a parse error is
-- logged and never propagates (25 ms callback budget, health breaker).
-- Mutates: activity, lastLineAt, diagBuffer, seenUnknownTypes, and through
-- handOff()/failTurn() the phase and the composer.
```

Preconditions set by `startTurn` before the stream starts: `phase =
"running"`, a fresh `sessionId` (also passed as `--session-id`),
`activeStreamId` incremented, `activity = "Working"`, `diagBuffer` empty,
`lastLineAt = startedAt = os.time()`, second ticks on.

## Step 0: guards (in order)

1. **Stale stream**: `if streamId ~= activeStreamId or phase ~= "running"
   then return end`. Lines that arrive after a stop, an error or the
   result are dropped silently. Stop, failTurn and a new turn all bump
   `activeStreamId`; the result moves `phase` to `"handoff"`.
2. `lastLineAt = os.time()` (watchdog feed), after the stale check and
   before parsing.
3. `noctalia.json.decode(line)`. On failure or a non-table: push the raw
   line into `diagBuffer` (ring, last 20 lines; these are stderr lines,
   since the command runs with `2>&1`), `noctalia.log` it, return.

## Step 1: route by `ev.type`

| `ev.type` | action |
|---|---|
| `"system"` | `subtype == "init"`: compare `ev.session_id` with `sessionId`; a mismatch is logged and ignored (the uuid we generated is authoritative for the handoff and for pkill). Other subtypes: ignore. |
| `"stream_event"` | see Step 2. |
| `"result"` | see Step 3. |
| `"assistant"` | ignore (a complete snapshot of blocks already seen). |
| `"rate_limit_event"` | ignore. |
| anything else | ignore; log once per unknown type. |

## Step 2: `stream_event`

Only `event.type == "content_block_start"` matters. It sets `activity`
from `event.content_block.type`:

| block type | activity |
|---|---|
| `thinking` | `Thinking` |
| `text` | `Writing` |
| anything else | `Working` |

Render only when the activity changes. Every other stream event (deltas,
block stops, `message_start`, `message_delta`, `message_stop`) is ignored.
The text itself is never shown: Desktop shows the reply after the handoff.

## Step 3: `result`

- **Error**: `ev.is_error == true` or `ev.subtype ~= "success"`. The
  message is `ev.result` (when a string), then the last 3 `diagBuffer`
  lines, or `"claude returned an error"` when both are empty. Call
  `failTurn(message, { needsLogin })`, where `needsLogin` is true when
  `ev.result` mentions `/login` or `Invalid API key`. failTurn logs the
  whole message, sets `phase = "error"`, restores the prompt into the
  input, turns ticks off, and notifies when the panel is closed.
- **Success**: call `handOff()`. It sets `phase = "handoff"`, turns ticks
  off and runs `xdg-open claude://resume?session=<sessionId>` (argv form,
  10 s timeout). Only when `xdg-open` exits 0 does the panel clear the
  composer, close, and (with niri present) poll for the Desktop window to
  focus. A failed `xdg-open` calls `failTurn` with the terminal resume
  offered.

The handoff waits for `result` on purpose: Desktop imports the transcript
file, and importing while the CLI still writes it gives two writers on one
file.

## Watchdog (owned by `update()`, spec'd here for cohesion)

Second ticks run while `phase == "running"` and the panel is open. After
more than 5 s without a line, `update()` runs `pgrep -f <sessionId>` as an
argv table (so no `sh -c` wrapper carrying the uuid can match itself), one
probe at a time. If the probe finds no process and the same stream is
still running, the turn fails with `"claude exited without a result"` plus
the `diagBuffer` tail. `runStream` delivers no exit event, so this probe is
the only detector for a CLI that dies before its result (missing binary,
crash before JSON, external kill). Once the result arrives the phase leaves
`"running"` and the watchdog stops, so the CLI's normal exit never reads as
an error.

## Fixture ground truth (do not "fix" the parser against docs)

- `stream-dump-plain.jsonl`: no `--include-partial-messages`: system/init,
  assistant (whole message), rate_limit_event, result. No block starts, so
  the activity stays `Working`.
- `stream-dump-partial.jsonl`: with the flag: adds system/status and
  stream_event lines; the thinking block emitted
  `content_block_start(thinking)` + `content_block_delta(signature_delta)`
  + `content_block_stop`; the text block emitted `text_delta`.
  `message_delta.delta` = `{stop_reason, ...}` (not content). `assistant`
  snapshots appear per completed block mid-stream.
- Both fixtures carry their own `session_id`, so the dry run logs one
  session-id mismatch per fixture. That log is expected.
