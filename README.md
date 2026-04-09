# Hermes Backup to GitHub

Bidirectional backup and sync system for [Hermes Agent](https://github.com/NousResearch/hermes-agent). Keeps your custom configuration version-controlled and synced across machines via GitHub.

```
┌─────────────┐  inotify  ┌──────────────┐  git push  ┌────────┐
│  ~/.hermes/  │ ────────→ │ backup.sh    │ ─────────→ │ GitHub │
└─────────────┘           └──────────────┘            └───┬────┘
       ↑                                                  │
       │              sync-down.sh                        │
       └──────────────────────────────────────────────────┘
                     git pull (60s poll)
```

## What It Does

- **Live push** — watches your `~/.hermes/` for changes to config, skills, memory, cron jobs. Auto-commits and pushes to GitHub within 10 seconds of any edit.
- **Live pull** — polls your GitHub repo every 60 seconds. When it detects changes (e.g., you edited config on GitHub), it pulls them down to `~/.hermes/` automatically.
- **Nightly safety net** — cron job at 3 AM does a full backup in case the live watcher missed anything.

## What Gets Backed Up

Only custom configuration — not the 5GB hermes-agent codebase or Python venv. Typical size: under 30MB.

| Path | What | Live Watch |
|------|------|------------|
| `config.yaml` | Core settings | Yes |
| `.env` | API keys | Yes |
| `skills/` | Custom skills | Yes |
| `memories/` | Persistent memory | Yes |
| `cron/` | Scheduled jobs | Yes |
| `hooks/` | Event hooks | Yes |
| `pairing/` | Device pairing | Yes |
| `auth.json` | Platform credentials | Yes |
| `state.db` | Session database | No (nightly only) |

Customize what gets backed up by editing `backup-manifest.yaml` — no script changes needed.

## Quick Start

**See [prompt.md](prompt.md)** — paste it into your Hermes chat and the agent will set everything up for you.

Or do it manually:

```bash
# 1. Create a PRIVATE GitHub repo (it will contain your .env with API keys)

# 2. Clone this repo and your private backup repo
cd ~/projects
git clone https://github.com/mayurjobanputra/Hermes-Backup-to-Github.git
git clone https://github.com/YOUR-USER/YOUR-PRIVATE-REPO.git

# 3. Copy the scripts and manifest to your private backup repo
cp Hermes-Backup-to-Github/scripts/* YOUR-PRIVATE-REPO/scripts/
cp Hermes-Backup-to-Github/backup-manifest.yaml YOUR-PRIVATE-REPO/

# 4. Configure git credentials
cd YOUR-PRIVATE-REPO
git config user.email "you@example.com"
git config user.name "Hermes Backup"
git config credential.helper store
echo "https://YOUR-USER:YOUR-PAT@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials

# 5. Run first backup
./scripts/backup.sh

# 6. Set up systemd services
sudo cp ../Hermes-Backup-to-Github/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-local-watcher hermes-github-watcher

# 7. Set up nightly cron
(crontab -l 2>/dev/null; echo "0 3 * * * cd ~/projects/YOUR-PRIVATE-REPO && ./scripts/backup.sh >> logs/backup.log 2>&1") | crontab -
```

## File Structure

```
Hermes-Backup-to-Github/
├── README.md                  # This file
├── prompt.md                  # Drop into Hermes chat for auto-setup
├── backup-manifest.yaml       # Defines what gets backed up
├── scripts/
│   ├── backup.sh              # Push local config to GitHub
│   ├── sync-down.sh           # Pull GitHub config to local
│   ├── watcher.sh             # Poll GitHub for changes (pull)
│   └── local-watcher.sh       # Watch local files for changes (push)
└── systemd/
    ├── hermes-local-watcher.service
    └── hermes-github-watcher.service
```

## Dependencies

- **Python 3** with PyYAML (`pip install pyyaml`)
- **inotify-tools** (`sudo apt-get install inotify-tools`)
- **rsync** (usually pre-installed)
- **git** with credential store configured

## Adding Files to Backup

Edit `backup-manifest.yaml`:

```yaml
files:
  - config.yaml
  - .env
  - my-custom-file.json        # ← add here

directories:
  - { src: skills/, dest: skills/ }
  - { src: my-data/, dest: my-data/ }  # ← or here
```

Restart the watcher: `sudo systemctl restart hermes-local-watcher`

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Watcher not pushing | `cd ~/projects/BACKUP-REPO && git push origin main` — should work without prompt |
| inotifywait not found | `sudo apt-get install inotify-tools` |
| PyYAML not found | `pip install pyyaml` |
| Too many pushes | Check `journalctl -u hermes-local-watcher` — likely state.db in manifest with `watch: true` |
| Service won't start | `journalctl -u hermes-local-watcher -n 50` for errors |

## Restoring on a Fresh Machine

1. Install hermes-agent
2. Clone your private backup repo: `git clone https://github.com/YOUR-USER/YOUR-PRIVATE-REPO.git ~/projects/YOUR-PRIVATE-REPO`
3. Run: `./scripts/sync-down.sh`
4. Restart gateway: `hermes gateway restart`

## License

MIT — use freely, modify, share back.
