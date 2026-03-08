# mimo Stability Audit — Bug Fixes

## Context
Comprehensive audit of all 9 hooks, install.sh, uninstall.sh, mimo CLI, and documentation. Three Explore agents reviewed the entire codebase. Below are the real issues after triaging false positives, ordered by priority.

**Triage notes — issues dismissed as false positives:**
- "Version file location mismatch" (CRITICAL→FALSE): Source `mimo` reads `$(dirname "$0")/VERSION` for dev use; installed CLI has version hardcoded via sed. By design.
- "TOCTOU curl|bash" (CRITICAL→NOT ACTIONABLE): Inherent to curl|bash pattern. VERSION and install.sh are in the same repo commit. Not a practical concern.
- "stdin consumed multiple times" (CRITICAL→FALSE): `INPUT=$(cat)` captures once, then `echo "$INPUT"` reuses. Correct.
- "Session ID collision in fallback" (CRITICAL→LOW): Requires empty session_id from Claude AND two sessions in same second AND same PID. Effectively impossible.
- "Race between SessionEnd and StatusLine" (HIGH→LOW): SessionEnd runs async at session end; StatusLine stops updating. No race.

---

## Fixes (Priority Order)

### 1. [HIGH] jq write validation — detect empty/corrupt output before mv
**Files**: `hooks/statusline-memory.sh:56-63`, `hooks/memory-gate.sh:44-48,67-68,104-105`, `hooks/session-start.sh:22-24`
**Problem**: If jq fails (corrupted input, out of memory), it may write empty output to the tmp file, then `mv` succeeds — replacing valid state with garbage. With `set -euo pipefail`, jq failure should abort, but the `> file && mv` pattern doesn't guarantee jq's exit code propagates correctly in all shells.
**Fix**: Validate tmp file size before mv:
```bash
jq ... > "${STATE_FILE}.$$.tmp" && [ -s "${STATE_FILE}.$$.tmp" ] && mv "${STATE_FILE}.$$.tmp" "$STATE_FILE"
```
Add `[ -s file ]` (file exists and is non-empty) to all 6 jq-write-then-mv sites across 3 files. If validation fails, the old state file is preserved.

### 2. [HIGH] track-changes.sh missing mkdir -p
**File**: `hooks/track-changes.sh:23`
**Problem**: `echo "$FILE_PATH" >> "$CHANGES_LOG"` fails if `~/.claude/memory-state/` doesn't exist. If PostToolUse fires before SessionStart (edge case with fast first edit), the directory might not exist yet.
**Fix**: Add `mkdir -p "$(dirname "$CHANGES_LOG")"` before the append, or add a directory existence check.

### 3. [HIGH] statusline-memory.sh — printf "%.0f" on non-numeric input
**File**: `hooks/statusline-memory.sh:32`
**Problem**: If `$PERCENTAGE` is empty, non-numeric, or "null" (jq returns "null" on missing field), `printf "%.0f"` either errors or returns 0. With `set -euo pipefail`, this can crash the statusline hook.
**Fix**: Guard with default: `PERCENTAGE=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' | grep -E '^[0-9.]+$' || echo "0")`

### 4. [MEDIUM] `/pcompact` documented but not shipped in repo
**Files**: `README.md:173`, `mimo:337` (help), `install.sh` CLI heredoc help
**Problem**: `/pcompact` is listed as a slash command in README, CLI help, and install.sh help, but the skill directory `skills/pcompact/` doesn't exist in the repo. It may be installed separately to `~/.claude/skills/pcompact/` but isn't part of the mimo install.
**Fix**: Either (a) add the pcompact skill to the repo and install.sh, or (b) remove references from help text and README since it's a separate skill not managed by mimo. Option (b) is simpler and more honest.

### 5. [MEDIUM] Uninstall doesn't clean up `mimo-installed-version` and `mimo-update-check`
**Files**: `uninstall.sh` (missing), install.sh (creates these files)
**Problem**: install.sh writes `mimo-installed-version` and session-start creates `mimo-update-check`, but uninstall.sh doesn't remove them. Minor orphaned files in `~/.claude/memory-state/`.
**Fix**: Add cleanup to uninstall.sh after the hook/skill removal:
```bash
rm -f "$HOME/.claude/memory-state/mimo-installed-version"
rm -f "$HOME/.claude/memory-state/mimo-update-check"
```

### 6. [MEDIUM] install.sh — chmod and sed failures not checked
**File**: `install.sh` (after hook heredocs, around line ~827 and ~1406)
**Problem**: `chmod +x` and `sed -i''` failures are not checked. If they fail, hooks are non-executable or contain `__VERSION__` literals. Install reports success.
**Fix**: Add `|| { error "Failed to ..."; exit 1; }` after chmod and sed commands.

### 7. [MEDIUM] Heredoc drift — source hooks missing version comments
**Files**: All `hooks/*.sh` vs their heredoc copies in `install.sh`
**Problem**: Source files have `# mimo —` comments; install.sh heredocs have `# mimo v__VERSION__ —`. The source files are the development copies; installed copies get version-stamped. This is intentional but creates a maintenance burden — every source change must be replicated in install.sh.
**Fix**: No code change needed. Document in a comment at top of install.sh that heredocs are the authoritative installed versions and source files are for development/testing. (This is already the implicit convention.)

### 8. [LOW] Background curl process never waited on
**File**: `hooks/session-start.sh:59-63`
**Problem**: `(curl ...) &` spawns a background process with no `wait`. It's a fire-and-forget pattern for the update check. The process is harmless (writes one small file) but technically leaves a zombie until the parent exits.
**Fix**: Not worth fixing — the subshell exits quickly and the parent (hook) exits shortly after. Zombies are reaped by init. No action needed.

### 9. [LOW] `wc -l` edge case with missing files
**Files**: `hooks/session-start.sh:266`, `hooks/subagent-context.sh:22`, `hooks/user-prompt-context.sh:38`
**Problem**: If CLAUDE-FULL.md is empty, `wc -l` returns "0" which is fine. If the file check passes but file is deleted between check and `wc -l`, the redirect `< file` fails. Very unlikely.
**Fix**: Not worth fixing — all are guarded by `[ -f "$file" ]` checks. Race window is microseconds.

---

## Documentation Fixes

### 10. [MEDIUM] Add FAQ entry for auto-update
**File**: `README.md` (FAQ section)
**Problem**: v1.5.0 added auto-update but FAQ has no entry explaining how it works.
**Fix**: Add FAQ entry: "How does the auto-update check work?" explaining the 24h TTL, background fetch, `mimo update` command.

### 11. [LOW] CHANGELOG v1.5.0 entry is thin
**File**: `CHANGELOG.md`
**Problem**: v1.5.0 entry is brief compared to previous versions.
**Fix**: Expand with details about which hook implements the check, the 24h cache, background fetch behavior.

---

## Files to Modify

| File | Changes |
|------|---------|
| `hooks/statusline-memory.sh` | Fix #1 (jq validation), Fix #3 (numeric guard) |
| `hooks/memory-gate.sh` | Fix #1 (jq validation on 3 sites) |
| `hooks/session-start.sh` | Fix #1 (jq validation on 1 site) |
| `hooks/track-changes.sh` | Fix #2 (mkdir -p) |
| `install.sh` | Fix #1-3 mirrored in heredocs, Fix #4 (remove /pcompact from CLI help heredoc), Fix #6 (chmod/sed error checks) |
| `uninstall.sh` | Fix #5 (clean up version files) |
| `mimo` | Fix #4 (remove /pcompact from help) |
| `README.md` | Fix #4 (remove /pcompact or add note), Fix #10 (FAQ entry) |
| `CHANGELOG.md` | Fix #11 (expand v1.5.0), add v1.5.1 entry |
| `VERSION` | Bump to 1.5.1 (patch — bug fixes only) |

## Verification

1. **jq validation**: Corrupt a state file with `echo "" > ~/.claude/memory-state/test.json`, run statusline hook — verify it doesn't overwrite with empty
2. **track-changes**: Delete `~/.claude/memory-state/`, run `echo '{"session_id":"test","tool_input":{"file_path":"/tmp/x"}}' | bash hooks/track-changes.sh` — verify it creates the directory and log
3. **statusline numeric guard**: Run `echo '{"context_window":{},"model":{},"session_id":"test","cost":{}}' | bash hooks/statusline-memory.sh` — verify no crash on missing percentage
4. **mimo help**: Verify `/pcompact` is removed (or documented correctly)
5. **uninstall cleanup**: Run uninstall.sh, verify `mimo-installed-version` and `mimo-update-check` are removed
6. **install.sh**: Run install, verify chmod and sed succeed with proper error messages
7. **mimo status**: All 9 hooks OK after changes
8. **Full cycle**: Start a session, do some edits, hit 50% threshold, verify checkpoint works end-to-end
