#!/usr/bin/env python3
"""Check every persona pack in personas/: shape, placeholders, lengths macOS won't cut off.

Usage: python3 tests/check_personas.py [pack.json ...]   (exit 1 on any problem)
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TITLE_KINDS = ["done", "waiting", "permission", "handoff", "signin", "approval", "run-ok", "run-failed", "pile"]
MESSAGE_KINDS = ["run-ok", "run-failed", "pile"]
BUTTONS = ["go", "go-done", "go-permission", "go-chat", "go-tab", "go-approval", "go-failed", "reply", "snooze"]
# Placeholders each string may use; every one listed for a title kind must be filled by the engine.
ALLOWED = {
    "titles": {"done": {"agent"}, "waiting": {"agent"}, "permission": {"agent"}, "handoff": {"agent"},
               "signin": {"agent"}, "approval": {"agent"}, "run-ok": {"what"}, "run-failed": {"what"},
               "pile": {"count", "tool"}},
    "messages": {"run-ok": {"took"}, "run-failed": {"code", "took"}, "pile": {"title", "message"}},
}
REQUIRED = {"titles": {"run-ok": {"what"}, "run-failed": {"what"}, "pile": {"count"}},
            "messages": {"run-failed": {"code"}, "pile": {"title"}}}
# Worst-case fills, so the length check is honest.
FILL = {"agent": "Claude", "what": "npm test", "count": "12", "tool": "Claude Code",
        "took": "12m 30s", "code": "127", "title": "x" * 20, "message": "x" * 20}
TITLE_MAX, BUTTON_MAX, MESSAGE_MAX = 34, 32, 200
MIN_LINES = {"done": 3, "waiting": 2, "permission": 3}


def starts_with_emoji(s):
    ch = s[:1]
    return bool(ch) and (unicodedata.category(ch) == "So" or ord(ch) > 0x2000)


def fill(s):
    return re.sub(r"\{(\w+)\}", lambda m: FILL.get(m.group(1), m.group(0)), s)


def check(path):
    problems = []
    try:
        pack = json.loads(path.read_text())
    except Exception as e:  # noqa: BLE001
        return [f"not valid JSON: {e}"]
    if pack.get("name") != path.stem:
        problems.append(f"name must be {path.stem!r}")
    for field in ("label", "description", "snoozed"):
        if not isinstance(pack.get(field), str) or not pack[field].strip():
            problems.append(f"{field} is required")
    for section, kinds in (("titles", TITLE_KINDS), ("messages", MESSAGE_KINDS)):
        table = pack.get(section, {})
        for kind in kinds:
            lines = table.get(kind)
            if not isinstance(lines, list) or not lines or not all(isinstance(x, str) and x.strip() for x in lines):
                problems.append(f"{section}.{kind}: a non-empty list of strings")
                continue
            if section == "titles" and len(lines) < MIN_LINES.get(kind, 1):
                problems.append(f"titles.{kind}: at least {MIN_LINES[kind]} lines")
            for line in lines:
                used = set(re.findall(r"\{(\w+)\}", line))
                if used - ALLOWED[section][kind]:
                    problems.append(f"{section}.{kind}: {line!r} uses {sorted(used - ALLOWED[section][kind])}")
                missing = REQUIRED.get(section, {}).get(kind, set()) - used
                if missing:
                    problems.append(f"{section}.{kind}: {line!r} must include {sorted(missing)}")
                limit = TITLE_MAX if section == "titles" else MESSAGE_MAX
                if len(fill(line)) > limit:
                    problems.append(f"{section}.{kind}: {line!r} is {len(fill(line))} chars filled (max {limit})")
                if section == "titles" and not starts_with_emoji(line):
                    problems.append(f"titles.{kind}: {line!r} must start with an emoji")
                if "*" in line or "`" in line:
                    problems.append(f"{section}.{kind}: {line!r} has markdown")
        extra = set(table) - set(kinds)
        if extra:
            problems.append(f"{section}: unknown kinds {sorted(extra)}")
    buttons = pack.get("buttons", {})
    for b in BUTTONS:
        label = buttons.get(b)
        if not isinstance(label, str) or not label.strip():
            problems.append(f"buttons.{b} is required")
            continue
        used = set(re.findall(r"\{(\w+)\}", label))
        if used - ({"agent"} if b == "reply" else set()):
            problems.append(f"buttons.{b}: {label!r} uses {sorted(used)}")
        if len(fill(label)) > BUTTON_MAX:
            problems.append(f"buttons.{b}: {label!r} is {len(fill(label))} chars filled (max {BUTTON_MAX})")
        if not starts_with_emoji(label):
            problems.append(f"buttons.{b}: {label!r} must start with an emoji")
    return problems


def main():
    paths = [Path(p) for p in sys.argv[1:]] or sorted((ROOT / "personas").glob("*.json"))
    bad = 0
    for path in paths:
        problems = check(path)
        print(f"{'ok  ' if not problems else 'FAIL'} {path.name}")
        for p in problems:
            print(f"     - {p}")
        bad += bool(problems)
    print(f"{len(paths) - bad}/{len(paths)} packs pass")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
