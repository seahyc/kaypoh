#!/usr/bin/env python3
"""End-to-end tests against a built Kaypoh.app, all in --dry-run (nothing is posted) and in a
sandboxed HOME (your real ~/.claude and ~/.codex are never touched).

    NO_REGISTER=1 APP_DIR=/tmp/an-test ./build.sh && APP_DIR=/tmp/an-test python3 tests/test_cli.py
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = Path(os.environ.get("APP_DIR", "/tmp/an-test")) / "Kaypoh.app/Contents/MacOS/kaypoh"
PACKS = {p.stem: json.loads(p.read_text()) for p in (ROOT / "personas").glob("*.json")}
SHIM = "/opt/example/bin/kaypoh"


def titles(voice, kind, **fill):
    out = []
    for t in PACKS[voice]["titles"][kind]:
        for k, v in fill.items():
            t = t.replace("{" + k + "}", v)
        out.append(t)
    return out


class CLI(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="an-home-"))
        self.env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "KAYPOH_SHIM": SHIM,
                    "KAYPOH_VOICE": "genz", "KAYPOH_MIN_SECONDS": "20"}

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def run_app(self, *args, stdin=None, env=None, dry=True, code=0):
        e = dict(self.env, **(env or {}))
        argv = [str(APP), *args] + (["--dry-run"] if dry and args[0] not in ("hook",) else [])
        if dry and args[0] == "hook":
            e["KAYPOH_DRY_RUN"] = "1"
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, env=e, timeout=30)
        self.assertEqual(p.returncode, code, f"{argv}\nstdout: {p.stdout}\nstderr: {p.stderr}")
        return p.stdout.strip()

    def notice(self, *args, **kw):
        return json.loads(self.run_app(*args, **kw).splitlines()[-1])

    def claude(self, payload, **kw):
        return self.notice("hook", "claude", stdin=json.dumps(payload), **kw)

    # --- Claude Code hooks

    def test_stop_quotes_the_reply_without_markdown(self):
        n = self.claude({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/tmp/olympus",
                         "last_assistant_message": "## Done\n**Fixed** the `login` test. See [the PR](https://x.y/1)."})
        self.assertEqual(n["kind"], "done")
        self.assertIn(n["title"], titles("genz", "done", agent="Claude"))
        self.assertEqual(n["subtitle"], "in olympus")
        self.assertEqual(n["body"], "“Done Fixed the login test. See the PR.”")
        self.assertEqual(n["key"], "session-s1")

    def test_stop_falls_back_to_the_transcript(self):
        t = self.home / "t.jsonl"
        t.write_text(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "All green."}]}}) + "\n")
        n = self.claude({"hook_event_name": "Stop", "session_id": "s2", "cwd": "/tmp/a", "transcript_path": str(t)})
        self.assertEqual(n["body"], "“All green.”")

    def test_a_short_turn_does_not_notify(self):
        self.run_app("hook", "claude", stdin=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s3"}), dry=False)
        n = self.claude({"hook_event_name": "Stop", "session_id": "s3", "last_assistant_message": "hi"})
        self.assertEqual(n, {"skipped": "short turn"})
        n = self.claude({"hook_event_name": "Stop", "session_id": "s3", "last_assistant_message": "hi"},
                        env={"KAYPOH_MIN_SECONDS": "0"})
        self.assertEqual(n["kind"], "done")

    def test_prompt_submit_is_silent(self):
        out = self.run_app("hook", "claude", stdin=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s4"}), dry=False)
        self.assertEqual(out, "", "UserPromptSubmit stdout would be added to Claude's context")

    def test_permission_is_urgent(self):
        n = self.claude({"hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "s5",
                         "message": "Claude needs your permission to use Bash"})
        self.assertEqual((n["kind"], n["urgency"]), ("permission", "urgent"))
        self.assertIn(n["title"], titles("genz", "permission", agent="Claude"))
        self.assertEqual(n["body"], "Claude needs your permission to use Bash")

    def test_idle_nudge_only_if_nothing_is_showing(self):
        n = self.claude({"hook_event_name": "Notification", "notification_type": "idle_prompt", "session_id": "s6",
                         "message": "Claude is waiting for your input"})
        self.assertEqual(n["kind"], "waiting")
        self.assertTrue(n["ifNew"])

    def test_old_claude_without_notification_type(self):
        n = self.claude({"session_id": "s7", "message": "Claude needs your permission to use Edit"})
        self.assertEqual(n["kind"], "permission")

    def test_irrelevant_notifications_are_skipped(self):
        self.assertEqual(self.claude({"hook_event_name": "Notification", "notification_type": "auth_success"}),
                         {"skipped": "notification auth_success"})

    # --- Codex

    def test_codex_turn_opens_the_thread_and_strips_markdown(self):
        payload = {"type": "agent-turn-complete", "thread-id": "abc-123", "cwd": "/tmp/olympus",
                   "last-assistant-message": "**Make failures cheap** and `retry`."}
        n = self.notice("hook", "codex", json.dumps(payload))
        self.assertEqual(n["body"], "“Make failures cheap and retry.”")
        self.assertEqual(n["action"]["open"], "codex://threads/abc-123")
        self.assertIn(n["title"], titles("genz", "done", agent="Codex"))
        self.assertIn(PACKS["genz"]["buttons"]["go-chat"], n["buttons"])

    def test_codex_ignores_other_events(self):
        self.assertEqual(self.notice("hook", "codex", json.dumps({"type": "other"})), {"skipped": "not a finished turn"})

    # --- Click targets

    def test_iterm_pane_gets_reply_button(self):
        n = self.claude({"hook_event_name": "Stop", "session_id": "s8", "last_assistant_message": "ok"},
                        env={"ITERM_SESSION_ID": "w0t1p0:9053558D-36ED-4F77-94C8-AD5C6AB3BEC7", "TERM_PROGRAM": "iTerm.app"})
        self.assertEqual(n["action"]["iterm"], "9053558D-36ED-4F77-94C8-AD5C6AB3BEC7")
        self.assertEqual(n["action"]["activate"], "com.googlecode.iterm2")
        self.assertEqual(n["buttons"][0], PACKS["genz"]["buttons"]["reply"].replace("{agent}", "Claude"))

    def test_vscode_opens_the_workspace_window(self):
        n = self.claude({"hook_event_name": "Stop", "session_id": "s9", "cwd": str(ROOT / "tests"), "last_assistant_message": "ok"},
                        env={"__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92", "TERM_PROGRAM": "vscode"})
        self.assertEqual(n["action"]["open"], f"cursor://file{ROOT}")

    @unittest.skipUnless(shutil.which("tmux", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin"), "tmux not installed")
    def test_tmux_pane(self):
        n = self.claude({"hook_event_name": "Stop", "session_id": "s10", "last_assistant_message": "ok"},
                        env={"TMUX": "/private/tmp/tmux-501/default,999,0", "TMUX_PANE": "%7"})
        self.assertEqual(n["action"]["tmux"]["pane"], "%7")
        self.assertEqual(n["action"]["tmux"]["socket"], "/private/tmp/tmux-501/default")
        self.assertIn(PACKS["genz"]["buttons"]["reply"].replace("{agent}", "Claude"), n["buttons"])

    # --- post, run, kinds, voices

    def test_post_strips_markdown_and_accepts_old_kinds(self):
        n = self.notice("post", "--source", "agent-vault", "--title", "Approve **now**", "--message", "Use `prod`",
                        "--kind", "vault-approval", "--open", "https://example.com")
        self.assertEqual((n["kind"], n["title"], n["body"]), ("approval", "🗝️ Approve now", "Use prod"))
        self.assertEqual(n["buttons"][0], PACKS["genz"]["buttons"]["go-approval"])

    def test_run_reports_failure_with_its_exit_code(self):
        n = self.notice("run", "--source", "scripts", "--title", "Nightly backup", "--", "/usr/bin/false", code=1)
        self.assertEqual(n["kind"], "run-failed")
        self.assertIn(n["title"], titles("genz", "run-failed", what="Nightly backup"))
        self.assertIn("1", n["body"])

    def test_every_pack_renders_every_demo(self):
        kinds = ["done", "waiting", "permission", "handoff", "signin", "approval", "run-ok", "run-failed", "pile"]
        for voice in PACKS:
            out = self.run_app("demo", *kinds, env={"KAYPOH_VOICE": voice}).splitlines()
            got = [json.loads(line) for line in out]
            self.assertEqual([n["kind"] for n in got], kinds, voice)
            for n in got:
                self.assertNotIn("{", n["title"] + n["body"] + "".join(n["buttons"]), f"{voice}: unfilled placeholder in {n}")

    def test_names_from_before_the_rename_still_work(self):
        env = {"KAYPOH_VOICE": "", "AGENT_NOTIFY_VOICE": "plain"}
        self.assertIn(self.notice("demo", "done", env=env)["title"], titles("plain", "done", agent="Claude"))
        old = self.home / ".config/agent-notify"
        old.mkdir(parents=True)
        (old / "config.json").write_text(json.dumps({"voice": "butler"}))
        self.assertIn(self.notice("demo", "done", env={"KAYPOH_VOICE": ""})["title"], titles("butler", "done", agent="Claude"))
        n = self.notice("post", "--source", "x", "--title", "t", "--message", "m", "--kind", "codex-done")
        self.assertEqual(n["kind"], "done")

    def test_unknown_voice_falls_back_to_plain(self):
        n = self.notice("demo", "done", env={"KAYPOH_VOICE": "nope"})
        self.assertIn(n["title"], titles("plain", "done", agent="Claude"))

    def test_voice_command_and_custom_packs(self):
        custom = dict(PACKS["plain"], name="mine", titles=dict(PACKS["plain"]["titles"], done=["🦄 {agent} did a thing"]))
        d = self.home / ".config/kaypoh/personas"
        d.mkdir(parents=True)
        (d / "mine.json").write_text(json.dumps(custom))
        env = {"KAYPOH_VOICE": ""}
        self.assertIn("mine", self.run_app("voice", env=env, dry=False))
        self.run_app("voice", "mine", env=env, dry=False)
        self.assertEqual(json.loads((self.home / ".config/kaypoh/config.json").read_text())["voice"], "mine")
        self.assertEqual(self.notice("demo", "done", env=env)["title"], "🦄 Claude did a thing")
        self.run_app("voice", "does-not-exist", env=env, dry=False, code=2)

    # --- install / uninstall

    def write_configs(self):
        claude = self.home / ".claude/settings.json"
        claude.parent.mkdir(parents=True)
        original = {"model": "opus", "hooks": {
            "Notification": [{"hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"},
                                        {"type": "command", "command": "/old/path/agent-notify hook claude 2>/dev/null || true"}]}],
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/guard"}]}]}}
        claude.write_text(json.dumps(original))
        codex = self.home / ".codex/config.toml"
        codex.parent.mkdir(parents=True)
        codex.write_text('model = "gpt-5"\nnotify = ["/usr/local/bin/ding", "--loud"]\n\n[profiles.fast]\nmodel = "mini"\n')
        return claude, codex, original

    def test_install_is_idempotent_and_uninstall_restores(self):
        claude, codex, original = self.write_configs()
        self.run_app("install", "--no-welcome", dry=False)
        settings = json.loads(claude.read_text())
        hooks = settings["hooks"]
        ours = f"{SHIM} hook claude >/dev/null 2>&1 || true"
        for event in ("Stop", "UserPromptSubmit", "Notification"):
            cmds = [h["command"] for g in hooks[event] for h in g["hooks"]]
            self.assertEqual(cmds.count(ours), 1, event)
        self.assertNotIn("/old/path/agent-notify hook claude 2>/dev/null || true",
                         [h["command"] for g in hooks["Notification"] for h in g["hooks"]])
        self.assertIn("/usr/local/bin/other-tool", [h["command"] for g in hooks["Notification"] for h in g["hooks"]])
        self.assertEqual(hooks["PreToolUse"], original["hooks"]["PreToolUse"])
        self.assertEqual(settings["model"], "opus")
        self.assertTrue((self.home / ".claude/settings.json.kaypoh.bak").exists())
        toml = codex.read_text()
        self.assertIn(f'notify = ["{SHIM}","hook","codex","--previous-notify","[\\"/usr/local/bin/ding\\",\\"--loud\\"]"]', toml)
        self.assertIn("[profiles.fast]", toml)

        again = self.run_app("install", "--no-welcome", dry=False)
        self.assertIn("Claude Code: nothing to change", again)
        self.assertIn("Codex already notifies", again)
        self.assertEqual(json.loads(claude.read_text()), settings)

        self.run_app("uninstall", dry=False)
        after = json.loads(claude.read_text())
        self.assertEqual(after["hooks"]["PreToolUse"], original["hooks"]["PreToolUse"])
        self.assertEqual(after["hooks"]["Notification"], [{"hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"}]}])
        self.assertNotIn("Stop", after["hooks"])
        self.assertIn('notify = ["/usr/local/bin/ding","--loud"]', codex.read_text())

    def test_codex_notify_goes_above_the_first_table(self):
        codex = self.home / ".codex/config.toml"
        codex.parent.mkdir(parents=True)
        codex.write_text('model = "gpt-5"\n[mcp_servers.x]\ncommand = "y"\n')
        self.run_app("install", "--codex", "--no-welcome", dry=False)
        lines = codex.read_text().splitlines()
        self.assertEqual(lines[1], f'notify = ["{SHIM}","hook","codex"]')
        self.run_app("uninstall", "--codex", dry=False)
        self.assertEqual(codex.read_text(), 'model = "gpt-5"\n[mcp_servers.x]\ncommand = "y"\n')

    def test_install_skips_tools_that_are_not_there(self):
        out = self.run_app("install", "--no-welcome", dry=False)
        self.assertIn("Claude Code: not found", out)
        self.assertIn("Codex: not found", out)

    def test_install_dry_run_changes_nothing(self):
        claude, codex, _ = self.write_configs()
        before = (claude.read_text(), codex.read_text())
        self.run_app("install")
        self.assertEqual((claude.read_text(), codex.read_text()), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
