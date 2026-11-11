#!/bin/sh
# One-line install for kaypoh:
#   curl -fsSL https://raw.githubusercontent.com/seahyc/kaypoh/main/install.sh | sh
# Builds Kaypoh.app from source (so macOS doesn't quarantine it), puts `kaypoh` in ~/.local/bin,
# and wires notifications into Claude Code and Codex. Rerun to update.
set -eu
repo="${KAYPOH_REPO:-https://github.com/seahyc/kaypoh.git}"
src="${KAYPOH_SRC:-$HOME/.local/share/kaypoh}"
bin_dir="${KAYPOH_BIN:-$HOME/.local/bin}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

[ "$(uname -s)" = Darwin ] || { echo "kaypoh is macOS only." >&2; exit 1; }
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "kaypoh builds with the Xcode Command Line Tools. Install them, then rerun:" >&2
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

say "Building Kaypoh.app"
"$src/build.sh" >/dev/null

mkdir -p "$bin_dir"
ln -sf "$src/bin/kaypoh" "$bin_dir/kaypoh"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "Add $bin_dir to your PATH, e.g.:  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc" ;;
esac

say "Wiring Claude Code and Codex"
KAYPOH_SHIM="$bin_dir/kaypoh" "$bin_dir/kaypoh" install

say "Done. Try a few:  kaypoh demo    Pick a voice:  kaypoh voice"
