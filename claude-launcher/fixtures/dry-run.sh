#!/usr/bin/env sh
# Fixture-driven dry run of panel.luau's stream parser, no noctalia needed.
# Usage: ./dry-run.sh   (requires luau and jq on PATH, e.g. via the devshell;
# override the runner with e.g. LUAU=", luau" outside it)
set -eu
LUAU=${LUAU:-luau}
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

run_fixture() {
  fixture=$1
  tmp=$(mktemp --suffix=.luau)
  trap 'rm -f "$tmp"' EXIT
  {
    cat "$dir/harness-prelude.luau"
    cat "$dir/../panel.luau"
    printf 'FIXTURE_LINES = {\n'
    jq -R -r 'select(length > 0) | "  [==[" + . + "]==],"' "$fixture"
    printf '}\n'
    cat "$dir/harness-feeder.luau"
  } > "$tmp"
  printf '%s: ' "$(basename "$fixture")"
  $LUAU "$tmp"
  rm -f "$tmp"
  trap - EXIT
}

run_transcript_fixture() {
  fixture=$1
  tmp=$(mktemp --suffix=.luau)
  trap 'rm -f "$tmp"' EXIT
  {
    cat "$dir/harness-prelude.luau"
    cat "$dir/../panel.luau"
    printf 'TRANSCRIPT_TEXT = [==[\n'
    cat "$fixture"
    printf '\n]==]\n'
    cat "$dir/harness-feeder-transcript.luau"
  } > "$tmp"
  printf '%s: ' "$(basename "$fixture")"
  $LUAU "$tmp"
  rm -f "$tmp"
  trap - EXIT
}

run_fixture "$dir/stream-dump-partial.jsonl"
run_fixture "$dir/stream-dump-plain.jsonl"
run_transcript_fixture "$dir/transcript-sample.jsonl"
