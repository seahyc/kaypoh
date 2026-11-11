# Release checklist (v1.0.0)

Done in the repo:
- [x] Generic kinds (old names still accepted), ten persona packs, the validator
- [x] `install` / `uninstall` for Claude Code (Stop, Notification, UserPromptSubmit) and Codex (notify, chained)
- [x] Markdown stripped everywhere; 20 s minimum turn; notices clear on your next prompt; 60 s expiry
- [x] Click targets: iTerm2 pane, tmux pane, VS Code/Cursor/Windsurf window, Codex thread
- [x] `demo`, `voice`, `--dry-run`, `version`; end-to-end tests (`tests/test_cli.py`)
- [x] `install.sh` (curl | sh), Homebrew formula draft, MIT LICENSE, public README, generic SKILL.md

Needs the owner (outward-facing, not done):
- [ ] Decide on the commit author email: history uses a work address
- [x] Name: Kaypoh (formerly agent-notify; the old command still works)
- [ ] Make github.com/seahyc/kaypoh public
- [ ] Tag `v1.0.0` and create a GitHub release
- [ ] Create `seahyc/homebrew-tap`, copy `packaging/homebrew/kaypoh.rb` to `Formula/`, fill in sha256
- [ ] Run `install.sh` on a clean macOS user account (no ~/.agents, no iTerm2) end to end
- [ ] Try Claude Code in VS Code and the Claude desktop app (hooks are documented to fire there; untested here)
- [ ] Record the click-to-pane clip for PH and X
- [ ] Post: Show HN (weekday morning US Eastern), Product Hunt (00:01 PT), X thread
