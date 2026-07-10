#!/usr/bin/env sh
# P1 empirical capture: niri IPC ground truth for parser-spec.md.
# Run user-side (needs a live niri session). While the event-stream capture
# runs: switch workspaces a few times, open a window, close a window, and
# focus different windows — that covers every event the parser handles.
set -eu
cd "$(dirname "$0")"

niri --version > niri-version.txt
niri msg --json workspaces > workspaces.json
niri msg --json windows > windows.json
niri msg action --help > action-help.txt 2>&1 || true

echo "Capturing event-stream for 25s — switch workspaces, open/close/focus windows NOW..."
timeout 25 niri msg --json event-stream > event-stream.jsonl || true

echo "Captured:"
wc -l workspaces.json windows.json event-stream.jsonl
