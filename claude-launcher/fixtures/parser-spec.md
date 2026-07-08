# handleLine parser spec (Phase 3)

State machine for `handleLine(streamId, line)` in `panel.luau`. Derived from the
empirical dumps in this directory (`claude` CLI v2.1.201, 2026-07-07) — see repo
CLAUDE.md: never extend this parser from assumed schema; re-dump instead.

## Contract

```lua
-- handleLine(streamId: number, line: string) -> ()
-- Called from the runStream onLine closure, which captures streamId at send time.
-- Mutates: the OPEN assistant message (last element of `messages`), sessionId
-- confirmation, streaming flag, diagBuffer, lastLineAt. Calls render() itself
-- when warranted (see Render policy). Entire body pcall-wrapped by the caller
-- or internally — a parse error must never propagate (25ms budget, health
-- circuit-breaker).
```

Preconditions established by `onSubmit` before the stream starts:
- a user message appended; an assistant message appended with
  `{role="assistant", text="", thinking=nil, thinkingOpen=false, status="streaming"}`;
- `streaming = true`, `activeStreamId` incremented, `lastLineAt = os.clock()`.

## Step 0 — guards (in order)

1. **Stale stream**: `if streamId ~= activeStreamId or not streaming then return end`.
   Buffered lines can arrive after stop/new-send; drop silently.
2. `lastLineAt = os.clock()` (watchdog feed) — after the stale check, before parsing.
3. `local ev, err = noctalia.json.decode(line)`. On failure or non-table:
   push the raw line into `diagBuffer` (ring, keep last 20; these are stderr
   lines — command runs with `2>&1`), `noctalia.log` it, return. No render.

## Step 1 — route by `ev.type`

| `ev.type` | action |
|---|---|
| `"system"` | `subtype == "init"`: confirm `ev.session_id == sessionId` (mismatch → log warning, keep going; the uuid we generated is authoritative for pkill either way). Other subtypes (`"status"`): ignore. No render. |
| `"rate_limit_event"` | ignore (usage widget descoped). |
| `"assistant"` | ignore — complete snapshot duplicating deltas already consumed. |
| `"stream_event"` | see Step 2. |
| `"result"` | see Step 3. |
| anything else | ignore, log at debug level once per unknown type. |

## Step 2 — `stream_event`: route by `ev.event.type`

Let `msg` = last element of `messages` (must be the open assistant message;
if `msg.role ~= "assistant"` something is off — log and return).

| `event.type` | action | render? |
|---|---|---|
| `message_start` | first one: no-op (msg already open). Subsequent ones in the same stream (should not happen with no tools): ignore, log. | no |
| `content_block_start` | `event.content_block.type == "thinking"` → `msg.status = "thinking"`, init `msg.thinking = msg.thinking or ""`. `== "text"` → `msg.status = "streaming"`. Other block types: ignore. Reset `deltaCount = 0`. | yes |
| `content_block_delta` | route by `event.delta.type`: `"text_delta"` → append `event.delta.text` to `msg.text`; `"thinking_delta"` → append `event.delta.thinking` to `msg.thinking`; `"signature_delta"` and unknown → ignore (fixture shows signature_delta carries only a crypto signature). | every 3rd delta (`deltaCount % 3 == 0`) |
| `content_block_stop` | no state change (status flips on the NEXT block start or on result). | yes |
| `message_delta` | carries `stop_reason`, not content — ignore. | no |
| `message_stop` | no-op; `result` is the authoritative terminal line. | no |

## Step 3 — `result`: finalize

1. `streaming = false`; `panel.setWantsSecondTicks(false)` (watchdog off).
2. `ev.is_error == true` (or `subtype ~= "success"`): `msg.status = "error"`;
   `msg.text` = whatever streamed so far, with `ev.result` (string) appended as
   the error explanation if non-empty; if `diagBuffer` non-empty, append its
   tail. **Phase 4 addition**: if the send used `--resume` and the error text
   matches a session-not-found shape, clear persisted session id.
3. Success: `msg.status = "done"`; **reconciliation** — if `ev.result` is a
   non-empty string, `msg.text = ev.result` (authoritative full text; self-heals
   deltas lost to the 64KiB runStream line cap or event pressure).
4. Always render.

## Render policy

Render on: block start/stop, every 3rd `text_delta`/`thinking_delta`, result.
Never render on: init/status/rate-limit/assistant/message_delta/message_stop/
stale/parse-fail lines. Rationale: render is host-diffed and cheap but not free
under the 25ms callback budget; block boundaries + every-3rd keeps perceived
latency token-ish while bounding work.

## Watchdog (owned by `update()`, not handleLine — spec'd here for cohesion)

While `streaming`: `panel.setWantsSecondTicks(true)` at stream start. Each tick:
if `os.clock() - lastLineAt > 20` → fire `pgrep -f <session-uuid>` via
`runAsync`; in its callback, if no process found AND still the same
`activeStreamId` AND still `streaming`: finalize open message as
`status = "error"`, text += "claude exited without a result" + diagBuffer tail,
`streaming = false`, ticks off, render. Covers binary-missing, crash-before-JSON,
auth failure, external kill. (runStream returning `false` synchronously at send
time is handled in `onSubmit`, not here.)

## Fixture ground truth (do not "fix" the parser against docs)

- `stream-dump-plain.jsonl` — no `--include-partial-messages`: system/init,
  assistant (whole message), rate_limit_event, result.
- `stream-dump-partial.jsonl` — with the flag: adds system/status and
  stream_event lines; thinking block emitted `content_block_start(thinking)` +
  `content_block_delta(signature_delta)` + `content_block_stop`; text block
  emitted `text_delta`. `message_delta.delta` = `{stop_reason, ...}` (not
  content). `assistant` snapshots appear per completed block mid-stream.
