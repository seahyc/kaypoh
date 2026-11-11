---
name: agent-notify
description: Post, replace, clear or inspect macOS notifications through agent-notify (your own copy and buttons, a badge per kind, a click that lands on the exact iTerm2/tmux pane, editor window, Codex thread or page). Use when you need the user's attention or a decision, when reporting a long command's result, or when debugging why a notice didn't show, vanished, or didn't focus the right place.
---

# agent-notify

`agent-notify` is on PATH. Claude Code and Codex already notify on their own when a turn ends
or needs permission (`agent-notify install` wires that). Post yourself only when you have
something more specific to say or ask.

```sh
agent-notify post --source claude --key KEY \
  --title "🙋 Can I push the hotfix to prod?" \
  --subtitle "in checkout-service" \
  --message "Tests pass on the branch. It touches billing, so I want your OK first." \
  --iterm-session "$ITERM_SESSION_ID" --urgency urgent \
  --button "go=👀 Review it" --button "🚀 Open MR=https://gitlab.com/…/merge_requests/482" --button snooze
```

## Writing the copy

Match the user's voice: `agent-notify status` prints it (genz, plain, tiger-mum,
passive-aggressive-coworker, …), and `agent-notify demo --dry-run` shows sample lines. Whatever
the voice, the user should get the point in one look. The voice is flavour; what happened has
to stay obvious.

- **Title**: one sentence saying who and what, starting with one emoji that fits. Keep it under
  about 45 characters so macOS doesn't cut it off.
- **Subtitle**: where it happened, usually `in <project>`. Leave the tool name out.
- **Message**: the one thing the user needs to know or decide, plainly enough to act on, in
  about 200 characters. Markdown is stripped, so don't use it.
- **Urgency**: `urgent` only when you're blocked on the user (a decision, an approval, a
  handoff). `normal` for "done, come look". `low` for FYI (silent, Notification Center only).

## Click and buttons

The click goes to the notice's target:

- `--iterm-session "$ITERM_SESSION_ID"` or `--tmux-pane "$TMUX_PANE"`: your exact pane.
- `--open URL`: http(s), `codex://threads/<id>`, or `vscode://` / `cursor://` /
  `windsurf://file/<path>`.
- `--run /abs/program args`.

Add `--activate BUNDLE_ID` to bring an app forward afterwards.

Without `--button`, the notice gets the voice's defaults for its kind: a "go" button labelled
for where it goes, a 10-minute snooze, and, for a done or waiting agent in a pane, a reply box
whose text is typed into your pane.

Choose your own with up to 3 `--button`. The first shows on hover, the rest under Options.

| Spec | Button |
|---|---|
| `go` / `go=👀 Review the diff` | the notice's click target, with the default or your own label |
| `snooze` / `snooze=⏰ Later` | comes back in 10 minutes |
| `reply` / `reply=💬 Answer` | a text box typed into the pane (needs `--iterm-session` or `--tmux-pane`) |
| `"🚀 Open MR=https://…"` | opens a URL |
| `"🔁 Rerun=/abs/path/script arg"` | runs a program by absolute path (space-separated args) |
| `--no-buttons` | no buttons at all |

Good button labels are 1–4 words, starting with an emoji and a verb ("✅ Ship it", "📄 Open the
report"). Offer the choices the user would actually make, best one first.

## Kinds, keys and housekeeping

- `--kind` picks the badge and sound: `done` 🎉, `waiting` 👋, `permission` 🙋, `handoff` 🧩,
  `signin` 🚪, `approval` 🔐, `run-ok` 🚀, `run-failed` 💥, `bell` 🔔. It's guessed when
  omitted. The older names (`claude-waiting`, `codex-done`, `vault-approval`, …) still work.
- Use one `--key` per resolvable thing.
  - Re-posting the same key replaces the notice.
  - `--if-new` skips it if one is already showing.
  - `agent-notify clear --source S --key K` withdraws it once resolved.
- Notices tidy away after 1 minute (`--expire SECONDS`, `0` = stay until dismissed).
- Long commands: `agent-notify run --source scripts --title "Nightly backup" -- /path/cmd args`.
- Debug:
  - `--dry-run` prints the notice instead of posting it.
  - `agent-notify list --json` shows outcomes, click targets and which button was used.
  - `agent-notify status` shows permission, banner style, voice and hooks.

Full reference: `README.md`. After editing `main.swift`, `badges.swift` or `build.sh`, run `./build.sh`.
