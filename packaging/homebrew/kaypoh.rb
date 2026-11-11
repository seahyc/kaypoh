# Homebrew formula for kaypoh. Lives in the tap repo seahyc/homebrew-tap as Formula/kaypoh.rb:
#   brew install seahyc/tap/kaypoh && kaypoh install
# Builds from source, so the app is never quarantined. On release, update url and sha256:
#   curl -sL https://github.com/seahyc/kaypoh/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
class Kaypoh < Formula
  desc "Busybody notifications for coding agents: the right pane, in a voice you pick"
  homepage "https://github.com/seahyc/kaypoh"
  url "https://github.com/seahyc/kaypoh/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "cd4b7df8e5205412fca70cc0200d70ef33451c971fb2d70412f7e637786269b4"
  license "MIT"
  head "https://github.com/seahyc/kaypoh.git", branch: "main"

  depends_on macos: :ventura

  def install
    ENV["APP_DIR"] = libexec.to_s
    system "./build.sh"
    (bin/"kaypoh").write <<~SH
      #!/bin/sh
      exec "#{opt_libexec}/Kaypoh.app/Contents/MacOS/kaypoh" "$@"
    SH
    (bin/"kaypoh").chmod 0755
  end

  def caveats
    <<~EOS
      Wire it into Claude Code and Codex (backs up their config first):
        kaypoh install
      Then try:  kaypoh demo   and pick a voice:  kaypoh voice
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/kaypoh version")
    assert_match "\"kind\":\"done\"", shell_output("#{bin}/kaypoh demo done --dry-run")
  end
end
