Set up a bidirectional backup and sync system for my Hermes installation. This backs up all custom configuration files to a private GitHub repo, with live push on local changes and pull on remote changes.

Prerequisites

Before we start, I need:

1. A GitHub account — if you don't have one, create it at https://github.com/signup
2. A Personal Access Token (PAT) — go to https://github.com/settings/tokens and create a Fine-grained token with:
   - Repository access: Only select repositories → pick your backup repo
   - Repository permissions: Contents = Read and Write
   - Copy the token immediately (you won't see it again)
3. A private GitHub repo for the backup — create one at https://github.com/new named something like Hermes-Backup. Make sure it's Private since it will contain your .env with API keys.

If you already have these, tell me:
- Your GitHub username
- Your PAT (I'll store it in git credentials, not in any backed-up files)
- The repo URL (e.g., https://github.com/YOUR-USER/Hermes-Backup.git)

What Gets Backed Up

Only custom configuration — not the 5GB hermes-agent codebase or Python venv. The actual custom state is typically under 30MB:

- config.yaml — your Hermes settings
- .env — API keys
- skills/ — all custom skills
- memories/ — persistent memory files
- cron/ — scheduled job definitions
- hooks/ — event hooks
- pairing/ — device pairing state
- auth.json, gateway_state.json, channel_directory.json — platform credentials
- SOUL.md — agent persona
- state.db — session database (nightly only, not live-watched)

How It Works

┌─────────────┐  inotify  ┌──────────────┐  git push  ┌────────┐
│  ~/.hermes/  │ ────────→ │ backup.sh    │ ─────────→ │ GitHub │
└─────────────┘           └──────────────┘            └───┬────┘
       ↑                                                  │
       │              sync-down.sh                        │
       └──────────────────────────────────────────────────┘
                     git pull (60s poll)


Local → GitHub (live): A file watcher uses inotify to monitor all backed-up files. When any change is detected, it waits 10 seconds (debounce), then commits and pushes to GitHub.

GitHub → Local (live): A second watcher polls GitHub every 60 seconds. When it detects a change, it pulls and copies files back to ~/.hermes/.

Nightly safety net: A cron job at 3 AM does a full backup in case the watcher misses anything.

Setup Instructions

Step 1: Clone or create the backup repo

cd ~/projects
git clone https://YOUR-USER:YOUR-PAT@github.com/YOUR-USER/Hermes-Backup.git
# If the repo is empty, that's fine — we'll populate it


If the repo doesn't exist yet, create it first at https://github.com/new (Private, no README).

Step 2: Create the backup manifest

This file defines what gets backed up. To add or remove files in the future, just edit this — no script changes needed.

Create ~/projects/Hermes-Backup/backup-manifest.yaml:
 (1/7)
[2026-04-09 3:33 p.m.] mayurdotai: # Hermes Backup Manifest
# ─────────────────────────
# All paths relative to HERMES_HOME (~/.hermes).
# Edit this file to add/remove backup targets — no script changes needed.

# ── Files (single file copies) ───────────────────────────────
files:
  - config.yaml
  - .env
  - auth.json
  - gateway_state.json
  - channel_directory.json
  - SOUL.md
  - config.yaml.save

# ── Directories (recursive copies) ───────────────────────────
# Format: src → source under HERMES_HOME, dest → destination in repo
directories:
  - { src: skills/,     dest: skills/,     exclude: ["__pycache__/", "*.pyc", "node_modules/", "venv/", ".git/"] }
  - { src: memories/,   dest: memories/ }
  - { src: cron/,       dest: cron/ }
  - { src: hooks/,      dest: hooks/ }
  - { src: pairing/,    dest: pairing/ }

# ── Databases (small state files with size guard) ────────────
# Backed up nightly only (too noisy for live watcher — every msg writes to state.db)
databases:
  - { src: state.db,       dest: databases/state.db,       max_size_mb: 50, watch: false }
  - { src: state.db-wal,   dest: databases/state.db-wal,   max_size_mb: 50, watch: false }
  - { src: state.db-shm,   dest: databases/state.db-shm,   max_size_mb: 10, watch: false }

# ── Never back up ────────────────────────────────────────────
exclude_patterns:
  - hermes-agent/
  - sessions/
  - cache/
  - logs/
  - bin/
  - image_cache/
  - audio_cache/
  - whatsapp/
  - sandboxes/
  - response_store.db*
  - models_dev_cache.json
  - gateway.pid
  - auth.lock


Step 3: Create the backup script

Create ~/projects/Hermes-Backup/scripts/backup.sh:
 (2/7)
[2026-04-09 3:33 p.m.] mayurdotai: #!/usr/bin/env bash
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

# ── Clean repo (preserve scripts, manifest, .git) ────────────
log "Cleaning repo working tree..."
cd "$REPO_DIR"
find . -mindepth 1 -maxdepth 1 \
    ! -name '.git' \
    ! -name 'scripts' \
    ! -name 'backup-manifest.yaml' \
    ! -name 'README.md' \
    -exec rm -rf {} + 2>/dev/null || true

# ── Process manifest ─────────────────────────────────────────
log "Copying from $HERMES_HOME..."
process_manifest

# ── Generate README ──────────────────────────────────────────
if ! $DRY_RUN; then
    cat > "$REPO_DIR/README.md" << 'EOF'
# Hermes-Backup

Automated backup of custom Hermes Agent configuration.

## Structure


backup-manifest.yaml  # What gets backed up (edit this to add files)
config.yaml           # Core settings
.env                  # API keys (private repo)
skills/               # Custom skills
memories/             # Persistent memory
cron/                 # Scheduled jobs
hooks/                # Event hooks
databases/            # State databases
scripts/              # backup.sh, sync-down.sh, watcher.sh

## Usage

bash
./scripts/backup.sh          # Push local to GitHub
./scripts/sync-down.sh       # Pull GitHub to local
./scripts/watcher.sh &       # Auto-sync GitHub changes (3/7)
[2026-04-09 3:33 p.m.] mayurdotai: 
## Adding files

Edit `backup-manifest.yaml` — add to `files:` or `directories:`.
No script changes needed.
EOF
fi

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


Step 4: Create the sync-down script

Create ~/projects/Hermes-Backup/scripts/sync-down.sh:

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

log "Updated: $BEFORE → $AFTER"

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


Step 5: Create the GitHub-to-local watcher

Create ~/projects/Hermes-Backup/scripts/watcher.sh:
 (4/7)
[2026-04-09 3:33 p.m.] mayurdotai: #!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Hermes Backup Watcher — polls GitHub for changes and syncs
# Usage: ./scripts/watcher.sh [--interval 60]
# Run as daemon: nohup ./scripts/watcher.sh &
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$SCRIPT_DIR"
SYNC_DOWN="$SCRIPT_DIR/scripts/sync-down.sh"
INTERVAL="${1:-60}"
LOG_FILE="$SCRIPT_DIR/logs/watcher.log"

mkdir -p "$SCRIPT_DIR/logs"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

cleanup() {
    log "Watcher stopped (pid $$)"
    exit 0
}
trap cleanup SIGINT SIGTERM

log "Watcher started (pid $$, interval ${INTERVAL}s)"
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
        bash "$SYNC_DOWN" 2>&1 | tee -a "$LOG_FILE"
    fi

    sleep "$INTERVAL"
done


Step 6: Create the local-to-GitHub watcher

Create ~/projects/Hermes-Backup/scripts/local-watcher.sh:
 (5/7)
[2026-04-09 3:33 p.m.] mayurdotai: #!/usr/bin/env bash
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


Step 7: Make scripts executable and configure git

chmod +x ~/projects/Hermes-Backup/scripts/*.sh
cd ~/projects/Hermes-Backup
git config user.email "your-email@example.com"
git config user.name "Hermes Backup"
git remote set-url origin https://github.com/YOUR-USER/Hermes-Backup.git


Step 8: Store git credentials (so pushes don't prompt for password)

git config credential.helper store
echo "https://YOUR-USER:YOUR-PAT@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials


Step 9: Run the first backup

cd ~/projects/Hermes-Backup
./scripts/backup.sh


You should see files being copied and a push to GitHub. Check your repo to confirm.

Step 10: Set up systemd services (persistent across reboots)

Create /etc/systemd/system/hermes-local-watcher.service:
 (6/7)
[2026-04-09 3:33 p.m.] mayurdotai: [Unit]
Description=Hermes Local Watcher - push config changes to GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /root/projects/Hermes-Backup/logs
ExecStart=/bin/bash /root/projects/Hermes-Backup/scripts/local-watcher.sh
Restart=always
RestartSec=10
Environment=HOME=/root

[Install]
WantedBy=multi-user.target


Create /etc/systemd/system/hermes-watcher.service:

[Unit]
Description=Hermes Watcher - sync GitHub changes to local
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /root/projects/Hermes-Backup/logs
ExecStart=/bin/bash /root/projects/Hermes-Backup/scripts/watcher.sh 60
Restart=always
RestartSec=10
Environment=HOME=/root

[Install]
WantedBy=multi-user.target


Enable and start both:

sudo systemctl daemon-reload
sudo systemctl enable --now hermes-local-watcher hermes-watcher
sudo systemctl status hermes-local-watcher hermes-watcher


Step 11: Set up the nightly cron job

(crontab -l 2>/dev/null; echo "0 3 * * * cd ~/projects/Hermes-Backup && /bin/bash scripts/backup.sh >> ~/projects/Hermes-Backup/logs/backup.log 2>&1") | crontab -


Step 12: Verify everything works

# Test live push — edit a watched file and wait 15 seconds
echo "# test $(date)" >> ~/.hermes/config.yaml.save
sleep 15
journalctl -u hermes-local-watcher --no-pager -n 5

# Check GitHub — the change should appear in your repo
# Then test the sync-down
cd ~/projects/Hermes-Backup
./scripts/sync-down.sh


Managing the System

Adding new files to backup

Edit backup-manifest.yaml — add to the files:, directories:, or databases: section. No script changes needed. The watchers will pick up the change on next restart:

sudo systemctl restart hermes-local-watcher


Excluding noisy files from live watch

For files that change frequently but aren't important (like databases), add watch: false to their manifest entry. They'll still be backed up nightly but won't trigger live pushes.

Manual operations

./scripts/backup.sh           # Manual push to GitHub
./scripts/backup.sh --dry-run # See what would be pushed
./scripts/sync-down.sh        # Manual pull from GitHub
./scripts/sync-down.sh --dry-run # See what would be pulled


Logs

journalctl -u hermes-local-watcher -f   # Watch live pushes
journalctl -u hermes-watcher -f          # Watch live pulls
cat ~/projects/Hermes-Backup/logs/backup.log  # Nightly backup log


Troubleshooting

Watcher not pushing? Check git credentials:
cd ~/projects/Hermes-Backup
git push origin main  # Should work without prompting


inotifywait not found?
sudo apt-get install inotify-tools


PyYAML not found?
pip install pyyaml


Permissions on .env? The backup copies .env with its original permissions. If your repo shows it as unreadable, that's expected — the backup script copies file metadata.

What Does NOT Get Backed Up

- hermes-agent/ — the full codebase (5.3GB Python venv). Reinstall from source.
- sessions/ — conversation history. Regenerable.
- cache/, logs/, bin/ — transient data.
- state.db via live watcher — backed up nightly only to avoid noisy per-message commits.

To restore from backup on a fresh machine: install hermes-agent, clone your backup repo, run ./scripts/sync-down.sh, restart the gateway.

---

System designed for hermes-agent. Tested on Ubuntu 24.04 with Python 3.11 and inotify-tools. (7/7)
