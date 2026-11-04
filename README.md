# agent-notify

One notification layer for every agent tool on this Mac: one look, one interface, no spam.
A tiny ad-hoc-signed app (`~/.local/libexec/agent-notify/Agent Notify.app`, bundle id
`local.agents.notify`) posts through macOS Notification Center. `agent-notify` is on PATH.

## Use it from any tool

```sh
agent-notify post --source TOOL --title "what happened" --message "detail" \
  [--key KEY] [--urgency low|normal|urgent] [--sound] [--if-new] \
  [--open https://... | --run /abs/program args...] [--activate BUNDLE_ID]
agent-notify clear --source TOOL --key KEY        # withdraw once resolved
agent-notify run --source scripts --title "Nightly backup" -- /path/to/backup.sh args
agent-notify list [--json]                        # recent history
```

- `--source` is the tool (`browserctrl`, `agent-vault`, `claude`, `codex`, `scripts`, …).
- `--key` names the event. Posting the same key again replaces the notice instead of
  stacking, and `clear` withdraws it. Use one key per thing that can be resolved
  (a request id, a tab, a session).
- `--if-new` posts only when no notice with that key is showing, so a state that is seen
  again and again (a site still blocking) alerts once.
- `--urgency urgent` is for things that need you now (approvals, handoffs, permission
  prompts). `low` is quiet and goes to Notification Center only.
- A click performs the action: open the URL, or run the program, then bring
  `--activate`'s app forward. Nothing else in a notice is ever executed.
- `run` reports "<title> finished in 3m 12s" or "<title> failed" with the exit status,
  and exits with the command's status.

## Design and anti-spam

- Every notice is titled `<Tool> · <what happened>` and grouped per tool.
- Each tool gets at most 3 non-urgent notices per 10 minutes. The rest fold into one
  "N more notices" summary that keeps updating. Urgent notices always show.
- A replaced notice doesn't count against the budget. State and history live in
  `~/.local/state/agent-notify/` (history is capped at 1 MB).
- Posting returns immediately, so it never slows a hook. A later click relaunches the app.

## Wired in

| Tool | How |
|---|---|
| browserctrl | Tab handoffs (captcha, sign-in): urgent, keyed per tab, opens the tab, withdrawn when solved |
| agent-vault | Approval requests: urgent, keyed per request, opens the approval page, withdrawn when decided |
| Claude Code | `Notification` hook in `~/.claude/settings.json`: `agent-notify hook claude`; built-in channel off |
| Codex | `notify` in `~/.codex/config.toml` → `~/.agents/bin/codex-notify` (keeps Computer Use's signal) |
| Scripts | `agent-notify run --source scripts --title … -- cmd` |

## Build

`./build.sh` compiles `main.swift`, draws the icon from `icon.swift`, signs ad hoc and
registers the app. The first post asks macOS for permission once (System Settings →
Notifications → Agent Notify).
