#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Hermes GitHub Watcher — polls GitHub for changes and syncs down
# Usage: ./scripts/watcher.sh [--interval 60]
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$SCRIPT_DIR"
SYNC_DOWN="$SCRIPT_DIR/scripts/sync-down.sh"
INTERVAL="${1:-60}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    log "GitHub watcher stopped (pid $$)"
    exit 0
}
trap cleanup SIGINT SIGTERM

log "GitHub watcher started (pid $$, interval ${INTERVAL}s)"
log "Watching: $REPO_DIR"

while true; do
    cd "$REPO_DIR"

    git fetch origin main --quiet 2>/dev/null || {
        log "WARN: git fetch failed, retrying in ${INTERVAL}s"
        sleep "$INTERVAL"
        continue
    }

    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "$LOCAL")

    if [[ "$LOCAL" != "$REMOTE" ]]; then
        log "Change detected: $LOCAL -> $REMOTE"
        bash "$SYNC_DOWN" 2>&1
    fi

    sleep "$INTERVAL"
done
