#!/usr/bin/env bash
#
# tokenmaxxer installer — LiteLLM usage widget for the macOS menu bar.
#
# Local clone:   ./install.sh
# One-liner:     curl -fsSL https://raw.githubusercontent.com/dev-toro/tokenmaxxer/main/install.sh | bash
#
# Configuration precedence: inline env var > .env (next to the script) >
# existing config.json > interactive prompt (when run in a terminal) > default.
# Run in a terminal and you'll be prompted for anything unset; pipe it
# (curl|bash) non-interactively and it falls back to defaults. Vars:
#   TOKENMAXXER_BASE_URL   LiteLLM gateway root      (required; or set later via menu)
#   TOKENMAXXER_BUDGET     budget in USD             (default 200)
#   TOKENMAXXER_WARN       warn % (orange)           (default 75)
#   TOKENMAXXER_CRIT       critical % (red)          (default 90)
#   TOKENMAXXER_INTERVAL   refresh interval          (default 60s)
#   TOKENMAXXER_API_KEY    LiteLLM virtual key       (stored in the macOS Keychain)
#
set -euo pipefail

# --- deploy config: source .env from the script dir, if present --------------
# Real env vars already in the environment win over .env (so the curl|bash
# one-liner can still be driven by inline TOKENMAXXER_* vars).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd || true)"
if [ -n "$SRC" ] && [ -f "$SRC/.env" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac          # skip blanks/comments
    key="${line%%=*}"
    [ -z "${!key:-}" ] && export "$line"             # don't clobber real env
  done < "$SRC/.env"
fi

REPO_RAW="https://raw.githubusercontent.com/dev-toro/tokenmaxxer/${TOKENMAXXER_BRANCH:-main}"
PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar"
# Data dir kept OUTSIDE the SwiftBar folder — SwiftBar's MakePluginExecutable
# chmod +x's everything it scans, which would turn the icon/config into plugins.
DATA_DIR="$HOME/Library/Application Support/tokenmaxxer"

# Raw config: empty means "not provided" -> prompted (if a TTY) or defaulted below.
BASE_URL="${TOKENMAXXER_BASE_URL:-}"
BUDGET="${TOKENMAXXER_BUDGET:-}"
WARN="${TOKENMAXXER_WARN:-}"
CRIT="${TOKENMAXXER_CRIT:-}"
INTERVAL="${TOKENMAXXER_INTERVAL:-}"
API_KEY="${TOKENMAXXER_API_KEY:-}"

say() { printf "\033[1;35m▸\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only."

# --- interactive config ------------------------------------------------------
# curl|bash leaves stdin attached to the pipe, so prompts must read /dev/tty.
# Probe by actually opening it (a char device can exist but be disconnected).
INTERACTIVE=0
if { exec 3<>/dev/tty; } 2>/dev/null; then INTERACTIVE=1; exec 3>&-; fi

# Seed unset values from an existing config.json so re-runs don't wipe settings.
cfg_get() { # cfg_get <key>
  [ -f "$DATA_DIR/config.json" ] || return 0
  /usr/bin/python3 -c "import json;print(json.load(open('$DATA_DIR/config.json')).get('$1',''))" 2>/dev/null
}
ask() { # ask <prompt> <default> ; prints answer (default if blank/non-interactive)
  local p="$1" d="$2" ans=""
  if [ "$INTERACTIVE" = 1 ]; then
    if [ -n "$d" ]; then printf '  %s [%s]: ' "$p" "$d" >/dev/tty
    else printf '  %s: ' "$p" >/dev/tty; fi
    IFS= read -r ans </dev/tty || ans=""
  fi
  printf '%s' "${ans:-$d}"
}

[ "$INTERACTIVE" = 1 ] && say "Configure tokenmaxxer (Enter accepts the [default]):"
[ -z "$BASE_URL" ] && BASE_URL="$(ask 'LiteLLM gateway URL'   "$(cfg_get base_url)")"
[ -z "$BUDGET"   ] && BUDGET="$(ask   'Monthly budget (USD)'   "$(cfg_get max_budget)")"
[ -z "$WARN"     ] && WARN="$(ask     'Warn % (orange)'        "$(cfg_get warn_pct)")"
[ -z "$CRIT"     ] && CRIT="$(ask     'Critical % (red)'       "$(cfg_get crit_pct)")"
[ -z "$INTERVAL" ] && INTERVAL="$(ask 'Refresh interval'       '60s')"

# Final fallbacks for anything still empty (non-interactive path).
BUDGET="${BUDGET:-200}"; WARN="${WARN:-75}"; CRIT="${CRIT:-90}"; INTERVAL="${INTERVAL:-60s}"
PLUGIN_NAME="litellm-usage.${INTERVAL}.py"

# --- file source: local repo dir, else download from REPO_RAW ----------------
fetch() { # fetch <relpath> <dest>
  if [ -n "$SRC" ] && [ -f "$SRC/$1" ]; then cp "$SRC/$1" "$2"
  else curl -fsSL "$REPO_RAW/$1" -o "$2" || die "download failed: $1"; fi
}

# --- Homebrew ----------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

# --- SwiftBar ----------------------------------------------------------------
if [ ! -d "/Applications/SwiftBar.app" ]; then
  say "Installing SwiftBar…"
  brew install --cask swiftbar
fi

# --- remove artifacts from older installs that polluted the SwiftBar folder --
# (icon/config used to live here and would re-register as phantom plugins).
rm -f "$PLUGIN_DIR/claude-icon.png" "$PLUGIN_DIR/litellm-usage.config.json" 2>/dev/null || true
rm -rf "$PLUGIN_DIR/Plugins/claude-icon.png" \
       "$PLUGIN_DIR/Plugins/litellm-usage.config.json" 2>/dev/null || true

# --- plugin (only file in the SwiftBar folder) -------------------------------
say "Installing plugin into $PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR" "$DATA_DIR"
fetch "litellm-usage.plugin.py" "$PLUGIN_DIR/$PLUGIN_NAME"
chmod +x "$PLUGIN_DIR/$PLUGIN_NAME"

# --- icon + config (in the data dir, not scanned by SwiftBar) ----------------
fetch "assets/icon.png" "$DATA_DIR/icon.png"
chmod 0644 "$DATA_DIR/icon.png"
say "Writing config (base_url=$BASE_URL, budget=\$$BUDGET, warn=$WARN%, crit=$CRIT%)"
cat > "$DATA_DIR/config.json" <<JSON
{
  "base_url": "$BASE_URL",
  "max_budget": $BUDGET,
  "warn_pct": $WARN,
  "crit_pct": $CRIT
}
JSON
chmod 0644 "$DATA_DIR/config.json"

# --- API key into Keychain ---------------------------------------------------
if [ -z "$BASE_URL" ]; then
  say "No gateway URL set. After install: menu → Configure → Set gateway URL, then add your key."
else
  SERVICE="$(printf '%s' "${BASE_URL#*://}" | tr '.' '-')-api-key"
  USER_NAME="$(id -un)"
  if ! security find-generic-password -s "$SERVICE" -a "$USER_NAME" -w >/dev/null 2>&1; then
    KEY="$API_KEY"
    if [ -z "$KEY" ] && [ "$INTERACTIVE" = 1 ]; then
      printf '  LiteLLM API key for %s (input hidden, blank to skip): ' "$BASE_URL" >/dev/tty
      IFS= read -rs KEY </dev/tty || KEY=""; printf '\n' >/dev/tty
    fi
    if [ -n "$KEY" ]; then
      security add-generic-password -U -s "$SERVICE" -a "$USER_NAME" -w "$KEY"
      say "Stored key in Keychain ($SERVICE)"
    else
      say "No key set yet. Add later:  security add-generic-password -U -s \"$SERVICE\" -a \"$USER_NAME\" -w \"<key>\""
    fi
  else
    say "Reusing existing Keychain key ($SERVICE)"
  fi
fi

# --- point SwiftBar at the plugin dir & (re)launch ---------------------------
defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR" >/dev/null 2>&1 || true
osascript -e 'tell application "SwiftBar" to quit' >/dev/null 2>&1 || true
sleep 1
open -a SwiftBar

say "Done. Look top-right. Change budget/thresholds via the menu → Configure."
