#!/usr/bin/env python3
#
#  check-no-deferrals.py — Stop gate: "fix it" means all of it.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""When the user says fix, a turn may not end by offering to fix later.

This is a production app. The recurring failure is not refusing work — it is
converting an instruction into a menu: a review reports fifteen findings, eleven
are fixed, four are "skipped, say the word", and the four are never mentioned
again. The user asked for a repair and received a quotation.

The gate is deliberately narrow so it cannot deadlock the sibling gate in
`check-directives.py`, which *requires* an honest "X remains undone because Y":

  - it fires only when the user's own message was an instruction to fix;
  - it looks for the **offer** pattern ("say the word", "shall I", "want me
    to") and for bare skip words — not for honest reporting of what was not
    run;
  - "remains undone because", "blocked by" and "cannot … until" are explicitly
    allowed, because a stated blocker is a report, and an offer is a deferral.

A genuine blocker is still reportable. What is not allowed is ending the turn
with the work unstarted and the decision handed back.
"""

from __future__ import annotations

import json
import os
import re
import sys

# The user telling us to repair something.
#
# `fix` and `repair` are imperative in this project essentially without
# exception, so they count on their own — an early version required a following
# noun from a list and missed "fix the register", which is the commonest way the
# instruction is actually given. The softer verbs still need an object, because
# "address" and "correct" have innocent uses.
FIX_INTENT = re.compile(
    r"\b(fix|fixed|repair|rectify)\b"
    r"|\b(resolve|correct|address|sort out|clean up)\b.{0,40}\b"
    r"(all|every|everything|them|these|those|it|this|issue|issues|problem|"
    r"problems|finding|findings|bug|bugs|error|errors|gap|gaps)\b"
    r"|\bno deferrals?\b|\bno excuses\b|\bno gaps\b",
    re.I | re.S)

# Handing the decision back instead of doing the work.
OFFERS = re.compile(
    r"say the word"
    r"|\bshall I\b"
    r"|\bwant me to\b"
    r"|\bwould you like me to\b"
    r"|\blet me know if you(?:'d| would)? (?:like|want)\b"
    r"|\bif you want,? I(?:'ll| can| will)\b"
    r"|\bI can .{0,30}\bif you\b"
    r"|\btell me (?:if|whether) you want\b",
    re.I)

# Naming work as dropped.
SKIPPED = re.compile(
    r"\bskipped\b|\bnot fixed\b|\bleft (?:unfixed|for later|as[- ]is)\b"
    r"|\bdeferred\b|\bfor a (?:later|future) (?:turn|session|pass)\b"
    r"|\bout of scope for now\b|\bworth doing later\b",
    re.I)

# An honest, stated blocker — always allowed, and required by the sibling gate.
BLOCKER = re.compile(
    r"remains? undone because"
    r"|\bblocked by\b"
    r"|\bcannot\b.{0,60}\buntil\b"
    r"|\bneeds? your (?:decision|input|call|answer)\b"
    r"|\brequires a product decision\b"
    r"|\bwould change intended behaviour\b",
    re.I)


def load(path):
    out = []
    if not path or not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except Exception:
                continue
            if record.get("type") in ("user", "assistant"):
                out.append((record["type"], record))
    return out


def blocks(record):
    content = record.get("message", {}).get("content")
    return content if isinstance(content, list) else []


def text_of(record):
    parts = []
    content = record.get("message", {}).get("content")
    if isinstance(content, str):
        parts.append(content)
    for block in blocks(record):
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text") or "")
    return "\n".join(parts)


def is_real_user_turn(record):
    text = text_of(record).strip()
    if not text:
        return False
    return not text.startswith(("<local-command", "<task-notification",
                                "<system-reminder", "Caveat:", "[Request interrupted"))


def main():
    payload = json.loads(sys.stdin.read() or "{}")
    records = load(payload.get("transcript_path", ""))
    if not records:
        return

    turns = [i for i, (kind, record) in enumerate(records)
             if kind == "user" and is_real_user_turn(record)]
    if not turns:
        return

    # Any fix instruction still in play — the last three turns, because a
    # directive does not expire when the next message arrives.
    asked = any(FIX_INTENT.search(text_of(records[i][1])) for i in turns[-3:])
    if not asked:
        return

    final = ""
    for kind, record in reversed(records):
        if kind == "assistant":
            final = text_of(record)
            break
    if not final.strip():
        return

    offers = OFFERS.findall(final)
    skips = SKIPPED.findall(final)
    if not offers and not skips:
        return
    if BLOCKER.search(final):
        return

    found = sorted({m if isinstance(m, str) else m[0]
                    for m in (offers + skips)})[:5]
    print(json.dumps({"decision": "block", "reason":
        "You were asked to fix this, and this turn ends by offering to fix it "
        "later: " + ", ".join(repr(f) for f in found) + ".\n\n"
        "This is a production app. Do the remaining work now. If something "
        "genuinely cannot be done, say so as a blocker — name what blocks it "
        "and what decision is needed — rather than as an offer. A stated "
        "blocker passes this gate; 'say the word' does not."}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # a broken gate must fail open, never wedge the session
