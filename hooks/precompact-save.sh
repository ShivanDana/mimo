#!/usr/bin/env bash
# mimo — PreCompact hook: transcript backup + custom compact instructions
# Copies transcript before compaction and outputs instructions for better compaction quality
set -euo pipefail

BACKUP_DIR="$HOME/.claude/backups"
mkdir -p "$BACKUP_DIR"

# Read stdin JSON
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')
CUSTOM_INSTRUCTIONS=$(echo "$INPUT" | jq -r '.custom_instructions // ""')

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Copy full transcript
    cp "$TRANSCRIPT" "$BACKUP_DIR/${TIMESTAMP}-precompact.jsonl"

    # Generate human-readable summary
    {
        echo "# Pre-compaction backup"
        echo "Date: $(date -Iseconds)"
        echo "Session: $SESSION_ID"
        echo "Trigger: $TRIGGER"
        [ -n "$CUSTOM_INSTRUCTIONS" ] && echo "Custom instructions: $CUSTOM_INSTRUCTIONS"
        echo ""
        echo "## User messages (first 50 lines)"
        # Best-effort extraction — transcript format may vary
        jq -r '
            select(.role == "user") |
            .content //
            (if .message then .message.content else empty end) |
            if type == "string" then .
            elif type == "array" then map(select(.type == "text") | .text) | join("\n")
            else empty end
        ' "$TRANSCRIPT" 2>/dev/null | head -50 || echo "(could not parse transcript)"
    } > "$BACKUP_DIR/${TIMESTAMP}-precompact-summary.md"
fi

# Output custom compact instructions for better compaction quality
jq -n '{hookSpecificOutput: {hookEventName: "PreCompact", additionalContext: "When compacting, preserve: (1) current task/focus and progress, (2) key decisions made this session, (3) files modified and their purposes, (4) any blockers or open issues. These are critical for mimo session continuity."}}'
