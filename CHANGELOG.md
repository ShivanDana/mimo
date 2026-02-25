# Changelog

All notable changes to mimo will be documented in this file.

## [1.3.0] - 2026-02-25

### Fixed
- **Save interruption now resumes work**: After a checkpoint (50%) or full save (80%) interruption, Claude now immediately picks up the interrupted task instead of stopping and waiting for user input
- **Concurrent session isolation**: Each Claude Code session now gets its own state file (`~/.claude/memory-state/<session-id>.json`), fixing race conditions when running multiple projects simultaneously
  - Sessions no longer overwrite each other's context thresholds
  - Ending one session no longer deletes other sessions' state
  - Stop hook no longer blocks wrong sessions from stopping

### Changed
- `mimo status` now shows all active sessions with per-session context percentages
- State file cleanup uses 7-day threshold for crash orphans (safe for long-running sessions)
- Session state creation is idempotent on resume (preserves checkpoint/save flags)
- Session IDs are sanitized for safe filesystem use

## [1.2.0] - 2026-02-25

### Added
- **Manual save commands**: `/save` (checkpoint) and `/save-full` (comprehensive save) as Claude Code slash commands
- Skills installed to `~/.claude/skills/save/` and `~/.claude/skills/save-full/`
- `mimo status` now checks skill installation
- `mimo help` now lists available slash commands

## [1.1.0] - 2026-02-25

### Changed
- **One-command install**: `session-start.sh` now auto-initializes `CLAUDE.md` and `CLAUDE-FULL.md` on first session start — no need to run `mimo init` separately
- Auto-generated `CLAUDE.md` includes workflow guidance (plan mode, subagents, verification, etc.) at the top and memory sections at the bottom
- Existing `CLAUDE.md` files are preserved: workflow block prepended at top, memory sections appended at bottom (idempotent)
- `mimo init` is now an optional re-initialization/reset command
- Updated install completion message and CLI help text

### Added
- `templates/claude-md-workflow.md` — reference template for the workflow guidance block

## [1.0.0] - 2026-02-24

### Added
- Hook-based memory system with 6 hooks:
  - `statusline-memory.sh` — ANSI progress bar with context % and threshold indicators
  - `memory-gate.sh` — Stop hook that blocks exit when memory save is needed
  - `precompact-save.sh` — Backs up transcript before compaction
  - `session-start.sh` — Resets state and injects memory context on startup/resume
  - `session-start-compact.sh` — Lightweight context injection after compaction
  - `session-end-backup.sh` — Final transcript backup on session exit
- Two-tier memory architecture:
  - `CLAUDE.md` — compact index (auto-loaded by Claude Code)
  - `CLAUDE-FULL.md` — deep archive with detailed session logs
- Automatic checkpoints at 50% context usage
- Full memory save at 80% context usage
- `mimo` CLI with `init`, `status`, `version`, `uninstall` commands
- One-line installer with safe `settings.json` merging
- Idempotent install/uninstall (safe to run repeatedly)
- Coexistence with user's existing Claude Code hooks
