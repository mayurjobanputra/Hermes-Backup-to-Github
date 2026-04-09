#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Hermes Sync-Down — pull GitHub config back to HERMES_HOME
# Usage: ./scripts/sync-down.sh [--dry-run]
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$SCRIPT_DIR/backup-manifest.yaml"
REPO_DIR="$SCRIPT_DIR"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log()  { printf '[sync-down] %s\n' "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

# ── Pull latest ──────────────────────────────────────────────
cd "$REPO_DIR"
BEFORE=$(git rev-parse HEAD)
git pull origin main --ff-only 2>&1 || die "git pull failed"
AFTER=$(git rev-parse HEAD)

if [[ "$BEFORE" == "$AFTER" ]]; then
    log "Already up to date."
    exit 0
fi

log "Updated: $BEFORE -> $AFTER"

# ── Python sync engine ──────────────────────────────────────
python3 - "$HERMES_HOME" "$REPO_DIR" "$MANIFEST" "$DRY_RUN" << 'PYEOF'
import yaml, os, sys, shutil, subprocess
from pathlib import Path

hermes_home = Path(sys.argv[1])
repo_dir = Path(sys.argv[2])
manifest_path = Path(sys.argv[3])
dry_run = sys.argv[4] == "true"

with open(manifest_path) as f:
    m = yaml.safe_load(f)

count = 0

# Sync files
for fname in m.get("files", []):
    src = repo_dir / fname
    dst = hermes_home / fname
    if src.is_file():
        if dry_run:
            print(f"  [dry] {fname}")
        else:
            os.makedirs(dst.parent, exist_ok=True)
            shutil.copy2(src, dst)
            print(f"  ✓ {fname}")
        count += 1

# Sync directories
for d in m.get("directories", []):
    src = repo_dir / d["dest"]
    dst = hermes_home / d["src"]
    if src.is_dir():
        if dry_run:
            print(f"  [dry] {d['dest']} -> {d['src']}")
        else:
            os.makedirs(dst, exist_ok=True)
            subprocess.run(["rsync", "-a", "--delete", f"{src}/", f"{dst}/"], check=True)
            print(f"  ✓ {d['dest']} -> {d['src']}")
        count += 1

# Sync databases
for db in m.get("databases", []):
    src = repo_dir / db["dest"]
    dst = hermes_home / db["src"]
    if src.is_file():
        if dry_run:
            print(f"  [dry] {db['dest']} -> {db['src']}")
        else:
            os.makedirs(dst.parent, exist_ok=True)
            shutil.copy2(src, dst)
            print(f"  ✓ {db['dest']} -> {db['src']}")
        count += 1

print(f"\nSynced {count} items.")
PYEOF

log "✓ Sync complete."
log "Restart gateway to pick up changes: hermes gateway restart"
