# Plan: Implement New Claude Code Hook Features in mimo

## Context

mimo is a hook-based memory system for Claude Code that auto-saves session context at 50% and 80% context window usage. It currently uses 6 hooks (SessionStart, Stop, PreCompact, SessionEnd, StatusLine). The new Claude Code hooks documentation introduces several new hook events and features that can directly improve mimo's reliability and memory save quality.

Additionally, there's a bug: the source hook files in `hooks/` use a single `state.json` while the changelog (v1.3.0) claims per-session isolation was implemented. The installed versions (written by `install.sh` heredocs) may differ from the source files.

---

## Changes

### 1. Bug Fix: Per-Session State in Source Hook Files

The source files use `STATE_FILE="$HOME/.claude/memory-state/state.json"` (single file) but should use `$HOME/.claude/memory-state/${SESSION_ID}.json` for multi-session safety.

**Files to fix:**
- `hooks/memory-gate.sh:7` - extract session_id from stdin JSON, build per-session path
- `hooks/session-start.sh:7` - already has SESSION_ID, just use it in the path
- `hooks/statusline-memory.sh:11` - extract session_id, use per-session path
- `hooks/session-end-backup.sh:7` - extract session_id, clean up correct file

**Pattern to use:**
```bash
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' | tr -cd 'a-zA-Z0-9-')
[ -z "$SESSION_ID" ] && SESSION_ID="fallback-$$-$(date +%s)"
STATE_FILE="$STATE_DIR/${SESSION_ID}.json"
```

### 2. CLAUDE_ENV_FILE Integration in SessionStart

Use the new `CLAUDE_ENV_FILE` feature so `session-start.sh` persists env vars (`MIMO_SESSION_ID`, `MIMO_STATE_FILE`, `MIMO_CHANGES_LOG`, `MIMO_CWD`) for all subsequent Bash tool calls and hooks to use.

**File:** `hooks/session-start.sh` - add after state reset:
```bash
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export MIMO_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
  echo "export MIMO_STATE_FILE=$STATE_FILE" >> "$CLAUDE_ENV_FILE"
  echo "export MIMO_CHANGES_LOG=$STATE_DIR/${SESSION_ID}-changes.txt" >> "$CLAUDE_ENV_FILE"
  echo "export MIMO_CWD=$CWD" >> "$CLAUDE_ENV_FILE"
fi
```

Update other hooks to prefer `$MIMO_STATE_FILE` with fallback to manual extraction.

### 3. New Hook: File Change Tracking via PostToolUse

**New file:** `hooks/track-changes.sh`
- **Hook event:** `PostToolUse`, matcher: `Write|Edit`
- **Runs async** so it never blocks Claude
- Extracts `tool_input.file_path` from stdin JSON
- Appends to `~/.claude/memory-state/<session-id>-changes.txt`

**Integration with `memory-gate.sh`:** Update the checkpoint/fullsave instruction text to tell Claude to read the changes log for a reliable list of all files modified during the session.

**Settings registration:**
```json
"PostToolUse": [
  {
    "matcher": "Write|Edit",
    "hooks": [
      {"type": "command", "command": "bash ~/.claude/hooks/track-changes.sh", "async": true, "timeout": 5}
    ]
  }
]
```

### 4. New Hook: CLAUDE.md Integrity Check via InstructionsLoaded

**New file:** `hooks/check-claude-md.sh`
- **Hook event:** `InstructionsLoaded` (no matcher support, fires on every load)
- Checks if the loaded file is `CLAUDE.md` and verifies the `Memory — Current State` marker exists
- If missing, outputs a `systemMessage` warning so Claude can self-repair
- Lightweight, non-blocking

**Settings registration:**
```json
"InstructionsLoaded": [
  {
    "hooks": [
      {"type": "command", "command": "bash ~/.claude/hooks/check-claude-md.sh", "timeout": 5}
    ]
  }
]
```

### 5. Update install.sh, uninstall.sh, and CLI

- **install.sh:** Add `track-changes.sh` and `check-claude-md.sh` to Step 2 (hook installation). Register `PostToolUse` and `InstructionsLoaded` in the settings merge jq expression (Step 4).
- **uninstall.sh:** Add cleanup for the 2 new hook files and changes log files.
- **mimo CLI:** Add new hooks to the `cmd_status()` verification list.

---

## Files Modified

| File | Action | Description |
|------|--------|-------------|
| `hooks/memory-gate.sh` | Modify | Per-session state fix; add changes log reference in save instructions; prefer `$MIMO_STATE_FILE` |
| `hooks/session-start.sh` | Modify | Per-session state fix; write to `CLAUDE_ENV_FILE`; init empty changes log |
| `hooks/session-start-compact.sh` | Modify | Prefer `$MIMO_CWD` env var with fallback |
| `hooks/session-end-backup.sh` | Modify | Per-session cleanup fix; also clean up changes log |
| `hooks/statusline-memory.sh` | Modify | Per-session state fix; prefer `$MIMO_STATE_FILE` |
| `hooks/track-changes.sh` | **New** | PostToolUse handler logging Write/Edit file paths |
| `hooks/check-claude-md.sh` | **New** | InstructionsLoaded handler verifying memory sections |
| `install.sh` | Modify | Add new scripts and hook registrations |
| `uninstall.sh` | Modify | Clean up new files |
| `mimo` | Modify | Add new hooks to status check |

## Features Evaluated and Skipped

- **Prompt-based Stop hook**: Adds latency/cost to every stop. Current grep for "checkpoint saved" is fast and reliable.
- **UserPromptSubmit context injection**: Would require fragile keyword matching in bash against CLAUDE-FULL.md. Claude already reads CLAUDE.md at session start.
- **Skill frontmatter hooks**: No clear use case for /save and /save-full since they're pure instruction text.

## Verification

1. Run `mimo status` to verify all 8 hooks (6 existing + 2 new) are installed and registered
2. Start a new session — verify `MIMO_STATE_FILE` is set in env, per-session state file created
3. Write/edit a file — verify `~/.claude/memory-state/<session-id>-changes.txt` is populated
4. Manually delete memory sections from CLAUDE.md, restart — verify warning message appears
5. Run concurrent sessions — verify separate state files, no interference
6. Run `mimo uninstall` — verify all 8 hooks and changes logs are cleaned up
