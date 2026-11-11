# agent-notify

**Notifications for your coding agents that take you to the right pane, in a voice you pick.**

Claude Code finished in one tab, Codex wants permission in another, and a test run died in a
third. agent-notify tells you which one, quotes what the agent said, and a click lands on that
exact iTerm2 pane, tmux pane, VS Code or Cursor window, or Codex thread. It's macOS-native, free,
and nothing leaves your Mac.

```
🎉 Claude done. Why not faster?                           [🎉]
in checkout-service
“Fixed the flaky login test and added a retry. All 214 tests pass. Want me to open the PR?”
                                  💬 Tell Claude off   📝 Check the work   😴 Nag me in 10 min
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/seahyc/agent-notify/main/install.sh | sh
```

or with Homebrew:

```sh
brew install seahyc/tap/agent-notify && agent-notify install
```

Either way, it builds a tiny app from source (needs the Xcode Command Line Tools:
`xcode-select --install`) and wires itself into Claude Code and Codex. Your existing config is
backed up first and other hooks are left alone. Then:

```sh
agent-notify demo            # see a few
agent-notify voice           # list voices
agent-notify voice tiger-mum # pick one
```

## What you get

- **The right place, one click.** iTerm2 window, tab and split pane; tmux pane; the VS Code,
  Cursor or Windsurf window for that repo; the Codex app thread. Anywhere else, it brings the
  app forward.
- **What happened, not "waiting for input".** The title says done, needs your OK, or failed.
  The body quotes the agent's last message as plain text, with the markdown stripped.
- **Reply from the notice.** Type an answer and it's sent to the agent's iTerm2 or tmux pane.
- **Quiet by default.** Turns shorter than 20 s don't notify, because you were watching. The
  same session replaces its notice instead of stacking. Each tool gets 3 notices per 10 minutes,
  and the rest fold into one "N more" summary. Notices clear when you go back and type, and
  tidy themselves away after a minute. Permission requests always come through.
- **Ten voices.** Pick one, or write your own.

## Voices

| Voice | "Done" sounds like | "Needs your OK" sounds like |
|---|---|---|
| `genz` (default) | 🔥 Claude cooked, come look | 🙋 Claude needs ur OK, no cap |
| `plain` | 🎉 Claude finished, your turn | 🙋 Claude needs your OK |
| `tiger-mum` | ✅ Claude done. Cousin's was faster | 🙋 Claude needs your OK. Decide |
| `needy-partner` | 🥹 Claude finished. Notice me? | 🙋 Claude needs your OK. Please? |
| `passive-aggressive-coworker` | 📎 Claude is done. Please advise | 🙂 Claude needs OK. Thanks! |
| `butler` | 🎩 Claude has finished. If I may | 🛎️ Claude awaits your permission |
| `drill-sergeant` | ✅ Claude finished. ON YOUR FEET | ✋ Claude HALTED. Give the OK |
| `sports-commentator` | 🏆 AND IT'S IN! Claude is done | 🚩 Claude stopped. Needs your OK |
| `cat` | 🐈 I sat on keys. Claude finished | 🐾 Claude needs your OK. Paws off |
| `auntie` | 😋 Claude done. You eat already? | 🙋 Claude needs OK. Can or not? |

A voice is a JSON file of titles, button labels and a few message lines per event
([`personas/plain.json`](personas/plain.json) is the reference). To make your own, copy one to
`~/.config/agent-notify/personas/NAME.json`, edit it, and run `agent-notify voice NAME`.
`python3 tests/check_personas.py your.json` checks it against the limits macOS uses for
truncation. Pull requests with new voices are welcome.

## Works with

| Agent | How it hooks in |
|---|---|
| Claude Code (terminal, VS Code, desktop) | `Stop`, `Notification` and `UserPromptSubmit` hooks in `~/.claude/settings.json` |
| Codex (CLI and app) | `notify` in `~/.codex/config.toml`. An existing notify program is chained, not replaced. |
| Anything else | `agent-notify post …` from a hook, a script, or the agent itself (below) |

| Where the agent runs | A click goes to |
|---|---|
| iTerm2 | the exact window, tab and split pane (asks once for permission to control iTerm2) |
| tmux (in any terminal) | the exact window and pane |
| VS Code, Cursor, Windsurf | the window for that repository |
| Codex app | that thread |
| Terminal, Ghostty, Warp, WezTerm, kitty | the app comes forward |

## Post your own

Any agent or script can post, and the agent can write its own copy and buttons:

```sh
agent-notify post --source claude --key deploy-482 \
  --title "🙋 Can I push the hotfix to prod?" --subtitle "in checkout-service" \
  --message "Tests pass. It touches billing, so I want your OK first." \
  --iterm-session "$ITERM_SESSION_ID" --urgency urgent \
  --button "go=👀 Review it" --button "🚀 Open MR=https://gitlab.com/…/merge_requests/482" --button snooze

agent-notify run --source scripts --title "Nightly backup" -- ./backup.sh   # reports how it went
agent-notify clear --source claude --key deploy-482                         # withdraw once resolved
```

- `--key` names the event. Posting the same key replaces the notice, `--if-new` posts only if
  nothing with that key is showing, and `clear` withdraws it.
- `--urgency urgent` is for "blocked on you". `low` is silent and goes to Notification Center
  only.
- The click target is `--iterm-session`, `--tmux-pane`, `--open URL` (http, https, `codex://`,
  `vscode://`, `cursor://`, `windsurf://`) or `--run /abs/program args`, plus `--activate
  BUNDLE_ID`.
- You can add up to 3 `--button`: `go`, `snooze`, `reply`, `"Label=https://…"` or
  `"Label=/abs/program args"`.
- `--kind` sets the badge and sound: `done` 🎉, `waiting` 👋, `permission` 🙋, `handoff` 🧩,
  `signin` 🚪, `approval` 🔐, `run-ok` 🚀, `run-failed` 💥, `bell` 🔔.
- `--dry-run` prints the notice as JSON instead of posting it.

[`SKILL.md`](SKILL.md) is a drop-in skill that teaches agents to write good notices.

## Settings

`~/.config/agent-notify/config.json`, or the matching environment variable:

| Key | Env | Default | |
|---|---|---|---|
| `voice` | `AGENT_NOTIFY_VOICE` | `genz` | persona pack name |
| `minSeconds` | `AGENT_NOTIFY_MIN_SECONDS` | `20` | shorter agent turns don't notify |
| `expire` | `AGENT_NOTIFY_EXPIRE` | `60` | seconds before a notice tidies away (`0` = never) |

macOS shows notices either as banners that hide after about 5 s, or as alerts that stay until
dismissed. `agent-notify install` opens the settings pane so you can choose. `agent-notify
status` shows the current style, the voice, and whether the hooks are wired.

## Uninstall

```sh
agent-notify uninstall          # removes only its own hooks; a chained Codex notify is restored
rm -rf ~/.local/share/agent-notify ~/.local/libexec/agent-notify ~/.local/bin/agent-notify
```

## How it works

A single Swift file builds a small ad-hoc-signed app (`Agent Notify.app`, no Dock icon) that
posts through Notification Center. The click target travels inside the notice, so macOS
relaunches the app on a click and it focuses the pane. It never executes anything except the
target you or the hook put there. State and history live in `~/.local/state/agent-notify/`.
There's no network, no telemetry, and no model calls: the agent's own words are the copy.

Urgent notices can't break through Focus modes, because that entitlement needs a paid Apple
provisioning profile.

## Develop

```sh
./build.sh                                                  # build and install to ~/.local/libexec
NO_REGISTER=1 APP_DIR=/tmp/an-test ./build.sh && APP_DIR=/tmp/an-test python3 tests/test_cli.py
python3 tests/check_personas.py
```

MIT licensed.
