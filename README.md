# agent-notify

One notification layer for every agent tool on this Mac: one look, one interface, no spam.
A tiny ad-hoc-signed app (`~/.local/libexec/agent-notify/Agent Notify.app`, bundle id
`com.seahyc.agent-notify`) posts through macOS Notification Center. `agent-notify` is on PATH.

## Use it from any tool

```sh
agent-notify post --source TOOL --title "what happened" --message "detail" \
  [--subtitle TEXT] [--kind KIND] [--key KEY] [--urgency low|normal|urgent] [--sound] [--if-new] \
  [--open https://...|codex://threads/ID | --run /abs/program args...] \
  [--iterm-session $ITERM_SESSION_ID] [--activate BUNDLE_ID]
agent-notify clear --source TOOL --key KEY        # withdraw once resolved
agent-notify run --source scripts --title "Nightly backup" -- /path/to/backup.sh args
agent-notify list [--json]                        # recent history (with each click target)
agent-notify status [--open-settings]             # allowed? persistent or temporary banners?
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

## Kinds: badge, sound and copy

Every notice gets an emoji badge (drawn by `badges.swift`, shown on the right), a system
sound, and a title that starts with its tool's emoji (🧡 Claude Code, 🤖 Codex, 🌐 browserctrl,
🗝️ agent-vault, ⚙️ Scripts). Pass `--kind`, or it is guessed from the tool and title.

| Kind | Badge | Sound | Used for |
|---|---|---|---|
| `claude-waiting` | 👋 coral | Pop | Claude Code is waiting for you |
| `claude-permission` | 🙋 red | Hero | Claude Code needs a permission |
| `codex-done` | 🎉 mint | Glass | a Codex turn finished |
| `browser-handoff` / `-signin` / `-debug` | 🧩 / 🚪 / 🔌 blue | Submarine | browserctrl needs you in a tab |
| `vault-approval` | 🔐 gold | Purr | agent-vault approval |
| `run-ok` / `run-failed` | 🚀 green / 💥 red | Ping / Basso | `agent-notify run` results |
| `pile` | 📚 purple | none | the "N more piling up" summary |
| `bell` | 🔔 indigo | Tink | anything else |

The hooks and `run` pick a random title from a few lines per kind ("👋 Claude finished and it's your turn",
"🎉 Codex wrapped up, over to you") in plain words, put the project in the subtitle ("in olympus"),
and end the body with what a click does.
Low-urgency notices are silent.

## Click and actions

- **Click / 👉 Take me there**: go to where it came from. A Claude Code or Codex CLI session in iTerm2
  focuses its exact window, tab and split pane. A Codex app turn opens that thread
  (`codex://threads/<id>`). browserctrl focuses the tab; agent-vault opens the approval page.
- **💬 Reply** (Claude Code waiting, in iTerm2): types your text into that pane and presses Return.
- **😴 Remind me in 10 min**: macOS brings the notice back in 10 minutes, marked ⏰.
  Plain notices with nowhere to go have no buttons, so nothing covers their text on hover.

The first iTerm2 focus or reply asks once whether Agent Notify may control iTerm2.

## Staying on screen

macOS shows a notice as a temporary banner (hides after about 5 s) or a persistent alert (stays
until dismissed), chosen per app in System Settings. The app asks for persistent alerts, but
macOS only applies that default the first time an app registers. `agent-notify status` reports
the current style; `--open-settings` opens the pane to switch it to Persistent.

Urgent notices can't be time-sensitive (break through Focus): that entitlement needs a
provisioning profile, and macOS kills an ad-hoc-signed app that claims it.

Notices remove themselves after 5 minutes (re-posting the same key restarts the clock).
`--expire SECONDS` changes it per notice, `AGENT_NOTIFY_EXPIRE` for everything, `0` = never.
They are grouped per session, thread or event, not per tool, so they don't pile into one stack
(the first click on a stack only expands it).

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
| Codex | `notify` in `~/.codex/config.toml` → `bin/codex-notify` (keeps Computer Use's signal) |
| Scripts | `agent-notify run --source scripts --title … -- cmd` |

## Build

`./build.sh` compiles `main.swift`, draws the icon from `icon.swift` and the badges from
`badges.swift`, copies the system sounds, signs ad hoc and
registers the app. The first post asks macOS for permission once (System Settings →
Notifications → Agent Notify).

## Install

The repo lives at `~/Code/agent-notify`, linked as `~/.agents/skills/agent-notify`. The
`agent-notify` shim in `~/.agents/bin` (linked into `~/.local/bin` by `~/.agents/scripts/setup.sh`)
runs the built app.
