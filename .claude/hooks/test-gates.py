#!/usr/bin/env python3
#
#  test-gates.py — the Stop gates' own regression suite.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Run me after touching any hook: `python3 .claude/hooks/test-gates.py`

These gates are read by nobody and run on every turn, which is the worst
combination for silent rot. Both of them have now been wrong in both
directions: `check-no-deferrals.py` first missed a real deferral that used none
of its vocabulary, then blocked three honest turns in a row for *quoting* that
vocabulary while repairing it — once in backticks, once in quotation marks,
once in italics, each discovered a round-trip at a time. `check-docs.py`
blocked a turn whose documentation was regenerated, verified and committed,
because it only ever looked at the uncommitted working tree.

Every one of those cases is below. A gate that fires on honest work is worse
than no gate, because it trains the person to route around it — so the
must-allow rows matter at least as much as the must-block ones.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HOOKS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HOOKS))
BT = chr(96)
FIX = "fix everything, no deferrals"


def transcript(records, path):
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")


def user(text):
    return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}}


def says(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}


def edits(*paths):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Edit",
         "input": {"file_path": os.path.join(ROOT, p)}} for p in paths]}}


def run(hook, records, tmp):
    path = os.path.join(tmp, "t.jsonl")
    transcript(records, path)
    out = subprocess.run(
        [sys.executable, os.path.join(HOOKS, hook)],
        input=json.dumps({"transcript_path": path}),
        capture_output=True, text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": ROOT}).stdout
    return "BLOCKED" if out.strip() else "allowed"


# (name, want, hook, records) — "the same words, used not mentioned" is the pair
# that keeps the mention-stripping honest: identical vocabulary, opposite verdict.
def cases():
    yield ("real deferral in plain prose", "BLOCKED", "check-no-deferrals.py",
           [user(FIX), says("I fixed the register widths. I didn't fix the "
                            "reconcile glyph - it needs a palette layer.")])
    yield ("residual-work heading", "BLOCKED", "check-no-deferrals.py",
           [user(FIX), says("Done.\n\n## What's still broken\n\n"
                            "The help search matches English only.")])
    yield ("partial-completion count", "BLOCKED", "check-no-deferrals.py",
           [user(FIX), says("The pass landed 13 of 15 findings. Pushed.")])
    yield ("an offer instead of the work", "BLOCKED", "check-no-deferrals.py",
           [user(FIX), says("I fixed eight of them. Shall I do the rest?")])
    yield ("blocker too far from its item", "BLOCKED", "check-no-deferrals.py",
           [user(FIX), says("The rename cannot proceed until you decide on the scheme.\n\n"
                            + "Lorem ipsum detail. " * 40
                            + "\n\n## What's still broken\n\nHelp search is English-only.")])

    yield ("mention in backticks", "allowed", "check-no-deferrals.py",
           [user(FIX), says("It matches " + BT + "I didn't fix..." + BT + " now. All pushed.")])
    yield ("mention in quotation marks", "allowed", "check-no-deferrals.py",
           [user(FIX), says('It matches "I didn\'t fix..." and "Shall I..." now. All pushed.')])
    yield ("mention in italics", "allowed", "check-no-deferrals.py",
           [user(FIX), says("Treating apostrophes as delimiters would let *I didn't fix the "
                            "parser, and I can't say when* swallow its own middle.")])
    yield ("mention in a fenced block", "allowed", "check-no-deferrals.py",
           [user(FIX), says("The pattern is:\n\n" + BT * 3 + "\nWhat's still broken\n"
                            + BT * 3 + "\n\nAll fixed and pushed.")])
    yield ("blocker beside its item", "allowed", "check-no-deferrals.py",
           [user(FIX), says("All eight fixed. The ninth remains undone because it needs "
                            "a product decision on which schedule to target.")])
    yield ("honest not-run report", "allowed", "check-no-deferrals.py",
           [user(FIX), says("All fixed and pushed. iOS build not attempted; the register "
                            "change is unverified on screen and needs a look.")])
    yield ("clean completion", "allowed", "check-no-deferrals.py",
           [user(FIX), says("All fifteen fixed and pushed as abc1234. Preflight green.")])
    yield ("no fix instruction in play", "allowed", "check-no-deferrals.py",
           [user("what does the register do?"),
            says("## What's still broken\n\nNothing; this is just an explanation.")])

    # check-docs.py — the trigger is a Swift source under a shipped target.
    yield ("help edited, committed with its manual", "allowed", "check-docs.py",
           [user("fix the help"),
            edits("Packages/FeatureUI/Sources/FinvestLensUI/HelpContent.swift")])
    yield ("source edited, no doc in its commit", "BLOCKED", "check-docs.py",
           [user("fix the engine"),
            edits("Packages/Engine/Sources/FinvestLensEngine/Book.swift")])
    yield ("tests only — not a behaviour change", "allowed", "check-docs.py",
           [user("fix the tests"),
            edits("Packages/Engine/Tests/FinvestLensEngineTests/BookTests.swift")])
    yield ("user waived the doc update", "allowed", "check-docs.py",
           [user("fix the engine, no doc update"),
            edits("Packages/Engine/Sources/FinvestLensEngine/Book.swift")])


def main():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        rows = list(cases())
        width = max(len(name) for name, *_ in rows)
        for name, want, hook, records in rows:
            got = run(hook, records, tmp)
            ok = got == want
            if not ok:
                failures.append((name, hook, want, got))
            print(f"  {name:<{width}}  want {want:<8} got {got:<8} "
                  f"{'ok' if ok else 'FAIL'}   [{hook}]")
    print()
    if failures:
        print(f"{len(failures)} of {len(rows)} FAILED")
        return 1
    print(f"all {len(rows)} gate cases pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
