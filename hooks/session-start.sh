#!/usr/bin/env bash
# mimo — SessionStart hook (startup/resume)
# Resets state for new session, auto-inits project, injects memory context into Claude
set -euo pipefail

STATE_DIR="$HOME/.claude/memory-state"
BACKUP_DIR="$HOME/.claude/backups"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# Read stdin JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

# Per-session state file (isolates concurrent sessions)
if [ -z "$SESSION_ID" ]; then SESSION_ID="fallback-$$-$(date +%s)"; fi
STATE_FILE="$STATE_DIR/${SESSION_ID}.json"

# Create state for new session (idempotent — preserves existing state on resume)
if [ ! -f "$STATE_FILE" ]; then
    jq -n --arg sid "$SESSION_ID" \
        '{session_id: $sid, percentage: 0, threshold: "clean", checkpoint_done: false, fullsave_done: false}' \
        > "${STATE_FILE}.$$.tmp" && mv "${STATE_FILE}.$$.tmp" "$STATE_FILE"
fi

# Export env vars for other hooks via CLAUDE_ENV_FILE
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "export MIMO_SESSION_ID=\"$SESSION_ID\"" >> "$CLAUDE_ENV_FILE"
    echo "export MIMO_STATE_FILE=\"$STATE_FILE\"" >> "$CLAUDE_ENV_FILE"
    echo "export MIMO_CHANGES_LOG=\"$STATE_DIR/${SESSION_ID}-changes.log\"" >> "$CLAUDE_ENV_FILE"
    echo "export MIMO_CWD=\"$CWD\"" >> "$CLAUDE_ENV_FILE"
fi

# Clean up orphan state files from crashed sessions (7-day threshold)
find "$STATE_DIR" -name "*.json" -mtime +7 -delete 2>/dev/null || true

# ─── Auto-update check (at most once per 24h, never blocks) ──────────────────
UPDATE_CHECK_FILE="$STATE_DIR/mimo-update-check"
INSTALLED_VERSION_FILE="$STATE_DIR/mimo-installed-version"
INSTALLED_VERSION=$(cat "$INSTALLED_VERSION_FILE" 2>/dev/null || echo "")
UPDATE_MSG=""

if [ -n "$INSTALLED_VERSION" ]; then
    SHOULD_CHECK=false
    if [ ! -f "$UPDATE_CHECK_FILE" ]; then
        SHOULD_CHECK=true
    else
        # Check if file is older than 24h (86400 seconds)
        LAST_CHECK=$(stat -f %m "$UPDATE_CHECK_FILE" 2>/dev/null || stat -c %Y "$UPDATE_CHECK_FILE" 2>/dev/null || echo "0")
        NOW=$(date +%s)
        if [ $(( NOW - LAST_CHECK )) -gt 86400 ]; then
            SHOULD_CHECK=true
        fi
    fi

    if [ "$SHOULD_CHECK" = "true" ]; then
        # Background fetch — never blocks session start
        (
            REMOTE=$(curl -fsSL --max-time 3 \
                "https://raw.githubusercontent.com/ShivanDana/mimo/main/VERSION" 2>/dev/null | tr -d '[:space:]')
            [ -n "$REMOTE" ] && echo "$REMOTE" > "$UPDATE_CHECK_FILE"
        ) &
    fi

    # Read cached remote version from PREVIOUS successful check
    REMOTE_VERSION=$(cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo "")
    if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$INSTALLED_VERSION" ]; then
        UPDATE_MSG="Update available: mimo v${INSTALLED_VERSION} → v${REMOTE_VERSION}. Run: mimo update"
    fi
fi

# ─── Auto-init: create CLAUDE.md and CLAUDE-FULL.md if missing ───────────────
WORKFLOW_MARKER="## Workflow Orchestration"
MEMORY_MARKER="Memory — Current State"
AUTO_INIT_MSG=""

if [ ! -f "$CWD/CLAUDE.md" ]; then
    # Create fresh: workflow block at top, memory sections at bottom
    cat > "$CWD/CLAUDE.md" << 'MIMO_CLAUDE_MD'
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow Orchestration

### 1. Plan Mode Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately – don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes – don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests – then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

## Memory — Current State
<!-- Updated by mimo checkpoint/save hooks -->
Last session: (not yet set)
Current focus: (not yet set)
Blockers: None

## Memory — Recent Sessions
<!-- Rolling list, max 7 entries. Oldest dropped. -->
<!-- Each entry has a line reference to CLAUDE-FULL.md -->

## Memory — Key Decisions
<!-- One-liner + CLAUDE-FULL.md line ref for reasoning -->
MIMO_CLAUDE_MD
    AUTO_INIT_MSG="Auto-initialized CLAUDE.md for this project."

elif ! grep -q "$MEMORY_MARKER" "$CWD/CLAUDE.md" 2>/dev/null; then
    # Existing CLAUDE.md but no memory sections — prepend workflow (if missing), append memory
    if ! grep -q "$WORKFLOW_MARKER" "$CWD/CLAUDE.md" 2>/dev/null; then
        TMPFILE=$(mktemp)
        cat > "$TMPFILE" << 'WORKFLOW_BLOCK'
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow Orchestration

### 1. Plan Mode Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately – don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes – don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests – then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

WORKFLOW_BLOCK
        cat "$CWD/CLAUDE.md" >> "$TMPFILE"
        mv "$TMPFILE" "$CWD/CLAUDE.md"
    fi

    # Append memory sections at bottom
    cat >> "$CWD/CLAUDE.md" << 'MEMORY_SECTIONS'

## Memory — Current State
<!-- Updated by mimo checkpoint/save hooks -->
Last session: (not yet set)
Current focus: (not yet set)
Blockers: None

## Memory — Recent Sessions
<!-- Rolling list, max 7 entries. Oldest dropped. -->
<!-- Each entry has a line reference to CLAUDE-FULL.md -->

## Memory — Key Decisions
<!-- One-liner + CLAUDE-FULL.md line ref for reasoning -->
MEMORY_SECTIONS
    AUTO_INIT_MSG="Auto-initialized memory sections in existing CLAUDE.md."
fi

# CLAUDE-FULL.md
if [ ! -f "$CWD/CLAUDE-FULL.md" ]; then
    cat > "$CWD/CLAUDE-FULL.md" << 'ARCHIVE'
# Deep Memory Archive

<!-- This file stores detailed session logs for long-term context preservation. -->
<!-- CLAUDE.md references specific line ranges here (e.g., [CLAUDE-FULL.md L7-L14]). -->
<!-- Append new sessions at the end. Do not delete old entries. -->

## Sessions
ARCHIVE
    if [ -z "$AUTO_INIT_MSG" ]; then
        AUTO_INIT_MSG="Auto-initialized CLAUDE-FULL.md for this project."
    else
        AUTO_INIT_MSG="${AUTO_INIT_MSG} Created CLAUDE-FULL.md."
    fi
fi

# ─── Build context message ───────────────────────────────────────────────────
MSG="[MIMO ACTIVE] Memory hooks enabled. Checkpoints at 50% context, full save at 80%."

if [ -n "$AUTO_INIT_MSG" ]; then
    MSG="${MSG}\n${AUTO_INIT_MSG}"
fi

# Check for deep memory archive
if [ -f "$CWD/CLAUDE-FULL.md" ]; then
    LINES=$(wc -l < "$CWD/CLAUDE-FULL.md" | tr -d ' ')
    MSG="${MSG}\nDeep memory archive: CLAUDE-FULL.md (${LINES} lines). Read specific line ranges as needed."
fi

# Include update notification if available
if [ -n "$UPDATE_MSG" ]; then
    MSG="${MSG}\n${UPDATE_MSG}"
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
