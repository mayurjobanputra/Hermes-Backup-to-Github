#!/usr/bin/env python3
"""
Generate an AI-powered commit message from a git diff via OpenRouter.

Usage: echo "$DIFF" | python3 scripts/ai-commit-msg.py <config_path>

Reads the diff from stdin, sends it to OpenRouter, prints the commit message
to stdout. Exits with code 1 on any failure (caller should fall back to
default message).
"""
import sys
import json
import urllib.request
import urllib.error
import yaml
from pathlib import Path

SYSTEM_PROMPT = """\
You are a commit message generator for a Hermes Agent backup system.

Hermes Agent is a self-improving AI agent by Nous Research. Users back up their
~/.hermes/ configuration to GitHub. The backup includes:

- config.yaml: core settings (model, terminal backend, TTS, toolsets)
- .env: API keys and secrets
- auth.json: OAuth credentials
- SOUL.md: the agent's personality/identity
- skills/: procedural skills organized by category (agent-created and installed)
- memories/: persistent memory (MEMORY.md = agent knowledge, USER.md = user model)
- cron/: scheduled jobs (jobs.json + output/)
- hooks/: event hooks
- pairing/: messaging platform pairing state
- gateway_state.json, channel_directory.json: messaging gateway config
- databases/state.db: session database (nightly only)

Given a git diff of changes to these files, write a concise, informative commit
message. Format:

- First line: short summary (max 72 chars), no "backup:" prefix
- If there are notable details, add a blank line then 1-3 bullet points

Focus on WHAT changed meaningfully (e.g. "Add arxiv research skill" or
"Update Telegram pairing config") rather than listing every file touched.
If it's just routine timestamp changes or minor state updates, say so briefly.
Do NOT wrap the message in quotes or markdown code blocks.\
"""

MAX_DIFF_CHARS = 8000  # keep token usage low


def main():
    if len(sys.argv) < 2:
        print("Usage: echo $DIFF | python3 ai-commit-msg.py <config_path>", file=sys.stderr)
        sys.exit(1)

    config_path = Path(sys.argv[1])
    if not config_path.is_file():
        sys.exit(1)

    with open(config_path) as f:
        config = yaml.safe_load(f) or {}

    ai_cfg = config.get("ai_commit_messages", {})
    if not ai_cfg.get("enabled"):
        sys.exit(1)

    api_key = ai_cfg.get("openrouter_api_key", "").strip()
    if not api_key:
        sys.exit(1)

    model = ai_cfg.get("model", "openai/gpt-4o-mini")

    diff = sys.stdin.read().strip()
    if not diff:
        sys.exit(1)

    # Truncate large diffs to keep costs down
    if len(diff) > MAX_DIFF_CHARS:
        diff = diff[:MAX_DIFF_CHARS] + "\n\n[diff truncated]"

    payload = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Generate a commit message for this diff:\n\n{diff}"},
        ],
        "max_tokens": 200,
        "temperature": 0.3,
    }).encode()

    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/mayurjobanputra/Hermes-Backup-to-Github",
            "X-Title": "Hermes Backup",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read())
        msg = body["choices"][0]["message"]["content"].strip()
        if msg:
            print(msg)
            sys.exit(0)
    except (urllib.error.URLError, KeyError, IndexError, json.JSONDecodeError) as e:
        print(f"AI commit msg failed: {e}", file=sys.stderr)

    sys.exit(1)


if __name__ == "__main__":
    main()
