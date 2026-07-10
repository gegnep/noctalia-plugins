#!/usr/bin/env sh
# Offline fixture harness for taskbar.luau. Requires luau and jq on PATH.
set -u

LUAU=${LUAU:-luau}
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
failed=0

run_stream_feeder() {
  name=$1
  feeder=$2
  tmp=$(mktemp --suffix=.luau)
  {
    cat "$dir/harness-prelude.luau"
    cat "$dir/../taskbar.luau"
    printf 'FIXTURE_LINES = {\n'
    jq -R -r 'select(length > 0) | "  [==[" + . + "]==],"' "$dir/event-stream.jsonl"
    printf '}\n'
    cat "$dir/$feeder"
  } > "$tmp"

  if "$LUAU" "$tmp"; then
    printf '%s: PASS\n' "$name"
  else
    printf '%s: FAIL\n' "$name"
    failed=1
  fi
  rm -f "$tmp"
}

run_snapshot_feeder() {
  tmp=$(mktemp --suffix=.luau)
  {
    cat "$dir/harness-prelude.luau"
    cat "$dir/../taskbar.luau"
    printf 'WORKSPACES_JSON = [==[\n'
    cat "$dir/workspaces.json"
    printf '\n]==]\n'
    printf 'WINDOWS_JSON = [==[\n'
    cat "$dir/windows.json"
    printf '\n]==]\n'
    cat "$dir/harness-feeder-snapshot.luau"
  } > "$tmp"

  if "$LUAU" "$tmp"; then
    printf 'snapshot: PASS\n'
  else
    printf 'snapshot: FAIL\n'
    failed=1
  fi
  rm -f "$tmp"
}

run_plain_feeder() {
  name=$1
  feeder=$2
  tmp=$(mktemp --suffix=.luau)
  {
    cat "$dir/harness-prelude.luau"
    cat "$dir/../taskbar.luau"
    cat "$dir/$feeder"
  } > "$tmp"

  if "$LUAU" "$tmp"; then
    printf '%s: PASS\n' "$name"
  else
    printf '%s: FAIL\n' "$name"
    failed=1
  fi
  rm -f "$tmp"
}

json_quote() {
  printf '%s' "$1" | jq -R -r '@json'
}

emit_fixture_fs() {
  printf 'FIXTURE_ROOT = %s\n' "$(json_quote "$dir")"
  printf 'HARNESS_FILES = {\n'
  find "$dir/desktop-files" "$dir/icon-theme" -type f 2>/dev/null | sort | while IFS= read -r file; do
    printf '  [%s] = [==[\n' "$(json_quote "$file")"
    cat "$file"
    printf '\n]==],\n'
  done
  printf '}\n'

  printf 'HARNESS_DIRS = {\n'
  find "$dir/desktop-files" "$dir/icon-theme" -type d 2>/dev/null | sort | while IFS= read -r path; do
    printf '  [%s] = {' "$(json_quote "$path")"
    find "$path" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | while IFS= read -r name; do
      printf '%s, ' "$(json_quote "$name")"
    done
    printf '},\n'
  done
  printf '}\n'
}

run_icons_feeder() {
  tmp=$(mktemp --suffix=.luau)
  {
    cat "$dir/harness-prelude.luau"
    emit_fixture_fs
    cat "$dir/../taskbar.luau"
    cat "$dir/harness-feeder-icons.luau"
  } > "$tmp"

  if "$LUAU" "$tmp"; then
    printf 'icons: PASS\n'
  else
    printf 'icons: FAIL\n'
    failed=1
  fi
  rm -f "$tmp"
}

run_stream_feeder "stream" "harness-feeder-stream.luau"
run_snapshot_feeder
run_plain_feeder "defensive" "harness-feeder-defensive.luau"
run_stream_feeder "callbacks" "harness-feeder-callbacks.luau"
run_icons_feeder

exit "$failed"
