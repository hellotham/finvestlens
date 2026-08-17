# Release notes

User-facing notes, newest first. What was built and why lives in
[implemented.md](implemented.md); what was consciously *not* built lives in
[deferred.md](deferred.md). This file is the short version: what a person who
uses FinvestLens would notice.

---

## 1.1

The first release after 1.0, and a large one: 392 commits. 1.0 was a working
double-entry ledger. 1.1 is that ledger with the things a real book turned out
to need — a business side, an investments side, a planning side, a
command-line, and a navigation model that copes with all of them at once.

### New

- **Investments.** A hub with a tab per portfolio, security detail pages,
  holdings and reconciliation, bond and fund providers alongside the equity
  ones, and a fundamentals sidecar. Prices come from a chosen provider with
  its provenance recorded, so a figure can always be traced to where it came
  from.
- **Business.** Customers, vendors, employees and jobs; invoices, bills and
  vouchers with terms and tax tables; posting, payments and credit notes;
  aging and customer-summary reports; a printable invoice PDF. Verified
  against GnuCash 5.16's own reports on a real book, to the cent.
- **Planning.** Debt, lifetime and tax planners, insights, wellbeing,
  a financial passport, challenges and records. Every default is visible and
  editable, and none of it is advice.
- **`finlens`, a read-only command line.** Ledger-modelled queries over a
  book — registers, balances, budgets, forecasts — with its own query and
  period grammars and a REPL. Read-only by design: it cannot write to a book.
  [docs/cli.md](cli.md) is the manual.
- **Bank-statement importers.** MT940/MT942 and CAMT.053 join CSV, QIF and
  OFX, with an import matcher that heals transfers, claims rows one-to-one,
  and refuses to treat free text as a bank's unique identifier.
- **Eight languages.** German, Spanish, French, Italian, Japanese, Brazilian
  Portuguese and Simplified Chinese alongside English.

### Changed

- **Navigation is modes, not menus.** Seven modes each with their own sidebar
  and tab strip; a mode's home tab cannot be closed, and the tabs a mode
  always has are derived rather than remembered. One period selector governs
  the surfaces that have a period.
- **The register was rebuilt** on GnuCash's own sheet model, with in-place row
  editing, working Tab order, an editable Num field, and the same view modes
  on iOS.
- **Reports read like statements.** Annual-report presentation, a Financial
  Review deck, comparative statements, Average Balance, and a Trial Balance
  treatment. AI-written slide narratives are gated by a validator that checks
  every figure against the book.
- **The dashboard is a tile board that never scrolls** — it fits the viewport
  or it is not on it.

### Fixed

Two rounds of full-codebase review closed 60 findings in July and 16 in
August. The ones a user would have felt:

- A **balance sheet could fail to balance** on a converted book: each column
  was rounded independently, so assets and equity could differ by a cent.
  Both invariants now hold at once — every column adds up to the total
  printed under it, *and* assets equal liabilities plus equity — with any
  currency-translation residue disclosed as its own equity line rather than
  hidden.
- A **daily schedule older than about thirteen years silently stopped**. The
  occurrence walk spent its whole budget crossing history and returned
  nothing, so the bill simply stopped appearing, with no error anywhere.
- **`"500.00 DR"` imported as a deposit.** Accounting exports mark the side
  with a `DR`/`CR` token rather than a sign; the parser stripped the letters
  and read the magnitude, flipping every withdrawal in the file.
- **A download covering several accounts posted all of it into one.** Files
  carrying more than one statement — an OFX with several `STMTRS` blocks, an
  MT940 with several `:25:` blocks, a CAMT with several `Stmt` blocks — are
  now imported one statement at a time, each against its own account.
- **A rule reading "amount greater than 1,000" fired on everything over a
  dollar**, because the threshold was parsed with a reader that stops at the
  comma. Money typed by a person is now read by one parser everywhere.
- **A budget's rollover compared against the wrong month.** The previous
  period was stepped back by the current window's length in seconds, so
  March's comparison ran 29 January – 28 February.
- **Quotes from three providers were dated a day late** for readers east of
  the exchange, because an instant with no timezone was read in the reader's
  own.
- **Prices could be stamped with the wrong currency** — 1,205 rows on one
  reference book, including US closes recorded as an Australian fund's unit
  price. The service now refuses a mismatch outright.
- **A carriage return in a memo broke the GnuCash round-trip**, because XML
  normalises line endings on parse unless the character is escaped.
- **Gains and losses were coloured at 2.22:1 contrast**, less than half of
  legible. Money now uses tokens measured against WCAG AA on every background
  the app draws.
