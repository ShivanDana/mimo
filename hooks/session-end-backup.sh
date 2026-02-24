#!/usr/bin/env bash
# mimo — SessionEnd transcript backup
# Final safety net. Copies transcript on session exit. Runs async.
set -euo pipefail

BACKUP_DIR="$HOME/.claude/backups"
STATE_FILE="$HOME/.claude/memory-state/state.json"
mkdir -p "$BACKUP_DIR"

# Read stdin JSON
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Copy transcript
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    cp "$TRANSCRIPT" "$BACKUP_DIR/${TIMESTAMP}-end.jsonl"
fi

# Clean up state file for this session
rm -f "$STATE_FILE"
