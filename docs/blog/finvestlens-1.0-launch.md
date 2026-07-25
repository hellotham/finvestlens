---
title: "FinvestLens 1.0: rebuilding GnuCash's accounting engine for the Mac"
description: >-
  A native Apple double-entry accounting app, verified against a real
  46,000-transaction GnuCash book to the cent. What we built, how we proved it,
  and the bugs that only real data will ever show you.
date: 2026-07-26
author: Hello Tham
tags: [swift, swiftui, macos, accounting, gnucash, open-source]
---

![FinvestLens](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/og-card.png)

Today we're releasing **[FinvestLens 1.0](https://hellotham.com/finvestlens/)** — a
native double-entry accounting application for macOS, iPadOS and iOS. It's free
software under the GPL, signed and notarized, and you can
[download it now](https://github.com/hellotham/finvestlens/releases/latest).

The elevator pitch is short: *the rigour of GnuCash, in an app that belongs on a
Mac.* The interesting part is everything underneath that sentence.

---

## The problem with loving GnuCash

GnuCash is genuinely excellent. It has twenty-five years of accounting
correctness baked into it — real double-entry bookkeeping, lots and cost basis,
multi-currency, a business layer that handles invoices and aging properly. Ask
an accountant to poke holes in its model and they'll struggle.

It's also a GTK application. On a Mac it looks like a visitor. There's no iPad
version, no iPhone version, no Shortcuts, no widgets, no Quick Look, no
Spotlight. None of the things that make software feel like it belongs.

The obvious move is to write a nice Mac front end over GnuCash's file format.
We didn't do that, because it locks you into someone else's on-disk decisions
forever. Instead we reimplemented the *model* — accounts, transactions, splits,
commodities, prices, lots — in idiomatic Swift, with our own native document
format, and kept GnuCash XML as an interchange format you can move through in
both directions.

That decision creates an obvious question. If you've rewritten the engine, how
do you know it's *right*?

## The oracle

Here's the approach that shaped everything else: **we never trusted our own
tests as the final word.** The final word was GnuCash itself.

The development book was a real one — 46,553 transactions, 559 accounts, over
100,000 price records, multiple currencies, a decade and a half of actual
financial history. Every significant claim was checked by importing that book
and comparing FinvestLens's output side by side with GnuCash 5.16's own
reports.

Not "looks about right." To the cent, on:

- net worth
- every account subtree balance
- register running balances
- the balance sheet
- the investment reports, including realised gains and cost basis

And in the other direction: export to GnuCash XML, re-import, export again —
and the two exports are **byte-identical**. GnuCash itself reads the exported
file back without complaint.

This matters more than it sounds. Synthetic test data agrees with whatever you
believed when you wrote it. Real data has opinions.

## The bugs only real data will show you

This is the fun part. Every one of these passed a full unit test suite and was
caught by the reference book.

**A commodity called "AT&T Top-up".** Our Ledger-format exporter wrote metadata
as `key: value` on a comment line. Commodity mnemonics with spaces in them
silently truncated the metadata that followed. Fix: quote metadata values, and
make the tokenizer quote-aware. You do not think of this until a book contains a
prepaid phone credit as a tradeable commodity.

**A whole-unit security holding fractional units.** The importer inferred
precision from the commodity's declared smallest fraction. One security was
declared as whole units but actually held a fractional quantity — so re-import
quietly rounded it away. The `commodity … format` sub-directive turned out to be
the authoritative source for precision, not the fraction. Round-trip fidelity
depends on believing the file over your own inference.

**`RvslInd` does not flip the sign.** Our ISO 20022 CAMT.053 importer treated a
reversal indicator as a sign flip. Reading the actual specification: it doesn't.
The amount is already signed. We'd have silently inverted every reversed
transaction in an imported statement.

**Short-position stock splits.** A stock split applied to a short position moves
the wrong way if you assume positive quantities. Nobody's synthetic test data
has a short position that later splits. One book did.

**`finlens print QUERY` ignored the query entirely.** Our command-line tool
filtered a whole-book export by matching a `guid` metadata key — except the
exporter writes the guid as a *note line*, and only the parser produces
metadata. So nothing ever matched, the "no guid found" fallback kept everything,
and `print Expenses:Food` cheerfully printed your entire book. It also converted
46,000 transactions to print five.

## What actually got built

Ten Swift packages, 221 files, 56,611 lines, and a deliberate rule that the
engine knows nothing about UI or persistence so it can be tested in isolation.

![The dashboard](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/screens/dashboard-light.png)

The dashboard is a tile board that never scrolls — every panel is sized to fit
the viewport, because a dashboard you have to scroll is a report with extra
steps.

**The register** is where the accounting actually happens. Transactions expand
into their splits inline; multi-currency and multi-split entries move to an
inspector rather than pretending to fit in a row.

![The transaction register](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/screens/transactions-light.png)

**Reports** were rebuilt to annual-report presentation standard rather than
"here is a table of numbers" — hierarchical face-and-notes built from your own
chart of accounts, ASC 274 liquidity ordering, materiality folding, proper
accounting typography with comparatives.

![The report gallery](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/screens/reports-light.png)

Also in the box: bank import for CSV, QIF, OFX/QFX, SWIFT MT940/MT942 and ISO
20022 CAMT.053; an import matcher that completes cross-account transfers rather
than duplicating them; on-device Apple Intelligence reading PDF statements;
budgets; a debt planner and lifetime planner; a small-business layer with
invoices, bills and aging; and eight languages.

## Making it fast enough to be pleasant

The first version opened the reference book in about **26 seconds**. A single
register edit took several seconds. That's not an app, it's a penance.

It now opens in **~6.3 seconds** and a register edit takes **~0.26s** (an
account edit, 0.067s). The general ledger scrolls all 46,000 transactions with
instant jumps to either end.

Nothing exotic got us there — just refusing to do work twice:

- The register's status strip is snapshotted in the same pass that builds the
  rows. It used to be three full-book scans *per render*.
- Autocomplete reads a per-revision cache instead of sorting 46,000
  transactions on every keystroke.
- Undo captures only what an edit is about to change. Price and settings edits
  used to snapshot the whole book as XML.
- Heavy reports are memoised on (parameters, book revision) and build behind a
  placeholder.
- An `os_signpost` harness watches every hot path, so regressions show up as
  data rather than vibes.

## Eight languages, and the trap nobody warns you about

FinvestLens ships in English, German, Spanish, French, Italian, Japanese,
Brazilian Portuguese and Simplified Chinese — 1,353 strings, with accounting
terminology following GnuCash's own conventions in each language so a migrant
reads familiar words.

Two things are worth passing on.

**Put the String Catalog in the app target, not the package.** SwiftUI resolves
`Text("…")` against `Bundle.main`. One catalog in the app therefore covers the
entire UI package too — which meant *zero* call-site churn across 89 view files.
The alternative is threading `bundle: .module` through every `Text`, and
discovering that `.navigationTitle`, `Section` and `Toggle` have no such
overload.

**Let the compiler tell you what the keys are.** We started with a hand-rolled
extractor. The authority turned out to be
`swift build -Xswiftc -emit-localized-strings`, whose output is exactly what the
runtime looks up — including the typed format specifiers interpolated strings
compile to. Diffing our catalog against it found **four live defects** where
strings had silently opted out of localization altogether:

```swift
Text("a " + "b")   // ← not localizable at all
```

That concatenation is a `String` expression, so Swift picks `Text(String)` — the
*verbatim* initialiser. No key is emitted, no translation ever happens, and
nothing warns you. The same trap catches any helper whose title parameter is
typed `String` instead of `LocalizedStringKey`; that's why our dashboard card
titles and register column headers stayed stubbornly English in the first German
build.

## Shipping it

Signed with a Developer ID, notarized by Apple, stapled.

One subtlety worth knowing: we notarize and staple **twice** — the `.app` and
then the `.dmg`. Stapling only the disk image passes every check you'd normally
run, but leaves the copy the user drags to `/Applications` without a local
ticket. First launch on a machine that happens to be offline then has nothing to
validate against. Both now carry their own.

Getting there also required enabling the hardened runtime on the two app
extensions — it was set on the app target only, and notarization requires it on
*every* executable in the bundle.

The whole pipeline is one script, so releasing is one command.

## A near miss worth confessing

For the website we needed screenshots. The first capture run produced a
beautiful dashboard — showing real account names and real balances, because the
app's session restore had helpfully reopened the real book over the demo we'd
opened.

Those got deleted. Instead there's now a generator that builds an entirely
synthetic book — invented employer, invented payees, invented holdings — that
balances to exactly zero at cost. Every screenshot on the site and in this
article comes from it.

Writing that generator produced two bugs that are almost too on-the-nose for an
accounting project: transactions whose legs didn't match, because each leg drew
its own random amount; and `Decimal(Double)` quietly reintroducing the
binary-float error the entire application exists to avoid.

## Fourteen days

The first commit landed on 12 July 2026. This one is 26 July. Three hundred and
twenty-five commits, ten packages, **1,179 tests**, and a phase plan taken from
P0 through P10 — engine, document, core UX, round-trip, everyday finance,
investments, dashboard, business, extended import, planning, and a Ledger CLI.

The thing that made that pace possible wasn't typing speed. It was having an
oracle. When a real book and a real GnuCash install can answer "is this
correct?" in seconds, you can move quickly *and* be sure — and you spend your
time on the interesting failures instead of wondering whether you have any.

## Try it

- **[Download FinvestLens 1.0](https://github.com/hellotham/finvestlens/releases/latest)** — macOS 26 or later, free, GPL v3
- **[The manual](https://hellotham.com/finvestlens/manual/)** — also inside the app under Help (⌘?)
- **[Source on GitHub](https://github.com/hellotham/finvestlens)**

Coming from GnuCash? **File ▸ Import ▸ GnuCash…** and your book comes across —
accounts, transactions, prices, schedules, business records. You can export back
any time. That's the point.

---

*FinvestLens is published by [Hello Tham](https://hellotham.com). It is not an
official GnuCash product and is not affiliated with the GnuCash project — but
the model it rests on is theirs, and we're grateful for it.*
