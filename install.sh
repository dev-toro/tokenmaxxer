#!/usr/bin/env bash
#
# tokenmaxxer installer — LiteLLM usage widget for the macOS menu bar.
#
# Local clone:   ./install.sh
# One-liner:     curl -fsSL https://raw.githubusercontent.com/dev-toro/tokenmaxxer/main/install.sh | bash
#
# Configuration: copy .env.example -> .env and edit (sourced automatically).
# Any value can also be passed inline as an env var, which wins over .env:
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
INTERVAL="${TOKENMAXXER_INTERVAL:-60s}"
BASE_URL="${TOKENMAXXER_BASE_URL:-}"
BUDGET="${TOKENMAXXER_BUDGET:-200}"
WARN="${TOKENMAXXER_WARN:-75}"
CRIT="${TOKENMAXXER_CRIT:-90}"
PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar"
PLUGIN_NAME="litellm-usage.${INTERVAL}.py"

say() { printf "\033[1;35m▸\033[0m %s\n" "$1"; }
die() { printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only."

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

# --- plugin + icon -----------------------------------------------------------
say "Installing plugin into $PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"
fetch "litellm-usage.plugin.py" "$PLUGIN_DIR/$PLUGIN_NAME"
fetch "assets/icon.png"          "$PLUGIN_DIR/claude-icon.png"
chmod +x "$PLUGIN_DIR/$PLUGIN_NAME"

# --- config ------------------------------------------------------------------
say "Writing config (base_url=$BASE_URL, budget=\$$BUDGET, warn=$WARN%, crit=$CRIT%)"
cat > "$PLUGIN_DIR/litellm-usage.config.json" <<JSON
{
  "base_url": "$BASE_URL",
  "max_budget": $BUDGET,
  "warn_pct": $WARN,
  "crit_pct": $CRIT
}
JSON

# --- API key into Keychain ---------------------------------------------------
if [ -z "$BASE_URL" ]; then
  say "No gateway URL set. After install: menu → Configure → Set gateway URL, then add your key."
else
  SERVICE="$(printf '%s' "${BASE_URL#*://}" | tr '.' '-')-api-key"
  USER_NAME="$(id -un)"
  if ! security find-generic-password -s "$SERVICE" -a "$USER_NAME" -w >/dev/null 2>&1; then
    KEY="${TOKENMAXXER_API_KEY:-}"
    if [ -z "$KEY" ] && [ -t 0 ]; then
      printf "Enter your LiteLLM API key for %s (blank to skip): " "$BASE_URL"
      read -rs KEY; echo
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
