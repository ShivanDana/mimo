#!/usr/bin/env bash
# mimo — PostToolUse hook: track file changes
# After every successful Write or Edit, append file path to per-session changes log
# Runs async — never blocks Claude
set -euo pipefail

# Read stdin JSON
INPUT=$(cat)

# Get changes log path from env or derive from session_id
CHANGES_LOG="${MIMO_CHANGES_LOG:-}"
if [ -z "$CHANGES_LOG" ]; then
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
    [ -z "$SESSION_ID" ] && exit 0
    CHANGES_LOG="$HOME/.claude/memory-state/${SESSION_ID}-changes.log"
fi

# Extract file_path from tool_input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
[ -z "$FILE_PATH" ] && exit 0

# Append to changes log (one path per line, deduped at read time)
echo "$FILE_PATH" >> "$CHANGES_LOG"
