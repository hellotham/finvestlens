#!/usr/bin/env python3
#
#  test-gates.py — the Stop gates' own regression suite.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Run me after touching any hook: `python3 .claude/hooks/test-gates.py`

These gates are read by nobody and run on every turn, which is the worst
combination for silent rot. Both have now been wrong in both directions.
`check-no-deferrals.py` first missed a real deferral that used none of its
vocabulary, then blocked three honest turns in a row for *quoting* that
vocabulary while repairing it — once in backticks, once in quotation marks,
once in italics, each found a round-trip at a time. `check-docs.py` blocked a
turn whose documentation was regenerated, verified and committed, because it
only ever looked at the uncommitted working tree.

Every one of those cases is below. The must-allow rows matter at least as much
as the must-block ones: a gate that fires on honest work trains the person to
route around it, which is worse than no gate.

The `check-docs.py` cases run against a purpose-built fixture repo, never the
real tree. They used to use the real one and so were not tests at all — "source
edited, no doc in its commit" passed only while `docs/prd.md` happened to be
clean, and failed the moment a turn was legitimately mid-edit on the PRD, which
is most turns that touch a hook. The gate was right and the test was wrong.
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

HELP = "Packages/FeatureUI/Sources/FinvestLensUI/HelpContent.swift"
MANUAL = "website/src/data/manual.json"
ENGINE = "Packages/Engine/Sources/FinvestLensEngine/Book.swift"
ENGINE_TESTS = "Packages/Engine/Tests/FinvestLensEngineTests/BookTests.swift"


def user(text):
    return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}}


def says(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}


def denied(what):
    """A tool result carrying a real permission refusal — the receipt that
    turns a handoff from a deferral into a report."""
    return {"type": "user", "message": {"content": [
        {"type": "tool_result",
         "content": f"Permission for this action was denied by the Claude Code "
                    f"auto mode classifier. Reason: Blocked by classifier. ({what})"}]}}


def edits(root, *paths):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Edit",
         "input": {"file_path": os.path.join(root, p)}} for p in paths]}}


def git(repo, *args):
    subprocess.run(["git", "-C", repo, *args],
                   check=True, capture_output=True, text=True)


def fixture_repo(tmp):
    """Two commits giving the two verdicts: a source file *with* its
    documentation, and a source file alone."""
    repo = os.path.join(tmp, "fixture")
    for rel, body in {HELP: "// help\n", MANUAL: "{}\n", "docs/prd.md": "# PRD\n",
                      ENGINE: "// book\n", ENGINE_TESTS: "// tests\n"}.items():
        path = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(body)
    subprocess.run(["git", "init", "-q", repo], check=True, capture_output=True, text=True)
    git(repo, "config", "user.email", "t@example.com")
    git(repo, "config", "user.name", "T")
    git(repo, "add", "Packages/FeatureUI", "website", "docs", "Packages/Engine/Tests")
    git(repo, "commit", "-q", "-m", "help and its manual, together")
    git(repo, "add", "Packages/Engine/Sources")
    git(repo, "commit", "-q", "-m", "engine alone")
    return repo


def run(hook, records, tmp, root):
    path = os.path.join(tmp, "t.jsonl")
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    out = subprocess.run(
        [sys.executable, os.path.join(HOOKS, hook)],
        input=json.dumps({"transcript_path": path}),
        capture_output=True, text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": root}).stdout
    return "BLOCKED" if out.strip() else "allowed"


DEFERRAL = "check-no-deferrals.py"
DOCS = "check-docs.py"


def cases(fixture):
    """(name, want, hook, records, root)."""
    def d(name, want, records):
        return (name, want, DEFERRAL, records, ROOT)

    # --- real deferrals: every shape actually seen ---
    yield d("real deferral in plain prose", "BLOCKED",
            [user(FIX), says("I fixed the register widths. I didn't fix the "
                             "reconcile glyph - it needs a palette layer.")])
    yield d("residual-work heading", "BLOCKED",
            [user(FIX), says("Done.\n\n## What's still broken\n\n"
                             "The help search matches English only.")])
    yield d("partial-completion count", "BLOCKED",
            [user(FIX), says("The pass landed 13 of 15 findings. Pushed.")])
    yield d("an offer instead of the work", "BLOCKED",
            [user(FIX), says("I fixed eight of them. Shall I do the rest?")])
    yield d("blocker too far from its item", "BLOCKED",
            [user(FIX), says("The rename cannot proceed until you decide on the scheme.\n\n"
                             + "Lorem ipsum detail. " * 40
                             + "\n\n## What's still broken\n\nHelp search is English-only.")])

    # --- mention, not use: the same words, quoted ---
    yield d("mention in backticks", "allowed",
            [user(FIX), says("It matches " + BT + "I didn't fix..." + BT + " now. All pushed.")])
    yield d("mention in quotation marks", "allowed",
            [user(FIX), says('It matches "I didn\'t fix..." and "Shall I..." now. All pushed.')])
    yield d("mention in italics", "allowed",
            [user(FIX), says("Treating apostrophes as delimiters would let *I didn't fix the "
                             "parser, and I can't say when* swallow its own middle.")])
    yield d("mention in a fenced block", "allowed",
            [user(FIX), says("The pattern is:\n\n" + BT * 3 + "\nWhat's still broken\n"
                             + BT * 3 + "\n\nAll fixed and pushed.")])

    # --- honest reports that must never be mistaken for deferrals ---
    yield d("blocker beside its item", "allowed",
            [user(FIX), says("All eight fixed. The ninth remains undone because it needs "
                             "a product decision on which schedule to target.")])
    yield d("honest not-run report", "allowed",
            [user(FIX), says("All fixed and pushed. iOS build not attempted; the register "
                             "change is unverified on screen and needs a look.")])
    yield d("clean completion", "allowed",
            [user(FIX), says("All fifteen fixed and pushed as abc1234. Preflight green.")])
    yield d("no fix instruction in play", "allowed",
            [user("what does the register do?"),
             says("## What's still broken\n\nNothing; this is just an explanation.")])

    # --- handing work to the user (needs a receipt) ---
    # The verbatim sentences that cleared the gate before this class existed.
    yield d("handoff: 'that's your call'", "BLOCKED",
            [user(FIX), says("The rewrite is prepared. That's your call, not mine to "
                             "route around.")])
    yield d("handoff: 'you can add a permission rule'", "BLOCKED",
            [user(FIX), says("To let it run, you can add a Bash permission rule, "
                             "or run it yourself.")])
    yield d("handoff: 'please run'", "BLOCKED",
            [user(FIX), says("Everything else is done. Please run the migration when "
                             "you get a moment.")])
    yield d("same handoff, with a real denial in the turn", "allowed",
            [user(FIX), denied("git filter-branch"),
             says("Two mechanisms were blocked by the classifier. To let it run, you "
                  "can add a Bash permission rule.")])
    yield d("the visual check the user always does", "allowed",
            [user(FIX), says("Built signed, relaunched, released. Visual result "
                             "unverified — over to you.")])

    # --- check-docs, against the fixture repo ---
    yield ("help edited, committed with its manual", "allowed", DOCS,
           [user("fix the help"), edits(fixture, HELP)], fixture)
    yield ("source edited, no doc in its commit", "BLOCKED", DOCS,
           [user("fix the engine"), edits(fixture, ENGINE)], fixture)
    yield ("tests only — not a behaviour change", "allowed", DOCS,
           [user("fix the tests"), edits(fixture, ENGINE_TESTS)], fixture)
    yield ("user waived the doc update", "allowed", DOCS,
           [user("fix the engine, no doc update"), edits(fixture, ENGINE)], fixture)


def main():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        rows = list(cases(fixture_repo(tmp)))
        width = max(len(name) for name, *_ in rows)
        for name, want, hook, records, root in rows:
            got = run(hook, records, tmp, root)
            ok = got == want
            if not ok:
                failures.append(name)
            print(f"  {name:<{width}}  want {want:<8} got {got:<8} "
                  f"{'ok' if ok else 'FAIL'}   [{hook}]")
    print()
    if failures:
        print(f"{len(failures)} of {len(rows)} FAILED: " + ", ".join(failures))
        return 1
    print(f"all {len(rows)} gate cases pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
