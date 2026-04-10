---
inclusion: always
---

# Hermes Backup to GitHub — Project Overview

This is a community-maintained, bidirectional backup and sync system for [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research. It version-controls custom `~/.hermes/` configuration via a user's own private GitHub repo.

This repo contains the reusable scripts and config. Users clone it, copy the scripts into their own private repo, and run from there. Do NOT put any user-specific data, credentials, or references to private backup repos into this repo.

## What is Hermes Agent?

Hermes Agent is an open-source, self-improving AI agent by Nous Research. It runs persistently (on a VPS, cloud, or local machine), connects to messaging platforms (Telegram, Discord, Slack, WhatsApp, Signal, etc.), and gets smarter over time through a built-in learning loop: it creates skills from experience, refines them during use, and maintains persistent memory across sessions.

All user configuration lives in `~/.hermes/`. This backup system protects that configuration.

## What Gets Backed Up (and what each file is)

### Files
| File | What it is in Hermes |
|------|----------------------|
| `config.yaml` | Core settings: model provider, terminal backend, TTS, compression, memory limits, toolsets |
| `.env` | API keys and secrets (OpenRouter, Anthropic, Telegram bot tokens, etc.) |
| `auth.json` | OAuth provider credentials (e.g. Nous Portal login) |
| `gateway_state.json` | State of the messaging gateway (which platforms are connected) |
| `channel_directory.json` | Maps messaging channels to their configs |
| `SOUL.md` | The agent's personality/identity file — slot #1 in the system prompt |
| `config.yaml.save` | Backup copy of config created by Hermes |

### Directories
| Directory | What it is in Hermes |
|-----------|----------------------|
| `skills/` | Agent-created and user-installed procedural skills, organized by category (e.g. `skills/github/`, `skills/creative/`, `skills/devops/`). Each skill has a `SKILL.md` and optional code. Categories have `DESCRIPTION.md` files. |
| `memories/` | Persistent memory files: `MEMORY.md` (agent knowledge), `USER.md` (user model), plus `.lock` files |
| `cron/` | Scheduled jobs: `jobs.json` defines them, `output/` stores results, `.tick.lock` for scheduling |
| `hooks/` | Event hooks that trigger on agent actions |
| `pairing/` | Device/platform pairing state (e.g. `telegram-approved.json`, `telegram-pending.json`, rate limits) |

### Databases (nightly only)
| File | Why nightly-only |
|------|-----------------|
| `state.db` | SQLite session database — every message writes to it, so live-watching would create hundreds of commits/day |
| `state.db-wal` | Write-ahead log for state.db |
| `state.db-shm` | Shared memory file for state.db |

## Architecture

```
Local (~/.hermes/) --[inotifywait]--> backup.sh --[git push]--> GitHub
GitHub --[60s poll]--> watcher.sh --[git pull]--> sync-down.sh --> Local (~/.hermes/)
Nightly cron at 3 AM --> backup.sh (safety net for databases)
```

Two systemd services keep the watchers running across reboots.

## Key Files in This Repo

| File | Purpose |
|------|---------|
| `backup-manifest.yaml` | Declarative config defining what gets backed up. Single source of truth — all scripts read from this. |
| `scripts/backup.sh` | Copies files from `~/.hermes/` to repo, commits, pushes. Uses embedded Python to parse the manifest. |
| `scripts/sync-down.sh` | Pulls from GitHub, copies changed files back to `~/.hermes/`. |
| `scripts/watcher.sh` | Polls GitHub every 60s, calls `sync-down.sh` on changes. |
| `scripts/local-watcher.sh` | Uses `inotifywait` to watch local `~/.hermes/` paths, debounces 10s, calls `backup.sh`. |
| `systemd/*.service` | Systemd unit files for the two watchers. |
| `prompt.md` | Drop-in prompt for Hermes Agent to auto-setup the system. |

## Tech Stack & Dependencies

- Bash (all scripts use `set -euo pipefail`)
- Python 3 + PyYAML (manifest parsing, embedded in bash scripts)
- `inotify-tools` (`inotifywait` for local file watching — Linux only)
- `rsync` (directory syncing with `--delete`)
- `git` with credential store
- `systemd` (service management — Linux only)

## Important Design Decisions

- `backup-manifest.yaml` is the single source of truth. Scripts never hardcode paths.
- `state.db` has `watch: false` to avoid commit spam from every message.
- The user's backup repo must be PRIVATE since it contains `.env` with API keys.
- The local watcher has a 10-second debounce to batch rapid changes.
- `backup.sh` cleans the repo working tree before copying (preserving `.git/`, `scripts/`, `logs/`, `backup-manifest.yaml`, `README.md`).
- Scripts use embedded Python (heredoc) rather than separate `.py` files to keep deployment simple.
