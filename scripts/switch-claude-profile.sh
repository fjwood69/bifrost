#!/usr/bin/env bash
# Claude Code profile switcher — Linux (NUC)
#
# Each non-sub profile uses its own isolated CLAUDE_CONFIG_DIR so switching
# profiles never contaminates auth state. The sub (OAuth) profile stays in
# ~/.claude/ as the default.
#
# On switch-away from a non-sub profile, if the live config has a new API key
# or OAuth token, it's saved back to the profile's golden config.
#
# Profiles:
#   claude-api  -> ~/.claude-api/  (direct API key auth)
#   claude-jr   -> ~/.claude-jr/   (Bifrost routing)
#   claude-sub  -> ~/.claude/      (OAuth subscription — default)
#
# Usage:
#   switch-claude-profile.sh <profile>
#   switch-claude-profile.sh status

TARGET="${1}"
PROFILE_DIR="$HOME/.claude-profiles"
SWITCH_LOG="$PROFILE_DIR/switch.log"

# Isolated config dirs for non-sub profiles
declare -A CONFIG_DIRS
CONFIG_DIRS[claude-api]="$HOME/.claude-api"
CONFIG_DIRS[claude-jr]="$HOME/.claude-jr"

# Default config dir (claude-sub lives here)
DEFAULT_CLAUDE_DIR="$HOME/.claude"
DEFAULT_CLAUDE_JSON="$HOME/.claude.json"

# ── VS Code profile path ──────────────────────────────────────────────────────

find_vscode_profile() {
    local cfg="$PROFILE_DIR/.vscode-profile-path"
    if [ -f "$cfg" ]; then
        # Check if the parent VS Code process is actually using this profile
        local profile_id
        profile_id="$(basename "$(dirname "$cfg")")"
        if ps aux 2>/dev/null | grep -q "[Vv][Ss]code.*--profile[= ]$profile_id"; then
            cat "$cfg"
            return
        fi
    fi
    # If no profile is in use, write to the default user settings
    local default_settings="$HOME/.config/Code/User/settings.json"
    if [ -f "$default_settings" ]; then
        echo "$default_settings"
        return
    fi
    # Fallback: find a profile with claudeCode settings
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

get_config_dir() {
    local target="$1"
    [ -n "${CONFIG_DIRS[$target]}" ] && echo "${CONFIG_DIRS[$target]}" || echo "$DEFAULT_CLAUDE_DIR"
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

# Read a JSON field from a file
json_field() {
    local file="$1" field="$2"
    python3 -c "import json,sys; d=json.load(open('$file')); sys.stdout.write(str(d.get('$field','')))" 2>/dev/null
}

# ── OAuth token save (leaving claude-sub) ──────────────────────────────────────

save_sub_oauth() {
    local sub_dir="$PROFILE_DIR/claude-sub"
    [ -d "$sub_dir" ] || return

    local live_json="$DEFAULT_CLAUDE_JSON"
    local live_creds="$DEFAULT_CLAUDE_DIR/.credentials.json"

    if [ -f "$live_json" ]; then
        python3 -c "
import json
d = json.load(open('$live_json'))
d.pop('primaryApiKey', None)
# Remove cached data that's stale between sessions
for k in ['cachedGrowthBookFeatures','clientDataCache','additionalModelOptionsCache',
          'additionalModelCostsCache','metricsStatusCache','seenNotifications']:
    d.pop(k, None)
with open('$sub_dir/claude.json', 'w') as f:
    json.dump(d, f, indent=2, sort_keys=True)
" && log_switch "  Saved claude-sub OAuth tokens"
    fi

    [ -f "$live_creds" ] && cp "$live_creds" "$sub_dir/credentials.json" && log_switch "  Saved claude-sub credentials"
}

# ── Drift detection: save new keys back to golden config on switch-away ────────

save_drift() {
    local target="$1"
    [ "$target" = "claude-sub" ] && return  # sub uses live config directly
    [ -n "${CONFIG_DIRS[$target]}" ] || return  # not an isolated profile

    local config_dir="${CONFIG_DIRS[$target]}"
    local live_json="$config_dir/claude.json"
    local golden_dir="$PROFILE_DIR/$target"

    [ -f "$live_json" ] || return
    [ -d "$golden_dir" ] || return

    local live_key
    live_key=$(json_field "$live_json" "primaryApiKey")
    local golden_key
    golden_key=$(json_field "$golden_dir/claude.json" "primaryApiKey")

    if [ -n "$live_key" ] && [ "$live_key" != "$golden_key" ]; then
        cp "$live_json" "$golden_dir/claude.json"
        log_switch "  Updated $target primaryApiKey in golden config"
    fi

    # Also sync credentials.json if it changed (should stay empty for non-sub)
    local live_creds="$config_dir/.credentials.json"
    local golden_creds="$golden_dir/credentials.json"
    if [ -f "$live_creds" ] && [ ! -f "$golden_creds" ] || [ "$(cat "$live_creds" 2>/dev/null)" != "$(cat "$golden_creds" 2>/dev/null)" ]; then
        cp "$live_creds" "$golden_creds"
        log_switch "  Updated $target credentials in golden config"
    fi
}

# ── Inject env vars into VS Code profile ──────────────────────────────────────

set_vscode_env() {
    local target="$1"
    [ -z "$VSCODE_PROFILE" ] || [ ! -f "$VSCODE_PROFILE" ] && { log_switch "  VS Code sync skipped"; return; }

    local config_dir
    config_dir=$(get_config_dir "$target")

    python3 -c "
import json, sys

log = open('$SWITCH_LOG', 'a')
def lprint(msg):
    log.write('[vscode] ' + msg + '\n')
    log.flush()

try:
    vs = json.load(open('$VSCODE_PROFILE'))
except Exception as e:
    lprint(f'ERROR reading VS Code profile: {e}')
    sys.exit(0)

env_vars = []
try:
    s = json.load(open('$PROFILE_DIR/$target/settings.json'))
    for k, v in s.get('env', {}).items():
        env_vars.append({'name': k, 'value': v})
        lprint(f'  env: {k}')
except Exception as e:
    lprint(f'ERROR reading env block: {e}')

# Inject CLAUDE_CONFIG_DIR for isolated profiles
if '$target' != 'claude-sub':
    env_vars.append({'name': 'CLAUDE_CONFIG_DIR', 'value': '$config_dir'})
    lprint('  env: CLAUDE_CONFIG_DIR=$config_dir')

vs['claudeCode.environmentVariables'] = env_vars

# Only set disableLoginPrompt on profile-level settings, not user-level
import os.path
is_profile = 'profiles' in '$VSCODE_PROFILE'.replace(os.sep, '/')
if is_profile:
    vs['claudeCode.disableLoginPrompt'] = $([ "$target" != "claude-sub" ] && echo "true" || echo "false")

json.dump(vs, open('$VSCODE_PROFILE', 'w'), indent=4)
lprint('VS Code profile updated')

log.close()
" 2>&1
    log_switch "  VS Code env set (${target})"
}

# ── Profile switch ─────────────────────────────────────────────────────────────

switch_profile() {
    local target="$1"
    local current
    current="$(get_active_profile)"

    local target_dir="$PROFILE_DIR/$target"
    if [ ! -f "$target_dir/settings.json" ] || [ ! -f "$target_dir/claude.json" ]; then
        echo "❌ Profile not found: $target"
        show_status
        exit 1
    fi

    echo "Switching $current → $target..."
    log_switch "START $current → $target"

    # Step 1: If leaving claude-sub, save OAuth tokens back
    if [ "$current" = "claude-sub" ]; then
        save_sub_oauth
        echo "  Saved claude-sub OAuth tokens."
    fi

    # Step 1b: If leaving an isolated profile, save drifted keys back
    if [ "$current" != "claude-sub" ] && [ -n "${CONFIG_DIRS[$current]}" ]; then
        save_drift "$current"
    fi

    # Step 2: Determine target config dir and ensure it exists
    local config_dir
    config_dir=$(get_config_dir "$target")
    mkdir -p "$config_dir"

    # Step 3: Copy profile files into config dir
    cp "$target_dir/settings.json"    "$config_dir/settings.json"     && log_switch "  settings.json → $config_dir"
    cp "$target_dir/claude.json"      "$DEFAULT_CLAUDE_JSON"          && log_switch "  ~/.claude.json"
    cp "$target_dir/credentials.json" "$config_dir/.credentials.json" && log_switch "  credentials.json"
    chmod 600 "$config_dir/.credentials.json"

    # Step 4: Write active marker
    echo "$target" > "$PROFILE_DIR/.active"
    log_switch "  .active → $target"

    # Step 5: Update VS Code profile env vars
    set_vscode_env "$target"

    # Step 6: Cleanup — remove stale settings from default dir
    if [ "$target" != "claude-sub" ]; then
        # If we're switching away from sub, the default dir still has sub's settings
        [ -f "$DEFAULT_CLAUDE_DIR/settings.json" ] && cp "$DEFAULT_CLAUDE_DIR/settings.json" "$PROFILE_DIR/claude-sub/settings.json" 2>/dev/null || true
    fi

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
