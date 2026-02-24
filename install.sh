#!/usr/bin/env bash
# mimo installer — hook-based memory system for Claude Code
# Usage: curl -fsSL https://raw.githubusercontent.com/ShivanDana/mimo/main/install.sh | bash
set -euo pipefail

MIMO_VERSION="1.0.0"
HOOKS_DIR="$HOME/.claude/hooks"
STATE_DIR="$HOME/.claude/memory-state"
BACKUP_DIR="$HOME/.claude/backups"
SETTINGS_FILE="$HOME/.claude/settings.json"
CLI_DIR="$HOME/.local/bin"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${GREEN}[mimo]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[mimo]${NC} %s\n" "$1"; }
error() { printf "${RED}[mimo]${NC} %s\n" "$1" >&2; }
step()  { printf "${BOLD}[%s/5]${NC} %s\n" "$1" "$2"; }

# ─── Step 1: Preflight checks ────────────────────────────────────────────────
step 1 "Preflight checks"

if ! command -v jq &>/dev/null; then
    error "jq is required but not installed."
    echo ""
    echo "Install jq:"
    echo "  macOS:  brew install jq"
    echo "  Ubuntu: sudo apt-get install jq"
    echo "  Other:  https://jqlang.github.io/jq/download/"
    exit 1
fi

BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
if [ "$BASH_MAJOR" -lt 3 ]; then
    error "bash 3.2+ required (found ${BASH_VERSION:-unknown})"
    exit 1
fi

if [ ! -d "$HOME/.claude" ]; then
    error "~/.claude/ not found. Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

info "jq $(jq --version 2>&1 | tr -d 'jq-'), bash ${BASH_VERSION}, ~/.claude/ exists"

# ─── Step 2: Write hook scripts ──────────────────────────────────────────────
step 2 "Installing hook scripts"

mkdir -p "$HOOKS_DIR" "$STATE_DIR" "$BACKUP_DIR"

cat > "$HOOKS_DIR/statusline-memory.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
# mimo v__VERSION__ — StatusLine context detector + ANSI progress bar
# Reads context usage from stdin JSON, writes threshold state, outputs colored bar
set -euo pipefail

# Thresholds — lower for testing (e.g., CHECKPOINT=5, FULLSAVE=15)
CHECKPOINT_THRESHOLD=50
FULLSAVE_THRESHOLD=80

STATE_DIR="$HOME/.claude/memory-state"
STATE_FILE="$STATE_DIR/state.json"
BAR_WIDTH=20

mkdir -p "$STATE_DIR"

# Read full stdin JSON
INPUT=$(cat)

# Extract fields
PERCENTAGE=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "?"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "none"')
COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')

# Round percentage to integer
PCT_INT=$(printf "%.0f" "$PERCENTAGE")
if [ "$PCT_INT" -gt 100 ]; then PCT_INT=100; fi
if [ "$PCT_INT" -lt 0 ]; then PCT_INT=0; fi

# Check if session changed — reset state if so
CURRENT_SESSION=""
if [ -f "$STATE_FILE" ]; then
    CURRENT_SESSION=$(jq -r '.session_id // ""' "$STATE_FILE" 2>/dev/null || echo "")
fi

if [ "$CURRENT_SESSION" != "$SESSION_ID" ]; then
    jq -n --arg sid "$SESSION_ID" \
        '{session_id: $sid, percentage: 0, threshold: "clean", checkpoint_done: false, fullsave_done: false}' \
        > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

# Read current done flags
CHECKPOINT_DONE=$(jq -r '.checkpoint_done // false' "$STATE_FILE" 2>/dev/null || echo "false")
FULLSAVE_DONE=$(jq -r '.fullsave_done // false' "$STATE_FILE" 2>/dev/null || echo "false")

# Determine threshold
THRESHOLD="clean"
if [ "$PCT_INT" -ge "$FULLSAVE_THRESHOLD" ] && [ "$FULLSAVE_DONE" = "false" ]; then
    THRESHOLD="fullsave_needed"
elif [ "$PCT_INT" -ge "$CHECKPOINT_THRESHOLD" ] && [ "$CHECKPOINT_DONE" = "false" ]; then
    THRESHOLD="checkpoint_needed"
fi

# Update state file (atomic write)
jq -n \
    --arg sid "$SESSION_ID" \
    --argjson pct "$PCT_INT" \
    --arg threshold "$THRESHOLD" \
    --argjson cp_done "$([ "$CHECKPOINT_DONE" = "true" ] && echo true || echo false)" \
    --argjson fs_done "$([ "$FULLSAVE_DONE" = "true" ] && echo true || echo false)" \
    '{session_id: $sid, percentage: $pct, threshold: $threshold, checkpoint_done: $cp_done, fullsave_done: $fs_done}' \
    > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# Build progress bar
FILLED=$(( PCT_INT * BAR_WIDTH / 100 ))
if [ "$FILLED" -gt "$BAR_WIDTH" ]; then FILLED=$BAR_WIDTH; fi
EMPTY=$(( BAR_WIDTH - FILLED ))

BAR_FILLED=$(printf '%*s' "$FILLED" '' | tr ' ' '█')
BAR_EMPTY=$(printf '%*s' "$EMPTY" '' | tr ' ' '░')
BAR="${BAR_FILLED}${BAR_EMPTY}"

# Choose ANSI color code
if [ "$PCT_INT" -ge "$FULLSAVE_THRESHOLD" ]; then
    CC="31"  # Red
elif [ "$PCT_INT" -ge "$CHECKPOINT_THRESHOLD" ]; then
    CC="33"  # Yellow
else
    CC="32"  # Green
fi

# Threshold indicator
INDICATOR=""
if [ "$THRESHOLD" = "fullsave_needed" ]; then
    INDICATOR=" \033[31m!\033[0m"
elif [ "$THRESHOLD" = "checkpoint_needed" ]; then
    INDICATOR=" \033[33m*\033[0m"
fi

# Output ANSI statusline
printf '\033[%sm%s %d%%\033[0m%b │ %s │ $%.2f' "$CC" "$BAR" "$PCT_INT" "$INDICATOR" "$MODEL" "$COST"
HOOK_EOF

cat > "$HOOKS_DIR/memory-gate.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
# mimo v__VERSION__ — Stop hook memory gate
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
HOOK_EOF

cat > "$HOOKS_DIR/precompact-save.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
# mimo v__VERSION__ — PreCompact transcript backup
# Copies transcript before compaction destroys it. Runs async, cannot block.
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
HOOK_EOF

cat > "$HOOKS_DIR/session-start.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
# mimo v__VERSION__ — SessionStart hook (startup/resume)
# Resets state for new session, auto-inits project, injects memory context into Claude
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
HOOK_EOF

cat > "$HOOKS_DIR/session-start-compact.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
# mimo v__VERSION__ — SessionStart hook (post-compact)
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
HOOK_EOF

cat > "$HOOKS_DIR/session-end-backup.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
# mimo v__VERSION__ — SessionEnd transcript backup
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
HOOK_EOF

# Stamp version into all hooks
sed -i'' -e "s/__VERSION__/${MIMO_VERSION}/g" "$HOOKS_DIR"/*.sh

# Make all hooks executable
chmod +x "$HOOKS_DIR"/*.sh

info "Installed 6 hooks to $HOOKS_DIR"

# ─── Step 3: Merge settings.json ─────────────────────────────────────────────
step 3 "Configuring settings.json"

# Define mimo's hook configuration as JSON
MIMO_HOOKS=$(cat <<'MJSON'
{
  "SessionStart": [
    {
      "matcher": "startup|resume",
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/session-start.sh", "timeout": 10}
      ]
    },
    {
      "matcher": "compact",
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/session-start-compact.sh", "timeout": 10}
      ]
    }
  ],
  "Stop": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/memory-gate.sh", "timeout": 10}
      ]
    }
  ],
  "PreCompact": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/precompact-save.sh", "async": true, "timeout": 30}
      ]
    }
  ],
  "SessionEnd": [
    {
      "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/session-end-backup.sh", "async": true, "timeout": 30}
      ]
    }
  ]
}
MJSON
)

MIMO_STATUSLINE='{"type": "command", "command": "bash ~/.claude/hooks/statusline-memory.sh"}'

if [ ! -f "$SETTINGS_FILE" ]; then
    # Fresh install — create settings with only mimo entries
    echo "$MIMO_HOOKS" | jq --argjson sl "$MIMO_STATUSLINE" \
        '{statusLine: $sl, hooks: .}' > "$SETTINGS_FILE"
    info "Created $SETTINGS_FILE"
else
    # Backup existing settings
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.mimo-backup"
    info "Backed up settings to settings.json.mimo-backup"

    # Check for non-mimo statusLine
    EXISTING_SL=$(jq -r '.statusLine.command // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_SL" ] && ! echo "$EXISTING_SL" | grep -q '/.claude/hooks/'; then
        warn "Replacing existing statusLine: $EXISTING_SL (backup preserved)"
    fi

    # Merge: remove old mimo hooks, append new ones, set statusLine
    jq --argjson mimo "$MIMO_HOOKS" --argjson sl "$MIMO_STATUSLINE" '
        # Filter out mimo hook groups from an array
        def remove_mimo: [.[]? | select((.hooks // []) | any(.command // "" | contains("/.claude/hooks/")) | not)];

        # Ensure .hooks exists
        .hooks //= {} |

        # For each event type: remove old mimo hooks, append new ones
        .hooks.SessionStart = ((.hooks.SessionStart // []) | remove_mimo) + $mimo.SessionStart |
        .hooks.Stop = ((.hooks.Stop // []) | remove_mimo) + $mimo.Stop |
        .hooks.PreCompact = ((.hooks.PreCompact // []) | remove_mimo) + $mimo.PreCompact |
        .hooks.SessionEnd = ((.hooks.SessionEnd // []) | remove_mimo) + $mimo.SessionEnd |

        # Set statusLine
        .statusLine = $sl
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"

    # Validate output is valid JSON before replacing
    if jq empty "${SETTINGS_FILE}.tmp" 2>/dev/null; then
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        info "Merged hooks into existing settings (user settings preserved)"
    else
        error "Merge produced invalid JSON. Restoring backup."
        mv "${SETTINGS_FILE}.mimo-backup" "$SETTINGS_FILE"
        rm -f "${SETTINGS_FILE}.tmp"
        exit 1
    fi
fi

# ─── Step 4: Install mimo CLI ────────────────────────────────────────────────
step 4 "Installing mimo CLI"

mkdir -p "$CLI_DIR"

cat > "$CLI_DIR/mimo" << 'CLI_EOF'
#!/usr/bin/env bash
# mimo — CLI for the mimo memory system for Claude Code
set -euo pipefail

MIMO_VERSION="__VERSION__"
HOOKS_DIR="$HOME/.claude/hooks"
STATE_FILE="$HOME/.claude/memory-state/state.json"
SETTINGS_FILE="$HOME/.claude/settings.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "  ${GREEN}[ok]${NC} %s\n" "$1"; }
fail() { printf "  ${RED}[!!]${NC} %s\n" "$1"; }
dim()  { printf "  ${YELLOW}[-]${NC}  %s\n" "$1"; }

cmd_version() {
    echo "mimo v${MIMO_VERSION}"
}

cmd_status() {
    echo ""
    printf "${BOLD}mimo status${NC}\n"
    echo ""

    # Hook scripts
    printf "${BOLD}Hook scripts:${NC}\n"
    ALL_HOOKS_OK=true
    for hook in statusline-memory.sh memory-gate.sh precompact-save.sh session-start.sh session-start-compact.sh session-end-backup.sh; do
        if [ -x "$HOOKS_DIR/$hook" ]; then
            ok "$hook"
        else
            fail "$hook (missing or not executable)"
            ALL_HOOKS_OK=false
        fi
    done

    echo ""
    printf "${BOLD}Settings:${NC}\n"
    if [ -f "$SETTINGS_FILE" ]; then
        HOOK_COUNT=$(jq '[.hooks[][]?.hooks[]? | select(.command // "" | contains("/.claude/hooks/"))] | length' "$SETTINGS_FILE" 2>/dev/null || echo "0")
        if [ "$HOOK_COUNT" -gt 0 ]; then
            ok "Hooks registered in settings.json ($HOOK_COUNT entries)"
        else
            fail "No mimo hooks found in settings.json"
        fi

        SL=$(jq -r '.statusLine.command // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
        if echo "$SL" | grep -q 'statusline-memory'; then
            ok "StatusLine configured"
        else
            fail "StatusLine not configured"
        fi
    else
        fail "settings.json not found"
    fi

    echo ""
    printf "${BOLD}Dependencies:${NC}\n"
    if command -v jq &>/dev/null; then
        ok "jq $(jq --version 2>&1 | tr -d 'jq-')"
    else
        fail "jq not installed"
    fi
    ok "bash ${BASH_VERSION}"

    echo ""
    printf "${BOLD}Session state:${NC}\n"
    if [ -f "$STATE_FILE" ]; then
        PCT=$(jq -r '.percentage // 0' "$STATE_FILE" 2>/dev/null || echo "0")
        THRESHOLD=$(jq -r '.threshold // "clean"' "$STATE_FILE" 2>/dev/null || echo "clean")
        ok "Context: ${PCT}%, threshold: ${THRESHOLD}"
    else
        dim "No active session"
    fi

    echo ""
    printf "${BOLD}Current project:${NC}\n"
    if [ -f "CLAUDE.md" ]; then
        if grep -q 'Memory — Current State' CLAUDE.md 2>/dev/null; then
            ok "CLAUDE.md has memory sections"
        else
            dim "CLAUDE.md exists but no memory sections (run: mimo init)"
        fi
    else
        dim "No CLAUDE.md in current directory"
    fi
    if [ -f "CLAUDE-FULL.md" ]; then
        LINES=$(wc -l < "CLAUDE-FULL.md" | tr -d ' ')
        ok "CLAUDE-FULL.md (${LINES} lines)"
    else
        dim "No CLAUDE-FULL.md (run: mimo init)"
    fi

    echo ""
}

cmd_init() {
    echo ""
    printf "${BOLD}mimo init${NC} — setting up memory for this project\n"
    echo ""

    WORKFLOW_MARKER="## Workflow Orchestration"
    MEMORY_MARKER="Memory — Current State"

    # CLAUDE.md
    if [ ! -f "CLAUDE.md" ]; then
        # Create fresh: workflow block at top, memory sections at bottom
        cat > CLAUDE.md << 'MIMO_CLAUDE_MD'
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
        ok "Created CLAUDE.md with workflow guidance and memory sections"

    elif grep -q "$MEMORY_MARKER" CLAUDE.md 2>/dev/null; then
        ok "CLAUDE.md already has memory sections (skipping)"

    else
        # Existing CLAUDE.md without memory sections
        if ! grep -q "$WORKFLOW_MARKER" CLAUDE.md 2>/dev/null; then
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
            cat CLAUDE.md >> "$TMPFILE"
            mv "$TMPFILE" CLAUDE.md
            ok "Prepended workflow guidance to CLAUDE.md"
        fi

        # Append memory sections at bottom
        cat >> CLAUDE.md << 'MEMORY_SECTIONS'

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
        ok "Added memory sections to CLAUDE.md"
    fi

    # CLAUDE-FULL.md
    if [ -f "CLAUDE-FULL.md" ]; then
        ok "CLAUDE-FULL.md already exists (skipping)"
    else
        cat > CLAUDE-FULL.md << 'ARCHIVE'
# Deep Memory Archive

<!-- This file stores detailed session logs for long-term context preservation. -->
<!-- CLAUDE.md references specific line ranges here (e.g., [CLAUDE-FULL.md L7-L14]). -->
<!-- Append new sessions at the end. Do not delete old entries. -->

## Sessions
ARCHIVE
        ok "Created CLAUDE-FULL.md"
    fi

    echo ""
    printf "${GREEN}[mimo]${NC} Project initialized. Start a Claude Code session to begin building memory.\n"
    echo ""
}

cmd_uninstall() {
    if [ -f "$HOME/.local/bin/mimo-uninstall" ]; then
        exec bash "$HOME/.local/bin/mimo-uninstall"
    else
        printf "${RED}[mimo]${NC} mimo-uninstall not found. Run manually:\n" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/ShivanDana/mimo/main/uninstall.sh | bash"
        exit 1
    fi
}

cmd_help() {
    cat << HELP
mimo v${MIMO_VERSION} — hook-based memory system for Claude Code

Usage: mimo <command>

Commands:
  init        Re-initialize memory files in the current project
  status      Show diagnostic information
  version     Print version
  uninstall   Remove mimo from your system
  help        Show this help

Getting started:
  1. mimo is already installed (hooks + settings configured)
  2. Start a Claude Code session — mimo auto-initializes your project
  3. Use 'mimo init' to manually reset memory files if needed

Learn more: https://github.com/ShivanDana/mimo
HELP
}

case "${1:-help}" in
    init)      cmd_init ;;
    status)    cmd_status ;;
    version)   cmd_version ;;
    uninstall) cmd_uninstall ;;
    help|--help|-h) cmd_help ;;
    *)
        printf "${RED}[mimo]${NC} Unknown command: %s\n" "$1" >&2
        cmd_help
        exit 1
        ;;
esac
CLI_EOF

# Stamp version
sed -i'' -e "s/__VERSION__/${MIMO_VERSION}/g" "$CLI_DIR/mimo"
chmod +x "$CLI_DIR/mimo"

# Write the uninstall helper
cat > "$CLI_DIR/mimo-uninstall" << 'UNINST_EOF'
#!/usr/bin/env bash
# mimo uninstaller — removes hooks, settings entries, and CLI
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${GREEN}[mimo]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[mimo]${NC} %s\n" "$1"; }

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo ""
printf "${BOLD}Uninstalling mimo${NC}\n"
echo ""

# 1. Remove hook scripts
for hook in statusline-memory.sh memory-gate.sh precompact-save.sh session-start.sh session-start-compact.sh session-end-backup.sh; do
    if [ -f "$HOOKS_DIR/$hook" ]; then
        rm "$HOOKS_DIR/$hook"
        info "Removed $hook"
    fi
done

# 2. Remove mimo entries from settings.json
if [ -f "$SETTINGS_FILE" ]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.mimo-uninstall-backup"

    jq '
        def remove_mimo: [.[]? | select((.hooks // []) | any(.command // "" | contains("/.claude/hooks/")) | not)];

        # Remove mimo hooks from each event type
        (if .hooks then
            .hooks |= with_entries(
                .value |= remove_mimo |
                select(.value | length > 0)
            )
        else . end) |

        # Remove statusLine if it is mimo
        (if (.statusLine.command // "" | contains("/.claude/hooks/")) then del(.statusLine) else . end) |

        # Clean up empty hooks object
        (if (.hooks | length) == 0 then del(.hooks) else . end)
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"

    if jq empty "${SETTINGS_FILE}.tmp" 2>/dev/null; then
        mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        info "Removed mimo entries from settings.json"
    else
        warn "Could not update settings.json (backup at settings.json.mimo-uninstall-backup)"
        rm -f "${SETTINGS_FILE}.tmp"
    fi
fi

# 3. Remove CLI
rm -f "$HOME/.local/bin/mimo"
rm -f "$HOME/.local/bin/mimo-uninstall"
info "Removed mimo CLI"

# 4. Preserve user data
echo ""
warn "Preserved (your data):"
echo "  ~/.claude/backups/       — transcript backups"
echo "  ~/.claude/memory-state/  — session state"
echo "  Project CLAUDE.md and CLAUDE-FULL.md files"
echo ""
info "mimo has been uninstalled. Your memory data is intact."
echo ""
UNINST_EOF

chmod +x "$CLI_DIR/mimo-uninstall"

info "Installed mimo CLI to $CLI_DIR/mimo"

# Check if ~/.local/bin is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    echo ""
    warn "\$HOME/.local/bin is not in your PATH. Add it:"
    echo ""
    echo "  # Add to your ~/.zshrc or ~/.bashrc:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# ─── Step 5: Done ────────────────────────────────────────────────────────────
step 5 "Installation complete"

echo ""
printf "${BOLD}${GREEN}mimo v${MIMO_VERSION} installed successfully!${NC}\n"
echo ""
echo "Next steps:"
echo "  1. cd into your project directory"
echo "  2. Start a Claude Code session — mimo auto-initializes your project"
echo ""
echo "Commands:"
echo "  mimo status     — check installation health"
echo "  mimo init       — re-initialize memory files in current project"
echo "  mimo uninstall  — remove mimo"
echo ""
