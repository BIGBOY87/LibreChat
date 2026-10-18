#!/usr/bin/env bash
# BANG IT UP MUSIC — start the existing private Codespaces browser and GitHub bridge.
# This script preserves browser profiles, does not open port 9222 publicly,
# and leaves a running bridge alone.
set -u

export PATH="$HOME/.local/bin:$PATH"
STATE="$HOME/.local/state/bang-browser"
BRIDGE_DIR="/tmp/bang-browser-bridge"
mkdir -p "$STATE"

log() { printf '[BANG browser %s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"; }
chrome_ready() {
  curl -fsS --max-time 3 http://127.0.0.1:9222/json/version 2>/dev/null | grep -q '"webSocketDebuggerUrl"'
}
novnc_ready() {
  curl -fsS --max-time 3 http://127.0.0.1:6080/vnc.html >/dev/null 2>&1
}
bridge_running() {
  command -v pgrep >/dev/null 2>&1 &&
    pgrep -u "$(id -u)" -f 'node ([^ ]*/)?bridge\.mjs([ ]|$)' >/dev/null 2>&1
}

MODE=""
if [[ "$#" -gt 0 ]]; then MODE="$1"; fi
case "$MODE" in
  --status)
    chrome_ready && echo 'Chromium CDP 9222: READY' || echo 'Chromium CDP 9222: OFFLINE'
    novnc_ready && echo 'noVNC 6080: READY' || echo 'noVNC 6080: OFFLINE'
    bridge_running && echo 'GitHub bridge: RUNNING' || echo 'GitHub bridge: NOT RUNNING'
    echo "Log: $STATE/startup.log"
    exit 0
    ;;
  --run)
    # A live node bridge holds the lock (file descriptor 9) until it exits.
    if command -v flock >/dev/null 2>&1; then
      exec 9>"$STATE/bridge.lock"
      if ! flock -n 9; then log 'Starter already active; existing session left untouched'; exit 0; fi
    fi
    if bridge_running; then log 'Existing bridge detected; not starting a duplicate'; exit 0; fi

    if ! chrome_ready || ! novnc_ready; then
      if [[ -x "$HOME/.local/bin/bang-desktop" ]]; then
        log 'Starting installed private noVNC/Chromium desktop'
        "$HOME/.local/bin/bang-desktop" || log 'Desktop launcher returned a warning; checking actual ports'
      else
        log 'Existing bang-desktop executable missing; no installation or profile changes performed'
      fi
    fi

    # The desktop launcher can take time to bring up Xvnc and Chromium.
    for attempt in $(seq 1 45); do
      chrome_ready && break
      sleep 2
    done
    if ! chrome_ready; then
      log 'Chromium CDP 127.0.0.1:9222 offline; bridge not started; inspect noVNC and this log'
      exit 0
    fi

    if bridge_running; then log 'Bridge already running; not starting a duplicate'; exit 0; fi
    if ! command -v gh >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
      log 'Existing gh/node dependency missing; no automatic software installation performed'
      exit 0
    fi

    # A Codespaces GITHUB_TOKEN may only access LibreChat; use stored owner OAuth.
    unset GITHUB_TOKEN GH_TOKEN
    mkdir -p "$BRIDGE_DIR"
    local_tmp="$BRIDGE_DIR/bridge.mjs.tmp.$$"
    if ! gh api repos/BIGBOY87/youtube-ai-agents/contents/bangitup_growth/browser_bridge/bridge.mjs \
         -H 'Accept: application/vnd.github.raw+json' > "$local_tmp"; then
      rm -f "$local_tmp"
      log 'Private bridge not accessible with gh authentication; no browser action executed'
      exit 0
    fi
    mv -f "$local_tmp" "$BRIDGE_DIR/bridge.mjs"
    cd "$BRIDGE_DIR" || exit 0

    if [[ ! -d node_modules/playwright-core ]]; then
      if ! command -v npm >/dev/null 2>&1 || ! npm install --no-audit --no-fund playwright-core; then
        log 'Required free playwright-core dependency unavailable'
        exit 0
      fi
    fi
    log 'Starting authenticated bridge (CDP remains localhost-only)'
    exec node bridge.mjs
    ;;
  '')
    # postStartCommand must finish promptly; launch in the background.
    nohup bash "$0" --run </dev/null >>"$STATE/startup.log" 2>&1 &
    log "Startup queued. Check with: bash $0 --status"
    exit 0
    ;;
  *)
    echo 'Usage: bash bang-autostart.sh [--run|--status]' >&2
    exit 2
    ;;
esac
