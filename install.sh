#!/bin/sh
# One-line install for agent-notify:
#   curl -fsSL https://raw.githubusercontent.com/seahyc/agent-notify/main/install.sh | sh
# Builds Agent Notify.app from source (so macOS doesn't quarantine it), puts `agent-notify` in
# ~/.local/bin, and wires notifications into Claude Code and Codex. Rerun to update.
set -eu
repo="${AGENT_NOTIFY_REPO:-https://github.com/seahyc/agent-notify.git}"
src="${AGENT_NOTIFY_SRC:-$HOME/.local/share/agent-notify}"
bin_dir="${AGENT_NOTIFY_BIN:-$HOME/.local/bin}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

[ "$(uname -s)" = Darwin ] || { echo "agent-notify is macOS only." >&2; exit 1; }
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "agent-notify builds with the Xcode Command Line Tools. Install them, then rerun:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

if [ -d "$src/.git" ]; then
  say "Updating $src"
  git -C "$src" pull --ff-only --quiet
else
  say "Downloading to $src"
  mkdir -p "$(dirname "$src")"
  git clone --depth 1 --quiet "$repo" "$src"
fi

say "Building Agent Notify.app"
"$src/build.sh" >/dev/null

mkdir -p "$bin_dir"
ln -sf "$src/bin/agent-notify" "$bin_dir/agent-notify"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "Add $bin_dir to your PATH, e.g.:  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc" ;;
esac

say "Wiring Claude Code and Codex"
AGENT_NOTIFY_SHIM="$bin_dir/agent-notify" "$bin_dir/agent-notify" install

say "Done. Try a few:  agent-notify demo    Pick a voice:  agent-notify voice"
