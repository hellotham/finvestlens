#!/usr/bin/env python3
#
#  check-docs.py — Stop gate: code changed, documentation did not.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""A turn that changes behaviour must also change the documents that describe it.

This exists because the same failure has recurred: a requirement is stated in
conversation, implemented in code, and never written down — so the next session
reads the PRD, believes it, and builds the opposite. The proof is `FR-AI-08`,
which said attachments are *copied* into the document folder when the
instruction had been to *link* them relatively; the code followed the PRD and
duplicated 189 receipts onto a NAS.

Scope is deliberately narrow, because a gate that fires when nothing is wrong is
a gate people learn to skip:

  - only **source** edits count — tests, scripts, hooks and docs themselves do
    not demand a doc update;
  - only edits made **in this turn**, not the whole uncommitted tree, which
    stays dirty for many turns at a time;
  - the coupled files (help → manual, strings → catalog) are checked
    specifically, because those two have their own CI gates and failing them
    late is expensive.
"""

from __future__ import annotations

import json
import os
import sys

# Source that changes what the app does for a user.
SOURCE_PREFIXES = (
    "Packages/", "finvestlens/", "FinvestLensWidgets/", "FinvestLensQuickLook/",
)
# …but not these: a test or a tool is not a behaviour change.
SOURCE_EXCLUDES = ("/Tests/", "/.build/", "Tests/")

# Any one of these satisfies the general requirement. They are the spec spine:
# prd = intended requirements, architecture = decisions, plan = phases,
# implemented = what was built, deferred = what was consciously not.
SPEC_DOCS = (
    "docs/prd.md", "docs/architecture.md", "docs/plan.md",
    "docs/implemented.md", "docs/deferred.md", "README.md",
)

# Specific couplings that CI enforces later and cheaply caught earlier.
COUPLED = [
    ("Packages/FeatureUI/Sources/FinvestLensUI/HelpContent.swift",
     "website/src/data/manual.json",
     "the in-app help changed, so the website manual must be regenerated "
     "(`cd website && node scripts/build-manual.mjs`)"),
]

# An explicit, deliberate opt-out. Not a loophole: it has to be typed by the
# user, in the turn, in these words — so the decision is on the record.
EXEMPTIONS = ("no doc update", "skip docs", "docs not needed", "no docs needed")


def load(path):
    """The transcript as a list of (kind, record)."""
    out = []
    if not path or not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except Exception:
                continue
            kind = record.get("type")
            if kind in ("user", "assistant"):
                out.append((kind, record))
    return out


def blocks(record):
    content = record.get("message", {}).get("content")
    return content if isinstance(content, list) else []


def is_real_user_turn(record):
    """A typed message, not a tool result or an injected reminder."""
    for block in blocks(record):
        if not isinstance(block, dict) or block.get("type") != "text":
            continue
        text = (block.get("text") or "").strip()
        if text and not text.startswith(("<local-command", "<task-notification",
                                         "<system-reminder", "Caveat:")):
            return True
    return isinstance(record.get("message", {}).get("content"), str)


def user_text(record):
    parts = []
    content = record.get("message", {}).get("content")
    if isinstance(content, str):
        parts.append(content)
    for block in blocks(record):
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text") or "")
    return " ".join(parts).lower()


def edited_paths(records, start):
    """Files written by Edit/Write/MultiEdit after index `start`."""
    paths = set()
    for _, record in records[start:]:
        for block in blocks(record):
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if block.get("name") not in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                continue
            path = (block.get("input") or {}).get("file_path")
            if isinstance(path, str):
                paths.add(path)
    return paths


def relative(path, root):
    return path[len(root):].lstrip("/") if root and path.startswith(root) else path


def main():
    payload = json.loads(sys.stdin.read() or "{}")
    records = load(payload.get("transcript_path", ""))
    if not records:
        return

    turns = [i for i, (kind, record) in enumerate(records)
             if kind == "user" and is_real_user_turn(record)]
    if not turns:
        return
    last = turns[-1]

    if any(phrase in user_text(records[last][1]) for phrase in EXEMPTIONS):
        return

    root = os.environ.get("CLAUDE_PROJECT_DIR", "")
    touched = {relative(p, root) for p in edited_paths(records, last)}
    if not touched:
        return

    source = [p for p in touched
              if p.startswith(SOURCE_PREFIXES)
              and p.endswith(".swift")
              and not any(x in p for x in SOURCE_EXCLUDES)]
    if not source:
        return

    problems = []
    if not any(p in touched for p in SPEC_DOCS):
        shown = ", ".join(sorted(source)[:4]) + ("…" if len(source) > 4 else "")
        problems.append(
            "Source changed (%s) but no specification document did. Record the "
            "requirement where the next session will read it: docs/prd.md for an "
            "intended requirement, docs/architecture.md for a decision, "
            "docs/implemented.md for what was built, docs/deferred.md for what "
            "was consciously not, README.md if the user-visible story moved."
            % shown)

    for trigger, required, message in COUPLED:
        if trigger in touched and required not in touched:
            problems.append(message.capitalize() + ".")

    if not problems:
        return

    print(json.dumps({"decision": "block", "reason":
        "Documentation is out of step with this turn's code.\n\n- "
        + "\n- ".join(problems)
        + "\n\nThis gate exists because a requirement stated in conversation and "
          "never written down is a requirement the next session will contradict "
          "— FR-AI-08 said attachments are copied when the instruction was to "
          "link them, and the code followed the PRD.\n\n"
          "Update the document now, or say plainly which document should have "
          "changed and why it should not. If a doc update genuinely does not "
          "apply, the user can say \"no doc update\" in their message."}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # a broken gate must fail open, never wedge the session
