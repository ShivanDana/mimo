#!/usr/bin/env bash
# mimo — SessionEnd transcript backup
# Final safety net. Copies transcript on session exit. Runs async.
set -euo pipefail

BACKUP_DIR="$HOME/.claude/backups"
STATE_DIR="$HOME/.claude/memory-state"
mkdir -p "$BACKUP_DIR"

# Read stdin JSON
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Copy transcript
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    cp "$TRANSCRIPT" "$BACKUP_DIR/${TIMESTAMP}-end.jsonl"
fi

# Clean up this session's state file, changes log, and flag file
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "none" ]; then
    rm -f "$STATE_DIR/${SESSION_ID}.json"
    rm -f "$STATE_DIR/${SESSION_ID}-changes.log"
    rm -f "$STATE_DIR/${SESSION_ID}-postcompact.flag"
fi
