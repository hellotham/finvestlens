#!/usr/bin/env python3
#
#  check-no-real-data.py
#  FinvestLens
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Refuse to publish the maintainer's own balances.

`docs/` and `website/` are public. The reference book is not: it is one real
household's accounts, and the standing rule is that its contents never reach
fixtures, screenshots, logs or the website.

That rule was kept by hand and failed. A sweep on 10 Aug 2026 found a complete
financial profile sitting in committed documentation — net worth, super
balance, portfolio value, realised gains, taxable income, two named accounts —
written there over months as evidence that a report "matched GnuCash to the
cent". The evidence was worth recording; the figures never were.

So the gate is a *magnitude* rule, not a blocklist. A real balance is large and
precise; a documentation example is small and round. Anything at or above
`THRESHOLD` with cents, or any figure in the millions, has to be either
obviously synthetic or explicitly waived on the line.

Waive with a trailing `<!-- synthetic -->` comment when a large figure really is
made up (the Acme/Globex business fixtures, a loan-calculator illustration).

The magnitude rule has a known floor, and it is not an oversight to fix by
lowering `THRESHOLD`. Real dividend figures were sitting in two reconciler
fixtures on 12 Aug 2026 — each under a hundred dollars, and dropping the
threshold far enough to catch them would flag every share price in the suite,
which is how a gate gets ignored.

So the second rule, `recoverableHolding`, does not look at size at all. It
looks for the *shape* a statement fixture leaks through: a per-unit rate
printed beside the amount it produced, from which the unit count — a holding —
falls out by division. Measured against the two fixtures as they were
published, it catches the one where the division is exact.

It does not catch the other, and that is the correct answer rather than a miss:
that fixture's amount was rounded, so no whole unit count exists and nothing is
recoverable from it. What leaked there was the *rate itself* being a real
security's, which no structure reveals — only a person who knows where the
number came from. That judgement stays with the maintainer, as CLAUDE.md ▸
Review gates assigns it. This gate covers magnitude and recoverability; it
still does not claim to cover provenance.
"""

from __future__ import annotations

import pathlib
import re
import sys
from decimal import Decimal, InvalidOperation

REPO = pathlib.Path(__file__).resolve().parent.parent

ROOTS = [
    ("docs", "*.md"),
    ("website/src", "*"),
    ("website/public", "*"),
    # Fixtures are named first in the rule above and were the one place this
    # gate never looked. A test file is as public as a doc — same repository,
    # same GitHub page — and it is where a figure copied off a real statement
    # while reproducing a parser defect actually lands.
    ("Packages", "*.swift"),
    ("finvestlens", "*.swift"),
    # Including this file: a gate that quotes the figure it caught republishes
    # it, and that is the mistake this whole entry is about.
    ("scripts", "*"),
]
EXTRA_FILES = ["README.md"]

# Reference material quoting someone else's published examples.
SKIP = {"docs/ledger-format-reference.md", "docs/ledger-cli-reference.md"}

# A precise figure of this size is a balance, not an illustration.
THRESHOLD = 10_000

MONEY = re.compile(r"\$([0-9][0-9,]*)(\.[0-9]{2})?\b")
# `<!--` suits Markdown; Swift and Python need their own comment openers, and
# without one the Swift roots could not be waived at all — the widget's sample
# balance sits inside a multi-line string literal whose line ends in a `\`
# continuation, where any trailing token would corrupt the JSON being tested.
WAIVER = re.compile(r"(?:<!--|//|#)\s*synthetic", re.I)
# 1234567 is nobody's balance. A run of ascending digits from 1 is the
# universal placeholder, and demanding a waiver comment for it would put the
# burden on the one figure that is self-evidently invented.
DIGITS = "123456789"


def isPlaceholder(whole: str) -> bool:
    bare = whole.replace(",", "")
    return len(bare) >= 4 and DIGITS.startswith(bare)


def offending(line: str) -> list[str]:
    if WAIVER.search(line):
        return []
    out = []
    for whole, cents in MONEY.findall(line):
        try:
            value = int(whole.replace(",", ""))
        except ValueError:
            continue
        if isPlaceholder(whole):
            continue
        # Cents on a large number is the signature of a real balance; a
        # round million is one whichever way it is written.
        if value >= 1_000_000 or (value >= THRESHOLD and cents):
            out.append("$" + whole + (cents or ""))
    return out


# --- Holding recovery -------------------------------------------------------
#
# The magnitude rule is blind to a small figure, and a statement fixture leaks
# through a structure rather than a size: print a per-unit rate beside the
# amount it produced and the unit count falls out of the division — which is a
# holding. Both fixtures found on 12 Aug 2026 had exactly that shape, and one
# printed the unit count outright.
#
# The discriminator is that the division comes out *exact*. Allowing a
# near-integer quotient instead was measured and abandoned: it took the clean
# tree from 2 hits to 16, matching an FX rate against a converted amount and
# the string "2025 notes" — a year. A gate that fires on a clean tree is one
# people learn to skip, so this stays strict and misses the rounded case.
WINDOW = 14
DECIMAL = re.compile(r"(?<![\w.])(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2,4})(?![\d])")
STATEMENT = re.compile(
    r"payment date|record date|net payment|franking|franked|per share|per note|"
    r"per unit|distribution rate|shares|units|payment advice|dividend statement",
    re.I)


def recoverableHolding(block: str) -> list[str]:
    """Rate × whole number = amount, all printed together on a statement."""
    if not STATEMENT.search(block):
        return []
    figures = []
    for whole, frac in DECIMAL.findall(block):
        try:
            figures.append(Decimal(whole.replace(",", "") + "." + frac))
        except InvalidOperation:
            continue
    out = []
    for rate in figures:
        # A per-unit rate: under ten, and printed to more than one decimal —
        # `5.00` is a dollar amount, `0.9338` is a rate.
        if not (Decimal("0.0001") <= rate < 10) or rate == rate.quantize(Decimal("0.1")):
            continue
        for amount in figures:
            if amount < 50:
                continue
            units = amount / rate
            if units >= 20 and units == units.to_integral_value():
                out.append(f"{rate} × {int(units)} units = {amount}")
    return out


def main() -> int:
    files: list[pathlib.Path] = [REPO / name for name in EXTRA_FILES]
    for root, glob in ROOTS:
        base = REPO / root
        if base.is_dir():
            files += [p for p in base.rglob(glob) if p.is_file()]

    problems: list[str] = []
    for path in sorted(set(files)):
        rel = str(path.relative_to(REPO))
        if rel in SKIP or any(d in rel for d in ("/node_modules/", "/dist/", "/.build/")):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        lines = text.splitlines()
        for number, line in enumerate(lines, 1):
            for figure in offending(line):
                problems.append(f"{rel}:{number}: {figure} — {line.strip()[:90]}")

        # A holding is recovered from figures on *different* lines, so this one
        # reads a sliding window rather than a line. The waiver is therefore
        # checked against a *span* rather than the window: a `// synthetic`
        # comment covers the WINDOW lines on either side of itself, so it can
        # be written in the doc comment introducing a fixture instead of inside
        # the string literal, where it would become part of the text under
        # test. Anchoring it to the window alone was tried first and does not
        # work — the comment sits just outside the window that fires.
        waived = [n for n, line in enumerate(lines) if WAIVER.search(line)]
        seen: set[str] = set()
        for index in range(len(lines)):
            if any(index - WINDOW <= w <= index + WINDOW for w in waived):
                continue
            for hit in recoverableHolding("\n".join(lines[index:index + WINDOW])):
                if hit in seen:
                    continue
                seen.add(hit)
                problems.append(f"{rel}:{index + 1}: holding recoverable — {hit}")

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} figure(s) look like real balances in published files.")
        print("Replace them with the claim they were evidence for "
              '("matches GnuCash to the cent"), or mark the line <!-- synthetic --> '
              "if the figure really is invented.")
        return 1
    print("No real-looking financial figures in the published files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
