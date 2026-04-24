#!/usr/bin/env bash
# Claude Code backend profile switcher
# Swaps settings.json, claude.json, credentials.json between
# ~/.claude/ (live config) and ~/.claude-profiles/<name>/ (profile store).
#
# Usage:
#   switch-claude-profile.sh <profile>   — activate a profile
#   switch-claude-profile.sh status      — show active profile
#
# Profiles live in ~/.claude-profiles/<name>/
# Each profile directory needs: settings.json, claude.json, credentials.json
#
# VS Code sidebar integration (optional):
#   Create ~/.claude-profiles/.vscode-profile-path containing the absolute
#   path to your VS Code profile's settings.json, e.g.:
#     ~/.config/Code/User/profiles/<hash>/settings.json
#   If absent, the script auto-detects the first VS Code profile that
#   contains claudeCode settings. If none found, VS Code sync is skipped.

TARGET="${1}"
PROFILE_DIR="$HOME/.claude-profiles"
CLAUDE_DIR="$HOME/.claude"
SWITCH_LOG="$PROFILE_DIR/switch.log"

# ── VS Code profile path ──────────────────────────────────────────────────────

find_vscode_profile() {
    local cfg="$PROFILE_DIR/.vscode-profile-path"
    if [ -f "$cfg" ]; then
        cat "$cfg"
        return
    fi
    local base="$HOME/.config/Code/User/profiles"
    [ -d "$base" ] || return
    for f in "$base"/*/settings.json; do
        grep -q "claudeCode" "$f" 2>/dev/null && { echo "$f"; return; }
    done
}

VSCODE_PROFILE="$(find_vscode_profile)"

# ── Helpers ───────────────────────────────────────────────────────────────────

log_switch() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$SWITCH_LOG"
    tail -20 "$SWITCH_LOG" > "$SWITCH_LOG.tmp" && mv "$SWITCH_LOG.tmp" "$SWITCH_LOG"
}

get_active_profile() {
    [ -f "$PROFILE_DIR/.active" ] && cat "$PROFILE_DIR/.active" || echo "unknown"
}

show_status() {
    local active
    active="$(get_active_profile)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Claude Code Backend"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Active: $active"
    echo ""
    echo "  Profiles in $PROFILE_DIR:"
    for d in "$PROFILE_DIR"/*/; do
        local name
        name="$(basename "$d")"
        [ -f "$d/settings.json" ] && echo "    $name"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Profile switch ─────────────────────────────────────────────────────────────

switch_profile() {
    local target="$1"
    local current
    current="$(get_active_profile)"

    if [ ! -f "$PROFILE_DIR/$target/settings.json" ] || [ ! -f "$PROFILE_DIR/$target/claude.json" ]; then
        echo "❌ Profile not found: $target"
        show_status
        exit 1
    fi

    echo "Switching $current → $target..."
    log_switch "START $current → $target"

    # Step 1: If leaving claude-sub, save refreshed OAuth tokens back to profile
    if [ "$current" = "claude-sub" ]; then
        [ -f "$CLAUDE_DIR/.credentials.json" ] && cp "$CLAUDE_DIR/.credentials.json" "$PROFILE_DIR/claude-sub/credentials.json"
        [ -f "$CLAUDE_DIR.json" ]              && cp "$CLAUDE_DIR.json"              "$PROFILE_DIR/claude-sub/claude.json"
        echo "  Saved claude-sub OAuth tokens."
        log_switch "  Saved claude-sub OAuth tokens"
    fi

    # Step 2: Copy target profile into live config dir
    cp "$PROFILE_DIR/$target/settings.json"    "$CLAUDE_DIR/settings.json"     && log_switch "  settings.json OK"    || log_switch "  ERROR settings.json"
    cp "$PROFILE_DIR/$target/claude.json"      "$CLAUDE_DIR.json"              && log_switch "  claude.json OK"      || log_switch "  ERROR claude.json"
    cp "$PROFILE_DIR/$target/credentials.json" "$CLAUDE_DIR/.credentials.json" && log_switch "  credentials.json OK" || log_switch "  ERROR credentials.json"
    chmod 600 "$CLAUDE_DIR/.credentials.json"

    # Step 3: Inject env vars into VS Code profile (so the extension picks them up)
    if [ -n "$VSCODE_PROFILE" ] && [ -f "$VSCODE_PROFILE" ]; then
        python3 -c "
import json, sys

log = open('$SWITCH_LOG', 'a')
def lprint(msg):
    print(msg)
    log.write('[vscode] ' + msg + '\n')
    log.flush()

try:
    vs = json.load(open('$VSCODE_PROFILE'))
except Exception as e:
    lprint(f'ERROR reading VS Code profile: {e}')
    sys.exit(0)  # non-fatal

env_vars = []
try:
    s = json.load(open('$PROFILE_DIR/$target/settings.json'))
    for k, v in s.get('env', {}).items():
        env_vars.append({'name': k, 'value': v})
        lprint(f'  env: {k}')
except Exception as e:
    lprint(f'ERROR reading env block: {e}')

vs['claudeCode.environmentVariables'] = env_vars
json.dump(vs, open('$VSCODE_PROFILE', 'w'), indent=4)
lprint('VS Code profile updated')
log.close()
" 2>&1
    else
        echo "  VS Code profile not found — skipping sidebar sync."
        log_switch "  VS Code sync skipped (no profile found)"
    fi

    # Step 4: Record active profile
    echo "$target" > "$PROFILE_DIR/.active"
    log_switch "  .active → $target"

    # Step 5: (pkill removed — it caused VS Code to auto-relaunch with stale env vars
    #          before the user could reload the window, triggering a login prompt.
    #          Manual "Reload Window" in VS Code picks up the updated env vars cleanly.)
    log_switch "  (no pkill)"

    echo "✓ Switched to $target — do Ctrl+Shift+P → Reload Window in VS Code."
    log_switch "DONE $target"
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "$TARGET" in
    status|--status|-s|"")
        show_status
        ;;
    *)
        switch_profile "$TARGET"
        ;;
esac
