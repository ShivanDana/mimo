#!/usr/bin/env bash
# mimo — Stop hook memory gate
# Blocks Claude from stopping when a memory save is needed
# Exit 0 = allow stop, Exit 2 = block stop (stderr → Claude as instructions)
set -euo pipefail

STATE_FILE="$HOME/.claude/memory-state/state.json"

# Read stdin JSON
INPUT=$(cat)

# LOOP BREAKER: If stop_hook_active is true, Claude is already continuing
# from a previous stop hook block. Allow it to stop now.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# If no state file, nothing to do
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

THRESHOLD=$(jq -r '.threshold // "clean"' "$STATE_FILE" 2>/dev/null || echo "clean")

# If no save needed, allow stop
if [ "$THRESHOLD" = "clean" ]; then
    exit 0
fi

# IDEMPOTENCY: Check if Claude already performed a save in this response
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
if echo "$LAST_MSG" | grep -qiE '(checkpoint saved|memory saved)'; then
    # Claude already saved — mark done and allow stop
    if [ "$THRESHOLD" = "fullsave_needed" ]; then
        jq '.fullsave_done = true | .checkpoint_done = true | .threshold = "clean"' "$STATE_FILE" \
            > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    elif [ "$THRESHOLD" = "checkpoint_needed" ]; then
        jq '.checkpoint_done = true | .threshold = "clean"' "$STATE_FILE" \
            > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    exit 0
fi

# FULL SAVE (80%+)
if [ "$THRESHOLD" = "fullsave_needed" ]; then
    # Mark as done before blocking (prevents re-trigger after Claude saves)
    jq '.fullsave_done = true | .checkpoint_done = true | .threshold = "clean"' "$STATE_FILE" \
        > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    cat >&2 <<'INSTRUCTIONS'
[MIMO — FULL SAVE REQUIRED — Context at 80%+]

Your context window is nearly full. Perform a complete memory save NOW before context is lost.

1. Read CLAUDE.md and CLAUDE-FULL.md in the project root
2. Update CLAUDE.md "Memory — Current State" section:
   - Today's date
   - Current task/focus and progress
   - Any blockers, open issues, or important context
3. Update CLAUDE.md "Memory — Recent Sessions" with a comprehensive entry for this session (keep max 7, drop oldest)
4. Update CLAUDE.md "Memory — Key Decisions" with any decisions made this session
5. Append a DETAILED session log to CLAUDE-FULL.md:
   - Session number, date, full context of work
   - ALL files changed with descriptions
   - All decisions made with reasoning
   - Current state and suggested next steps
6. Update the line references [L##-L##] in CLAUDE.md to match the new CLAUDE-FULL.md entry

After saving, say "memory saved" and suggest running /compact to free context space.
INSTRUCTIONS
    exit 2
fi

# CHECKPOINT (50%+)
if [ "$THRESHOLD" = "checkpoint_needed" ]; then
    # Mark as done before blocking
    jq '.checkpoint_done = true | .threshold = "clean"' "$STATE_FILE" \
        > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    cat >&2 <<'INSTRUCTIONS'
[MIMO — CHECKPOINT NEEDED — Context at 50%+]

Save a checkpoint of your current work to preserve context:

1. Read CLAUDE.md and CLAUDE-FULL.md in the project root
2. Update CLAUDE.md "Memory — Current State" section:
   - Today's date
   - What you're currently working on
   - Any blockers or key context to preserve
3. Update "Memory — Recent Sessions" — add/update this session entry (max 7)
4. Append a brief session log to CLAUDE-FULL.md:
   - Session number, date, work summary
   - Key files changed
   - State at checkpoint
5. Update line references [L##-L##] in CLAUDE.md

After saving, say "checkpoint saved" and continue working normally.
INSTRUCTIONS
    exit 2
fi

exit 0
