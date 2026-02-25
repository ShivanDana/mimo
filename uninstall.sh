#!/usr/bin/env bash
# mimo uninstaller — standalone script for removing mimo
# Usage: curl -fsSL https://raw.githubusercontent.com/ShivanDana/mimo/main/uninstall.sh | bash
#    or: mimo uninstall
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${GREEN}[mimo]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[mimo]${NC} %s\n" "$1"; }
error() { printf "${RED}[mimo]${NC} %s\n" "$1" >&2; }

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo ""
printf "${BOLD}Uninstalling mimo${NC}\n"
echo ""

# ─── 1. Remove hook scripts ──────────────────────────────────────────────────
REMOVED=0
for hook in statusline-memory.sh memory-gate.sh precompact-save.sh session-start.sh session-start-compact.sh session-end-backup.sh; do
    if [ -f "$HOOKS_DIR/$hook" ]; then
        rm "$HOOKS_DIR/$hook"
        info "Removed $hook"
        REMOVED=$((REMOVED + 1))
    fi
done
if [ "$REMOVED" -eq 0 ]; then
    warn "No hook scripts found (already removed?)"
else
    info "Removed $REMOVED hook scripts"
fi

# ─── 1b. Remove skill files ────────────────────────────────────────────────
for skill in save save-full; do
    if [ -d "$HOME/.claude/skills/$skill" ]; then
        rm -rf "$HOME/.claude/skills/$skill"
        info "Removed skill: /$skill"
    fi
done

# ─── 2. Remove mimo entries from settings.json ───────────────────────────────
if [ -f "$SETTINGS_FILE" ]; then
    if ! command -v jq &>/dev/null; then
        warn "jq not found — cannot clean settings.json automatically"
        warn "Manually remove mimo hook entries from $SETTINGS_FILE"
    else
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
else
    warn "No settings.json found"
fi

# ─── 3. Remove CLI ───────────────────────────────────────────────────────────
for bin in "$HOME/.local/bin/mimo" "$HOME/.local/bin/mimo-uninstall"; do
    if [ -f "$bin" ]; then
        rm "$bin"
        info "Removed $(basename "$bin")"
    fi
done

# ─── 4. Preserve user data ───────────────────────────────────────────────────
echo ""
warn "Preserved (your data):"
echo "  ~/.claude/backups/       — transcript backups"
echo "  ~/.claude/memory-state/  — session state"
echo "  Project CLAUDE.md and CLAUDE-FULL.md files"
echo ""
echo "To remove all data: rm -rf ~/.claude/backups ~/.claude/memory-state"
echo ""
info "mimo has been uninstalled. Your memory data is intact."
echo ""
