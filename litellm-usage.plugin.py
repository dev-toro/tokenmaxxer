#!/usr/bin/python3
# -*- coding: utf-8 -*-
#
# SwiftBar plugin: LiteLLM usage for the current user.
# Menu bar:  ✨ <bar chart> <pct%>   (spend vs budget)
# Click:     spend, budget bar, total tokens, dashboard link, Configure submenu.
#
# Data sources:
#   spend  -> x-litellm-key-spend response header from the LiteLLM gateway (zero-cost poll)
#   budget -> config value (gateway virtual keys usually can't read max_budget)
#   tokens -> sum of usage.* from local Claude Code session logs (~/.claude/projects)
#
# Config lives in litellm-usage.config.json next to this file (edit via the menu).
# Env vars ANTHROPIC_BASE_URL / LITELLM_MAX_BUDGET override the config file.
#
# <xbar.title>LiteLLM Usage</xbar.title>
# <xbar.version>1.1</xbar.version>
# <xbar.author>tokenmaxxer</xbar.author>
# <xbar.desc>Spend vs budget % bar chart + total tokens for a LiteLLM gateway.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>

import os
import sys
import json
import glob
import time
import ssl
import base64
import subprocess
import urllib.request

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT = os.path.abspath(__file__)
PLUGIN_DIR = os.path.dirname(SCRIPT)
ICON_FILE = os.path.join(PLUGIN_DIR, "claude-icon.png")
CONFIG_FILE = os.path.join(PLUGIN_DIR, "litellm-usage.config.json")
CACHE_FILE = os.path.expanduser("~/Library/Caches/litellm-usage-swiftbar.json")
LOG_GLOB = os.path.expanduser("~/.claude/projects/**/*.jsonl")
TIMEOUT = 8

# ---------------------------------------------------------------------------
# Config (persisted to CONFIG_FILE, editable from the Configure menu)
# ---------------------------------------------------------------------------
DEFAULTS = {
    "base_url": "https://ai.celonis.dev",  # LiteLLM gateway root
    "max_budget": 200.0,                   # USD; key usually can't read it, so set here
    "warn_pct": 75.0,                      # bar turns orange at/above this
    "crit_pct": 90.0,                      # ...and red at/above this
}
NUM_KEYS = ("max_budget", "warn_pct", "crit_pct")
ENV_OVERRIDE = {"base_url": "ANTHROPIC_BASE_URL", "max_budget": "LITELLM_MAX_BUDGET"}


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_FILE) as fh:
            saved = json.load(fh)
        for k in DEFAULTS:
            if k in saved:
                cfg[k] = float(saved[k]) if k in NUM_KEYS else str(saved[k])
    except (OSError, ValueError, TypeError):
        pass
    for k, env in ENV_OVERRIDE.items():
        v = os.environ.get(env)
        if v:
            try:
                cfg[k] = float(v) if k in NUM_KEYS else v
            except ValueError:
                pass
    return cfg


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, "w") as fh:
        json.dump({k: cfg.get(k, DEFAULTS[k]) for k in DEFAULTS}, fh, indent=2)


def derived(base_url):
    """Return (base_url, keychain_service, dashboard_url) from a gateway root."""
    b = base_url.rstrip("/")
    service = b.split("://", 1)[-1].replace(".", "-") + "-api-key"
    return b, service, b + "/ui"


# ---------------------------------------------------------------------------
# Menu actions (dialogs)
# ---------------------------------------------------------------------------
def _dialog(label, default):
    script = (
        'display dialog "%s" default answer "%s" with title "LiteLLM Usage" '
        'buttons {"Cancel", "Save"} default button "Save"' % (label, default)
    )
    r = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        return None  # cancelled
    for token in r.stdout.strip().split(", "):
        if token.startswith("text returned:"):
            return token.split(":", 1)[1].strip()
    return None


def handle_action(action):
    cfg = load_config()
    num = {
        "set-budget": ("max_budget", "Total budget in USD:"),
        "set-warn": ("warn_pct", "Warn (orange) at what %?"),
        "set-crit": ("crit_pct", "Critical (red) at what %?"),
    }
    if action in num:
        key, label = num[action]
        ans = _dialog(label, cfg.get(key))
        if ans is not None:
            try:
                cfg[key] = float(ans)
                save_config(cfg)
            except ValueError:
                pass
    elif action == "set-base-url":
        ans = _dialog("LiteLLM gateway URL:", cfg.get("base_url"))
        if ans:
            cfg["base_url"] = ans
            save_config(cfg)
    elif action == "open-config":
        if not os.path.exists(CONFIG_FILE):
            save_config(cfg)
        subprocess.run(["/usr/bin/open", "-t", CONFIG_FILE])


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
def get_api_key(service):
    user = subprocess.run(["/usr/bin/id", "-un"], capture_output=True, text=True).stdout.strip()
    r = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", service, "-a", user, "-w"],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError("no key in Keychain (%s)" % service)
    return r.stdout.strip()


def fetch_spend(base_url, key):
    """POST an empty body to /v1/messages. Gateway returns 400 but still emits
    x-litellm-key-spend, and x-litellm-response-cost is 0 -> free poll."""
    req = urllib.request.Request(
        base_url + "/v1/messages",
        data=b"{}",
        method="POST",
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    )
    ctx = ssl.create_default_context()
    try:
        headers = urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx).headers
    except urllib.error.HTTPError as e:
        headers = e.headers          # 400 path — header still present
    val = headers.get("x-litellm-key-spend") if headers else None
    return float(val) if val is not None else None


def sum_tokens():
    total = 0
    for fp in glob.iglob(LOG_GLOB, recursive=True):
        try:
            with open(fp, "r", errors="ignore") as fh:
                for line in fh:
                    if '"usage"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    m = d.get("message")
                    u = m.get("usage") if isinstance(m, dict) else None
                    if isinstance(u, dict):
                        for k in ("input_tokens", "output_tokens",
                                  "cache_creation_input_tokens", "cache_read_input_tokens"):
                            v = u.get(k)
                            if isinstance(v, int):
                                total += v
        except OSError:
            continue
    return total


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------
def human_tokens(n):
    for unit, div in (("B", 1e9), ("M", 1e6), ("K", 1e3)):
        if n >= div:
            return "%.1f%s" % (n / div, unit)
    return str(n)


def load_cache():
    try:
        with open(CACHE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_cache(d):
    try:
        os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
        with open(CACHE_FILE, "w") as fh:
            json.dump(d, fh)
    except OSError:
        pass


def bar(pct, width=20):
    filled = max(0, min(width, int(round(pct / 100.0 * width))))
    return "█" * filled + "░" * (width - filled)


def icon_param():
    """SwiftBar templateImage= param for the icon (monochrome; adapts to light/dark
    and follows the line color), or '' if the asset is missing."""
    try:
        with open(ICON_FILE, "rb") as fh:
            return " templateImage=" + base64.b64encode(fh.read()).decode("ascii")
    except OSError:
        return ""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) > 1:
        handle_action(sys.argv[1])
        return

    cfg = load_config()
    MAX_BUDGET = cfg["max_budget"]
    WARN_PCT = cfg["warn_pct"]
    CRIT_PCT = cfg["crit_pct"]
    base_url, service, dashboard = derived(cfg["base_url"])

    cache = load_cache()
    stale = False
    err = None

    try:
        spend = fetch_spend(base_url, get_api_key(service))
        if spend is None:
            raise RuntimeError("no x-litellm-key-spend header")
    except Exception as e:                       # noqa: BLE001 - surface any failure
        err = str(e)
        spend = cache.get("spend")
        stale = spend is not None

    tokens = sum_tokens()

    if spend is not None:
        cache.update({"spend": spend, "ts": int(time.time())})
        save_cache(cache)

    pct = (spend / MAX_BUDGET * 100.0) if (spend is not None and MAX_BUDGET > 0) else None

    level = "ok"
    if pct is not None:
        level = "crit" if pct >= CRIT_PCT else ("warn" if pct >= WARN_PCT else "ok")
    color = {"crit": " color=red", "warn": " color=orange"}.get(level, "")
    icon = icon_param()

    # ---- menu bar (icon + bar chart + %) ----
    if pct is not None:
        title = "%s %.0f%%" % (bar(pct, width=10), pct)
    else:
        title = "$%.0f" % spend if spend is not None else "$?"
    if stale or level == "crit":
        title += " ⚠"
    print("%s | font=Menlo size=13%s%s" % (title, color, icon))

    # ---- dropdown ----
    print("---")
    if spend is not None:
        print("Spend: $%.2f | font=Menlo" % spend)
    else:
        print("Spend: unavailable | color=red font=Menlo")
    if MAX_BUDGET > 0:
        print("Budget: $%.2f | font=Menlo" % MAX_BUDGET)
        if pct is not None:
            print("%s  %.1f%% | font=Menlo%s" % (bar(pct), pct, color))
    else:
        print("Budget: not set | font=Menlo")
    print("---")
    print("Tokens (Claude Code, this Mac): %s | font=Menlo" % format(tokens, ","))
    print("---")
    if stale:
        age = int(time.time()) - int(cache.get("ts", 0))
        print("⚠ Stale: using cached spend (%ds old) | color=orange font=Menlo" % age)
    if err:
        print("Error: %s | color=red font=Menlo" % err)
    print("Open dashboard | href=%s" % dashboard)
    print("Refresh | refresh=true")
    print("---")
    print("Configure")
    py = sys.executable

    def item(label, action, refresh=True):
        r = " refresh=true" if refresh else ""
        print("--%s | shell=%s param1=\"%s\" param2=%s terminal=false%s"
              % (label, py, SCRIPT, action, r))

    item("Set budget…  ($%.0f)" % MAX_BUDGET, "set-budget")
    item("Set warn %%  (%.0f%%)" % WARN_PCT, "set-warn")
    item("Set critical %%  (%.0f%%)" % CRIT_PCT, "set-crit")
    item("Set gateway URL…", "set-base-url")
    print("-----")
    item("Edit config file…", "open-config", refresh=False)


if __name__ == "__main__":
    main()
