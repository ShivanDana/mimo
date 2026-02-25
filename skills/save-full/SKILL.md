---
name: save-full
description: "Perform a full mimo memory save — comprehensive session log to CLAUDE.md and CLAUDE-FULL.md"
---

[MIMO — MANUAL FULL SAVE]

Perform a complete memory save to preserve full session context.

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
