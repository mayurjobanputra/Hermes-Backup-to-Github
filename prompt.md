Set up a bidirectional backup and sync system for my Hermes installation. This backs up all custom configuration files to a private GitHub repo, with live push on local changes and pull on remote changes.

Everything you need is in the community repo: https://github.com/mayurjobanputra/Hermes-Backup-to-Github

## Prerequisites

Before we start, I need to provide you with:

1. **A GitHub account** — create one at https://github.com/signup if needed
2. **A Personal Access Token (PAT)** — go to https://github.com/settings/tokens and create a Fine-grained token with:
   - Repository access: **Only select repositories** → pick your backup repo
   - Repository permissions: **Contents** = Read and Write
   - Copy the token immediately (you won't see it again)
3. **A private GitHub repo** for the backup — create one at https://github.com/new named something like `Hermes-Backup`. **Make it Private** since it will contain your `.env` with API keys.

Tell the agent:
- Your GitHub username
- Your PAT (stored in `~/.git-credentials`, never in the backup repo)
- Your private backup repo URL (e.g., `https://github.com/YOUR-USER/Hermes-Backup.git`)

## Setup Steps

Clone the community repo first, then copy the scripts into the user's private backup repo. Do NOT store personal credentials in the community repo.

```bash
cd ~/projects
git clone https://github.com/mayurjobanputra/Hermes-Backup-to-Github.git
git clone https://github.com/USER/PRIVATE-REPO.git
```

Copy setup files from community repo to private backup repo:

```bash
cd ~/projects/PRIVATE-REPO
mkdir -p scripts systemd logs
cp ../Hermes-Backup-to-Github/scripts/* scripts/
cp ../Hermes-Backup-to-Github/backup-manifest.yaml .
cp ../Hermes-Backup-to-Github/systemd/* systemd/
chmod +x scripts/*.sh
```

Configure git and store credentials:

```bash
cd ~/projects/PRIVATE-REPO
git config user.email "user@example.com"
git config user.name "Hermes Backup"
git remote set-url origin https://github.com/USER/PRIVATE-REPO.git
git config credential.helper store
echo "https://USER:PAT@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials
```

Install system dependencies:

```bash
sudo apt-get install -y inotify-tools
pip install pyyaml  # if not already installed
```

Run the first backup:

```bash
./scripts/backup.sh
```

Set up systemd services. Copy the service files to `/etc/systemd/system/` and edit the `ExecStart` paths to point to the actual backup repo location (`~/projects/PRIVATE-REPO/scripts/`). Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-local-watcher hermes-github-watcher
sudo systemctl status hermes-local-watcher hermes-github-watcher
```

Set up nightly cron job:

```bash
(crontab -l 2>/dev/null; echo "0 3 * * * cd ~/projects/PRIVATE-REPO && ./scripts/backup.sh >> logs/backup.log 2>&1") | crontab -
```

## Verification

Test the full loop:

1. Edit a watched file: `echo "# test" >> ~/.hermes/config.yaml.save`
2. Wait 15 seconds for debounce + push
3. Check: `journalctl -u hermes-local-watcher --no-pager -n 5`
4. Verify on GitHub — the change should be in the repo

## What Gets Backed Up

See `backup-manifest.yaml` — it defines everything. To add or remove files, just edit the manifest. No script changes needed.

Key points:
- Databases (`state.db`) have `watch: false` — they change on every message and would cause noisy pushes. They're backed up nightly via cron instead.
- The `exclude_patterns` section lists things that should never be backed up (5GB venv, sessions, cache, etc.).

## Architecture

```
Local -> GitHub: inotifywait watches manifest paths -> 10s debounce -> backup.sh -> git push
GitHub -> Local: polls every 60s -> git pull -> sync-down.sh -> copies to ~/.hermes/
Nightly: cron at 3 AM -> backup.sh (safety net)
```

Two systemd services keep this running across reboots. See `README.md` in the community repo for full details and troubleshooting.
