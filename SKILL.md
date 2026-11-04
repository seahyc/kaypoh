---
name: agent-notify
description: Post, replace, clear or inspect macOS notifications from any agent tool or script through the shared agent-notify layer (one look, emoji badge per kind, click goes to the exact iTerm pane, Codex thread, tab or page). Use when a tool needs to get YC's attention, report a long command's result, or when debugging why a notice didn't show, vanished, or didn't focus the right place.
---

# agent-notify

`agent-notify` is on PATH. Full reference: `README.md` in this folder.

- Get attention: `agent-notify post --source TOOL --title "what happened" --message "detail" --key KEY [--urgency urgent] [--open URL | --run /abs/exe args] [--iterm-session "$ITERM_SESSION_ID"]`
- Withdraw once resolved: `agent-notify clear --source TOOL --key KEY`
- Report a long command: `agent-notify run --source scripts --title "Nightly backup" -- /path/cmd args`
- Debug: `agent-notify list --json` (outcomes and click targets), `agent-notify status` (permission, banner vs persistent)

Rules: one `--key` per resolvable thing so repeats replace instead of stacking; `urgent` only when
YC is needed now; the click should land on the exact place (pane, thread, tab), not just an app.
After editing `main.swift`, `badges.swift` or `build.sh`, run `./build.sh`.
