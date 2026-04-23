# scripts/

Shell utilities for using Bifrost as a Claude Code backend.

## switch-claude-profile.sh

Swaps the active Claude Code config between profiles stored in `~/.claude-profiles/`.

Each profile is a directory containing `settings.json`, `claude.json`, and `credentials.json` — snapshots of `~/.claude/`. The switcher copies the target profile into `~/.claude/` (the live config Claude Code reads), preserves OAuth tokens when leaving a subscription profile, and optionally updates the VS Code extension's env vars so the sidebar stays in sync.

**Setup:**

```bash
# Create profile directories
mkdir -p ~/.claude-profiles/claude-api ~/.claude-profiles/claude-sub ~/.claude-profiles/claude-jr

# Snapshot your current Anthropic API config:
cp ~/.claude/settings.json         ~/.claude-profiles/claude-api/
cp ~/.claude.json                   ~/.claude-profiles/claude-api/claude.json
cp ~/.claude/.credentials.json     ~/.claude-profiles/claude-api/credentials.json

# Clone as starting point for claude-jr profile, then edit settings.json:
cp -r ~/.claude-profiles/claude-api ~/.claude-profiles/claude-jr
# Edit ~/.claude-profiles/claude-jr/settings.json:
#   ANTHROPIC_BASE_URL  → http://localhost:8787/anthropic
#   ANTHROPIC_API_KEY   → your Bifrost virtual key (sk-ant-... format)
#   ANTHROPIC_CUSTOM_MODEL_OPTION → initial model, e.g. parasail/Qwen/Qwen3.5-35B-A3B-FP8
```

**VS Code sidebar sync (optional):**

Create `~/.claude-profiles/.vscode-profile-path` containing the path to your VS Code profile's `settings.json`:

```
~/.config/Code/User/profiles/<hash>/settings.json
```

If this file is absent, the script auto-detects the first VS Code profile containing `claudeCode` settings. If none is found, the VS Code sync step is silently skipped — the CLI still switches correctly.

**Install:**

```bash
chmod +x scripts/switch-claude-profile.sh
ln -sf "$(pwd)/scripts/switch-claude-profile.sh" ~/bin/switch-claude-profile.sh

# Aliases (add to ~/.bashrc):
alias claude-api='switch-claude-profile.sh claude-api'
alias claude-sub='switch-claude-profile.sh claude-sub'
alias claude-jr='switch-claude-profile.sh claude-jr'
alias claude-status='switch-claude-profile.sh status'
```

---

## jr-model

Interactive model picker for the `claude-jr` profile. Presents a numbered menu of available models; selecting one updates `ANTHROPIC_CUSTOM_MODEL_OPTION` in both the profile store and (if `claude-jr` is currently active) the live `~/.claude/settings.json` and VS Code profile.

The model list at the top of the file is the place to add, remove, or rename entries for your own provider setup. Each entry is a tuple of `(key, model_id, display_name, description)`.

**Install:**

```bash
chmod +x scripts/jr-model
ln -sf "$(pwd)/scripts/jr-model" ~/bin/jr-model
```

---

## VS Code profile path config

Both scripts use the same discovery logic for the VS Code profile:

1. Read `~/.claude-profiles/.vscode-profile-path` if it exists
2. Otherwise scan `~/.config/Code/User/profiles/*/settings.json` for the first file containing `claudeCode`
3. If nothing found, skip VS Code sync silently

To set it explicitly:

```bash
echo "$HOME/.config/Code/User/profiles/<your-hash>/settings.json" \
  > ~/.claude-profiles/.vscode-profile-path
```
