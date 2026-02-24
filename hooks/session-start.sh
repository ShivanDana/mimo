#!/usr/bin/env bash
# mimo — SessionStart hook (startup/resume)
# Resets state for new session, injects memory context into Claude
set -euo pipefail

STATE_DIR="$HOME/.claude/memory-state"
STATE_FILE="$STATE_DIR/state.json"
BACKUP_DIR="$HOME/.claude/backups"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# Read stdin JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "none"')
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

# Reset state for new session
jq -n --arg sid "$SESSION_ID" \
    '{session_id: $sid, percentage: 0, threshold: "clean", checkpoint_done: false, fullsave_done: false}' \
    > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# Build context message
MSG="[MIMO ACTIVE] Memory hooks enabled. Checkpoints at 50% context, full save at 80%."

# Check for deep memory archive
if [ -f "$CWD/CLAUDE-FULL.md" ]; then
    LINES=$(wc -l < "$CWD/CLAUDE-FULL.md" | tr -d ' ')
    MSG="${MSG}\nDeep memory archive: CLAUDE-FULL.md (${LINES} lines). Read specific line ranges as needed."
fi

# Check for recent backups
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "*.jsonl" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "0" ]; then
    LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/*.jsonl 2>/dev/null | head -1)
    BACKUP_DATE=$(date -r "$LATEST_BACKUP" +%Y-%m-%d 2>/dev/null || echo "unknown")
    MSG="${MSG}\nTranscript backups: ${BACKUP_COUNT} saved (latest: ${BACKUP_DATE})"
fi

# Output as structured JSON — additionalContext is injected into Claude's context
jq -n --arg ctx "$(echo -e "$MSG")" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
