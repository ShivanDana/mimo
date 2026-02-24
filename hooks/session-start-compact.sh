#!/usr/bin/env bash
# mimo — SessionStart hook (post-compact)
# Lightweight context injection after compaction. Does NOT reset state flags.
set -euo pipefail

CWD=$(cat | jq -r '.cwd // "."')

MSG="[MIMO] Continuing after compaction. Read CLAUDE.md 'Memory' sections for prior context."

if [ -f "$CWD/CLAUDE-FULL.md" ]; then
    LINES=$(wc -l < "$CWD/CLAUDE-FULL.md" | tr -d ' ')
    MSG="${MSG} CLAUDE-FULL.md available (${LINES} lines)."
fi

jq -n --arg ctx "$MSG" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
