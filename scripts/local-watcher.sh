#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Hermes Local Watcher — watches ~/.hermes for changes to
# backed-up files and auto-pushes to GitHub.
# Usage: ./scripts/local-watcher.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$SCRIPT_DIR/backup-manifest.yaml"
REPO_DIR="$SCRIPT_DIR"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
BACKUP="$SCRIPT_DIR/scripts/backup.sh"
DEBOUNCE_SEC=10

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    log "Local watcher stopped (pid $$)"
    exit 0
}
trap cleanup SIGINT SIGTERM

# ── Build watch list from manifest ───────────────────────────
WATCH_PATHS=()

# Files
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    p="$HERMES_HOME/$f"
    [[ -e "$p" ]] && WATCH_PATHS+=("$p")
done < <(python3 -c "
import yaml
with open('$MANIFEST') as f: m = yaml.safe_load(f)
for f in m.get('files', []): print(f)
")

# Directories
while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    p="$HERMES_HOME/$d"
    [[ -d "$p" ]] && WATCH_PATHS+=("$p")
done < <(python3 -c "
import yaml
with open('$MANIFEST') as f: m = yaml.safe_load(f)
for d in m.get('directories', []): print(d['src'])
")

# Databases (skip if watch: false)
while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    p="$HERMES_HOME/$d"
    [[ -e "$p" ]] && WATCH_PATHS+=("$p")
done < <(python3 -c "
import yaml
with open('$MANIFEST') as f: m = yaml.safe_load(f)
for d in m.get('databases', []):
    if d.get('watch', True): print(d['src'])
")

if [[ ${#WATCH_PATHS[@]} -eq 0 ]]; then
    log "ERROR: No paths to watch"
    exit 1
fi

log "Local watcher started (pid $$)"
log "Watching ${#WATCH_PATHS[@]} paths:"
for p in "${WATCH_PATHS[@]}"; do
    log "  📁 $p"
done

# ── Watch loop with debounce ────────────────────────────────
pending=false
last_trigger=""

while true; do
    change=$(inotifywait -r -q \
        --event modify,create,delete,move \
        --format '%w%f' \
        --exclude '(\.pyc$|__pycache__|\.swp$|\.tmp$|\.lock$)' \
        "${WATCH_PATHS[@]}" 2>/dev/null || true)

    if [[ -n "$change" ]]; then
        [[ "$change" == *.lock ]] && continue
        [[ "$change" == *"local-watcher"* ]] && continue

        log "Change detected: $change"
        pending=true
        last_trigger="$change"
    fi

    if $pending; then
        log "Debouncing ${DEBOUNCE_SEC}s (triggered by: $last_trigger)..."
        sleep "$DEBOUNCE_SEC"

        # Drain any queued events during debounce
        timeout 1 inotifywait -r -q \
            --event modify,create,delete,move \
            "${WATCH_PATHS[@]}" 2>/dev/null || true

        log "Running backup..."
        if bash "$BACKUP" 2>&1; then
            log "✓ Backup complete"
        else
            log "✗ Backup failed"
        fi
        pending=false
        last_trigger=""
    fi
done
