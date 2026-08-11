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
    to"), for bare skip words, and for the **residual-work report** — a turn
    that ends by listing what is still wrong;
  - "remains undone because", "blocked by" and "cannot … until" are allowed,
    because a stated blocker is a report and an offer is a deferral — but only
    for the item they sit beside.

A genuine blocker is still reportable. What is not allowed is ending the turn
with the work unstarted and the decision handed back.

Two holes were found by replaying a turn this gate let through, and both are
closed here. That turn fixed 13 of 15 review findings, then wrote a section
headed **What's still broken** listing the other two with file:line — no offer
phrase, no skip word, nothing the vocabulary lists could see. Hence `RESIDUAL`.
And the blocker exemption was whole-message, so one honest sentence anywhere
excused every unfixed item in a long report; hence the ±300-character
proximity rule. Precision about a defect is not a substitute for repairing it.
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

# Deferring by *structure* rather than by vocabulary — the miss this gate was
# rebuilt for.
#
# The turn that got through said neither "skipped" nor "shall I". It reported
# the repairs it had made, then opened a section headed **What's still broken**,
# listed three real defects with file:line, and stopped. Nothing in the earlier
# word lists appears in a paragraph like that, because naming a defect
# accurately is not the tell — *ending the turn having named it* is.
#
# So this class matches the residual-work report itself: the heading, the
# partial-completion count ("13 of 15 findings"), and the plain admissions.
RESIDUAL = re.compile(
    r"what'?s (?:still |left )?(?:broken|open|outstanding|remaining|unfixed|left)"
    r"|\bstill (?:broken|outstanding|unfixed|open|to (?:do|fix)|need(?:s|ed)? fixing)\b"
    r"|\bremaining (?:issues?|problems?|findings?|work|items?|gaps?|defects?)\b"
    r"|\b(?:known|open) (?:issues?|defects?|findings?)\b"
    r"|\bremains? (?:broken|outstanding|unfixed|open)\b"
    r"|\bI (?:did ?n[o']t|have ?n[o']t|haven'?t|didn'?t) (?:fix|address|repair|do)\b"
    r"|\bnot (?:yet )?(?:fixed|repaired|addressed|implemented|done)\b"
    r"|\b\d+ of \d+ (?:findings?|issues?|items?|problems?|fixes|defects?)\b"
    r"|\bthe (?:other|remaining) \w+ (?:are|remain)\b",
    re.I)

# Text that is being *mentioned* rather than *used*.
#
# The gate blocked the very turn that repaired it, matching "13 of 15
# findings", "What's still broken" and "shall I" — every one of them a quotation
# of the patterns being added, in a report whose work was complete. A detector
# that cannot tell use from mention fires on every discussion of itself, and a
# gate that cries wolf on honest work is one people learn to route around.
#
# Backticks, fenced blocks and double/curly quotes are the marks a writer uses
# for mention, so matches inside them are ignored. **Single quotes are
# deliberately not included**: apostrophes are everywhere in ordinary prose, and
# treating them as delimiters would let "I didn't fix the parser, and I can't
# say when" swallow its own middle and slip through. The residual risk — a
# deferral written inside quotation marks — is not a shape deferrals take.
MENTION = re.compile(
    r"```.*?```"            # fenced code
    r"|`[^`\n]*`"           # inline code
    r"|\"[^\"\n]{0,160}\""  # "double quoted"
    r"|“[^”\n]{0,160}”"     # “curly quoted”
    r"|\*\*[^*\n]{0,160}\*\*"  # **strong**
    r"|\*[^*\n]{0,160}\*",     # *emphasised* — the marker that caught this
    re.S)                      # gate out a second time, on the very fix for it


def spoken(text):
    """The message with quotations and code blanked out, positions preserved."""
    return MENTION.sub(lambda m: " " * len(m.group(0)), text)


# Handing the user work that the assistant could do itself.
#
# This is the loophole the other classes left open, and it was used repeatedly:
# no offer, no skip word, no residual heading — just an instruction pointed at
# the user. "That's your call, not mine to route around." "You can add a Bash
# permission rule." "Run it yourself." Each one reads as deference and lands as
# a deferral, and the generic BLOCKER phrases excused all of them.
#
# A handoff is not forbidden. It is forbidden *without a receipt* — see
# `has_denial_receipt`. The project's rule everywhere else is that a claim
# carries its evidence; a blocker is a claim, so it carries evidence too.
HANDOFF = re.compile(
    r"\byou (?:can|could|should|need to|will need to|have to|must) "
    r"(?:run|add|execute|install|grant|enable|set|edit|apply|do|approve|allow)\b"
    r"|\b(?:run|do|execute) (?:it|this|that|the following|these) yourself\b"
    r"|\bplease run\b"
    r"|\badd a (?:bash )?permission rule\b"
    r"|\b(?:that|this)(?:'s| is) (?:your|the user's) (?:call|decision|choice|shout)\b"
    r"|\bnot mine to\b"
    r"|\bI'?ll leave (?:it|that|this) (?:to|with) you\b"
    r"|\bhand(?:ing)? (?:it|this|that) (?:back|over)?\s*to you\b"
    r"|\byour move\b",
    re.I)

# The one handoff this project *requires*, so it must never be blocked: the
# user does the looking. `/relaunch` mandates exactly this wording — "visual
# result unverified; over to you" — and a gate that fights the workflow it is
# meant to protect is one that gets switched off.
VISUAL_HANDOFF = re.compile(
    r"unverified on screen|visual (?:result|verification)|over to you to look"
    r"|you do the (?:looking|visual)|needs? (?:a look|your eyes)",
    re.I)

# Evidence in *this turn's transcript* that an action was actually refused —
# a tool-permission denial, a hook block, a sandbox refusal. Asserting a
# blocker is not the same as having hit one.
DENIAL = re.compile(
    r"Permission for this action was denied"
    r"|Blocked by classifier"
    r"|Permission denied"
    r"|requested permissions? .{0,40}(?:denied|rejected)"
    r"|user (?:denied|rejected) (?:the|this|that) ",
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


def attempts_after(records, index):
    """How many tool calls the assistant made after `index`, absolute."""
    total = 0
    for kind, record in records[index + 1:]:
        if kind != "assistant":
            continue
        for block in record.get("message", {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                total += 1
    return total


# A refusal excuses a handoff only if the turn shows the alternatives being
# tried afterwards. Two is the bar: one retry can be the same call again.
ATTEMPTS_REQUIRED = 2


def has_denial_receipt(records, start):
    """Did something actually refuse this turn — *and* was that refusal final?

    Scans everything after the last user message — tool results, hook output,
    permission errors — for evidence that an action was genuinely blocked.
    Without it, "you can run this yourself" is not a blocker, it is a deferral
    wearing a blocker's clothes, and this project's standing rule is that a
    claim carries its receipt.

    A receipt alone was not enough, and this is why the rule grew a second
    half. On 11 Aug 2026 `git push --force-with-lease=refs/heads/main:<sha>`
    was refused by the permission classifier, and that one denial was reported
    as "the force-push is refused, rewriting history has no non-force path" —
    a wall. Plain `git push --force-with-lease origin main` was accepted
    minutes later. The refusal was real; the conclusion drawn from it was not.
    One refused *spelling* is not a refused *task*, so a denial now only
    excuses a handoff when the transcript shows the alternatives actually being
    attempted after it.
    """
    denied_at = None
    for offset, (kind, record) in enumerate(records[start:], start=start):
        # Only what came *back* counts. Scanning the assistant's own prose let
        # it certify itself: writing "you can add a permission rule" both
        # triggered the handoff rule and satisfied the receipt for it, so the
        # sentence this class exists to catch cleared its own bar. A receipt
        # cannot be written by the claimant.
        if kind != "user":
            continue
        content = record.get("message", {}).get("content")
        if isinstance(content, str):
            continue                       # a typed message, not a tool result
        for block in content or []:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            if DENIAL.search(json.dumps(block.get("content"))):
                denied_at = offset
                break
        if denied_at is not None:
            break
    if denied_at is None:
        return False
    # The refusal happened. Was it the end of the attempt, or the start of
    # looking for another way?
    return attempts_after(records, denied_at) >= ATTEMPTS_REQUIRED


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
    # Match on what the turn *says*, not on what it quotes.
    final = spoken(final)

    # A blocker excuses the item it *sits beside*, not the whole message.
    #
    # The old rule let one sentence of honest blocker anywhere in a long report
    # wave through every other unfixed item in it — the bigger the report, the
    # cheaper the exemption. An honest blocker is adjacent to what it blocks by
    # construction ("X remains undone because Y"), so proximity costs nothing to
    # write and closes the hole.
    excused = [m.span() for m in BLOCKER.finditer(final)]

    def is_excused(span):
        return any(start < span[1] + 300 and span[0] < end + 300
                   for start, end in excused)

    found = []
    for pattern in (OFFERS, SKIPPED, RESIDUAL):
        for match in pattern.finditer(final):
            if not is_excused(match.span()):
                found.append(match.group(0).strip())

    # Handing work over is judged separately, and BLOCKER does not excuse it:
    # "that's your call" *is* the blocker phrasing, so letting it self-excuse is
    # what made this class invisible. Only two things clear a handoff — an
    # actual refusal recorded this turn, or the visual check the user has always
    # done themselves.
    if not (has_denial_receipt(records, turns[-1]) or VISUAL_HANDOFF.search(final)):
        found += [m.group(0).strip() for m in HANDOFF.finditer(final)]

    if not found:
        return

    found = sorted(set(found))[:5]
    print(json.dumps({"decision": "block", "reason":
        "You were asked to fix this, and this turn ends with work named but not "
        "done: " + ", ".join(repr(f) for f in found) + ".\n\n"
        "This is a production app. Do the remaining work now — including the "
        "defects you just finished describing. Listing a defect accurately is "
        "not the same as fixing it, and a section headed 'what's still broken' "
        "is a deferral however precise its file:line references are.\n\n"
        "If something genuinely cannot be done, say so as a blocker *next to "
        "the item it blocks* — name what blocks it and what decision is needed. "
        "An adjacent blocker passes this gate; a heading does not.\n\n"
        "If what you wrote hands the work to the user — 'you can run this', "
        "'that's your call', 'add a permission rule' — then do it yourself "
        "instead. That phrasing clears this gate only when something in this "
        "turn actually refused you (a tool denial, a hook block) or when it is "
        "the on-screen check the user always does. Exhaust the alternatives "
        "first: a blocked tool is not a blocked task."}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open — a broken gate must never wedge the session — but fail
        # *loudly*. A one-word typo (`last` for `turns[-1]`) silently disabled
        # this gate entirely, and a silent gate is indistinguishable from a
        # gate that agrees with you. stderr surfaces; stdout is parsed as the
        # hook's verdict and must stay clean.
        import traceback
        print("check-no-deferrals.py CRASHED — gate is not running:",
              file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
