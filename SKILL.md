---
name: agent-notify
description: Post, replace, clear or inspect macOS notifications from any agent tool or script through the shared agent-notify layer (emoji badge per kind, your own copy and buttons, a click that lands on the exact iTerm pane, Codex thread, tab or page). Use when you need YC's attention or a decision, when reporting a long command's result, or when debugging why a notice didn't show, vanished, or didn't focus the right place.
---

# agent-notify

`agent-notify` is on PATH. Claude Code and Codex already notify automatically when a turn ends
or needs permission; post yourself only when you have something more specific to say or ask.

```sh
agent-notify post --source claude --key KEY \
  --title "🙋 Should I push the hotfix to production?" \
  --subtitle "in olympus" \
  --message "Tests pass on the branch. It touches billing, so I'd like your OK first." \
  --iterm-session "$ITERM_SESSION_ID" --urgency urgent \
  --button "go=👀 Review it" --button "🚀 Open MR=https://gitlab.com/…/merge_requests/482" --button snooze
```

## Writing the copy

YC wants it fun but plain: conversational, contextual, simple sentences. Never terse or cryptic.

- **Title**: one full sentence that says who and what, starting with one emoji that fits
  ("✅ The migration finished and the data checks out", "🙋 I need your OK to delete 3 old buckets").
  No jargon or puns that need decoding. Under ~60 characters.
- **Subtitle**: where it happened, usually `in <project>`. Leave the tool name out; the emoji
  and title already say it.
- **Message**: the one thing YC needs to know or decide, then what a click does
  ("Click to jump to its iTerm tab."). One or two sentences, ~200 characters.
- **Urgency**: `urgent` only when you're blocked on YC (a decision, an approval, a handoff).
  `normal` for "done, have a look". `low` for FYI (silent, Notification Center only).

## Click and buttons

The click goes to the notice's target: `--iterm-session "$ITERM_SESSION_ID"` (your exact pane),
`--open URL` (http, https, or `codex://threads/<id>`), or `--run /abs/program args`.
Add `--activate BUNDLE_ID` to bring an app forward afterwards.

Without `--button`, the notice gets defaults for its kind:
👉 go (labelled to say where: "👀 Review it", "💬 Open conversation", "🔐 Review request",
"🧭 Open the tab", "🔍 Show me"), 😴 Remind me in 10 min, and for a waiting Claude in iTerm,
💬 Reply (YC's text is typed into your pane).

Choose your own with up to 3 `--button` (the first one shows on hover, the rest under Options):

| Spec | Button |
|---|---|
| `go` / `go=👀 Review the diff` | the notice's click target, default or own label |
| `snooze` / `snooze=⏰ Later` | comes back in 10 minutes |
| `reply` / `reply=💬 Answer` | text box typed into the iTerm pane (needs `--iterm-session`) |
| `"🚀 Open MR=https://…"` | opens a URL (http, https, codex) |
| `"🔁 Rerun=/abs/path/script arg"` | runs a program by absolute path (space-separated args) |
| `--no-buttons` | no buttons at all |

Good button labels are 1–4 words starting with an emoji and a verb ("✅ Approve", "📄 Open the
report", "🔁 Try again"). Offer the choices YC would actually make, best one first.

## Kinds, keys and housekeeping

- `--kind` picks the badge and sound: `claude-waiting` 👋, `claude-permission` 🙋, `codex-done` 🎉,
  `browser-handoff` 🧩, `browser-signin` 🚪, `browser-debug` 🔌, `vault-approval` 🔐, `run-ok` 🚀,
  `run-failed` 💥, `bell` 🔔. Guessed from the source and title when omitted.
- One `--key` per resolvable thing: re-posting the same key replaces the notice; `--if-new` skips
  it if one is already showing; `agent-notify clear --source S --key K` withdraws it once resolved.
- Notices tidy away after 5 minutes (`--expire SECONDS`, `0` = stay until dismissed).
- Long commands: `agent-notify run --source scripts --title "Nightly backup" -- /path/cmd args`.
- Debug: `agent-notify list --json` (outcomes, click targets, which button), `agent-notify status`.

After editing `main.swift`, `badges.swift` or `build.sh`, run `./build.sh`. Full reference: `README.md`.
