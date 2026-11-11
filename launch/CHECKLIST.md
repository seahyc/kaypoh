# Release checklist

Done:
- [x] v1: generic kinds, ten persona packs and a validator, `install`/`uninstall`, markdown
  stripping, 20 s minimum turn, cleared on your next prompt, 60 s expiry, tmux and editor clicks,
  `demo`, `voice`, `--dry-run`, end-to-end tests
- [x] Named Kaypoh (formerly agent-notify; the old command, variables and config still work)
- [x] Commit history authored with the GitHub no-reply address
- [x] github.com/seahyc/kaypoh public; v1.0.0 and v1.0.1 released
- [x] Homebrew tap github.com/seahyc/homebrew-tap: `brew install seahyc/tap/kaypoh` builds,
  `brew test` and `brew audit --strict` pass
- [x] `install.sh` tested end to end from an empty HOME

Still open:
- [ ] Try Claude Code in VS Code and the Claude desktop app (hooks are documented to fire there; untested)
- [ ] Record the click-to-pane clip for Product Hunt and X
- [ ] Post: Show HN (weekday morning US Eastern), Product Hunt (00:01 PT), X thread
- [ ] Releasing: bump VERSION, tag vX.Y.Z, `gh release create`, then update url and sha256 in
  packaging/homebrew/kaypoh.rb and in seahyc/homebrew-tap Formula/kaypoh.rb
