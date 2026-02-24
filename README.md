# mimo

Hook-based memory system for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Gives Claude persistent memory across sessions using automatic checkpoints and a two-tier archive.

## What it does

Claude Code loses all context when a session ends or the context window fills up. mimo fixes this:

- **Automatic checkpoints** at 50% context — Claude saves a snapshot of current work
- **Full memory save** at 80% context — Claude writes a detailed session log before context is lost
- **Transcript backups** — every session and compaction event is backed up
- **Two-tier memory** — compact index in `CLAUDE.md` (auto-loaded) + detailed archive in `CLAUDE-FULL.md`
- **Progress bar** — colored status line shows context usage, model, and cost

When you start a new session, Claude reads the memory sections in `CLAUDE.md` and picks up where it left off.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ShivanDana/mimo/main/install.sh | bash
```

**Requirements:** `jq`, `bash` 3.2+, [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed

Then initialize memory in your project:

```bash
cd your-project
mimo init
```

That's it. Start a Claude Code session and mimo handles the rest.

## How it works

mimo installs 6 hooks into Claude Code's hook system:

| Hook | Event | What it does |
|------|-------|-------------|
| `statusline-memory.sh` | StatusLine | Shows context %, colored progress bar, threshold indicators |
| `session-start.sh` | SessionStart (startup/resume) | Resets state, injects memory context |
| `session-start-compact.sh` | SessionStart (compact) | Lightweight context reminder after compaction |
| `memory-gate.sh` | Stop | Blocks Claude from stopping until memory is saved |
| `precompact-save.sh` | PreCompact | Backs up transcript before compaction |
| `session-end-backup.sh` | SessionEnd | Final transcript backup |

### Memory architecture

```
CLAUDE.md (compact, auto-loaded every session)
├── Memory — Current State     ← date, focus, blockers
├── Memory — Recent Sessions   ← rolling list of 7 sessions with line refs
└── Memory — Key Decisions     ← one-liners with line refs

CLAUDE-FULL.md (deep archive, read on demand)
└── Sessions                   ← detailed logs with files changed, decisions, next steps
```

Claude writes to both files at checkpoints. `CLAUDE.md` entries reference specific line ranges in `CLAUDE-FULL.md` (e.g., `[CLAUDE-FULL.md L7-L14]`), so Claude can read just the relevant section when needed.

### Threshold behavior

The status line tracks context window usage:

```
████████░░░░░░░░░░░░ 40%  │ Claude Opus 4.6 │ $0.53     (green — normal)
██████████████░░░░░░ 52% * │ Claude Opus 4.6 │ $1.20     (yellow — checkpoint needed)
████████████████████ 83% ! │ Claude Opus 4.6 │ $2.41     (red — full save needed)
```

- **50%** — checkpoint: Claude saves current state (quick snapshot)
- **80%** — full save: Claude writes a detailed session log (comprehensive)

The stop hook (`memory-gate.sh`) blocks Claude from ending a turn until the save is complete.

## CLI

```bash
mimo init        # Add memory sections to current project's CLAUDE.md
mimo status      # Diagnostic: hooks, settings, dependencies, session state
mimo version     # Print version
mimo uninstall   # Remove mimo (preserves your memory data)
```

## Uninstall

```bash
mimo uninstall
```

Or standalone:

```bash
curl -fsSL https://raw.githubusercontent.com/ShivanDana/mimo/main/uninstall.sh | bash
```

This removes hooks and settings entries but **preserves your data**:
- `~/.claude/backups/` — transcript backups
- `~/.claude/memory-state/` — session state
- Project `CLAUDE.md` and `CLAUDE-FULL.md` files

## Settings merge

mimo safely merges into your existing `settings.json`:

- **Preserves** all your non-mimo settings (e.g., `alwaysThinkingEnabled`)
- **Preserves** your own hooks on the same event types
- **Idempotent** — running the installer twice produces the same result
- **Backs up** your settings before any changes (`settings.json.mimo-backup`)

mimo identifies its own hooks by the `~/.claude/hooks/` path in the command field. Only hooks matching this fingerprint are added/removed during install/uninstall.

## Customization

### Thresholds

Edit `~/.claude/hooks/statusline-memory.sh` and change:

```bash
CHECKPOINT_THRESHOLD=50   # checkpoint at this %
FULLSAVE_THRESHOLD=80     # full save at this %
```

Lower these for testing (e.g., 5 and 15).

### Progress bar width

In the same file:

```bash
BAR_WIDTH=20   # characters wide
```

## Troubleshooting

Run `mimo status` to check everything:

```
mimo status

Hook scripts:
  [ok] statusline-memory.sh
  [ok] memory-gate.sh
  [ok] precompact-save.sh
  [ok] session-start.sh
  [ok] session-start-compact.sh
  [ok] session-end-backup.sh

Settings:
  [ok] Hooks registered in settings.json (6 entries)
  [ok] StatusLine configured

Dependencies:
  [ok] jq 1.7.1
  [ok] bash 5.2.37(1)-release

Session state:
  [-]  No active session

Current project:
  [ok] CLAUDE.md has memory sections
  [ok] CLAUDE-FULL.md (42 lines)
```

Common issues:

- **"jq not found"** — Install with `brew install jq` (macOS) or `sudo apt-get install jq` (Ubuntu)
- **"~/.claude/ not found"** — Install Claude Code first
- **Status line not showing** — Restart Claude Code after installing mimo
- **Hooks not firing** — Check `mimo status` and verify settings.json has the entries

## License

MIT
