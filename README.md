# tokenmaxxer ✨

A tiny macOS menu-bar widget showing your **LiteLLM gateway spend vs budget** as a bar
chart, plus total Claude Code tokens. Built as a [SwiftBar](https://swiftbar.app) plugin.

```
✨ ███░░░░░░░ 34%
```

Click it for spend, budget bar, total tokens, a dashboard link, and a **Configure** menu.
The bar turns **orange** past your warn threshold and **red** past critical.

## Install

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/dev-toro/tokenmaxxer/main/install.sh | bash
```

Or from a clone:

```bash
git clone https://github.com/dev-toro/tokenmaxxer.git && cd tokenmaxxer && ./install.sh
```

The installer is idempotent: installs Homebrew + SwiftBar if missing, drops the plugin and
icon into `~/Library/Application Support/SwiftBar/`, writes config, and stores your API key
in the macOS Keychain.

Non-interactive (e.g. CI / piped):

```bash
TOKENMAXXER_BASE_URL=https://your-litellm-gateway.example.com \
TOKENMAXXER_BUDGET=200 \
TOKENMAXXER_API_KEY=sk-xxxx \
curl -fsSL https://raw.githubusercontent.com/dev-toro/tokenmaxxer/main/install.sh | bash
```

## How it works / data sources

| Metric | Source | Notes |
|--------|--------|-------|
| **Spend** | `x-litellm-key-spend` response header | Polled with an empty `POST /v1/messages` → HTTP 400 but the header is present and `response-cost` is `0`, so the poll is **free**. |
| **Budget %** | local config value | Most virtual keys can't read `max_budget` (`/key/info` is admin-only), so the budget is set in config. |
| **Tokens** | `~/.claude/projects/**/*.jsonl` | Sum of `usage.*_tokens`. Claude Code on this Mac only — not all gateway traffic. |

If the gateway grants your key the `/user/daily/activity` route, the widget could read
authoritative live spend + budget + tokens instead; not required for the above.

## Configure

Menu → **Configure**: set budget, warn %, critical %, gateway URL, or open the JSON.
Config: `~/Library/Application Support/SwiftBar/litellm-usage.config.json`.
Env vars `ANTHROPIC_BASE_URL` / `LITELLM_MAX_BUDGET` override the file.

## Files

```
litellm-usage.plugin.py   # the widget (installed as litellm-usage.60s.py)
assets/icon.png           # menu-bar sparkles icon (SF Symbol, templated)
install.sh                # bootstrap installer
scripts/make-icon.sh      # regenerate the icon from an SF Symbol
```

## Uninstall

```bash
rm -f ~/Library/Application\ Support/SwiftBar/litellm-usage.*.py
rm -rf ~/Library/Application\ Support/tokenmaxxer
# optional: brew uninstall --cask swiftbar
```

## Requirements

macOS, `python3` (system `/usr/bin/python3` is fine), a LiteLLM gateway + virtual key.
