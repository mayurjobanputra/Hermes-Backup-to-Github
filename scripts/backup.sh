#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Hermes Backup — push local config to GitHub
# Usage: ./scripts/backup.sh [--dry-run]
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$SCRIPT_DIR/backup-manifest.yaml"
REPO_DIR="$SCRIPT_DIR"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log()  { printf '[backup] %s\n' "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

# ── Python manifest processor ────────────────────────────────
process_manifest() {
python3 - "$HERMES_HOME" "$REPO_DIR" "$MANIFEST" "$DRY_RUN" << 'PYEOF'
import yaml, os, sys, shutil, subprocess
from pathlib import Path

hermes_home = Path(sys.argv[1])
repo_dir = Path(sys.argv[2])
manifest_path = Path(sys.argv[3])
dry_run = sys.argv[4] == "true"

with open(manifest_path) as f:
    m = yaml.safe_load(f)

actions = []

# 1. Copy files
for fname in m.get("files", []):
    src = hermes_home / fname
    dst = repo_dir / fname
    if src.is_file():
        actions.append(("file", str(src), str(dst), fname))
    else:
        print(f"  ⊘ {fname} (not found)")

# 2. Copy directories
for d in m.get("directories", []):
    src = hermes_home / d["src"]
    dst = repo_dir / d["dest"]
    excludes = d.get("exclude", [])
    if src.is_dir():
        actions.append(("dir", str(src), str(dst), d["src"], excludes))
    else:
        print(f"  ⊘ {d['src']} (not found)")

# 3. Copy databases (with size guard)
for db in m.get("databases", []):
    src = hermes_home / db["src"]
    dst = repo_dir / db["dest"]
    max_mb = db.get("max_size_mb", 50)
    if src.is_file():
        size_mb = src.stat().st_size / (1024 * 1024)
        if size_mb > max_mb:
            print(f"  ⊘ {db['src']} ({size_mb:.1f}MB exceeds {max_mb}MB)")
        else:
            actions.append(("file", str(src), str(dst), db["src"]))
    else:
        print(f"  ⊘ {db['src']} (not found)")

# Execute actions
for action in actions:
    kind = action[0]
    src, dst, label = action[1], action[2], action[3]
    if dry_run:
        print(f"  [dry] {label}")
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if kind == "file":
        shutil.copy2(src, dst)
    elif kind == "dir":
        excludes = action[4]
        cmd = ["rsync", "-a", "--delete", "--exclude=.git/"]
        for ex in excludes:
            cmd.append(f"--exclude={ex}")
        cmd.extend([f"{src}/", f"{dst}/"])
        subprocess.run(cmd, check=True)
    print(f"  ✓ {label}")

print(f"SYNCED_COUNT={len(actions)}")
PYEOF
}

# ── Clean repo (preserve scripts, manifest, .git, templates, systemd) ──
log "Cleaning repo working tree..."
cd "$REPO_DIR"
find . -mindepth 1 -maxdepth 1 \
    ! -name '.git' \
    ! -name 'scripts' \
    ! -name 'systemd' \
    ! -name 'templates' \
    ! -name 'backup-manifest.yaml' \
    ! -name 'prompt.md' \
    ! -name 'README.md' \
    -exec rm -rf {} + 2>/dev/null || true

# ── Process manifest ─────────────────────────────────────────
log "Copying from $HERMES_HOME..."
process_manifest

# ── Commit & Push ────────────────────────────────────────────
cd "$REPO_DIR"
git add -A

if git diff --cached --quiet; then
    log "No changes. Done."
    exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
CHANGED=$(git diff --cached --stat | tail -1)
git commit -m "backup: $TIMESTAMP" -m "$CHANGED"

if ! $DRY_RUN; then
    git push origin main 2>&1
    log "✓ Pushed to GitHub"
else
    log "[dry] Would push: $CHANGED"
fi
