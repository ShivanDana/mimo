#!/usr/bin/env bash
# mimo — UserPromptSubmit hook: post-compact context injection
# On the first user prompt after compaction, inject memory state as additionalContext
# One-shot via flag file — zero overhead on normal prompts
set -euo pipefail

# Get session_id from env or extract from stdin
INPUT=$(cat)
SESSION_ID="${MIMO_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
fi
[ -z "$SESSION_ID" ] && exit 0

# Check for post-compact flag — if not present, exit immediately (zero overhead)
FLAG_FILE="$HOME/.claude/memory-state/${SESSION_ID}-postcompact.flag"
if [ ! -f "$FLAG_FILE" ]; then
    exit 0
fi

# Flag exists — this is the first prompt after compaction
CWD="${MIMO_CWD:-}"
if [ -z "$CWD" ]; then
    CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
fi

# Extract memory sections from CLAUDE.md
CURRENT_STATE=""
KEY_DECISIONS=""
if [ -f "$CWD/CLAUDE.md" ]; then
    CURRENT_STATE=$(sed -n '/^## Memory — Current State/,/^## /{/^## Memory — Current State/d;/^## /d;p;}' "$CWD/CLAUDE.md" | head -15)
    KEY_DECISIONS=$(sed -n '/^## Memory — Key Decisions/,/^## \|^$/{ /^## Memory — Key Decisions/d; /^## /d; p; }' "$CWD/CLAUDE.md" | head -15)
fi

# Get CLAUDE-FULL.md line count
FULL_LINES=""
if [ -f "$CWD/CLAUDE-FULL.md" ]; then
    FULL_LINES=$(wc -l < "$CWD/CLAUDE-FULL.md" | tr -d ' ')
fi

# Build context message
MSG="[MIMO — Post-Compact Context Recovery]"
MSG="${MSG}\nYou just went through compaction. Here's your session state:"
if [ -n "$CURRENT_STATE" ]; then
    MSG="${MSG}\n\nMemory — Current State:\n${CURRENT_STATE}"
fi
if [ -n "$KEY_DECISIONS" ]; then
    MSG="${MSG}\n\nMemory — Key Decisions:\n${KEY_DECISIONS}"
fi
if [ -n "$FULL_LINES" ]; then
    MSG="${MSG}\n\nCLAUDE-FULL.md available (${FULL_LINES} lines) — read specific line ranges as needed."
fi

# Delete flag file (one-shot)
rm -f "$FLAG_FILE"

jq -n --arg ctx "$(echo -e "$MSG")" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
