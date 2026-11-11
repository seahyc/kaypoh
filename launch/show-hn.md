# Show HN draft

**Title:** Show HN: agent-notify – macOS notifications that take you to the agent's exact pane

**URL:** https://github.com/seahyc/agent-notify

**Text:**

I run four or five Claude Code and Codex sessions at once, split across iTerm2 panes. The
built-in bell tells me something is done. It doesn't tell me which session, or what it said, so I
end up tabbing through panes to find the one that's waiting.

agent-notify is a small macOS app (one Swift file, no Electron) that hooks into Claude Code and
Codex. When a turn finishes or needs permission, you get a notice with the project name and the
agent's last message as the body. Clicking it focuses the exact iTerm2 split pane or tmux pane,
the VS Code or Cursor window for that repo, or the Codex app thread. You can also type a reply in
the notice and it's sent to the pane.

Things I added after living with it:

- Turns under 20 s don't notify, since you were probably watching.
- One notice per session that updates in place, and a 3-per-10-minutes budget per tool. The
  overflow folds into one "N more" summary.
- The notice clears itself when you go back and type.
- Agents can post their own notices with their own copy and buttons ("🚀 Open MR",
  "🔁 Rerun"), which is more useful than a generic "done".

And because a notification layer is a good place for a bit of fun, the copy comes in ten voices:
plain, Gen Z, tiger mum ("Claude done. Cousin's was faster"), passive-aggressive
coworker ("Claude needs OK. Thanks!"), butler, cat, and so on. They're
JSON files, so writing your own takes five minutes.

There's no network, no telemetry and no model calls; the agent's own words are the content.
Install with `curl … | sh` or Homebrew. It builds from source, so Gatekeeper doesn't get
involved. MIT licensed.

It's macOS only for now. Linux would need a different notification and focus layer, and I'd love
to hear from anyone who wants that. I'd also like to know which terminals people want pane-level
focus for next. Ghostty and WezTerm are the obvious ones.
