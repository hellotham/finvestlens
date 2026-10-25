# Release notes

User-facing notes, newest first. What was built and why lives in
[implemented.md](implemented.md); what was consciously *not* built lives in
[deferred.md](deferred.md). This file is the short version: what a person who
uses FinvestLens would notice.

---

## 1.2 (not yet released)

FinvestLens on the 27 releases, on a phone, in the reader's language, and with
your own choice of where the Apple Intelligence features run.

### New

- **A phone layout.** On an iPhone — and in an iPad window narrowed to a
  phone's width — FinvestLens is a tab bar: Dashboard, Accounts,
  Investments, Reports and More. It used to be the iPad's layout, centred
  and cut off on both sides. The register is a list of postings with the
  row actions on a long press; the editor changes the date, description,
  notes and each split's account and amount.
- **Books on Box.** Keep a book in your own Box account and open it with
  **Open from Box…**, in the File menu or on the welcome screen. It goes
  through a Box app you set up yourself, so no one else's app is ever
  between you and your files. Saving with ⌘S, closing the book or quitting
  uploads a new version — a large book in parts, so a cut-off upload carries
  on where it stopped; opening it again fetches the latest first; work saved
  without a connection goes up when it returns; and a version another device
  saved is never replaced — **Keep Both** puts yours beside it.
- **A model of your own.** Point Settings ▸ Apple Intelligence at a folder
  of MLX models and choose one: it serves every Apple Intelligence feature,
  on your Mac, iPhone or iPad. Nothing is bundled, recommended or
  downloaded.
- **Invoices read from their picture.** Split from Invoice, Smart Import's
  invoices and Categorise from Attachment read a photographed or scanned
  invoice as a picture, with Vision's text reader to hand — it got every
  field right on every test page, where reading the text alone missed two
  totals in fifteen. A photo is turned the right way up first.
- **Where each request runs, said where you start it.** Every command that
  could leave the device says where it runs, beside its button. Private
  Cloud Compute is built in and stays off until Apple grants the
  entitlement it needs.
- **Everything in your language.** Reports, the review decks, error
  messages, undo names, toasts, Siri's phrases and the starter chart of
  accounts are now translated too, in all eight languages.

### Better

- **Saving doesn't freeze the window.** The write to the book's file — seconds
  on a network or cloud folder — runs in the background; on the reference
  book the window's share of a save fell from 9.6 s to 0.24 s.
- **Apple Intelligence on Foundation Models 27.** A document is cut to fit
  by the model's own count of it, and a written summary has every figure
  in it checked against the book before you see it.
- **A crashed copy no longer locks you out.** A lock left behind by a
  FinvestLens on this Mac that is no longer running is cleared when the
  book opens, rather than the app opening with no window.
- **iPhone and iPad save when you leave the app.** iOS can end an app in
  the background without warning; the book is saved as you switch away.
- **Search keeps up with your typing, and its results are a register.** A
  keystroke searches a large book in a few milliseconds, and what it finds
  shows as All Transactions narrowed to the matches, which you edit as you
  would any register — the way GnuCash's Find opens its results. Void or
  Delete over a selection takes every selected transaction, as one Undo.
- **Reports in full.** Income & Expense breaks every category down into its
  subcategories, every level; Cash Flow and the Account Summary show every
  level of your accounts, each parent with its subtotal; and on the income
  statement and balance sheet a small group shows all of its accounts.
- **The Transactions report covers every account** until you choose some,
  and an account you choose brings its subaccounts with it; a security's
  postings show in its units. The account pickers scroll through every match.
- **Sidebar clicks land.** On the Mac, clicking an account's name or balance
  could select nothing — only the gap between them worked. The sidebar, and
  every other list you choose from, no longer offers its text for copying,
  which is what was taking the click. Accounts are dragged by a grip at the
  end of the row.
- **Accounts opens faster on the Mac** — in under a third of the time on a
  large book, and faster again the next time.
- **Investment Return**, a new report: each security's capital gain,
  dividends and franking credits over the period, and all three together
  against the money you put in — by portfolio, closed positions included.
- **The investment reports read alike.** Portfolio, Investment Lots, Capital
  Gains and Investment Return share one set of controls — the period, a
  Portfolio filter, Closed positions, and the cost-basis method — and one
  layout: by portfolio, then security in order of gain, each row with a
  **Yield p.a.**: the gain as a simple annual rate on what you paid, over
  the time you held it.
- **Closed positions, where you look for them.** Investments says how many
  are hidden, with Show beside it; every investment report has a Closed
  positions switch — off for the valuations, on for the histories.
- **Wide reports fit the phone.** A report's controls scroll sideways on an
  iPhone instead of pushing the page off both edges, and a table with more
  than three columns — the investment reports, Average Balance — reads as a
  block per row, each figure under its heading.
- **Choosing accounts narrows a report.** In Cash Flow and Average Balance,
  as in Transactions, nothing chosen is the report's default scope and an
  account you choose is exactly what it covers, subaccounts included. The
  picker used to open with every bank account already ticked, so one click
  unticked an account instead of narrowing to it. Changing the cost-basis
  method or fee treatment now recomputes the report, too.
- **No lock left behind.** Closing the last window now quits FinvestLens,
  saving the book and releasing it for your other Macs. If FinvestLens is
  stopped without warning — by an update or a crash — with nothing unsaved,
  another Mac opens the book without asking after half an hour.
- **Autosave works wherever the book is.** It could fail with "you don't
  have permission" in a folder the app had not been given; it no longer
  needs the folder.

### Requirements

macOS 27, iPadOS 27 or iOS 27. The Mac app is sandboxed, as the Mac App
Store requires.

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
