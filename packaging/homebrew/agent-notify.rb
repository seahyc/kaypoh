# Homebrew formula for agent-notify. Lives in a tap repo (seahyc/homebrew-tap, Formula/agent-notify.rb):
#   brew install seahyc/tap/agent-notify && agent-notify install
# Builds from source, so the app is never quarantined. On release, update url and sha256:
#   curl -sL https://github.com/seahyc/agent-notify/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
class AgentNotify < Formula
  desc "Notifications for coding agents that land on the right pane, in a voice you pick"
  homepage "https://github.com/seahyc/agent-notify"
  url "https://github.com/seahyc/agent-notify/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_ON_RELEASE"
  license "MIT"
  head "https://github.com/seahyc/agent-notify.git", branch: "main"

  depends_on :macos
  depends_on macos: :ventura

  def install
    system "./build.sh", { "APP_DIR" => libexec.to_s }
    (bin/"agent-notify").write <<~SH
      #!/bin/sh
      exec "#{opt_libexec}/Agent Notify.app/Contents/MacOS/agent-notify" "$@"
    SH
    (bin/"agent-notify").chmod 0755
  end

  def caveats
    <<~EOS
      Wire it into Claude Code and Codex (backs up their config first):
        agent-notify install
      Then try:  agent-notify demo   and pick a voice:  agent-notify voice
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/agent-notify version")
    out = shell_output("#{bin}/agent-notify demo done --dry-run")
    assert_match "\"kind\":\"done\"", out
  end
end
