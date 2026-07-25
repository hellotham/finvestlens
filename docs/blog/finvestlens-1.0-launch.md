---
title: "FinvestLens 1.0: 56,000 lines of accounting software in fourteen days"
description: >-
  A native Apple double-entry accounting app, verified against a real
  46,000-transaction GnuCash book to the cent — built by writing specifications
  and issuing prompts. What worked, what I had to catch, and what real data
  found that no test suite would.
date: 2026-07-26
author: Hello Tham
tags: [swift, swiftui, macos, accounting, gnucash, ai-assisted-development, open-source]
---

![FinvestLens](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/og-card.png)

Today I'm releasing **[FinvestLens 1.0](https://hellotham.com/finvestlens/)** — a
native double-entry accounting application for macOS, iPadOS and iOS. Free
software under the GPL, signed and notarized, and you can
[download it now](https://github.com/hellotham/finvestlens/releases/latest).

The first commit landed on 12 July 2026. This one is 26 July. In between: 325
commits, ten Swift packages, 56,611 lines across 221 files, 1,179 tests, and a
phase plan taken from P0 through P10.

I typed very little of it. I directed it — and that turns out to be a skill with
its own failure modes, which is the more interesting story.

---

## The problem worth solving

GnuCash is genuinely excellent. Twenty-five years of accounting correctness —
real double-entry bookkeeping, lots and cost basis, multi-currency, a business
layer that handles invoices and aging properly. Ask an accountant to poke holes
in its model and they'll struggle.

It's also a GTK application. On a Mac it looks like a visitor. No iPad version,
no iPhone version, no Shortcuts, no widgets, no Quick Look, no Spotlight.

The obvious move is a nice Mac front end over GnuCash's file format. I didn't
want that — it locks you into someone else's on-disk decisions forever. I wanted
the *model* reimplemented in idiomatic Swift, with a native document format, and
GnuCash XML kept as an interchange format you can move through in both
directions.

Which raises the question that shaped the whole project. If you've rewritten the
engine, **how do you know it's right?**

## I wrote documents before I wrote code

The temptation with a capable coding agent is to start asking for features. I
think that's the main way these projects go wrong: you get a pile of plausible
code with no spine.

So the first artefacts weren't code. They were a **PRD** with numbered
requirements, an **architecture document** with numbered decisions, a **porting
strategy** mapping GnuCash's C modules to Swift ones, and a **phased plan** —
eleven phases, each with objectives, dependencies, deliverables, exit criteria,
test focus and risks.

That plan set rules that did most of the heavy lifting later:

- **Engine-first, bottom-up.** Nothing is built on an unproven foundation. Money
  and the model before persistence; persistence before UI.
- **Every phase is releasable.** Each ends at a usable, test-green state.
- **Test-gated.** A phase is done only when its exit criteria pass. Two hard
  gates — the double-entry invariant, and round-trip fidelity — never move.
- **Dependencies point downward only.** The engine builds and tests with nothing
  above it.

The payoff is that "is this done?" stops being a matter of opinion. Every task
cites a requirement; every phase has an exit criterion someone can run. When I
asked for P5, I wasn't asking for "investments, you know, the usual" — I was
asking for something with a written definition of finished.

## The oracle

Here's the decision I'd repeat on any project like this: **I never let our own
tests be the final word.**

The final word was GnuCash itself. I supplied three things the agent could check
against, and then insisted it did:

1. **A real book.** 46,553 transactions, 559 accounts, over 100,000 price
   records, multi-currency, a decade and a half of actual financial history.
2. **A real GnuCash install** (5.16) to produce reference reports.
3. **GnuCash's actual C/C++ source**, cloned locally, as the porting oracle —
   not the documentation, not the binary, the source.

That third one changed the quality of the work more than anything else. A prompt
like *"audit our lot and cost-basis implementation against the real GnuCash
source and fix every divergence"* produces categorically better results than
*"implement cost basis."* One is verifiable; the other is vibes.

The line-by-line source audit alone turned up frozen splits that should count in
reconciled balances, a price lookup that should be nearest-in-time rather than
newest-on-or-before, and indirect currency chaining we'd missed — each fixed
with a test and a source citation.

The result I care about: import that book into FinvestLens, run the reports, put
them beside GnuCash's own, and they agree **to the cent** — net worth, every
account subtree, register running balances, the balance sheet, and the
investment reports including realised gains. Export to GnuCash XML, re-import,
export again, and the two exports are **byte-identical**.

## The prompt shape that works

After a few days a pattern emerged. The productive instruction is almost never
"build X." It's:

> **Audit X against Y, and fix what you find.**

Where Y is something external and checkable. Over two weeks that produced a
GnuCash parity audit on accounts and transactions, the source line-by-line
audit, a menu-parity sweep, a report-catalogue build-vs-skip triage, a HIG
review, a PRD audit, four separate usability and performance audits, and a
report-quality redesign researched against actual annual-report presentation
standards.

Each one came back with a list, and the list got fixed. That's a very different
activity from feature requests, and it's where most of the real quality came
from.

The most productive single instruction was the last one of that kind: a
**full-codebase adversarial review** — ten independent finder angles over the
whole implementation, then per-candidate verification, then a gap sweep for what
the first pass missed. It surfaced 63 candidates. 60 were confirmed and fixed
the same day; 2 were refuted, which matters just as much — an agent that never
says "actually, that one's wrong" isn't reviewing, it's agreeing.

## What only real data will ever find

Every bug below passed a full unit-test suite and was caught by the reference
book. This is my favourite section because none of it is hypothetical.

**A commodity called "AT&T Top-up".** Our Ledger exporter wrote metadata as
`key: value` on a comment line. A commodity mnemonic with a space in it silently
truncated everything after it. You do not invent this test case. A real book
contains prepaid phone credit as a tradeable commodity.

**A whole-unit security holding fractional units.** The importer inferred
precision from the commodity's declared smallest fraction. One security was
declared whole-unit but actually held a fraction — so re-import quietly rounded
it away. The file's own `format` declaration turned out to be authoritative, not
our inference. Round-trip fidelity means believing the file over yourself.

**`RvslInd` does not flip the sign.** Our ISO 20022 CAMT.053 importer treated a
reversal indicator as a sign flip. Reading the actual specification: it doesn't.
The amount is already signed. We'd have inverted every reversed transaction in
an imported statement.

**Short-position stock splits.** A split applied to an open short position moves
the wrong way if you assume positive quantities — producing phantom lots and
overstated gains. No synthetic fixture has a short position that later splits.
One real book did.

**`finlens print QUERY` ignored its query.** Our command-line tool filtered a
whole-book export by matching a `guid` metadata key — except the exporter writes
the guid as a *note line*, and only the parser produces metadata. Nothing ever
matched, the "no guid found" fallback kept everything, and `print Expenses:Food`
cheerfully printed the entire book.

## Where I had to step in

An honest account needs this part.

**Judgement calls stayed mine.** Four things were consciously *not* built, and
each is recorded as a decision with reasoning rather than left as a silent gap:
online bank sync (cloud-mediated connectors sit poorly with a local-first app,
and the Australian CDR path carries accreditation burden out of proportion to a
file-import tool); TXF export (a US tax format with no meaning for an AU book);
a "set budget" rule action (budgets here are per-account planned amounts — a
rule assigning one to a transaction has no coherent target); Quick Look for
`.gnucash` (it's the interchange format, not the document you browse). An agent
will happily build all four. Deciding they shouldn't exist is the job.

**I supplied the ground truth.** The real book, the GnuCash install, the source
checkout, four genuine bank export files to validate the import matcher against.
None of that is something the agent could have obtained.

**I did the looking.** The build-and-relaunch loop was automated; deciding
whether the result actually looked right was not.

**And I caught the near-misses.** The best example: the first screenshot run for
this website produced a beautiful dashboard — showing my real account names and
real balances, because the app's session restore had helpfully reopened the real
book over the demo. Those got deleted, and there's now a generator that builds an
entirely synthetic book. Writing *that* produced two bugs almost too on-the-nose
for an accounting project: transactions whose legs didn't match because each leg
drew its own random amount, and `Decimal(Double)` quietly reintroducing the
binary-float error the whole application exists to avoid.

I also had to catch a stray `hellonotes` where `finvestlens` belonged in the
website's base path — the kind of typo that silently 404s every link on a
project page.

## What actually got built

![The dashboard](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/screens/dashboard-light.png)

The dashboard is a tile board that never scrolls — every panel sized to fit the
window, because a dashboard you scroll is a report with extra steps.

![The transaction register](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/screens/transactions-light.png)

The register expands transactions into their splits inline; multi-currency and
multi-split entries move to an inspector rather than pretending to fit in a row.

![The report gallery](https://raw.githubusercontent.com/hellotham/finvestlens/main/website/public/images/screens/reports-light.png)

Reports were rebuilt to annual-report presentation standard — hierarchical
face-and-notes from your own chart of accounts, ASC 274 liquidity ordering,
materiality folding, proper accounting typography with comparatives.

Also in the box: bank import for CSV, QIF, OFX/QFX, SWIFT MT940/MT942 and ISO
20022 CAMT.053; an import matcher that completes cross-account transfers rather
than duplicating them; on-device Apple Intelligence reading PDF statements;
budgets; debt and lifetime planners; a small-business layer with invoices, bills
and aging; a read-only `finlens` command line modelled on Ledger; and eight
languages.

## Two things worth passing on

**Performance came from refusing to do work twice.** The first version opened the
reference book in ~26 seconds and took several seconds per register edit. It now
opens in ~6.3s and edits in ~0.26s. Nothing exotic: the register's status strip
is snapshotted in the same pass that builds the rows (it used to be three
full-book scans *per render*), autocomplete reads a per-revision cache instead of
sorting 46,000 transactions per keystroke, undo captures only what an edit
touches, and heavy reports are memoised on (parameters, book revision). An
`os_signpost` harness watches the hot paths so regressions arrive as data.

**Let the compiler tell you what your localizable strings are.** We shipped
1,353 strings in eight languages. The authority turned out to be
`swift build -Xswiftc -emit-localized-strings`, whose output is exactly what the
runtime looks up. Diffing our catalog against it found four live defects where
strings had silently opted out of localization:

```swift
Text("a " + "b")   // ← not localizable at all
```

That concatenation is a `String` expression, so Swift picks the *verbatim*
initialiser. No key is emitted, no translation happens, nothing warns you. The
same trap catches any helper whose title parameter is typed `String` instead of
`LocalizedStringKey` — which is why the dashboard card titles stayed stubbornly
English in the first German build.

## What I'd tell someone trying this

- **Write the spec first.** Numbered requirements and written exit criteria turn
  "done" from an opinion into a check.
- **Find an oracle.** Something external that can answer "is this correct?"
  without your judgement. A reference implementation, a real dataset, a published
  specification. Then insist on audits against it rather than requests for
  features.
- **Real data over synthetic data, always.** Synthetic fixtures agree with
  whatever you believed when you wrote them. Real books have opinions.
- **Reserve the judgement calls.** What *not* to build, what a number should
  mean, and whether the thing on screen is actually good — those stayed with me
  the entire time, and should have.
- **Verify the verification.** More than once during this project a measurement
  was wrong rather than the code — readings taken mid-animation, greps that
  matched a substring of the thing they were meant to exclude. Being sceptical of
  your own instrumentation is part of the work.

Fourteen days is the headline number, but it isn't really the point. The pace
came from having an oracle: when a real book and a real GnuCash install can
answer "is this correct?" in seconds, you can move quickly *and* be sure, and you
spend your time on interesting failures instead of wondering whether you have
any.

## Try it

- **[Download FinvestLens 1.0](https://github.com/hellotham/finvestlens/releases/latest)** — macOS 26 or later, free, GPL v3
- **[The manual](https://hellotham.com/finvestlens/manual/)** — also in the app under Help (⌘?)
- **[Source on GitHub](https://github.com/hellotham/finvestlens)** — including the PRD, architecture, phase plan and the full build narrative in `docs/`

Coming from GnuCash? **File ▸ Import ▸ GnuCash…** brings your book across —
accounts, transactions, prices, schedules, business records — and you can export
back any time. That's rather the point.

---

*FinvestLens is published by [Hello Tham](https://hellotham.com). It is not an
official GnuCash product and is not affiliated with the GnuCash project — but the
model it rests on is theirs, and I'm grateful for it.*
