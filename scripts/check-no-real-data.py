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
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

ROOTS = [
    ("docs", "*.md"),
    ("website/src", "*"),
    ("website/public", "*"),
]
EXTRA_FILES = ["README.md"]

# Reference material quoting someone else's published examples.
SKIP = {"docs/ledger-format-reference.md", "docs/ledger-cli-reference.md"}

# A precise figure of this size is a balance, not an illustration.
THRESHOLD = 10_000

MONEY = re.compile(r"\$([0-9][0-9,]*)(\.[0-9]{2})?\b")
WAIVER = re.compile(r"<!--\s*synthetic\s*-->", re.I)


def offending(line: str) -> list[str]:
    if WAIVER.search(line):
        return []
    out = []
    for whole, cents in MONEY.findall(line):
        try:
            value = int(whole.replace(",", ""))
        except ValueError:
            continue
        # Cents on a large number is the signature of a real balance; a
        # round million is one whichever way it is written.
        if value >= 1_000_000 or (value >= THRESHOLD and cents):
            out.append("$" + whole + (cents or ""))
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
        if rel in SKIP or "/node_modules/" in rel or "/dist/" in rel:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for figure in offending(line):
                problems.append(f"{rel}:{number}: {figure} — {line.strip()[:90]}")

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
