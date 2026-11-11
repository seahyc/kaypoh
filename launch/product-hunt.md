# Product Hunt draft

**Name:** agent-notify

**Tagline (60 chars max):** Agent notifications that take you to the right pane
(alternatives: "Your coding agents, now with a tiger mum" · "Know which agent needs you, and go there")

**Topics:** Developer Tools, Mac, Artificial Intelligence, Open Source

**Description (260 chars max):**
Running several Claude Code or Codex sessions? agent-notify tells you which one finished or needs
you, quotes what it said, and one click lands on that exact pane or window. Ten voices, from
plain to tiger mum. Free, open source, local.

**Gallery (in order):**
1. Hero: three notices stacked (tiger mum "done", passive-aggressive coworker "needs your OK",
   drill sergeant "npm test FAILED"), with the caption "Same agents. Pick the voice."
2. A short clip: notice arrives → click → the iTerm2 split pane comes forward with the agent
   waiting.
3. Reply from the notice: type "yes, open the PR" → it appears in the pane.
4. The voice grid: one notice in each of the ten voices.
5. Terminal: `curl … | sh`, `agent-notify voice tiger-mum`.

**Maker's first comment:**

Hi PH 👋 I built this for myself. I usually have four or five agent sessions going across
iTerm2 panes, and the default bell only told me that something was done, not which session or
what it said.

agent-notify hooks into Claude Code and Codex. Each notice says which project, quotes the
agent's last message, and the click lands on the exact pane (iTerm2, tmux), the editor window
(VS Code, Cursor, Windsurf), or the Codex thread. You can reply from the notice too.

It tries hard not to be noisy. Short turns are skipped, each session has one notice that updates
in place, overflow folds into a summary, and a notice clears when you go back to that session.

The voices started as a joke and stayed because they make the notices readable *and* fun. Tiger
mum is my favourite: "Claude done. Why not faster?" Voices are JSON files, so please send me
yours.

Free, MIT, nothing leaves your Mac. I'd love to know which terminal you want pane-level focus in
next.
