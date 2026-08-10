#!/usr/bin/env python3
#
#  no-figures-in-commits.py — PreToolUse gate: a commit message is published.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Block a `git commit` whose message carries a real balance.

`scripts/check-no-real-data.py` has guarded *published files* since July, on
the sound principle that a precise figure of a certain size is somebody's
balance rather than an illustration. It never looked at commit messages — and
a commit message is as public as any file in the tree, on the same GitHub page,
indexed the same way.

That gap cost 31 commits. `git filter-repo --replace-text` cleaned the blobs
and left every message untouched, so figures like a cleared balance to the
cent, a seven-figure net worth and a portfolio total went out with the
history and are still there: rewriting them needs a history rewrite, and
every mechanism for that is refused by the tool-permission layer.

So this gate exists to make the count stop at 31. Same threshold as the file
checker, deliberately — one rule, one place to change it:

  * any figure of $1,000,000 or more, however written; or
  * $10,000 or more *with cents*, which is the signature of a real balance
    rather than a round example.

Illustrative figures are fine and common in this project's messages ("a $400
dining entry", "the $10 tolerance"), and none of them trip either clause.
"""

from __future__ import annotations

import json
import re
import shlex
import sys

THRESHOLD = 10_000
MONEY = re.compile(r"\$([0-9][0-9,]*)(\.[0-9]{2})?\b")

# Typed by the user, in the turn, to override — the same escape hatch the
# sibling gates use, so a decision to publish a figure is on the record.
WAIVER = re.compile(r"figures? (?:are )?(?:synthetic|deliberate)|allow this figure", re.I)


def figures(text: str) -> list[str]:
    found = []
    for whole, cents in MONEY.findall(text):
        try:
            value = int(whole.replace(",", ""))
        except ValueError:
            continue
        if value >= 1_000_000 or (value >= THRESHOLD and cents):
            found.append("$" + whole + (cents or ""))
    return found


def commit_message(command: str) -> str:
    """The message text a `git commit` invocation would use.

    Handles the three shapes this project actually uses: `-m`, `-F -` with a
    heredoc, and `-F <file>`. A heredoc body is not in the command string at
    all, so it is read from the raw command text after the `<<` marker.
    """
    if not re.search(r"\bgit\b[^|;&]*\bcommit\b", command):
        return ""
    parts = []
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    for index, token in enumerate(tokens):
        if token in ("-m", "--message") and index + 1 < len(tokens):
            parts.append(tokens[index + 1])
        elif token.startswith("--message="):
            parts.append(token.split("=", 1)[1])
    # A `-F -` heredoc: everything between the marker line and its terminator.
    heredoc = re.search(r"<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?\s*\n(.*?)\n\1",
                        command, re.S)
    if heredoc:
        parts.append(heredoc.group(2))
    return "\n".join(parts)


def main() -> None:
    payload = json.loads(sys.stdin.read() or "{}")
    if payload.get("tool_name") != "Bash":
        return
    command = (payload.get("tool_input") or {}).get("command", "")
    message = commit_message(command)
    if not message or WAIVER.search(message):
        return
    found = figures(message)
    if not found:
        return

    listed = ", ".join(sorted(set(found))[:6])
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason":
                f"This commit message carries what reads as a real balance: {listed}.\n\n"
                "A commit message is as public as any file in the tree — same "
                "page, same indexing — and unlike a file it cannot be corrected "
                "later without rewriting history, which the permission layer "
                "refuses. That is how 31 messages in this repo came to hold real "
                "figures that are still public.\n\n"
                "Describe the shape instead of the amount ('agrees to the cent', "
                "'a seven-figure total'), or round it into an illustration. If "
                "the figure really is synthetic, say so in the message."
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open, loudly — a gate that dies silently is a gate that agrees
        # with you. stdout is the verdict channel and must stay clean.
        import traceback
        print("no-figures-in-commits.py CRASHED — gate is not running:",
              file=sys.stderr)
        traceback.print_exc(file=sys.stderr)

