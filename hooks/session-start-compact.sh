#!/usr/bin/env bash
# mimo — SessionStart hook (post-compact)
# Lightweight context injection after compaction. Does NOT reset state flags.
# Also writes post-compact flag for UserPromptSubmit hook to consume.
set -euo pipefail

STATE_DIR="$HOME/.claude/memory-state"

# Read stdin JSON
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')

# Write post-compact flag for UserPromptSubmit hook
if [ -n "$SESSION_ID" ]; then
    touch "$STATE_DIR/${SESSION_ID}-postcompact.flag"
fi

MSG="[MIMO] Continuing after compaction. Read CLAUDE.md 'Memory' sections for prior context."

if [ -f "$CWD/CLAUDE-FULL.md" ]; then
    LINES=$(wc -l < "$CWD/CLAUDE-FULL.md" | tr -d ' ')
    MSG="${MSG} CLAUDE-FULL.md available (${LINES} lines)."
fi

jq -n --arg ctx "$MSG" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
