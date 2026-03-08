# Plan: Smart stale session detection + cleanup

## Context
`mimo status` shows 15 "active" sessions, but only 1 is actually alive. The rest are orphans from sessions that crashed or were force-quit without the SessionEnd hook firing.

**Key insight**: The StatusLine hook is a natural heartbeat — it writes to the state file every few seconds. A state file's `mtime` directly indicates when the session was last alive. Verified:
- Current session (`83f3c4cb`): mtime 20:00 today (seconds ago)
- Dead sessions: mtimes from Mar 1-3 (days ago) or hours ago today

## Changes

### 1. Smart auto-cleanup in session-start.sh using mtime heartbeat
**Files**: `hooks/session-start.sh:35-36`, `install.sh` (session-start heredoc)

Replace the blunt 7-day cleanup with heartbeat-based detection:
```bash
# Before:
# Clean up orphan state files from crashed sessions (7-day threshold)
find "$STATE_DIR" -name "*.json" -mtime +7 -delete 2>/dev/null || true

# After:
# Clean up orphan state files from dead sessions (no statusline heartbeat in 2h)
find "$STATE_DIR" -name "*.json" -mmin +120 -delete 2>/dev/null || true
find "$STATE_DIR" -name "*-changes.log" -mmin +120 -delete 2>/dev/null || true
find "$STATE_DIR" -name "*-postcompact.flag" -mmin +120 -delete 2>/dev/null || true
```

**Why 120 minutes (2 hours)**: Conservative buffer. The StatusLine hook fires every few seconds in an active session, so even an idle-but-open session will have a very recent mtime. 2 hours guarantees no false positives while catching dead sessions quickly. Also cleans up associated files (changes log, postcompact flag) — not just `.json`.

### 2. Show stale vs active in `mimo status`
**Files**: `mimo` (cmd_status), `install.sh` (CLI heredoc)

Instead of showing all sessions as `[ok]`, distinguish live from stale:
```bash
# In the session loop, check mtime:
LAST_UPDATE=$(stat -f %m "$sf" 2>/dev/null || stat -c %Y "$sf" 2>/dev/null || echo "0")
NOW=$(date +%s)
AGE=$(( NOW - LAST_UPDATE ))
if [ "$AGE" -gt 7200 ]; then
    dim "${SID}: ${PCT}%, stale (last seen $(( AGE / 3600 ))h ago)"
else
    ok "${SID}: ${PCT}%, threshold: ${THRESHOLD}"
fi
```

This gives the user clear visibility: `[ok]` = live, `[-]` = stale/dead.

### 3. Add `mimo cleanup` CLI command
**Files**: `mimo`, `install.sh` (CLI heredoc)

Manual cleanup for stale sessions (state files not updated in 2+ hours):
```bash
cmd_cleanup() {
    echo ""
    printf "${BOLD}mimo cleanup${NC}\n"
    echo ""

    NOW=$(date +%s)
    COUNT=0
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        LAST_UPDATE=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "0")
        AGE=$(( NOW - LAST_UPDATE ))
        if [ "$AGE" -gt 7200 ]; then
            SID=$(basename "$f" .json)
            rm -f "$f" "$STATE_DIR/${SID}-changes.log" "$STATE_DIR/${SID}-postcompact.flag"
            COUNT=$((COUNT + 1))
        fi
    done

    if [ "$COUNT" -gt 0 ]; then
        info "Removed $COUNT stale session(s)"
    else
        info "No stale sessions found (all sessions are active)"
    fi
    echo ""
}
```

Uses the same 2-hour heartbeat threshold — only removes sessions that are actually dead, never kills a live session.

Add to case statement: `cleanup) cmd_cleanup ;;`
Add to help: `  cleanup     Remove stale session state files`

### 4. Update help text and README
- Add `mimo cleanup` to `cmd_help()` in both source `mimo` and install.sh CLI heredoc
- Add `mimo cleanup` to README CLI section

## Files to Modify

| File | Change |
|------|--------|
| `hooks/session-start.sh` | Replace 7-day cleanup with 2h heartbeat cleanup (json + logs + flags) |
| `mimo` | Add `cmd_cleanup()`, update `cmd_status()` stale detection, update help + case |
| `install.sh` | Mirror all changes in session-start heredoc + CLI heredoc |
| `README.md` | Add `mimo cleanup` to CLI section |

## Verification
1. `mimo status` — current session shows `[ok]`, stale sessions show `[-]` with "stale (Xh ago)"
2. `mimo cleanup` — removes only stale sessions, reports count, preserves active session
3. `mimo status` after cleanup — shows only the active session
4. `mimo help` — lists `cleanup` command
5. Start a new session — verify old stale files auto-cleaned on start (if >2h old)
