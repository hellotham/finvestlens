# Implemented — history, audits & fixes (P0–P11)

The record of what has been **built and verified**. **Every phase P0–P10 is
complete**: the engine, native document + NAS locking, GnuCash import/export,
core UX, everyday finance, investments + multi-currency + quotes,
sync/dashboard/alerts, Apple Intelligence, small-business features, extended
statement import (SWIFT MT + ISO 20022), the planning & insights layer, and
the Ledger journal codec + `finlens` CLI — plus two **July 2026 redesigns**:
usability & performance, and report quality. [deferred.md](deferred.md) lists
the smaller open tails.

This file is the narrative: what each audit found, what was fixed, and how it
was verified (mostly against a real GnuCash book — 46,553 transactions, 559
accounts, 102,706 prices, multi-currency — compared side by side with GnuCash
5.16, matching to the cent). New history is appended here; open work goes to
deferred.md.

Companions: [PRD](prd.md) · [Architecture](architecture.md) · [Plan](plan.md) ·
[Deferred](deferred.md).

---

## Sidebar — one context menu instead of two (15 Aug 2026)

Reported from use: right-clicking an account gave a different menu depending on
whether that account happened to be *selected* — the app's own menu (Favourites,
Edit, Reconcile, Cascade, Delete) on an unselected row, the system's default on
the selected one.

The cause is a SwiftUI routing rule rather than a mistake in the menu itself: a
per-row `.contextMenu` is consulted only when the row is **outside** the current
selection. Right-clicking the selected row goes through the `List`'s selection
machinery, and with no selection-typed menu supplied it fell back to the system
default.

Fixed with `contextMenu(forSelectionType:)` on the sidebar `List`
(`Views.swift`, `AccountsSidebar.sidebarMenu(for:)`), which is the API meant for
this: **one definition serving both paths by construction**, so they cannot
drift apart again, with multi-selection handled for free. Rows that are not
accounts get an empty menu deliberately — offering an account's Delete on a
destination row would be worse than offering nothing.

The wider sidebar design this belongs to — modes, per-mode collections, sorting
and drag semantics — is in [navigation-design.md](navigation-design.md). It
**shipped** as phase P12 (§"Navigation redesign", below); this note pre-dates
that and said "still a proposal" for a fortnight after it was not one. This fix
stands on its own either way.

## Import review sheet — the crash on a real statement (15 Aug 2026)

Reported from daily use: the app aborted when importing a two-month credit-card
OFX. Three defects, one visible.

**The crash — SwiftUI's attribute graph, not our logic.** Both `.ips` reports
end `abort → AG::precondition_failure → AG::data::table::grow_region()`, 123
frames with **no frame of ours**, because the abort happens while the graph is
being allocated rather than inside any `body`. `ImportView` was a `Form`, which
materialises every row at once, and each row carried a `Picker` enumerating
every postable account — so the graph had to hold one node per account per row.

Reproduced before it was fixed, in a standalone `swiftc` harness on synthetic
data at the reference book's scale (550 postable accounts), confirming the same
top eight frames as the app:

| shape | scales with | result |
|---|---|---|
| `Form` + `Picker` (shipped) | total rows — non-lazy | ok at 150 rows, **abort at 175** |
| `List` + `Picker` | *visible* rows × accounts | ok to 2000 rows; abort at 5000 accounts |
| `List` + `AccountField` | neither | ok at 5000 rows and 5000 accounts |

The failing statement has 220 rows, so the sheet had been failing on anything
past roughly 175 lines. The fix is both halves — a lazy `List`, and
`AccountField` (one button until clicked) for the destination *and* the
investment rows' security chooser. `List` alone only moves the ceiling. The
Categorise sheet had met this first and already carried the fix; the rule is now
in [architecture.md](architecture.md) §10.1 rather than a third code comment.

**Clearing a row never worked.** The `Picker` offered "— none —" and choosing it
did nothing: `assignments[id] = nil` *removes* the dictionary key, so
`destination(for:)` fell straight back to the matcher's suggestion — and with
`fallbackToImbalance` on by default the row imported to Imbalance regardless.
Exclusions now live in their own `Set` and those rows leave the results array
entirely. `AccountField` gained an opt-in `clearable` ✕ (off by default: most
call sites require an account). The test asserts the **counterfactual** — that a
row left in the array *is* imported — since filtering is the only thing that
excludes it.

**Four prompts were shipping untranslated.** `AccountField.prompt` was typed
`String`, which selects `Text`'s verbatim initializer, emits no catalog key, and
so renders its English literal in all eight languages — invisible to the CI gate,
which can only compare against keys the compiler emits. Now a
`LocalizedStringKey`, with "Choose an account", "Search category…", "Choose at
billing" and "Leave account alone" translated; the dead `Destination` and
`— none —` keys were removed. Decorative glyphs in the field are now
`accessibilityHidden`.

Verified: 1,471 tests across eleven packages, both platform builds, catalogs
matching the compiler, manual in sync, SPDX clean.

### The import target now has a default (FR-XIO-11)

Raised in the same session: the sheet asked which account to import into and
offered nothing, on every import. It now pre-fills, in confidence order.

**The file name first.** Banks name exports after the account, so
`ANZ VISA.ofx` is the strongest available signal — stronger than whichever
register happened to be open. `ImportFileNameMatch` strips the extension, the
noise words export names carry ("statement", "transactions", the format), and
bare numbers (dates, sequence numbers, masked digits); what remains is compared
to account names in three tiers — the account name *is* the file name; the file
names part of one account; the file carries a whole account name plus extra
words. **It abstains on a tie**, the same rule the smart categoriser follows:
two accounts fitting equally well means the name did not identify one, and
guessing would post a whole statement into the wrong account.

Checked against the reference book (81 accounts a statement can post to):
`ANZ VISA.ofx` resolves to exactly one account at the exact tier, while
`ANZ.ofx` correctly suggests nothing — four accounts share that prefix.
(Institution names in docs and fixtures are formats, not holdings — the
deliberate call recorded above under the source-grounding pass.)

### Duplicate detection was too eager (FR-XIO-14)

Raised from use: a bank export's rows are rarely duplicates of anything, yet
matching a name and an amount flagged them. Reading the matcher, it was worse
than reported — passes 2 and 3 matched on **amount and date alone**; the payee
was never consulted at all. The transfer matcher had required narratives to
agree since it was written (`narrativesAgree`); duplicate detection never did.

The same test now applies to duplicates, with two qualifications that the code
itself forced:

**Contradiction, not agreement.** `narrativesAgree` is false when either side is
empty, so requiring it outright would stop a description-less statement row
being recognised on re-import. Only two sides that both say something, and say
different things, veto.

**Payee transactions only.** The first attempt vetoed everything and broke a
real case: a completed transfer between the user's own accounts, "Card payment"
in the book against "Direct Debit" on the statement. Two systems naming one
movement differently is routine, and a transfer's identity is its amount, date
and the two accounts. So the veto applies only where the other legs are
income/expense — where the payee *is* the transaction's identity, and a
different one means different money.

Validated on the real book and the four real statements, both import orders:
320 rows, 245 duplicate flags, **every one justified** by reference equality or
a shared narrative token. The review sheet now shows the matched entry's date
and description in the flag's tooltip, so the claim can be checked rather than
taken on trust.

**The drift window is two days, not four.** The narrative veto does not help
when the payee genuinely repeats, which is the commonest case of all: a standing
order, a subscription, a large movement chunked by a daily payment limit. Four
days reached back into the *previous* period and flagged those. A hand-entry
drifts a day or two from the bank's posting date, not four.

Both directions were measured, because a false *negative* here duplicates money
in the ledger and is the worse error. The first attempt — refusing the window
whenever the amount recurred — did exactly that: on the real book one CMA row
stopped matching and double-imported, giving seven boundary legs where six
belong. Two days keeps every true positive on the four real statements (39/39,
58/58, 3/3, 145 of 220, both import orders) and drops the four-days-apart false
positive, which is now a synthetic test rather than a property of one book.

**The acceptance harness had stopped running**, which is why this needed
repairing before it could validate anything. Two stale assumptions: the book's
`Everyday Card` account is now `CDIA`, and the book has no `Imbalance` account,
so `fallbackToImbalance` had nothing to fall back to and every uncategorised row
was skipped — the harness read 0 imported and failed for a reason unrelated to
matching. It now creates the fallback on its working copy. Its third assumption
— that none of the statements pre-exist — can no longer be established from this
book (all four have since been imported, so 39 of 39 CMA rows legitimately are
duplicates), and restoring it would mean deleting the April history a later
assertion counts. That assertion is replaced by the property it was really
guarding, which holds whatever the book contains: no duplicate flag may rest on
amount and date alone against a contradicting narrative.

### CSV: the tokenizer bug that made most bank exports unimportable

Raised from a real Wise export that would not import. The mapping was part of
it, but underneath sat something worse.

**Swift groups CR+LF into one `Character`.** Its scalars are `[13, 10]`, so it
matches neither `"\r"` nor `"\n"` — it matches `"\r\n"`. The tokenizer had cases
for the first two, so a CRLF line break fell through to the default branch and
was appended *into the field*: the whole file became a single row. Measured on
the real export — 44 lines tokenized as **one row of 925 fields**, importing
nothing. RFC 4180 specifies CRLF and most bank exports use it, so this was not
an edge case; it hid because every fixture in the suite was LF-only. The
tokenizer's own doc comment claimed CRLF support. A bare CR now ends a row too
(a CR inside a quoted field arrives through the quoted branch, so this cannot
split one), and three tests pin all three endings.

### CSV shape detection (FR-XIO-13)

The app now works a bank CSV out from its own header instead of asking for
column numbers. `CSVFormatDetector` scans the first 20 rows, scores each by how
many cells are recognisable column names, maps by name, infers the date format,
and records the preamble depth.

Two things keep it safe to apply unasked. The header is **found, never
assumed** — exports carry title lines, account blocks and blank rows above it,
and Excel adds more — and a candidate is **accepted only if the rows beneath it
actually parse** (60% of them). A preamble line containing the word "Date"
cannot survive that second test, and a file the app has not understood falls
back to the manual mapping rather than importing something wrong.

Date-format inference has its own trap: `DateFormatter` accepts `05/01/2026`
for `dd-MM-yyyy`, so counting successful parses alone picks whichever separator
came first in the candidate list and reports a format the file does not use.
The punctuation between the parts must line up before the count is trusted.

Verified against the real export: recognised as **Wise**, one preamble row,
`dd-MM-yyyy`, columns date 1 / amount 3 / payee 14 (Merchant) / memo 5
(Description) / reference 0 (TransferWise ID), **43 of 43 rows imported**. The
`Total fees` column is deliberately *not* mapped: Wise books each fee as its own
`FEE-` row, and the running balance confirms it — reversing the file (it is
newest-first) makes all 42 balance steps equal their row's amount exactly, so
folding the column in would double-count all 19 fees.

**The manual mapping is complete too.** `memo` and `reference` were on
`CSVColumnMapping` from the start with no control in the sheet, so no
hand-mapped import could carry a narrative or a statement reference; both now
have one, as does the preamble depth (`skipRows`), which previously could not
be expressed at all — `hasHeader` drops exactly one row. Saved CSV profiles
carry the three new fields, decoding as absent from profiles written before
they existed.

### The bank's own account id, remembered (FR-XIO-12)

Raised immediately after, and the better mechanism: a file name is a guess,
while the identifier inside the statement is the bank's own name for the
account. GnuCash has done this for years — `xaccAccountSetOnlineID` stamps the
chosen account in `import-account-matcher.cpp:462`, and `test_acct_online_id_match`
matches later files against it.

Ported, including the part that is easy to miss: the comparison is **by
prefix**, not equality. Banks are inconsistent about how much of the identifier
they put in a file — a card statement carries the account number alone where a
bank statement prefixes the routing number — so a stored id that is a prefix of
the incoming one still identifies the account. The **longest** stored prefix
wins; two equally long matches are ambiguous and refused (GnuCash logs a `PERR`
at the same point). One trailing space is trimmed from either side, which is
GnuCash's own tolerance for padded exports.

The identifier is read per format: OFX `BANKID`/`ACCTID` (composed
routing-then-account so a card statement's shorter id still prefix-matches a
later bank statement), CAMT's statement-level `<Acct>` IBAN or `<Othr><Id>`
— explicitly not a counterparty's `CdtrAcct`, which sits inside an entry — and
MT940's `:25:`. QIF, CSV and extracted PDFs carry none.

It is stored in the account's **`online_id`** slot, GnuCash's own key, so it
round-trips (asserted by a test: export → import preserves it) and a book shared
with GnuCash keeps working in both. It is learned from the account the user
actually confirmed, not the one suggested — a corrected suggestion is exactly
the case worth remembering — and an account that already carries an id keeps it,
since overwriting would silently re-point a mapping the user established.

**It already works on the reference book with no setup.** That book carries four
accounts with `online_id` values GnuCash wrote during years of OFX imports and
our importer preserved; the statement that prompted this work matches one of
them exactly — a single hit on the credit-card account — so the sheet opens on
the right account the first time it is used.

**Then the open register**, if a statement can post to it. Income, expense and
equity accounts are excluded from both routes: a statement imported into an
Expense account is never what was meant, so suggesting one is worse than
suggesting nothing.

The note under the field says which route was used ("Matched from the file
name." / "The account you were viewing.") and disappears as soon as the user
picks something else. A pre-filled field the user cannot distinguish from their
own earlier choice is the failure mode this avoids — the sheet posts real money.
The suggestion only ever fills an empty field, so re-entering never overrides a
choice already made.

---

## P11 · I5–I7 — the market's side of the book (15 Aug 2026)

The last three phases, and the point they were building to: the app now holds
both halves of an investment — what the ledger records and what the market
says — and can tell you where they disagree.

### I5 · Company data, cached beside the book and never in it

`FundamentalsCache` writes to `~/Library/Application Support/…/Fundamentals/`,
keyed by commodity identity. **Prices stay the only fetched thing that enters a
document**, which is what keeps the two invariants — splits balance to zero,
GnuCash XML round-trips byte-identically — entirely out of this feature's
reach. A test asserts exactly that: after a fetch, the book's price, transaction
and slot counts are unmoved.

TTLs are per section (`Stamped<T>`), because the facts age differently: a
profile monthly, statements quarterly, dividends weekly. One timestamp for the
record would either refetch a company description every week or show a stale
dividend list as current.

**Five providers serve company data**, and decision **D5**'s preference is
real rather than sentimental: a configured **keyed** provider is asked *before*
the keyless default, because Yahoo's `quoteSummary` is an unofficial endpoint
behind a rate-limited handshake while EODHD, Alpha Vantage and Twelve Data are
documented APIs the user signed up to. The order is: the security's own choice
(`FR-INV-22`, so a bond still goes to FIIG whatever else is configured), then a
configured keyed provider, then Yahoo. Stooq and Finnhub say plainly that they
serve none — a `servesFundamentals` that lied would put a Refetch on screen
with nothing behind it, and a test asserts the factory and the claim never
disagree.

All three keyed providers share one trap, which is why they share a file:
**their numbers arrive as text**, and each spells "nothing" differently — Alpha
Vantage writes the literal `"None"`, EODHD sends `null` or `"-"`, Twelve Data
omits the key. Parsing any of them as zero states a fact nobody has. Two more
worth keeping: Alpha Vantage answers a **spent quota with HTTP 200** and a
`Note` field, so reporting it as "no data" would send someone hunting for a
missing company instead of waiting out their daily limit; and Twelve Data nests
some statement lines one level down, which are flattened rather than dropped.

Their costs differ enough to matter. EODHD returns the profile *and* all three
statements in **one** request (two including dividends); Alpha Vantage needs
**five**, which on its free tier's 25-a-day is five securities — so the
per-section TTLs earn their keep there more than anywhere.

**Yahoo's two endpoints, measured rather than assumed:**

- `v10/finance/quoteSummary` needs a **cookie-plus-crumb handshake** — a bare
  request answers `401 Invalid Crumb`. `fc.yahoo.com` returns 404 and sets the
  `A3` cookie anyway; `getcrumb` then returns a token; the summary then answers.
  Verified end to end through the production `URLSessionHTTPClient`. The
  handshake is shared across a run by an actor, not repeated per security.
- `v8/finance/chart?events=div|split` needs **no handshake at all** and returns
  dividends and splits — 20 over ten years for an ASX issuer. So a refused
  crumb loses the profile and keeps the dividends, which is how the provider is
  written.

That second endpoint also settles **`FR-INV-36`**: `FR-INV-03a` claimed the
Yahoo provider fetched "dividends, and splits" and it did not — across the
whole package the only matches for either word were `String.split`. Now
something does, and it is the fundamentals provider, not the price provider.

**Yahoo rate-limits the handshake hard**, per address: the same sequence
returned 9 KB of company data and then started answering 429 minutes later.
That is an environmental condition, so the live harness reports and skips it
rather than going red, and the user-facing message says prices are unaffected
and to try again shortly — waiting is the useful advice, not checking a setting.

Two traps worth keeping. Yahoo's statement rows are **not uniform**: most values
are `{"raw": …}` but `maxAge` is a bare integer in the same dictionary, so a
decoder that assumes the wrapper throws on the first row and loses the whole
statement. And an **empty** `{}` must decode to *absent*, never zero — "this
bank does not report a gross profit" and "this bank's gross profit was nothing"
are different claims.

**A negative answer is cached too**, and that was a real defect before it was
fixed: a provider with no statements for a security left the section empty, so
it stayed "never fetched", so it was fetched again on every single page visit,
forever. Recording an empty stamped section makes the TTL apply to the absence.
Only in the success path — a request that *failed* records nothing, so a network
blip does not suppress retries for a quarter.

### I6 · Where the ledger and the market disagree

The reconciliation is the strongest argument for the hub existing: it needs both
halves at once, so no portfolio tracker and no accounting package can do it
alone. Nothing is ever corrected — every finding is a discrepancy to look at.

- **Dividends**: declared against recorded, in the four classes. Matching is
  **amount first, then date**, and that was found by a test rather than
  designed: matching purely on nearness lets a $120 special dividend two weeks
  out beat the $500 payment three weeks out, and then reports both as wrong —
  two false findings from one clean quarter.
- **Corporate actions**: a provider split with no matching unit movement. The
  quiet one — every price before that date disagrees with the units held, so
  past valuations and the whole chart are wrong, and nothing else would notice.
  Tested by ratio with a tolerance, because a book that recorded the split *and*
  traded around it will not land on the arithmetic exactly.
- **Outliers**: a stored price judged against the **median** of its neighbours,
  not the mean — one bad price drags a mean far enough to hide itself and to
  implicate the rows either side. The factor is deliberately loose at 4: a
  security really can move 50% in a week, and a check that fires on real
  volatility is one people switch off.

### I7 · Scope, preview, and a cadence that is not a deadline

- **Fetch scope** (`FR-INV-25`): all holdings, only what is behind, or holdings
  plus **closed positions whose held period has a hole**. D4 in one sentence — a
  closed position is not worth today's price, but a gap inside the period it
  *was* held corrupts historical net worth, so it is worth fetching once and not
  daily.
- **Run preview** (`FR-INV-34`) counts **requests, not securities**. A batch
  provider's whole group is one request, so eleven bonds and one share is two
  requests; showing securities alone would make the cheapest scope look like the
  dearest.
- **Manual-valuation cadence** (`FR-INV-30`): hand-valued holdings are judged
  against their own expected cadence — quarterly by default, what an Australian
  super fund publishes — instead of the trading calendar. A fund is no longer
  called stale every Tuesday the ASX happens to trade, which is how a worklist
  stops being read.

## P11 · I4 — bonds priced by their ISIN (15 Aug 2026)

Every bond price row in the reference book was exactly `1.0`. A bond worth 72%
of face was valued at 100% of it, and had been for years, because no provider
here could find a corporate bond: they all take a ticker and a bond has none.

**FIIG** (`FIIGQuoteProvider`) closes it, and needed a provider shape the
protocol did not have. Measured against the live API on 15 Aug 2026, not
assumed:

- **One request is the whole market.** `pageSize=2000` returns all **702**
  bonds with `pageCount: 1` (~510 KB, 5.6s). So `BatchQuoteProvider` was added
  alongside `QuoteProvider`: fetch once, look up locally. Eleven bonds cost one
  request rather than eleven downloads of the same payload — and the new
  `QuoteService.latestPrices(for:…)` serves non-batch providers by looping, so
  a call site never has to know which shape it holds.
- **Keyed by ISIN**, via `QuoteProviderKind.matchesByIdentifier` and
  `QuoteService.lookupKey`, which reads GnuCash's `cmdty:xcode`. Without that
  the run would send eleven mnemonics FIIG has never heard of, forever.
- **`price` is a percentage of par** (live range 13.500 … 177.182), so the
  conversion is `÷ 100` and it happens at the parse boundary — a `Quote` from
  FIIG then means what a `Quote` means everywhere else. Shipping the raw figure
  would have valued a $100,000 holding at $9.85 million.
- **No history.** `bondHistory` is `null` on all 702 records, so
  `supportsHistory` is `false` and `history(symbol:…)` throws rather than
  returning `[]` — an empty series is indistinguishable from "did not trade",
  and the caller would record a gap that is really a missing capability.

**The TLS workaround was not needed, and the reason matters.** The reference
implementation (`investalens`, `lib/providers/fiig-bond-rates.ts`) disables
certificate verification because the server omits an intermediate CA and Node
does not chase AIA to fetch it. That is a Node limitation, not a server one:
`curl` reported `ssl_verify_result=0` and the live harness
(`LiveFIIGTests`, `FL_LIVE_FIIG=1`) goes through the production
`URLSessionHTTPClient` and passes. Verification is never disabled here.

**Per-security providers**, because one provider per run stopped being enough
the moment a book held both shares and bonds (`FR-INV-22`). `quoteProviders` is
a new kvp map; `effectiveProvider(for:in:)` lets a security's own choice outrank
the run's, and falls back when the chosen provider has no key rather than
failing that security every run. `fetchLatestQuotes` now groups by effective
provider, so batch providers cost one request per group. A batch reports
absences by omission, so securities it did not cover are *named* — being absent
from an index is the one failure a person can fix.

**Nothing is inferred.** An ISIN's shape does not prove a bond is listed at
FIIG, so `fiigCandidates` only *offers*: the worklist raises "N holdings have an
ISIN and could be priced by FIIG" with a one-click fix, and until it is taken
an ISIN is never sent there.

**On the reference book** (`LiveBondPricingTests`, on a copy): 11 bonds carry an
ISIN, **10 are in FIIG's index**, and after one run all ten hold real market
prices — spread across roughly 70–100% of face — where 10 rows had been exactly
`1.0`. The eleventh is held and not listed; it is reported by name rather than
silently skipped. The design's "11 bonds" was optimistic; 10 of 11 is the
measured answer.

The exact figures are deliberately **not** recorded here, and the harness no
longer prints them either. FIIG publishes its whole index publicly, so a bond
price quoted to five decimals is close to unique in that list — writing one down
beside "this is the reference book" would say which bond is held. The
magnitude gate cannot see that (the figures are small and form no recoverable
holding); it is the provenance judgement its docstring assigns to a person.

## P11 · I3 — one security's whole story (15 Aug 2026)

The overview (I2) answers "can I trust these numbers". The detail page answers
everything the answer raises. `FinancialReports.securityDetail` assembles it in
one pass — the price series feeds both the chart and the price table, the
movements feed both the chart's markers and the activity list, the holding
periods feed the shading — because computing them per section would walk the
price database eight times for one page.

- **The chart is the thing no competitor can draw**: the provider's line, *your*
  buys and sells placed at what you actually paid, your average cost as a
  dashed rule, and the periods you held it shaded. A marker above the line is a
  purchase above that day's market. The line breaks at gaps rather than being
  drawn through days nobody has a price for.
- **While held** is a range option, and the only one that judges your own
  decisions; everything before you bought is somebody else's story.
- **Prices is the only price table in the app** (`FR-INV-29`), one security at a
  time, with the **source column visible** — 68% of the reference book's rows
  were hand-entered and nothing on screen had ever said so. Editing a fetched
  figure re-stamps it `user:price-editor`, because a number a person typed over
  a provider's is no longer the provider's.
- **ISIN is editable** (`FR-INV-32`): `Book.updateCommodityMetadata` gained an
  `exchangeCode` parameter where empty clears and `nil` leaves alone — "no ISIN"
  has to be a thing a person can say, and the field is how I4 finds a bond at
  all.
- **CSV export** re-imports: the columns are the ones `CSVPriceImporter` reads,
  with source as a trailing column it ignores, and dates as ISO day strings —
  exporting the stored 10:59Z instant would make a Sydney reader think every
  close happened at nine in the evening.

Two traps worth keeping. The header's "previous price" is the previous *priced
day*, not the previous row: a re-fetch landing on a hand-priced day leaves two
rows for one observation, and comparing the day against itself reports no change
while the real prior close sits one further back. And adding a file to a
dependency package needs that package's dependents' `.build` cleared — SPM
caches the target's source list, and the symptom is `cannot find 'X' in scope`
for a file that is plainly there.

## The real-data gate never looked at fixtures (12 Aug 2026)

`check-no-real-data.py` opens by naming the rule it enforces — the reference
book's contents "never reach **fixtures**, screenshots, logs or the website" —
and then scanned `docs/`, `website/` and `README.md` only. Fixtures, named
first, were the one root it had never opened.

Found by hand in that blind spot: a dividend reconciler test carrying a real
capital-note statement — a net payment, its franking credits, and the
distribution rate per note, all copied off the page while reproducing a parser
defect. The payment alone is modest, which is exactly why no magnitude rule
reached it; but the printed rate divides into the payment a whole number of
times, so the fixture published the size of the holding as well as its issuer.
Replaced with synthetic figures preserving every property the two tests assert
(franked equals the net payment; credits are three sevenths of the dividend, so
the gross-up recovery still lands): 11 tests, all green.

The first grep found one file; sweeping properly found four. The same statement
had seeded a classifier fixture, and two source comments recorded real payment
amounts as evidence for why the extraction prompt is ordered the way it is —
the claim survives without them ("it returned 0 on two different issuers'
statements with the credit plainly printed"), which is the same substitution
the commit-message cleanup made in July. `DividendReconcilerTests` had said in
its own header that the figures were changed; they were internally consistent
with the real per-note rate, so that statement is now true rather than
intended.

Left alone deliberately: institution names in importer fixtures (`ANZ CREDIT
CARD` in an MT940 narrative, an ETF's actual name, `Commonwealth Bank` as a
commodity's `fullName`). Those are *formats*, not holdings — genericising them
would cost the fixtures their realism and protect nothing. So are ordinary
illustration amounts, a grocery line or a single distribution with no printed
rate to divide by: nothing is recoverable from one figure.

The gate now covers `Packages/**/*.swift` and `finvestlens/**/*.swift`, with
`.build/` skipped beside `node_modules/` and `dist/` — 1,928 of the 2,371 Swift
files under `Packages/` are third-party checkouts, and a hit in someone else's
code is noise, not a finding.

Two changes were needed to make that scope survivable:

- **A waiver Swift can express.** The only waiver was `<!-- synthetic -->`. The
  widget's sample balance sits inside a multi-line string literal on a line
  ending in a `\` continuation, where any trailing token corrupts the JSON
  under test — so the waiver now also accepts `//` and `#` openers.
- **A placeholder rule.** `$1,234,567.89` is nobody's balance. A run of
  ascending digits from 1 is recognised as invented, rather than demanding a
  waiver on the one figure that is self-evidently not real.

### A second rule, because "a regex cannot judge this" was untested

The first version of this entry said magnitude is all a gate can judge and
provenance stays a person's. Half of that was an assertion nobody had measured,
and measuring it proved it wrong.

These fixtures did not leak through *size*. They leaked through a **shape**: a
per-unit rate printed beside the amount it produced, so the unit count — the
holding — falls out by division. That is mechanical, and `recoverableHolding`
now checks it over a 14-line sliding window, gated on statement vocabulary
(`Net Payment`, `per note`, `Franking`, …).

The discriminator is that the division comes out **exact**. Allowing a
near-integer quotient was tried and abandoned on the numbers: it took the clean
tree from 2 hits to 16, matching an FX rate against a converted amount and, at
its worst, the string `2025 notes` — a year. A gate that fires on a clean tree
is one people learn to skip, so it stays strict and misses the rounded case.

Measured against the two fixtures **as they were published**: it catches the
reconciler one, where rate × units is exact. It does not catch the classifier
one — and that is the right answer, not a miss. That fixture's amount is
rounded, so no whole unit count exists and nothing is recoverable. What leaked
there was the rate *being a real security's*, which no structure reveals.

The waiver had to become a **span** rather than a window: a `// synthetic`
comment covers 14 lines either side, so it can sit in the doc comment
introducing a fixture instead of inside the string literal, where it would
become part of the text under test. Anchoring it to the window alone was the
first attempt and failed — the comment sits just outside the window that fires.
A reconciliation fixture must have the flagged shape to exercise the
arithmetic, so it carries the waiver and says why.

So the standing limit is narrower than first written: the gate covers magnitude
**and recoverability**. Provenance — a real rate that happens to look ordinary —
is what remains a person's, as CLAUDE.md ▸ Review gates assigns it.

Verified in both directions: 13 cases over `offending()`, 4 over
`recoverableHolding()`, the two published leaks re-caught from `git show`, and
clean on the tree.

Also genericised: `NABPF` as the worked example in `finlab prices --symbol`
([lab.md](lab.md), `PricesCommand.swift`) and in this file's own P11 heading.
The ticker is public, but as the example in a page about maintaining *the*
reference book it implied a holding; `CBA` is the repo's existing illustration
and carries no such signal.

## One clock for prices — GnuCash's neutral time (11 Aug 2026)

A price is a fact about a **day**, and storing it as an instant let conventions
accumulate: the reference book carried **twenty-four** distinct clock times for
the same idea. Days then differed by reader, which is how an inferred trading
calendar reached 278 days a year against a real 250.

The convention is GnuCash's, read from its source rather than chosen —
`libgnucash/engine/gnc-date.h`: *"adjust it to 10:59:00Z of that day"*, with
`gnc-date.cpp`'s `gnc_tm_get_day_neutral` taking the day via `gnc_localtime_r`,
so the civil day is the **local** one. 10:59Z is neutral because it stays on the
same civil day from UTC−10 through UTC+13.

- `Price.dayNeutral(_:)` and `Price.isDayNeutral` in `Engine`; the memberwise
  initialiser normalises by default, with `preservingTime:` for importers.
- **Importers opt out.** The GnuCash XML and Ledger importers pass
  `preservingTime: true`: a file's timestamps are data, and rewriting them would
  break fidelity to the source.
- **So does the store**, and that one was nearly shipped as a bug.
  `SQLiteDocumentStore` reads prices with `preservingTime: true`; without it,
  *loading* a book silently restamped every price in memory, so the next save
  would rewrite timestamps with no migration ever run — and the importers' own
  opt-out would be defeated the moment a book was stored and reloaded. It hid
  itself well: a survey of the loaded book reported "0 to restamp" while the
  file on disk still held five visible conventions. Checking the disk rather
  than the loaded model is what caught it.
- `finlab prices --normalise-times` migrates an existing book.
- `priceHealth` now compares `asOf` **by day**, not by instant: a price stored
  at 10:59Z was dropped by a caller passing that same day's midnight.

Verified on a copy of the reference book: 160,139 prices in, 160,139 out, one
convention on disk afterwards, and **zero prices changed which day they
describe** — only the time within a day moves.

`normalisePriceTimes` was quadratic on the first attempt (`removePrices` once
per price, each a full scan) and ran ten minutes before being killed. Same shape
as the `splits(for:)` defect fixed earlier the same day — twice in one day for
one mistake.

## "Valued by hand" was reading a stale GnuCash flag (11 Aug 2026)

Reported from the app: a security sat under **Valued by hand** while its price
history was being updated daily. Both were true, which is the defect.

`canFetchQuotes` asked `commodity.getQuotes` — GnuCash's `cmdty:get_quotes`.
That flag records what **GnuCash** could fetch, from the much smaller set of
providers Finance::Quote supported; a `false` there means "GnuCash could not",
never "nothing can". The app's own fetch has never consulted it —
`pricableSecurities` is every security — so the security stayed current while
the table called it hand-valued. Two definitions of "can be priced", disagreeing.

The flag is now read only as a **positive** signal, and its absence proves
nothing. What counts is evidence: a `Finance::Quote…` source on any stored
price means some provider served that security. Hand-valued is the residue —
everything no provider has ever priced. `user:price`, `user:price-editor`,
`user:split-import` and `user:xfer-dialog` are all typed or imported, and none
of them count as a provider.

On the reference book this moves exactly the security reported, and leaves the
six corporate bonds where they belong until the FIIG provider lands in I4:
25 ASX held / 0 hand-valued, 6 bonds held / 6 hand-valued, 1 WAM held / 0.
The commodity set is memoised on the book revision — asking per security would
rescan the price database once per row on screen.

## Delisted securities rebuilt from EODHD (11 Aug 2026)

Sixteen ASX securities in the reference book are absent from EODHD's live
symbol list; all sixteen are closed positions, so none affects a current
valuation, but their history still has to be right for capital gains.

**A blanket replace would have destroyed data**, which is the finding worth
keeping. Checking each against EODHD's own range first showed three traps: one
security has 1,504 stored rows and EODHD has *none* for it; another's history
starts in 1988 where EODHD's starts in 1990; a third's last ten days are in the
book and not at the provider. Eight of the sixteen have no EODHD data at all.

So the action was chosen per security rather than in bulk — six replaced where
the provider strictly covers the stored range or the book held only a two-to-
four row stub (+10,048 prices), two merged where the book has substantial
history outside the provider's range (+662, and both boundaries verifiably
intact afterwards), eight skipped. The one with no provider data was left
untouched at its full 1,504 rows.

## Real balances removed from published commit messages (10–11 Aug 2026)

Commit messages in this repository carried the reference book's real balances.
A message is as public as any file in the tree. Fixed in two passes, and the
second existed only because the first was incomplete.

`git filter-repo --replace-text` rewrites **blobs only** — it cleaned the files
and left every message untouched, which is easy to misread as success.
`--replace-message` is the one that does messages.

The first pass applied the project's standing size rule alone (a million or
more, or ten thousand-plus with cents) and left **thirteen figures across twelve
messages**, several in the same sentence as `[redacted]` markers that had
already landed — which is exactly what made them easy to skim past. Two shapes
are invisible to a size threshold: **shorthand** (no cents to match) and
**sub-threshold but real** (a four-figure account movement is still a real
balance). Both were caught by a second lens — any money on a line that also
asserts something about the real book (`Assets:`/`Liabilities:`/…, "net worth",
"the real book"). `.claude/hooks/no-figures-in-commits.py` now applies size
**or** that context test, blocks shorthand, and flags none of the published
messages; three regression cases were added.

The rewrite preserved the tree: HEAD's tree hash unchanged, commit count
unchanged, one tag re-pointed.

**The remediation's tail was GitHub's, and had to be verified twice.**
Unreferenced commits stay served until GitHub garbage-collects, which is a
support ticket rather than a command — there is no API (`POST …/git/gc` →
*Not Found*). Support sent the same reassurance twice on 11 Aug. After the
first, the sample SHAs still answered **HTTP 200** on the web page, the
unauthenticated API *and* `.patch`. After the second they answer **404 / 404 /
422**, with 0 forks and an empty network, and 378 published messages flag
nothing. Nothing ever *referenced* the objects — refs were `main` and `v1.0`
on current history, 0 pull requests ever — so the delay was collection, not a
dangling reference. The lesson kept is the check rather than the outcome: a
provider's word that data is gone is a claim to verify from outside, and those
three URLs answered differently on the two occasions the same sentence arrived.

## Quick Look for `.gnucash` (9 Aug 2026)

Previously recorded as a judgement call to skip; built instead. The app
declares `org.gnucash.book` as an **imported** type — the type is GnuCash's and
we only read it — and the extension previews all three shapes GnuCash writes,
told apart by their first bytes rather than by extension: gzipped XML, plain
XML, and its SQLite backend.

Interchange was deliberately **not** linked in: that would drag Engine into an
extension Quick Look launches on a Finder selection. The XML paths instead read
GnuCash's own `<gnc:count-data>` header from an inflated *prefix*, so a 9.6 MB
book measured 6.7 ms; the SQLite path reuses the existing reader, telling the
two schemas apart by table name (`accounts`/`transactions` against our
`account`/`txn`, read from `libgnucash/backend/sql/`).

## P11 · Per-security price fetch, and a single-source rebuild (11 Aug 2026)

The first thing the new destination was used for found a real hole: one holding
had been effectively unpriced since 2023 — 41 rows across three and a half
years where about 875 belong — because Yahoo does not serve that ASX hybrid.
Exactly the case `FR-INV-03c` names EODHD for.

Nothing could act on it. `updatePriceHistory` covers *every* security and
`refetchPriceHistory` covers a subset but **replaces**; there was no way to fill
one security's gaps. Added, as the first half of `FR-INV-23`:

- `AppModel.updatePriceHistory(for:using:)` — the merging update, scoped to
  chosen securities. The distinction from the replacing twin is the one that
  matters here: a security whose early history came from GnuCash and whose
  recent years a provider stopped serving needs a merge, because replacing
  would discard the good years to fix the bad ones.
- `finlab prices --symbol` (comma-separated, matched on mnemonic or ticker
  override) and `--replace`. An unmatched name is an error, not a silent no-op.

Both were used on the reference book: a merge added 858 prices for 2022–2026
and left the 2019–2021 GnuCash rows untouched, then — on the maintainer's
instruction to single-source the security — a replace rebuilt the whole series
from EODHD: **1,846 rows, one source, 2019-03-21 through 2026-07-17, no
duplicate days**. EODHD's own history was checked first and covers the book's
full range; replacing a longer series with a shorter one loses data silently,
so that is a check and not a formality.

Neither provider has anything after 17 July 2026 and EODHD still lists the
security, so the remaining absence is the market's, not the database's.

`finlab` reads keys from `FINLAB_<PROVIDER>_KEY` and never from the Keychain —
the app's items carry an ACL naming the app binary. The key was passed by shell
substitution from the Keychain so it was never written down anywhere.

Fixed while building this: `investmentIssues`' predicate needed `@MainActor`.
Task-isolated closures cannot be passed into `filter`'s main-actor-isolated one
under Swift 6 — debug builds accept it and `-c release` does not, so it only
appeared when `finlab` was built for release.

## P11 · I2a — the destination's first paint, and the Engine scans behind it (11 Aug 2026)

Reported from the running app: the destination took seconds to draw, and the
sparklines still did not line up. Both measured before being touched.

**First paint: 5.99s → 0.97s** on the reference book. The cost was never in the
new code — the sparklines and row assembly together are 0.04s. It was two
long-standing `Engine` scans that the destination is simply the first surface to
call once per security account:

| Component | Before | After |
| --- | --- | --- |
| `advancedPortfolio` | 4.76s | **0.06s** |
| `priceHealth` | 1.16s | **0.87s** |
| Row assembly + sparklines | 0.03s | 0.04s |

- **`Book.splits(for:)`** was `transactions.flatMap(\.splits).filter { … }` — a
  walk of every transaction in the book *and* an array of every split in it,
  **per account asked about**. It is now served from an account index built
  alongside the existing GUID lookups and invalidated with them.
- **`Book.lotEvents(for:)`** walked all 46,553 transactions per account for the
  same reason. It now iterates the account's own splits, caching each
  transaction's brokerage apportionment once.
- **`priceHealth`** bucketed all ~150k prices into civil days *twice* — once
  building the `TradingCalendar`, once for its own day sets. One pass now feeds
  both (`startOfDay` alone is 0.36s over that many prices). Its movements pass
  moved off the whole-book walk too, with an explicit book-order tie-break:
  walking accounts groups a commodity's movements by account, two accounts can
  move the same commodity on one day, and `sorted(by:)` is not stable — without
  the tie-break a holding period could open and close in a different order.

Cost basis is verified against GnuCash, so "the suites are green" was not
sufficient evidence for the `lotEvents` rewrite. `LivePriceHealthTests`
re-implements the previous algorithm verbatim and compares event for event
across the real book: **2,248 events over 99 security accounts, all identical**.
Every price-health figure is likewise unchanged (86.0% coverage, 25/0/7,
17 securities with gaps while held, 2,915 days).

**Sparklines share a column.** They now sit *before* the name rather than after
it. The name column is `minWidth`, so a chart placed after it inherited that
column's variable width and landed at a different offset on every row — the
wander that survived the shared-axis fix. Ahead of the name it is at a fixed
distance from the leading edge, and a chart whose purpose is comparison is
finally comparable.

## P11 · I2 — the Investments destination (11 Aug 2026)

The hub itself (`FR-INV-08`). *Prices & Securities* is gone: its sidebar row, its
segmented tab picker, its list of every price row in the book, and its list of
exchange rates. `InvestmentsView.swift` replaces them; `PricesView.swift` and
`SecuritiesView.swift` are reduced to the per-security sheets they also held and
renamed `PriceEntrySheets.swift` / `SecurityEditSheets.swift`.

- **Sidebar.** *Investments* now sits with Dashboard and Reports rather than in
  *Records* between Rules and Emergency Records. The old placement was the
  diagnosis: it filed investments as a cabinet to maintain rather than something
  you read to decide. `SidebarSelection.prices` became `.investments`; session
  restore still accepts the old spelling, so a saved session does not silently
  drop to the dashboard.
- **Confidence band** (`FR-INV-09`): value-weighted coverage as a ring plus a
  headline, what needs a price, and the run state. The ring is
  `accessibilityHidden` and every figure it shows is repeated in the band's
  spoken label — a decorative gauge must not be the only carrier of a number.
- **Worklist** (`FR-INV-13`): classes of problem with counts, the affected
  symbols, and the fix as a button. Absent entirely on a healthy book.
- **Holdings** (`FR-INV-11`, `FR-INV-14`): freshness mark, symbol, name,
  sparkline, market value, return since holding, age. Sorted by value within
  each group, because the position that most affects whether the total is right
  belongs at the top. Grouped **Holdings / Valued by hand / Watching / Closed**
  (`FR-INV-24`, `FR-INV-30`), with closed hidden behind a book preference.
- **Sparklines** (`FR-INV-12`) are drawn in a `Canvas`, one path per contiguous
  run, so a gap is a **break**. Swift Charts would have joined across it unless
  each run were a distinct series, and declaring that series needs a
  `PlottableValue` label — which the string extractor then demands translated in
  eight languages, for text that is never displayed.

  **Corrected the same day, on first sight of the running app.** The first cut
  scaled each line to *its own* first and last price, which made the column
  unreadable — nothing lined up down the page — and, worse, dishonest: five
  days of data stretched the full width, and a holding a month stale still drew
  to the right-hand edge as though it were current. The time axis is now
  **shared by the whole table**, so a horizontal position is the same date on
  every row and a line that stops short is a line whose data stops short. Value
  scale stays per row, because two securities' prices have no common measure.

  The period is now **named and adjustable** (`AppModel.SparkRange`, a book
  preference): one month through five years, chosen from a **Price History**
  toolbar picker and stated in words above the first group. Written out rather
  than abbreviated — "3M" is a hint, not a name, and VoiceOver reads it as
  "three em". The gap threshold scales with the period too (a week's floor,
  else 2% of the window), because a fortnight is a third of a one-month chart
  and half a percent of a five-year one; a fixed threshold shattered long
  windows into confetti. The empty case keeps the same 22pt box as a drawn
  line — collapsing it to a bare rule let the `HStack` centre a shorter view,
  so rows without history sat at a different height and the column wandered.
- **Exchange rates** (`FR-INV-33`) get one line rather than a list: the same
  trust question, since a holding in a currency with no rate is silently
  unvalued.
- **Provider choice** (`FR-INV-22`) moved from the Quotes sheet into the Update
  Prices control-group menu; ⌘⇧U is unchanged.

`AppModel+Investments.swift` joins I1's price health to the lot engine's return
figures. `canFetchQuotes(for:)` is what the Reports layer's `quotable` parameter
was for: a ticker override set in this app makes a security quotable even though
GnuCash never marked it, and that mapping cannot live in the Engine. Health is
memoised on the book revision keyed to `endOfToday()` — the scan costs ~1.1s on
the reference book, which is fine once per change and ruinous once per redraw.

**Documentation shipped with the surface, not after it.** `HelpContent.swift` ▸
*Investments* was rewritten and `website/src/data/manual.json` regenerated in the
same commit; the help book had described the destination this replaces, and it is
published. The string catalog gained 67 keys in eight languages (with plural
variations) and lost 31 orphans; `scripts/check-localization.py --build` reports
the catalogs match the compiler.

**Verified.** 10 tests (`InvestmentRowsTests`) over grouping, the closed-position
preference, quotability via override, sparkline segmentation, the worklist, value
ordering, rate health, the period preference, the shared window, and the gap
threshold scaling with it; 1,322 tests across eleven packages; both platform
builds; catalogs matching the compiler.

Two of those tests first passed for the wrong reason and were rewritten to
discriminate: `"BIG"` sorts before `"SMALL"` alphabetically as well as by value,
and a `monthly <= fiveYears` segment count is true however the threshold behaves.
Both now use inputs whose expected answer is the opposite of the accidental one.

**Not verified: on screen** beyond the two defects reported from the running app
and fixed above. The ring, the worklist and the row layout have not been looked
at.

## P11 · I1 — the price-health models (11 Aug 2026)

First phase of the Investments hub ([investments-design.md](investments-design.md)).
**Models only — no UI changed, and the Prices & Securities destination is
untouched until I2.** `FinancialReports.priceHealth(_:currency:asOf:…)` in
`Packages/Reports/Sources/FinvestLensReports/PriceHealth.swift`.

Three ideas, each replacing something the old destination got wrong:

- **Freshness against observed trading days** (`FR-INV-10`). `TradingCalendar`
  infers each exchange's trading days from the book's own price history rather
  than shipping holiday tables — self-maintaining, and automatically right about
  weekends, holidays and half-days. An exchange too sparse to speak for itself
  (a handful of bonds) borrows the book-wide union; only an empty book falls
  back to bare weekdays. Freshness is measured against the exchange's latest
  observed day, not against `asOf`, so **a Friday close reads as current on
  Monday** — the false alarm elapsed-day arithmetic produces every week.
- **Holding-aware gaps** (`FR-INV-26`). A missing price is a defect only inside
  a period the security was held; that is when it silently corrupts historical
  net worth. `holdingPeriods(from:asOf:)` derives those periods from split
  quantities (a partial sale does not close one). This is what makes
  `FR-INV-25` precise — fetch a closed position where its held period has holes,
  not for today's price.
- **Value-weighted coverage** (`FR-INV-09`). The fraction of *held market value*
  priced on the latest trading day. A count cannot distinguish "all fine" from
  "one holding is most of the book and a month stale". `nil` when nothing held
  can be valued — a different statement from 0%.

Also surfaced: per-source provenance (`FR-INV-27`), which the book has always
recorded and no UI has ever shown; and `priceCount` (rows) alongside
`pricedDays` (distinct days), whose difference counts duplicate same-day prices.

`priceHealth` takes an explicit `Calendar` rather than always using `.current`:
every date it returns is a start-of-day in that calendar, so a caller — or a CI
machine in another zone — has to be able to agree on which one.

**Verified.** 15 unit tests (`PriceHealthTests`), and `LivePriceHealthTests`
against the real book behind `FL_PERF_FILE`, which computes health for 81
securities in 1.13 s and cross-checks the held population against
`FinancialReports.portfolio` — two independent paths that must not disagree in
front of the user. Its first run found a real defect (rows vs days), which is
why the harness exists.

**What it measured**, and what justifies the rest of P11: 86.0% value-weighted
coverage; 25 held securities current, 7 old, 7 that no provider can price; and
**17 securities with gaps inside periods they were held, totalling 2,915 missing
trading days** — historical valuations that are silently wrong today.

Corrected in the PRD at the same time: `FR-INV-03a` claimed the Yahoo provider
fetched dividends and splits. It never has — `YahooQuoteProvider` uses only
`v8/finance/chart`.

## Large-book validation on real NAS hardware, and `finlab` (10 Aug 2026)

The last item in [deferred.md](deferred.md) §1 that said "needs real NAS
hardware". A live GnuCash book was imported to an SMB share and worked on
headlessly: prices refreshed, four months of receipts and dividend statements
matched, attached and categorised.

### `finlab` — the write side of the command line

`finlens` is read-only by design (ADR-L2), and that promise was worth keeping,
so none of this was added to it. `Packages/Lab` is a new package whose binary
`finlab` carries six verbs — `import`, `bench`, `prices`, `documents`,
`repair` and `relink` — documented in [lab.md](lab.md).

### The documentation was publishing the reference book (10 Aug 2026)

A sweep of the published files found a complete financial profile in committed
documentation: net worth (twice, to the cent), the SMSF balance, portfolio
value, cost basis and realised gains, a card account's Present and Reconciled
balances, taxable income and the resulting tax, a wellbeing score, and two
account names. Each had been written as *evidence* — that a report matched
GnuCash to the cent, that a rewrite left a total unchanged — and each claim
survives without its figure.

All of it is scrubbed from `docs/` and `README.md`. It remains in the git
history, which a scrub cannot reach.

The rule was already written down and was kept by hand, which is why it failed
slowly and invisibly over months. `scripts/check-no-real-data.py` now gates
`docs/`, `README.md` and `website/` in CI on a magnitude test rather than a
blocklist — a real balance is large and precise, an example is small and round,
so anything at a million or over, or ten thousand-plus carrying cents, has to be
waived on the line with `<!-- synthetic -->`. Verified both ways: it passes on
the scrubbed tree and fails on the worst line put back.

### A lock must not outlive its holder (10 Aug 2026)

`FileLock` released on the normal path and nowhere else. `deinit` removed the
file presenter but not the lock; nothing handled signals. So a `killall`, a
⌃C in a headless run, or a crash left the lock file behind — and because the
lock **syncs on purpose** (§6.1, the cross-machine single-writer guard), the
stranded file propagated to every other machine and locked them out too, until
the heartbeat aged out.

Four nets now, in the order they get a chance to run: `release()` on the normal
path; `release()` from `deinit` for a lock object dropped while held; a
`LockReaper` on `SIGTERM`/`SIGINT`/`SIGHUP` that removes only files still
carrying this process's own instance id; and — for `SIGKILL`, a panic, or a
power cut, which no handler can ever catch — `isProvablyDead`, which lets the
*next* opener break a lock whose pid is gone.

That last check is **same-host only**, and deliberately so: another machine's
process table is not ours to read, so a remote holder is still judged by
heartbeat alone. Getting that backwards would break the very guarantee the
syncing lock exists to provide. Both directions are tested.

Also fixed, same class: `finlab bench --save` and `finlab import` released the
lock with a trailing statement rather than `defer`, so a throw from `save()`
leaked it — on `import`, onto the destination the failed run had just created,
so the retry was refused by its own wreckage.

### Attachments are links, not copies (10 Aug 2026)

The ingest above attached its matches with `attachDocument(named:data:to:)`,
whose contract is to **copy** the file into the document folder — and that
folder falls back to the folder holding the book. So the run duplicated 189
receipts onto the NAS beside the book and pointed every link at the duplicate
instead of at the file the user had filed. The correct call already existed two
functions further down (`linkDocument(at:to:)`, "links an existing file in
place — no copy"), and the app's own drag-and-drop path was already using it;
the batch paths reached for the wrong one.

Fixed at the source — `finlab documents`, Match Attachments, Attach File… and
the cash-receipt path all link now. Smart Import still copies, because pasted or
scanned bytes have no original to point at.

`linkDocument` also only relativised against the *primary* document folder, so
anything filed in the secondary one had the user's full home path written into
the book. It now relativises against either, which is what makes two archives —
receipts in one folder, statements in another — work at all.

`finlab relink` repaired the existing book: 95 links rewritten to include their
archive subfolder, 759 verified to resolve, and the 189 copies pruned only after
each was confirmed byte-identical to a file still in the archive.

It is the only package that depends on **FeatureUI**, deliberately.
Attachment matching, smart categorisation and quote fetching all live on
`AppModel`, which despite its module imports no SwiftUI and was already driven
headlessly by that package's own tests. Driving it means a maintenance run
exercises the code the app runs, rather than a second implementation free to
drift from it. The app target and `finlab` are two thin shells over one model.

### NFR-02 measured

A 46,578-transaction / 103,365-posting / 559-account / 54 MB book, on an SMB
share (`//nas3._smb._tcp.local`, 23.9 MB/s read, 57.5 MB/s write) and on the
local SSD.

| | Local SSD | SMB share |
| --- | --- | --- |
| GnuCash import (8.1 MB gzip → 127 MB XML) | — | 32.3 s (20.8 s parse + 11.5 s write-back) |
| Open read-only (copy + read) | 1.82 s | 3.51 s |
| ├ copy to local working copy | 0 ms | 972 ms |
| ├ open SQLite + migrate | 1 ms | 1 ms |
| └ materialise the book | 1.75 s | 1.60 s |
| Open read-write (lock + copy + read) | 1.87 s | 5.08 s |
| Whole-book write to local SQLite | 8.80 s | 8.81 s |
| Save (fingerprint ×2 + write-back) | 9.22 s | 15.40 s |
| **Read SQLite directly across the wire** | — | **40.56 s** |

Import fidelity was checked by reading both files with `finlens stats`: unique
payees, accounts, transactions, postings, uncleared postings and date span all
identical.

### The open architecture decision, closed

Whether to skip the working-copy hop on local volumes (§6.2) is settled:
**always working-copy, and direct mode is not built.**

- **Locally there is nothing to win.** The hop costs **0 ms**, because copying
  a file on APFS is a clone.
- **Remotely it costs 11.6×.** Reading the same book without the hop took
  **40.56 s against 3.51 s**, and only 1.96 s of that was CPU — the rest is
  SQLite's small random reads each paying network latency, which is the exact
  hazard §6 opens with.

A trade-off with no upside on one side and an order of magnitude on the other
is not a trade-off. ADR-8 stands unqualified.

Two things the numbers say about where time actually goes: the **whole-book
write is 8.8 s and identical on both volumes**, so a save is dominated by
serialisation rather than by the network — incremental persistence
(architecture.md §5.2) is the lever if save latency ever matters, not faster
IO. And the network part of a save is ~6 s of a 15 s total, which is the two
full-file SHA-256 fingerprints plus the temp copy and replace: four traversals
of a 54 MB file, not one.

### Four months of documents, matched and filed

Jan–Apr 2026, through `AppModel.matchAttachments` — the app's own matcher.

| | Documents | Matched | Attached | Categorised |
| --- | --- | --- | --- | --- |
| Receipts and invoices | 183 (97 duplicates skipped) | **172 (94%)** | 172 | 157 |
| Dividend / distribution statements | 17 (2 already linked) | 14 (82%) | 13 | 11 |

The book afterwards: **46,578 transactions, unchanged** — nothing was created
or destroyed. Postings 103,365 → 103,558 and accounts 492 → 499, both from
itemised invoice splits and the dividend income accounts created on demand.
Uncategorised postings in `Imbalance-AUD` fell **438 → 277**: 161 legs left the
wash account for real categories.

Worth knowing when checking that figure: the wash account's *balance* moves
**further from zero** when categorisation succeeds, which reads like damage and
is the opposite. The legs being removed are the positive counter-legs of card
spending, so taking them out makes a negative balance more negative. The way to
confirm a run did no harm is that the balance moved by exactly the sum of the
legs that left, and that the transaction count did not change at all.

What is left unmatched is left honestly. **11 receipts have no corresponding
transaction in the book at all** — checked by searching the Jan–Apr postings
for each amount read and finding none. Of 4 statements, all four are a *second
file* for a payment its twin already claimed (PL8, NAB and Telstra each arrive
under two filenames), which is the correct outcome for one payment.

### A receipt from a trip shares no number with its transaction

The first pass left 8 receipts unmatched for one reason: they were bought
overseas (6 NZD, 2 MYR). A card charged abroad posts in the book's currency, so
the receipt says NZD 72.11 and the transaction says AUD −64.51, and the rate
between them is nowhere in the book.

The obvious fixes are both bad. Asking the owner to *tag* transactions with a
currency is work proportional to the ledger rather than to the receipts, and it
is circular — to tag the right transactions you must already know which ones
your receipts belong to. Converting at an assumed rate is worse: tried on this
book, picking the posting nearest an assumed rate paired a New Zealand clothing
receipt with a **supermarket run in another country**, because with tens of
candidates in a window something always lands within a percent of any rate you
choose.

Neither is needed, because the card issuer already wrote the original down:

    THE SQUARE RESTAURANT     CHRISTCHURCH  72.11  NZD 2.18 AUD

Merchant, city, **the amount actually charged**, its currency, then the fee.
`ForeignAmountScanner` (Interchange) reads that, and the matcher indexes it once
per run, so a receipt's own figure matches the book **exactly** — no rate, no
tolerance, nothing tagged. 37 transactions in this book carry it, across NZD,
MYR, USD, THB and EUR. The trailing fee arrives mangled in real exports
(`NZD 1.1.56 AUD`, `MYR22.68 AUD`) and is deliberately not read.

That took the unmatched receipts from 19 to **11**, every foreign one recovered
bar a scan whose amounts are absent from the book. The telling case is a café
receipt that never printed a currency code at all: nothing detected it as
foreign, but the book knew — `ALPINE PARROT QUEENSTOWN 51.40 NZD` — and the
OCR had read 51.40. **You do not need to know the receipt's currency; match the
number and let the book supply it.**

A rate-based fallback exists for issuers that record nothing
(`finlab documents --fx NZD=0.905`), off unless asked for, and it refuses to
answer when more than one transaction in the window fits the band — two
candidates is not a near-miss to break by picking the closer one, it is the
signal that the amount identifies nothing. It was not needed here.

### The rest were never going to match

Reading the remaining receipts for how they were paid split them cleanly, and
the two halves need opposite responses. Four say **cash** — those have no
transaction to match because the money left a wallet, and the only way they
reach the book is by being entered. Six say **card** — those went through an
account, so a transaction exists somewhere and the statement carrying it has
not been imported. That is a data gap, not a matching failure, and no matcher
can close it.

`DocumentClassifier.tender` makes that call, and `finlab documents
--cash-account "Assets:Someone:Cash"` enters the cash ones: date and vendor
from the document, the named account credited, the file attached, and the
counter-leg parked in the wash account so the *existing* categoriser finishes
the job rather than a second one being written.

The account is required and never inferred. A receipt records that notes
changed hands, not whose — a household with a cash account each produces
identical dockets, and picking one would be inventing a fact about the ledger.

Card detection is deliberately broader than cash detection, which the first
version got wrong: a tablet bought on a debit card was proposed as a *cash
purchase* because the reflowed OCR never produced the exact phrase the strict
list wanted. The mistakes are not symmetric — missing a card leaves a receipt
unmatched and costs nothing, while calling a card purchase cash invents a
transaction that double-counts the moment the statement arrives. So the card
list reads bare words too, and anything ambiguous is left alone. With that
fixed, the classifier's answers matched an independent Vision probe of the same
receipts exactly.

### Two ways a date can be a day early

The four entries landed a day before their receipts. A date built from a
filename is midnight *local*, which in Sydney is 13:00 UTC the day before, and
a posting day is stored as midnight UTC — `GnuCashDate` writes
`00:00:00 +0000` and `isDayOnly` treats exactly that as "carries no time of
day". Stored raw, the rows read a day early anywhere reading UTC (`finlens`
does) and would export to GnuCash on the wrong day.
`AppModel.postingDay(from:)` now takes the local calendar day and re-anchors
it to midnight UTC, so the day the person meant survives the convention the
file expects.

Repairing the four already written found the second, larger version of the same
mistake. `finlab repair` first asked "is the posted time midnight UTC?" and
selected **759** transactions — GnuCash stores plenty of dates at 10:59 UTC,
which is late evening here and the same calendar day read either way. Applying
it would have rewritten hundreds of rows that were never wrong, to fix
something that was not wrong with them; the dry run is the only reason it
didn't. The predicate is now "the UTC day and the local day disagree", which
selects exactly the four, leaves a 10:59 UTC row byte-identical, and is
idempotent on a second pass. A repair whose blast radius is two orders of
magnitude larger than the defect is not a repair.

### Two matcher defects, found only because real documents were used

**Distributions were hunted among purchases.** `parseAttachment` decided a
document was income by requiring the text to contain "dividend" *and*
("frank" or "imputation"). Australian registries do not cooperate: a NAB
capital-note advice says "distribution" and never "dividend"; a Vanguard
advice says "dividend" and never "franked". Each failed a different half of
the test, fell through to the invoice path, and was searched for as money
going *out* — so a distribution sitting in the book on the exact day for the
exact amount was never found. Verified two ways: from the documents' own
vocabulary (`payment date` and `record date` appear in every one of them, while
"dividend" and "franked" each appear in only some), and from the book — for six
of the failing statements the deposit was present on exactly the day the advice
named, for exactly the amount it stated, and still went unmatched.

The test now lives in `DocumentClassifier.isSecurityIncome` beside the
classifier that already existed for this and was going unused, and requires
two independent signals: what is being paid, and registry vocabulary. It took
dividend matching from **6/17 to 14/17**. Direction is also now read from the
document rather than inferred from `dividend != nil`, so a model call that
declines a statement no longer turns it into a purchase.

**"…already has an attachment" was confidently wrong.** That note searched a
year either side for a linked transaction of the same amount, on the reasoning
that the amount narrowed it enough. On 46,578 transactions it does not narrow
it at all — everyday spending is full of common round totals — so the note
reported a café receipt dated in January as matching a supermarket purchase
almost two months later, and named an unrelated shop for another. A claim
that "this is your transaction, already linked" now has to clear the same
14-day bar as a claim that "this is your transaction"; only a document whose
date could not be read at all still falls back to the loose search.

### Defects found and fixed

- **`documents` leaked the book lock.** A headless session drives no
  heartbeat, so a leaked lock does not merely linger — it stays *fresh* for
  its full 90-second staleness window and refuses the next run, including an
  immediate retry, rather than letting it break the lock.
- **A destination file that does not exist yet has no volume.** Probing the
  *file* to decide local-vs-network threw and fell back to "local", reporting
  an SMB share as local for as long as it took to notice. Probing the
  enclosing directory as a fallback fixes it.
- **Modification time is not a document date, and the failure is not
  random.** In the real statement tree most genuine Jan–Apr documents carried
  May–July mtimes (bulk-downloaded later) while a pile of 2024–2025 statements
  carried January 2026 mtimes (bulk-downloaded then) — sorting on mtime gets
  both halves wrong. `DocumentDate` reads names most-semantic-first instead, so
  a registry's own `period end 31 january 2026` outranks the
  `2026-05-01_17-25-58` download stamp in the same filename. Nineteen 2024–2025
  Plato statements were being pulled into the period before that rule existed.

---

## In-app help book (25 Jul 2026)

The Help menu opened a 72-line sheet: a paragraph on getting started, the search
operators, and a shortcut table that had **gone stale** (it listed ⌘N as "New
book" — ⌘N is New Transaction; ⌥⌘N is New Book — plus ⌘T and ⌘J, which do not
exist). It is now a proper help book: **25 topics in four sections**, with a
topic sidebar, per-topic pages and search.

**Built as data, not HTML.** `HelpContent.swift` is the book — sections of
topics, each a list of typed blocks (`text`, `heading`, `bullets`, `steps`,
`table`, `tip`) whose strings are `LocalizedStringKey`s. `HelpView.swift`
renders them. Two consequences worth the choice: the pages **translate through
the app's String Catalog** like every other string — of the 338 help keys the
compiler emits, the prose ships in all eight languages and 34 (shortcut glyphs
and search operators) are marked untranslatable — and the same code serves
macOS, iPadOS and iOS.
An Apple Help Book (`.help` bundle, indexed HTML, Help Viewer) was the
alternative; it would have meant a parallel localization pipeline, a `hiutil`
index to maintain, and nothing at all on iOS.

Help is a **window** on macOS, not a sheet — the same HIG reasoning already
applied to Reports and Reconcile: you read it *while* working. iOS keeps the
sheet.

Search matches a topic's title, summary **and** an untranslated English keyword
list, so a reader who searches "reconcile" or "split" finds the page even when
the UI is in German — the words they learned from GnuCash still work.

Content covers the real feature set, checked against the code rather than
memory: accounts and the chart, the register and splits, search operators,
saving/locking/NAS/audit, bank import and the matcher, Smart Import, rules and
auto-categorise, reconciling, schedules and bills, budgets, documents and
relative links, investments and price providers, reports and decks, the
planners, goals, business, emergency records, GnuCash/Ledger/`finlens`, and a
shortcut reference **regenerated from the app's actual `keyboardShortcut`
declarations**.

---

## Localization — eight languages (25 Jul 2026)

The app ships localized: **English, German, Spanish, French, Italian, Japanese,
Brazilian Portuguese and Simplified Chinese**. 1,126 UI strings, translated
throughout, with accounting terminology following GnuCash's own conventions per
language (Buchung / opération / 勘定科目 / 分录 …) so a GnuCash user reads
familiar words.

**Where the catalog lives, and why.** SwiftUI resolves `Text("…")` against
`Bundle.main`, so a single `Localizable.xcstrings` in the **app target** serves
the whole `FeatureUI` package too. That is what made this tractable: **zero**
call-site churn across 89 view files — no `bundle: .module` on every `Text`,
`Section`, `Toggle`, `.navigationTitle` (several of which have no `bundle:`
overload at all). The Quick Look extension is a separate bundle, so it carries
its own two-string catalog. `STRING_CATALOG_GENERATE_SYMBOLS = NO`: the key set
collides on case and trailing ellipses (`Add Record` / `Add Record…`), and we
look strings up by literal, never by generated symbol.

**The key list is the compiler's, not a guess.** A hand-rolled extractor got
the work started, but the authority is
`swift build -Xswiftc -emit-localized-strings`, whose `.stringsdata` is exactly
what the runtime will look up — including the typed format specifiers
(`%@`, `%lld`) that interpolated strings compile to. Diffing the catalog
against it drove the count to **zero missing keys and zero dead entries**, and
caught five classes of bug a source scan cannot:

- **`Text("a " + "b")` is not localizable at all.** Swift resolves the
  concatenation to `Text(String)` — the *verbatim* initialiser — so the
  compiler emits no key. Two long help strings had silently opted out; they are
  now single literals.
- **Helpers typed `String` swallow localization the same way.** `Card`,
  `treemapCard`, the register's status-bar `cell`, and two `accountPicker`
  helpers all took `String` and passed it to `Text`/`LabeledContent`. That is
  why the dashboard card titles, the register column headers and the
  `Present:` / `Cleared:` / `Reconciled:` strip stayed English in the first
  German build. All now take `LocalizedStringKey`.
- **Ternary branches** — `Text(cond ? "a" : "b")` — are two keys, and neither
  is the first token after the paren.
- `TableColumn`, `CommandMenu`, `SharePreview` and `ColorPicker` are
  localizable APIs that a naive `Text(`/`Button(` sweep misses.
- Chart `.value("Security", …)` labels and App Intent titles are keys too.

**Deliberately not translated**: the app name, `PDF`, the URL placeholder and
the copyright line are marked `shouldTranslate: false`. The Text Size slider's
`A` and the reconcile column's `R` are typographic samples, not words.

Verified by launching the app under `-AppleLanguages` for German, Japanese and
French and reading the result: sidebar, menus, register columns, status bar,
inspector and toolbar all render translated, with number and currency
formatting following the locale (`53.941,18` in German, `53 941,18 $AU` in
French).

### The gaps that audit could not see (10 Aug 2026)

Three catalogs now: **1,567 keys** in the app (71 untranslatable, 37 carrying
plural forms), 7 in Quick Look, 9 in the new widget catalog. What closed:

- **Helper parameters typed `String`** — the same trap as above, in seven more
  places: `upNextRow`, `PassportView.row`, `PlanningView.row`,
  `ReconcileView.stat`, `BusinessView.labelled`/`totalRow`,
  `CheckPrinting.labelled` and Quick Look's `row`. About 28 labels, including
  the whole Up Next card on the dashboard, emitted no key at all. Where a row
  is labelled with the owner's own account name a separate `dataRow` keeps it
  verbatim — their words are not ours to translate.
- **`String`-typed messages** — toasts, the reconcile status line, import
  caveats, Siri responses and the widget's bills line are built as `String`, so
  a bare literal is neither extracted nor looked up. They go through
  `String(localized:)`, which *does* resolve plural variations even though
  `Text` does not.
- **English suffix plurals.** 28 call sites interpolated `"s"`/`"ies"`
  (`"\(n) transaction\(n == 1 ? "" : "s")"`), which rendered "3 Änderungs" and
  "变更s". They are single format keys with catalog plural variations now.
  `xcstringstool` will not infer which argument drives the plural when `%lld`
  appears twice, so the four two-count sentences use explicit substitutions.
  Verified by rendering from the built bundle: "1 Änderung angewendet." /
  "3 Änderungen angewendet.", and digit grouping follows the locale — 2,312 /
  2.312 / 2 312.
- **The widget extension had no catalog.** An extension has its own bundle, so
  "Net Worth" and "Alerts" rendered English in every language while the help
  promised translated names.
- **Help search matched English only.** `HelpTopic.title` is a
  `LocalizedStringResource` now, which unlike `LocalizedStringKey` can be read
  back as a `String`; searching resolves through a prebuilt index.
- **App Intent responses** reach the catalog after all, via
  `String(localized:)` — the earlier note that they could not was wrong.

The reason all of this survived an audit that reported full coverage: nothing
ran the extractor. `scripts/check-localization.py` does, gated in CI
(`localization` job) — it compares the compiler's emitted keys against the
catalogs **both ways**, over **both platforms**. Both halves matter: Xcode
extracts only targets that own a catalog, never the SPM packages where most
strings live; and a macOS-only run never compiles the `#else` branch of
`#if os(macOS)`, which is where `"Browse accounts"` had been shipping
untranslated.

---

## P10 — Ledger interchange & the `finlens` CLI (25 Jul 2026)

The last phase: read/write the Ledger 3 journal format, and a ledger-modelled
command line over the book. Design and research in
[ledger-design.md](ledger-design.md), with the two specs it was written
against — [ledger-format-reference.md](ledger-format-reference.md) (the
grammar, from `doc/ledger3.texi` v3.4.1 and the C++ parser) and
[ledger-cli-reference.md](ledger-cli-reference.md) (the CLI surface). The
user-facing manual is [cli.md](cli.md).

**P10a — the codec.** `LedgerJournal` / `LedgerParser` / `LedgerWriter` /
`LedgerAmountStyle` in Interchange: first-character dispatch over the living
grammar — postings with the hard two-space separator, `@`/`@@`/`(@)` costs,
balance assertions evaluated in file order, balance assignments, `(unbalanced)`
and `[balanced]` virtuals, `; key: value` and `; :tag:` metadata, the directive
set with `include`/`year`/`apply` state machines, `~` periodic and `=`
automated entries captured as extras, decimal-comma inference, and
per-commodity display-style learning. Every error reports `file:line` and
recovers to the next entry. Parse → write → parse is a fixed point.

**P10b — book mapping.** `LedgerBookMapping` both ways (guid/type metadata,
`@@` legs, reconcile states, aux dates, assertion verification, virtual policy,
an import summary), a deterministic whole-book export, and File ▸ Import/Export
▸ Ledger Journal… menu items.

**Verified on the real reference book**: 46,553 transactions / 559 accounts /
159,871 prices export to a 16.4 MB journal in ~3.0 s and re-import in ~7.1 s
with **zero errors**, every balance matching to the cent, and
export→import→export **byte-identical**. Two findings only real data could
surface shaped the codec: commodity mnemonics contain spaces (`AT&T Top-up`),
so metadata values and symbols are quoted; and the `commodity … format`
sub-directive is authoritative for precision on import, because a whole-unit
security can still hold fractional units.

**P10c — the CLI.** A new `Packages/CLI` with a testable `FinvestLensCLICore`
library and the thin `finlens` executable. Hand-rolled option parsing with
ledger's interleaving and short clusters; the query grammar (account regexes
with implicit OR, `and`/`or`/`not` with parens, `payee`/`@`, `tag`/`%`,
`code`/`#`, `note`/`=`, trailing `for`/`since`/`until`/`show` sections); smart
dates and period expressions with natural-boundary bucket alignment; a
filter → value → sort pipeline honouring ledger's **exclusive** `--end`; and
renderers for `balance`, `register`, `print`, `csv`, `accounts`, `payees`,
`commodities`, `prices`, `pricedb`, `stats`, `equity`, `cleared` and `source`,
plus the interactive REPL with `push`/`pop`/`reload`. The CLI is **strictly
read-only** (ADR-L2): a read-only store connection, no lock, no working copy,
no writes. Verified on the real book — **371 account balances match the engine
exactly**, the file is byte-identical after a run, and no `.lock` appears.

Two conformance details the goldens caught: `--depth N` folds by *account path
components* (not display rows), and `to`/`until SPEC` ends **before** that span
— the same exclusivity as `-e`.

**P10d — depth.** `-l/--limit` and `-d/--display` value expressions over a
small typed AST (the posting vocabulary, comparisons, regex match, arithmetic,
`[date]` literals) — deliberately grown to fit, not a port of ledger's
~80-function language; unknown names are rejected at *parse* time, so a typo
exits 1 instead of quietly matching nothing. Running totals moved into the
pipeline, snapshotted per commodity over the whole filtered set before `-d`,
`--head`/`--tail` and `-S` reshape it. The `--budget` family over a journal's
`~` entries (or a book's own Budgets), the `budget` command's four columns,
`--forecast` projections that are reported but never added to the book, `xact`
drafts, and the `.finlensrc` init file with `FINLENS_*` defaults sitting under
argv.

Three fixes to existing code fell out of P10d: **`finlens print QUERY` ignored
the query** and printed everything (it filtered a whole-book export on a `guid`
*metadata* key, but the export writes the guid as a note line — only the parser
produces metadata — so nothing matched and the fallback kept all of it);
`--head`/`--tail` restarted the running total at the first shown row; and
`LedgerExport.styles(for:)` was split out of `journal(from:)` so `equity` and
`xact` stop building a whole 46,000-transaction journal to format a few
amounts. One conformance trap worth recording: `FINLENS_DEPTH=1` must not read
as the bare flag `--depth`, so boolean coercion applies only to options that
genuinely take no value.

**Deliberately out** (recorded in ledger-design.md §5.4): format strings
(`-F`, `--bold-if`), `select`, `convert`, `--pivot`, `--anon`, `-j`/`-J` plots,
and `lisp`/`xml` output. Environment compatibility is `FINLENS_*` only — we do
not read `LEDGER_FILE` or `.ledgerrc`.

The env-gated acceptance harnesses are `LiveLedgerRoundTripTests` and
`LiveCLIParityTests` (`FL_PERF_FILE` names the book, `FL_FINLENS` the binary);
53 CLI unit tests pin the layouts, grammars and the read-only guarantee.

---

## Full-codebase review pass (25 Jul 2026)

A max-effort review of the entire codebase against the PRD, Architecture and
Plan (ten independent finder angles → per-candidate adversarial verification →
a gap sweep; 63 distinct candidates, 60 confirmed, 2 refuted). Everything
confirmed was fixed the same day; all nine suites green (1,094 tests, +29
regression pins) and both platform targets build.

**Money-correctness fixes (engine & import).** Stock splits now rescale open
*short* positions (both FIFO/LIFO and average-cost — a split while short
previously produced phantom lots and overstated gains); Scrub no longer flags
the single-split zero-value stock-split shape as degenerate (GnuCash's own
scrub accepts it — Check & Repair used to nag forever); Close Book **aborts**
(preview warns, toast on execute) when the equity account is
foreign-denominated and no exchange rate exists, instead of silently booking
the unconverted figure; a weekend-back-adjusted first occurrence is no longer
dropped when the query window ends just before the nominal start (bills came
due late); `statementDate` survives a GnuCash-XML round-trip (the getter now
reads the `timespec` flavour the importer produces); CAMT booked reversals
keep `CdtDbtInd`'s sign — the extra `RvslInd` flip inverted every reversal
(ISO 20022 defines the indicator as the reversal entry's own direction; the
fixture was corrected against the standard); lone-decimal-comma amounts
("4,99") no longer parse 100× too large, and the Intelligence layer now
delegates to the one importer parser instead of a drifted copy; OFX values are
entity-decoded; a UTF-8 BOM is stripped at every import decode; the matcher's
verbatim-reference pass now requires the money to agree (recycled cheque
numbers swallowed real rows) and payee learning skips wash accounts; QIF
`RtrnCap` maps to return-of-capital (was booked as dividend income); OFX
investment rows are labelled from `SECLIST` tickers, not raw CUSIPs.

**Data-safety fixes (persistence & app).** FileLock: the heartbeat re-checks
on-disk ownership (a machine waking from sleep used to clobber a legitimately
re-assigned lock — the loss is now surfaced as a toast and the session falls
back to fingerprint-guarded saves); breaking a stale lock re-reads inside the
delete so two racing breakers can't both acquire; an unreadable/corrupt lock
file now reads as a stale unknown holder (Break Lock offered) instead of
silently disabling locking. The SQLite loader never drops a row over a corrupt
GUID — accounts, transactions and prices mint a counted random identity like
splits always did, so the load-warnings toast reports it. Posting scheduled
transactions is one whole-book undo action (⌘Z used to rewind `lastPosted`
but leave the transactions — reposting duplicated them); Revert and
reload-from-disk clear the undo stack (stale snapshots could rewrite the
adopted book); investment imports stamp the broker FITID as `online_id` and
the review flags already-imported trades (re-importing an overlapping broker
file used to re-create every trade); Split-from-Invoice preserves the funding
leg's identity (saving used to clear its reconcile state);
duplicate/copy-paste carry tags; every money-entry sheet parses with the
strict whole-string parser ("4,001.23" typed into Reconcile used to start the
session against $4).

**Correct statuses & guarded intelligence.** Bills: a blank-description
schedule never matches a blank-description transaction; a bill due today is
*due*, not overdue (day granularity); name matches must also agree on amount
within ±25% (FR-BILL-01's expected-amount matching — a $5 coffee named "Rent"
no longer settles the rent). Income above its budget is favourable — no more
"Over budget: Salary" (alerts filter income lines; the budget row now reads
"Ahead by"). FR-PLAN-05's fifth alert kind, **unusual spend**, is implemented
(current month ≥2× the trailing six-month average and ≥$100 over — transparent
arithmetic in the message). FR-GOAL-01's **goal-to-bill link** shipped (goal
editor picker + row badge). The review-deck story validator's blanket
1900–2100 "calendar year" exemption is gone — only ungrouped years the slide's
own facts name (label years expanded, ±1) pass ungrounded, so a fabricated
"$2,000" is rejected again; statement sign-correction votes on the account
convention per statement, so positive-owed-balance credit-card statements no
longer import with every row inverted; the account-name matcher prefers an
account's own leaf prefix and gates short-needle containment ("Car" filed
under Cars, not Childcare); quote fetches record the provider-reported
currency in the price source ("Finance::Quote:yahoo (USD)") so the documented
provenance actually exists; latest-quote refresh skips identical same-day
rows (every book open used to append duplicates forever) and all history
fetches share the one-run-at-a-time guard.

**Performance & structure.** The dashboard's alerts/bills/budget reads,
`plannerDebts`, `knownTags`, the price scatter (stable ids), and the cash-flow
forecast (its memo key embedded a live `Date()`, so it never hit) are all
memoised through `cachedReport`; the report screen attaches one `.task` to the
container instead of one per branch (every report computed twice on first
open); free-text search debounces 200 ms (tests call `runSearch()`
directly); `endOfToday()` uses calendar day-arithmetic (the +86 400 form was
wrong on DST transition days) and `todayCap` delegates to it. Shared concepts
now live once: `Account.isWash` (matcher, Uncategorised review, Smart
Categorise), `Book.baseCurrency` (root-commodity-first — `commodities.first`
was registration-order dependent), `BookKvpKeys` (Engine constants for the
cross-module slots), `StatementLabels.uncategorised` (seven comparison sites),
`DividendAccounts` paths, the narrative tokeniser
(`ImportMatcher.narrativeTokens` with an opt-in date-token filter),
`AmountFormat.compact` (the two decks' copies each took only the *first*
character of the currency symbol, so a multi-character symbol was truncated —
"CHF " became "C"; the unified one keeps everything before the first digit),
`ReportPeriod.financialYearLabel`, and
`GnuCashDate.parseDayOnly` (CAMT allocated a `DateFormatter` per entry row).
Dead code deleted: `AsyncReport`, `detailLine`/`legDetailLine`,
`debtPlanResults`, `financialYearPackDocuments`, `apiKey`/`setAPIKey`,
`SubaccountsTip`, `Book.removeInvoice`/`noOpenLots`, the `Item.swift` template
husk; `selectedSplitID` is computed from the selection set.

**CI & docs.** The SPDX gate now covers the app-target directories (six files
gained the machine-readable header) and the allowed-to-fail macOS-26 job runs
FeatureUI's tests; plan.md's P6 status, the architecture package graph (Shared
was missing), PRD FR-FIND-01's shared-grammar claim, and deferred.md's rule
tail were corrected to match the code, with two new recorded judgement calls
(rule set-budget, Quick Look for `.gnucash`). *(Quick Look for `.gnucash` was
later built — 9 Aug 2026, recorded above; only the rule tail remains a skip.)*

---

## Test comprehensiveness pass (24 Jul 2026)

The closing quality gate: measured line coverage across every package
(merged best-of per suite), then filled the gaps that mattered — and fixed
the five real bugs the new tests flushed out. **1,065 tests green** (was
835), all suites, both platforms, plus the three env-gated live acceptance
harnesses re-run against the reference book.

**Coverage (lines, before → after, own-suite):**

| Package | Before | After | Gate |
|---|---|---|---|
| Engine | 80.6% | **91.8%** | ≥90% ✓ (was the one breach) |
| Interchange | ~92% merged | higher (Gzip 87%, dates 97%, SX import 93%) | ✓ |
| Persistence 93% · Reports 93% · Rules 99% | — | unchanged | ✓ |
| Quotes providers | patchy | AlphaVantage/Finnhub/Stooq 100%, EODHD/TwelveData 97% | ✓ |
| Intelligence `DocumentText` | 50% | **94%** (deterministic PDF-reflow fixtures) | ✓ |
| FeatureUI logic files | 0–59% | InlineEdit/CSV **100%**, SmartCategorize 96%, Budget 97%, ReportDocuments 95%, ReportBuilders 96% | ✓ |

**Notable new suites:** hand-amortised loan schedules; all recurrence
weekend-adjust branches with hand-verified calendar dates; the smart
categoriser's plan/ambiguity/threshold behaviours pinned (its tuned
constants finally have committed guardrails); a **synthetic report-catalogue
sweep** — the CI-runnable counterpart of the env-gated live catalogue, so the
report builders are no longer CI-dark; check-repair scenarios; CSV export
wire format; PDF text-reflow with scrambled content-stream fixtures; widget
snapshot wire format.

**Bugs found by the pass, fixed and pinned:**
1. **`goalEligibleAccounts` always empty** — `AccountNode.typeName` is
   capitalized ("Bank") but three call sites compared it to the lowercase
   `AccountType.rawValue`, so the **Add Goal button was permanently
   disabled**, the invoice funding-account picker was empty, and Time &
   Mileage's income pickers were empty. One case-insensitive
   `AccountNode.isType(…)` helper now serves all three.
2. **`Recurrence.occurrences` skipped weekend adjustment for the first
   occurrence** — the list disagreed with `next(after:)` for a
   weekend-anchored start; the seed is now adjusted like every other
   occurrence.
3. **Alpha Vantage's unknown-symbol answer** (`{"Global Quote": {}}`) threw
   a raw `DecodingError` instead of `QuoteError.noData`.
4. **`"500 IDR"` parsed as −500** — the amount parser's debit marker matched
   any `DR` suffix, including currency codes; it now requires a standalone
   token.
5. **`LoanCalculator.totalInterest` returned −principal** on a zero-length
   term; now 0.

One expectation corrected on my side of the audit: weekend adjustment on
*weekly* recurrences is deliberately discarded (month-anchored semantics,
GnuCash-faithful) — pinned with a comment rather than "fixed".

Deliberately not chased: SwiftUI view bodies (not unit-testable), live-HTTP
transport, FoundationModels session paths (the `LiveModelTests` suite covers
them on-device), and Keychain-backed key storage.

## Deferred-backlog pass (24 Jul 2026)

A sweep of [deferred.md](deferred.md) implementing everything buildable
without external dependencies (runners, NAS hardware, translators stay
blocked; TXF and bank sync stay skipped by decision). Five items closed:

- **GnuCash credit notes (FR-BUS-01).** `Invoice.isCreditNote`, faithful to
  the GnuCash source: the `credit-note` int64 in `<invoice:slots>` is lifted
  on import and always written on export; posting flips every leg's sign
  (`is_cust_doc != is_cn` — the A/R leg carries action "Credit Note"); a book
  holding credit notes exports the **"Credit Notes" book feature** so pre-2.5
  GnuCash refuses rather than misreads. Persistence migration, editor toggle,
  list/detail badges, printable title (AU "ADJUSTMENT NOTE" in the
  tax-invoice layout). The production review's sign-inversion defect is gone.
- **Round-trip fidelity tail (FR-XIO-01).** `InvoiceEntry.entered` is now a
  real field (imported, exported, persisted — no longer re-derived from
  `entry:date`), and `KvpValue` distinguishes `.timespec` from `.date`, so a
  timespec slot at exactly midnight re-exports as a timespec. Both pinned by
  round-trip tests.
- **Load-time warnings (NFR-05).** The SQLite load path still opens
  what it can, but counts every silent default (`LoadWarnings`, task-local,
  threaded through `parseDecimal`/`parseKvp`/`decodeAddress`/GUID fallbacks)
  and the app surfaces a toast on open: "Opened with 2 amounts, 1 identifier
  unreadable and defaulted…". Exercised by a corruption test.
- **iOS book rename/move.** The welcome screen's recents now carry a context
  menu — Rename (in place, audit-log sidecar moved along, Recents and
  bookmarks updated), Move (the system `fileMover`), Remove from Recents.
  Works on macOS too.
- **Rule link-to-bill (FR-RULE-01).** A new `linkToBill` rule action stamps
  matched payments with the schedule's GUID (`finvestlens/bill-id`, an
  ordinary exportable slot); bill reminders check the link **before** the
  description heuristic, so a bill whose payment descriptions vary still
  clears exactly. Editor picker, summary text, and apply-to-history support
  included. (convert-type remains skipped — fuzzy in a double-entry model.)

835 tests green across the six packages (Engine 183, Interchange 81,
Persistence 33, Rules 10, Reports 116, FeatureUI 412); both platforms build.

## Report consistency pass (24 Jul 2026)

A full review of every report surface against the annual-report standard the
Jul 2026 redesign set, closing the "internals migrate to the document
scaffold later" tail. The audit matrix covered headers, amount formatting,
period controls, export, empty states, charts, and typography across all 23
report kinds plus the decks, FY pack, and passport. What changed:

- **One masthead everywhere.** The shared `ReportMasthead` (entity · serif
  title · period · units line, centred — the statement standard) now heads
  the document scaffold (so every scaffold report incl. the six business
  documents), and the two interactive tools. PDF exports carry the same
  masthead: `PrintableStatement` gained the entity line and serif title.
- **Five legacy views migrated onto the scaffold** — Transactions,
  Reconciliation, Portfolio, Investment Lots, Capital Gains now render as
  `ReportDocument`s (their print builders were already the source of truth),
  which gives them the masthead, KPI callouts, ruled tables, notes, PDF
  **and Share** for free. Period control is now uniformly the parameter
  bar's `PeriodSelector` (as-of kinds read the period end); Transactions and
  Reconciliation gained a single-account picker there (defaulting to the
  selected register account), and the investment kinds host the cost-basis /
  fee pickers in the same bar. ~550 lines of one-off view code deleted.
- **Two tools remain interactive by design** — the Forecast (what-if editor)
  and Price History (explorer) — but now open with the masthead, share the
  palette, and export branded PDFs. `CashFlowView` was renamed
  `ForecastView` (it renders the `.forecast` kind; the `.cashFlow` document
  is a different report).
- **Spending Insights joined the scaffold** with a new `summary` block
  (plain-language sentences between callouts and tables, also in the PDF) —
  it had been the one report with no export at all.
- **Portfolio gained an allocation donut** in the document (top holdings,
  tail rolled into "Other"), and every multi-series chart (both allocation
  donuts, the price scatter) now draws from one `ReportPalette` anchored on
  the accent colour instead of SwiftUI's default rainbow. The forecast's
  what-if markers moved from orange to a reserved purple.
- **Real empty states.** A scaffold kind that builds nothing (or an empty
  document) shows a `ContentUnavailableView` with a kind-specific reason —
  previously an infinite "Preparing…" spinner.
- **Share everywhere.** The report screen's toolbar now offers Share beside
  PDF for statements (new `ShareableStatementPDF`) and scaffold documents
  alike; previously only the legacy views could share.
- The dead **Compare stepper** (gated on a hardcoded-false flag) was
  removed; the passport page now honours the app's text-size preference
  (`scaledFont` throughout); the reconciliation integrity note lost its
  debug-ish "Please report this" phrasing.

Verified by `LiveReportCatalogueTests` on the real book: all 17 scaffold
kinds build under their default configurations — 11 content-bearing kinds
asserted non-empty (sections/KPIs/charts counted), business documents build,
price history prints, and the forecast's empty state is exercised. 412
FeatureUI tests green; both platforms build.

## P9 — Planning & insights (24 Jul 2026)

The final phase: Microsoft Money's flagship planning layer plus the
Frollo-inspired wellness pieces, over the GnuCash-rigour engine. Design and
models in [planning-design.md](planning-design.md); the governing rules were
**transparent, adjustable, deterministic, and never advice** — every surface
carries the estimate disclaimer, every assumption is on screen, and every
number traces to the book.

- **Calculators** (`FinvestLensReports`, pure and fixture-tested): `DebtPlan`
  (monthly avalanche/snowball simulation, rolling payments, underwater
  detection, minimums-only baseline), `LifetimeProjection` (annual five-bucket
  model — cash/investments/retirement/property/debts — with life events,
  bracket-estimated tax while working, ordered drawdown in retirement, and a
  book-seeding walk that classifies accounts by type with retirement detected
  by name), `TaxEstimate` (progressive brackets as **editable data** seeded
  with AU resident rates per FY incl. the 2026 cut, flat levy, CGT discount,
  franking/withholding credits), `SpendingInsights` (period-vs-prior category
  joins bound to the pie/bar breakdown, deterministic template sentences),
  `WellbeingScore` (four 0–25 components with exposed arithmetic).
- **Book layer** (`AppModel+Planning`): five new KVP collections (debt plan,
  lifetime plan, tax settings, challenges, emergency records) on the standard
  reload/persist/commit pattern; classification heuristics (retirement roots,
  franking/PAYG names, mortgage exclusion) kept visible on the screens they
  feed.
- **UI**: a **Planner** sidebar destination (Debt Reduction / Lifetime / Tax
  Estimate segments); **Spending Insights** as a report kind in the gallery,
  menu, and favourites machinery; a **Wellbeing** dashboard tile with the
  full working one click away; the **Financial Summary (passport)** as a
  Present-section card and Reports-menu item (A4 PDF, statement typography);
  **savings challenges** in the Goals screen (paced ahead/on-track/behind
  against the straight line, context-menu delete); **Emergency Records** as a
  Records destination behind an optional local-authentication gate (view
  gate, honestly labelled); **Audit Log** viewer in the Book menu.
- **Audit log**: `<book>.audit.log` sidecar written on the same code path as
  undo registration (all five scoped-`editing` tiers), undo/redo replays
  labelled, 1 MB rotation, never inside the book file.
- **Skipped**: TXF export (US-specific; meaningless for an AU book —
  [deferred.md](deferred.md) §5). The `tax-US` code slot still round-trips.

Verified: 636 tests green across Reports/Interchange/FeatureUI (24 new for
P9), and the plan's exit criteria on the **real book** (`LivePlanningTests`):
bucket seeding put the SMSF balance in retirement with cash/investments/
property/debts populated, a 51-year lifetime projection ran from seeded
defaults, the live credit card produced a five-month payoff plan, the tax
estimate flowed tagged accounts through the FY 2026–27 brackets
(taxable income through the brackets to a base figure plus levy), insights produced grounded
sentences, the wellbeing score resolved, and the passport assembled a net
worth over six asset classes.

## P8 — Extended statement import: MT940/MT942 + CAMT.053 (24 Jul 2026)

The last planned import formats (`FR-XIO-04`), closing phase P8 (online bank
sync having been skipped by decision the same day — [deferred.md](deferred.md)
§5). Both are native parsers in `Interchange`, feeding `StagedTransaction`
rows into the same Import Matcher as CSV/QIF/OFX:

- **`MT940Importer`** — SWIFT MT940 customer statements *and* MT942 interim
  reports through one tag-line scanner: `{…}` block markers and headers
  ignored, continuation lines folded into their field, transactions read from
  `:61:` statement lines (value date, optional entry date, `D`/`C`/`RD`/`RC`
  marks with reversal sign-flips, optional funds code, comma-decimal amount,
  transaction type, customer reference vs `//bank reference` — the bank ref
  preferred, `NONREF` dropped). The `:86:` narrative joins its lines into the
  memo; German-convention `?nn` subfields are recognised (`?32`/`?33` →
  payee, `?20`–`?29` → remittance memo). Fixtures follow the SWIFT spec and
  published bank samples (ABN AMRO / ING / Danske style).
- **`CAMTImporter`** — ISO 20022 CAMT.053 (and structurally-identical
  CAMT.052) via a streaming `XMLParser`: one row per `<Ntry>` — amount signed
  by `CdtDbtInd` and flipped by a true `RvslInd`, `PDNG` entries skipped
  (they re-arrive booked), booking date preferred over value date, reference
  chosen entry-`AcctSvcrRef` → detail `AcctSvcrRef` → `TxId` → meaningful
  `EndToEndId`, the counterparty (creditor on debits, debtor on credits, both
  `<Nm>` and the newer `<Pty><Nm>` nesting) as payee, unstructured remittance
  lines joined as the memo. Namespace prefixes are tolerated; batched entries
  stay one row at the entry amount, as booked.
- **Detection** — `BankFileFormat` gains `mt940`/`camt` with extensions
  (`.sta`/`.mt940`/`.940`/`.942`/`.fin`, `.camt`/`.c52`/`.c53`/`.c54`) and
  `detect(_:extension:)` content sniffing for ambiguous `.xml`/`.txt`
  (CAMT root/namespace, OFX header, `:20:`+`:25:` tags, QIF `!Type:`), used
  by the bank-file open flow; the review sheet and matcher are unchanged.

Exit criterion verified in `MT940CAMTTests`: an MT940 and a CAMT.053 imported
through `ImportMatcher.match` against a book with history — same-FITID rows
dedupe via `online_id`, new rows pass the mismatch veto, and payee history
assigns the destination account. 78 Interchange tests green.

## Import matcher — transfer completion & real-statement validation (24 Jul 2026)

The QIF/OFX import pipeline was exercised end-to-end against **four real bank
exports** (an ANZ credit-card OFX v2, a CBA a card account OFX v1/SGML, and two Macquarie
QIFs) on a copy of the reference book, with the requirement that transfers
between the user's own accounts come out as **one transaction with a leg in
each account** — in whatever order the statements are imported. What that
surfaced, and what was built:

- **Two-digit QIF years** — `D30/06/26` parsed as year 26 AD (the `yyyy`
  pattern happily reads "26"). `QIFImporter` now carries `yy` twins for every
  slash format and rejects implausible years so the right pattern gets its
  turn, preserving the file-wide day-first/month-first orientation choice.
- **Cross-account transfer completion ("healing")** — when the counterpart
  statement was imported first and its unmatched side sits in a wash account
  (`Imbalance-*`/`Orphan-*`/`Unspecified`/`Uncategorised`), the matcher
  detects the opposite-amount leg in the other real account (same currency,
  ±4 days) and the import **re-points the wash leg** at the target account
  instead of posting a mirror-image duplicate. A **narrative-agreement gate**
  (shared significant tokens — AU banks put the entity name in both sides'
  narratives) stops coincidental equal amounts from pairing. Rules and
  heuristics never override a detected transfer.
- **FITID-mismatch veto** — an amount+date match against a split whose
  `online_id` differs from the row's FITID is refused: a bank never re-issues
  an event under a new id. This killed every false boundary flag on the OFX
  side (last statement's entries vs this statement's new rows).
- **One-to-one claiming** — each existing split (and each pending wash leg)
  absorbs at most one row per batch, so four identical recurring transfers
  against two book entries import the two genuinely new ones (GnuCash's
  matcher claims matches the same way).
- **Statement dates are exact** — user fact (24 Jul 2026): a **daily payment
  limit** chunks a large movement into identical amounts on consecutive days,
  so near-day amount equality between statement-sourced entries is
  coincidence, not identity. Consequences: a **wash-parked book half matches
  a row on the same calendar day only** (its date IS the bank's posting
  date); **transfer healing pairs same-day only** (banks post both sides the
  same day — every historical transfer in the reference book confirms); and
  duplicate matching tries **same-day candidates before the ±window**, so
  identical recurring amounts pair with their own day instead of an earlier
  row greedily claiming a neighbour's leg and starving the last row. The
  ±4-day window survives solely for its real purpose: a hand-entered
  transaction (which has a real destination, not a wash leg) drifting from
  its bank posting date.
- **Wash-half demotion** — a "duplicate" whose counter-legs all sit in wash
  accounts is itself just an unfinished half; completing a pending transfer
  outranks matching it.
- **Reference stamping** — skipped duplicates get the incoming FITID written
  to the matched split's `online_id` (GnuCash's convention), so the next
  re-import matches definitively; healed legs are stamped the same way.
- **Payee history from memos** — destination suggestion now also learns from
  money-leg memos (where renames park the raw narrative), raw-to-raw like the
  smart categoriser; the substring fallback is deterministic (was
  dictionary-order). Cleaned descriptions preserve the raw narrative in the
  money leg's memo so self-learning survives `cleanMerchant`.
- **Credit-card funding fallback** — a positive "PAYMENT - THANK YOU" row on a
  credit account suggests the bank account most often behind recent deposits
  (2-year window), so the first-imported side of a card payment posts as a
  proper transfer.
- **Imbalance fallback** — rows nothing categorised can post to the book's
  existing `Imbalance-<CUR>` account (toggle, default on) instead of silently
  not importing, feeding the Uncategorised sweep; the review list shows a
  **transfer** badge alongside the duplicate badge.

Verified by `LiveBankImportTests` (env-gated on `FL_PERF_FILE` +
`FL_IMPORT_DIR`): both import orders on copies of the real book — parse counts
(220/58/39/3), all dates in-window, the two card payments (8 Jun, 11 May) and
the SMSF internal transfer (20 May) each land exactly once with clean legs,
**zero false duplicates on the reference-less QIF side** (asserted: CMA.qif
flags nothing, and the boundary window holds exactly six equal-value legs per
side — the book's two April transfers plus all four daily-limit May chunks,
nothing absorbed, nothing doubled), re-importing all four files is a no-op,
and the run reports per-file coverage (e.g. VISA: 142/220 auto-categorised,
78 to Imbalance for review). The only flags left are true duplicates: each
card payment seen from its second statement, and a transfer row whose
transaction the counterpart import had already completed. One chunk pair that
posted across a weekend (a card account debit Sat 2 May, CMA credit Mon 4 May) stays as
two wash-parked halves rather than guessing a cross-day pairing — totals
correct, linkable in review.

## Report redesign — annual-report statements & review decks (24 Jul 2026)

The statement reports moved from working-paper presentation to
**annual-report standard**, and the results gained two **presentation
decks**. Research, judgement rules, and status live in
[report-redesign.md](report-redesign.md); the design decision is
[architecture.md §5.6a](architecture.md) (ADR-6a: presentation arranges,
never computes). The brief's example — `Income:Distributions:VGAD:
Distribution` on the face of a statement — now reads as **VGAD** under a
**Distributions** caption, with fund detail in a note that ties back.

**The statement layer** (`Statements.swift`). `StatementBuilder` projects
the engine's verified flat lines onto the user's own account tree and
applies researched judgement rules (IAS 1 face-vs-notes; AICPA/ASC 274
personal-statement presentation): top-level groups become face captions;
single-child chains collapse (never a colon path — a generic leaf like
"Distribution" loses its name to the specific parent); captions with ≤ 3
postings-bearing accounts inline their children on the face; captions
under 2% of their section fold into "Other" with a note — but cash and
equivalents (IAS 1 minimum line item) and Uncategorised (an integrity
signal) never fold; assets order by liquidity with positives leading and
integrity balances last, liabilities by maturity, income/expenses by
magnitude; every note's total ties to its face line. Statement titles use
the personal-statements vocabulary: **Statement of Financial Position**
(assets − liabilities = net worth on the face; the equity view moves to a
Composition-of-net-worth note), **Income Statement**, **Statement of
Changes in Net Worth** (opening + surplus + valuation movement = closing,
the valuation term derived and footnoted). Prior-year comparative columns
appear when the book reaches back.

A finding on the reference book: the face's net worth and the equity view
differ — real multi-currency
translation (income converted at posting-date rates, assets at current
rates; GnuCash behaves identically). The composition note now reconciles
it with a **"Currency translation and valuation differences"** line, as an
annual report's translation reserve would — explained on the page instead
of silently disagreeing.

**Rendering** (`StatementView.swift`). Centred masthead (entity, serif
title, period, units line), a Note reference column, right-aligned tabular
figures with **negatives in parentheses** and the currency symbol on first
figures and totals only, a single rule above subtotals, a **double rule**
under closing figures, then *Notes to the financial statements* (Note 1 is
always Basis of preparation). One `StatementSheet` serves screen and PDF.
The **Trial Balance** joined the same treatment: Debit/Credit columns, one
section per category in class order, caption rows with note detail, the
unrealised valuation adjustment on its own Adjustments line (credit side,
as the engine defines it), and a double-ruled grand total stating the
report's point — the books balance. The **Financial Year Pack** now opens
with the three statements (Changes in Net Worth joined it) ahead of
capital gains and dividends & franking; statement kinds dropped the
Compare stepper (they carry their own prior-year column).

**The review decks.** Two 16:9 slide decks in the Reports gallery's
*Present* section (and Reports menu), sharing one machinery (`ReviewSlide`,
`SlideCard`, paging with arrow keys, landscape PDF via a new
`ReportExport.pdfPage`): the **Financial Review** (highlights with a
net-worth line; the net-worth **waterfall bridge** opening → income →
expenses → valuation & FX → closing; income and spending analysis using
the statement layer's own captions with prior-year markers; monthly cash
flow; portfolio; dividends & franking; capital gains; financial position
with debt-to-assets and months of cash cover) and the **Investment
Review**, built from web research into fund factsheets and brokerage
performance summaries (overview with total return on money in; allocation
with the concentration read — holdings count, largest, top-five share;
mark-to-market winners and losers; income with franking and yield on
value; realised gains split at the one-year CGT-discount boundary; and a
return decomposition — income + realised + unrealised over money in,
GnuCash's own model). Slides are content-gated (the dashboard's
has-content rule); every slide carries a deterministic action title; no
new arithmetic anywhere — every figure comes from the existing verified,
memoised computations.

**The guardrail earned its keep immediately.** On the first live run the
on-device narrator's insight claimed "a 2.3% increase in income and a 1.4%
decrease in expenses" — numbers it invented. The response: every slide's
facts pack gained grounded deltas (opening/closing/change/percent, prior
totals, savings rate), the prompt now forbids deriving numbers, and a new
deterministic **`ReviewStoryValidator`** disposes — every numeric token in
a story must round-match a listed figure (raw or k/m-scaled), a listed
delta percent, a label numeral, or a calendar year, or the story is
rejected and the deterministic title stands. The exact live failure is
pinned as a test's reject case. Stories cache per (slide, book revision).

Verified: 399 tests / 83 suites (statement identities incl. trial-balance
column conservation; deck gating on cash-only vs dividend vs securities
books; bridge and decomposition reconciliation against engine totals; the
validator's accept/reject cases), both platform builds, and screenshots on
the reference book — the Statement of Financial Position face and notes,
the Trial Balance, and deck slides ("Portfolio returning 63.2%
on money in"; "33 holdings; the top five are 28.6% of the portfolio").

## Usability & performance redesign (24 Jul 2026)

Four audit passes — usability (persona "Chris" + a periodic/monthly/EOFY
journey walked through twelve use cases), functionality (every public
`AppModel` function swept for UI callers; hidden features, dead code and
duplicates registered), performance (per-render full-book scans traced;
progress-feedback inventory), and session/resilience/accessibility/platform —
produced findings F1–F22, redesign decisions RD1–RD4 (taken with the GnuCash-
familiarity constraint deliberately dropped), and perf items P1–P10. The
working documents are [usability-review.md](usability-review.md) and
[performance-review.md](performance-review.md) (their §7 status notes record
the accepted deviations). Executed as four phases, each committed green:

**Phase 0 — consolidation.** One account-chooser family (`AccountSearch` is the
single matching algorithm; every raw `Picker` site converted to
`AccountField`/`AccountPickerButton`); dead code deleted with tests migrated to
successor APIs; misplaced shared views extracted (`SharedComponents`,
`LinkToTransactionSheet`); a single exchange-rate API; a
`Bundle.main.bundleIdentifier` guard in `publishWidgetData` that stopped
WidgetKit/UNUserNotificationCenter NSExceptions from killing test processes.

**Phase 0.5 — performance quick wins.** The register status strip became a
snapshot folded into `refreshRegister`'s existing row pass (was three
full-book `balance` scans per SwiftUI body pass — P1), pinned by fold tests
(voided, frozen, filter-independence) alongside the engine-parity test.
QuickFill reads a per-revision recency list (was a 46k-transaction sort per
keystroke — P2). `postableAccounts` is cached with the account tree (was a
per-body-pass flatten × every picker cell — P4). **Scoped undo** grew two
tiers (P9): `editingPrices` (array snapshot) and `editingBookKvp` (frame
snapshot + collection reload, so undo can't be re-persisted away) — price
fetches, rate edits, price import, and every settings/collection commit no
longer pay the whole-book XML export (~6.6s on the reference book) per edit;
structural/business ops stay whole-book. An `os_signpost` + DEBUG over-budget
`Perf` harness wraps tree/register rebuilds, search replay, report builds and
whole-book snapshots.

**Phase 1 — structural UI.** **RD1, one register:** the account register is a
single expandable-splits table (selection opens legs inline; **Show All
Splits** expands everything — new `expandAll` row path + test); the
Basic/Auto-Split/Journal switcher is deleted; the whole-book journal is the
sidebar's **All Transactions**. Register controls moved to the window toolbar
(View ▾ · Sort ▾ · Filter · Reconcile · Edit); the window toolbar pins
[+ New ▾][⬇ Import ▾] leading so nothing hides behind » (F1); Saved Searches
folded into the search field's suggestions. **RD2, plain language** (strings
only): Repair Book · Close Financial Year · Group · Show Details ·
All Transactions · Out of balance. **RD4, entry without ceremony:** ⌘N focuses
the entry bar (⇧⌘N full editor, ⌥⌘N New Book), whose prompt says so;
QuickFill completes inline as ghost text — Tab accepts and fills transfer +
amount. Dashboard gained the **Up Next** card (F9): live rows for stale
prices, uncategorised count, stalest reconcile, and this month's statement
import, each with its action button, computed once per (revision, day).

**Phase 2 — journey accelerators.** **RD3, reconcile reimagined:** auto-clear
runs the moment a session starts ("matched N of M — review the rest" as an
inline status, not an alert); the difference remaining is the headline; rows
still needing eyes sort first and stay put while ticking (ordering test);
Finish explains itself while disabled. **One-click prices** (6.4):
`updateAllPrices()` from Book ▸ Update Prices (⌘⇧U), the Up Next card, or the
Prices toolbar, with determinate progress and a completion toast; Prices &
Quotes became the two-tab **Prices & Securities** destination (the buried
securities manager — watchlist, price targets, rename, refetch — is a
first-class tab; the Alerts card deep-links to it; the navigation subtitle
shows last-updated). **Status overlay** (6.8): one bottom-of-window surface
for progress chips, Saving…, and completion/failure toasts; quote fetches,
price updates, saves (P10: `saveWithStatus`, also used by autosave), attach
failures (F20 — previously silent `try?`s) and Revert route through it.
**Session restoration** (F18): sidebar destination incl. selected account
(per book) and dashboard period survive relaunch. **Async reports** (P3): the
heavy reports (portfolio, capital gains, lots, transactions, reconciliation)
memoise per (parameters, revision) and build behind a "Building…" placeholder
via `AsyncReport`; forecast and close-preview memoised likewise; the
categoriser sheet yields before its corpus scan so its spinner paints (P6).
Reports gained a **Recents** row (F12); a dedicated **Reports menu** with
direct jumps; ⌘⇧M Match Attachments; ⌥⌘1/2/3 destination jumps; the
attachments panel cross-links All Linked Documents (6.7).

**Phase 3 — depth.** **Financial Year Pack** (6.6b): pick a financial year
(current + three back, bounded by the book), preview the bundle, export one
PDF — Income Statement, Balance Sheet, Capital Gains, and a new **Dividends &
Franking** summary classifying income per security into franked / unfranked /
imputation credits from the Dividends account tree with a grossed-up total
(classification pinned by tests against the app's own dividend booking
shape). Dashboard **Customise** menu shows/hides panels (F10); the Goals card
surfaces the earmarking maths (total set aside; what's left unallocated —
or over-allocation, in orange — when one account funds the goals). Sweeps:
Escape closes every sheet (F19); icon-only buttons carry accessibility labels
(F21); iPad parity (F22 — web links via `openURL`, Link File… via
`fileImporter`, honest messaging where a macOS-only affordance is absent);
the register's empty state offers "Add a Transaction (⌘N)".

**The dashboard became a board, not a page (F8, user-clarified).** The first
fix (a soft scroll-edge fade) misread the finding: the requirement is that
the dashboard **never scrolls** — the priority list exists to decide what
earns the screen. The masonry `ScrollView` is gone; the dashboard deals a
fixed tile board — columns from the window width, unit rows from its height
(row height stretched so the board lands flush on the bottom edge), panels
placed in priority order into the emptiest fitting column, and anything that
doesn't fit dropped. Panels are **content-aware** (a card whose whole message
is "nothing in this period" yields its tile — Alerts keeps one unit for
"nothing needs attention"); leftover rows stretch the column's last tile;
charts stretch into their tiles; list cards cap rows with "+N more"; Recent
Activity sizes its row count from the tile it was dealt. Verified by
screenshot at full-screen (six information-dense tiles, flush) and 1150×760
(top four cards, flush): no scrolling, no clipping, live re-deal on resize.

**Accepted deviations** (recorded in the review docs' §7 status notes, and in
§10 of [architecture.md](architecture.md)): reports build after first paint
but **on the main actor** — the non-`Sendable` `Book` makes a background read
a race; going further needs a read-gate (writers wait on readers), deferred
until the memoised first-build is shown too slow in practice. Incremental
tree/journal rebuilds (P5.4/P7) stay unbuilt until the signpost harness
produces numbers demanding them.

Verified at each phase: the FeatureUI suite (386 tests / 81 suites at
completion) plus both platform builds (macOS + iOS simulator); the app was
relaunched on the reference book after every phase, with the toolbar, board
and reconcile changes confirmed by screenshot.

## Deferred-backlog closeout (18 Jul 2026)

Resolved a batch of open P0–P7 items from deferred.md, each with tests and a
GnuCash-source reference where relevant:

- **CSV export** (FR-XIO-06) — `CSVExporter` for the account tree, transactions
  (one row per split, GnuCash's "full" layout) and prices; columns mirror
  GnuCash's `csv-tree-export` / `csv-transactions-export`. File ▸ Export CSV.
- **CSV price import** (FR-XIO-03) — `CSVPriceImporter` (explicit mapping or
  header autodetection); `AppModel.importPrices` resolves symbols against the
  book's commodities. Import CSV in the Prices panel.
- **Import GnuCash scheduled transactions + budgets** (FR-IMP-03/04) — a
  second-pass parser (`GnuCashScheduledBudgetImport`) maps `<gnc:schedxaction>`
  (recurrence, template splits via the sched-xaction slot) and `<gnc:budget>`
  (per-period amounts) into the `finvestlens/*` KVP slots the app reads.
  Verified against the real Ashley Bears book (2 SX + 1 budget); live
  round-trip stays byte-clean.
- **Twelve Data + Stooq quote providers** (FR-INV-03b) — one keyed JSON, one
  keyless CSV fallback; surfaced via `QuoteProviderKind.allCases`.
- **Re-open a finished reconciliation** (FR-REC-03) — reverts the last
  statement's reconciled splits to cleared.
- **Manual attach-a-file** (FR-REG-10) — Transaction ▸ Attach File… over the
  existing `assoc_uri` document-link machinery.
- **Open Read-Only on a live lock** (FR-DAT-06) — `openReadOnly` reads without
  taking the lock; edits refused at the `editing`/`editingWholeBook`
  chokepoints; save throws. Offered on the locked-open alert.
- **Autosave-interval setting** (FR-DAT-10) — Off/1/5/10/15 min in a new General
  settings tab; the loop re-reads it live.
- **Free-text search operators** (FR-FIND-01) — `from:`/`to:` (incl. relative
  `-7d`/`-2w`/`-3m`/`-1y`), `type:`, `category:`, `has:`, and `-` negation added
  to the token grammar.
- **Window/state restoration** — reopen the last book on launch (General
  setting).
- **Help menu** — a FinvestLens Help item (⌘?) opening an in-app
  getting-started + search-grammar + keyboard-shortcut reference.
- **CSV import mapping profiles** (FR-XIO-08) — named column-mapping profiles
  (Load / Save as Profile… / Delete) persisted app-wide for repeat imports.
- **Rules: `account` trigger + set-tags / set-description actions**
  (FR-RULE-01, partial) — engine + apply-to-history + editor UI; convert-type /
  link-to-bill / allocate-to-goal still need bill/goal infra.
- **Advanced Portfolio: Money In / Money Out / Income / rate-of-return columns**
  (FR-RPT-02) — from the lot engine's proceeds/cost-basis, plus an **Income**
  column: cash dividends/interest attributed by summing income-account splits in
  every transaction that touches the security account (GnuCash's
  `advanced-portfolio.scm` money-in model), FX-converted on the posting date and
  deduped per transaction. Income folds into total return over money-in.
- **Scheduled-split formulas with variables** (FR-SCH-02) — a `ScheduledSplit`
  can carry a GnuCash credit/debit **formula** (e.g. `interest`, `pay - interest`)
  instead of a fixed amount; `AmountExpression` evaluates it against named
  variables prompted at post time. Imported from GnuCash's SX formula slots and
  surfaced in the Add-Scheduled sheet + the Enter-Due-Transactions prompt.
- **QIF splits + investment actions, OFX investment statements** (FR-XIO-01/02) —
  `StagedTransaction` grew optional `investment` detail and `splits`. The QIF
  parser reads `!Type:Invst` records (action `N`, security `Y`, price `I`,
  quantity `Q`, commission `O`) and `S`/`E`/`$` split legs; the OFX parser reads
  `<BUYSTOCK>`/`<SELLSTOCK>`/`<BUYMF>`/`<SELLMF>`/`<INCOME>`/`<REINVEST>` blocks.
  The importer routes investment rows to the Stock Assistant — the review sheet
  matches each to a security account, picks a settlement (and dividend income)
  account, and creates the stock transaction — while split cash rows post one leg
  per category. Investment rows never reach the cash matcher.
- **Billable time & mileage** (FR-PLAN-14) — a Business ▸ Time & Mileage panel
  logs hours or distance against a customer (quantity × rate, optional job +
  income account); unbilled entries gather onto a customer invoice (one line
  each, reusing the invoice machinery) and are marked billed. A KVP-backed
  collection (`finvestlens/billableEntries`) that round-trips through save/reload.
- **Legacy reports → PDF export** (FR-RPT-05) — the seven interactive reports
  (Transactions, Reconciliation, Forecast, Portfolio, Investment Lots, Price
  Scatter, Capital Gains) each gain a **PDF** toolbar button that builds a
  printable `ReportDocument` from the report's live data and exports it through
  the same paginated statement path the scaffold reports use. The interactive
  views (with their charts) are kept deliberately; only the PDF surface was the
  actionable gap.
- **Rules: allocate-to-goal action** (FR-RULE-01) — a rule can now earmark a
  matched transaction's amount to a savings goal (`FR-GOAL-01`); Apply-to-History
  previews the allocation and commits the aggregated goal deltas as one change.
  Leaves only convert-type and link-to-bill on the rules-action tail.
- **Smart Import: create a transaction from an unmatched invoice** (FR-AI-07) —
  when an analysed invoice has no matching register transaction, the review row
  now offers *Create Transaction…* with a funding-account picker (bank / cash /
  asset / credit / liability). The new transaction pays the total from that
  account, split across each line item's suggested category (line-sum residual
  posted as an adjustment), and the PDF is linked to it.
- **Savings goals / piggy banks** (FR-GOAL-01) — named targets that earmark part
  of an asset account (Firefly III's piggy banks): target amount + optional date
  + group, add/withdraw money (a read-model, no transaction posted), progress
  bars, and completion. Book-menu Savings Goals panel; stored as one JSON
  collection in a book KVP slot (`finvestlens/savingsGoals`), so each change is
  one undoable whole-book edit and it round-trips through save/reload.
- **Check printing** (FR-REG-11) — Transaction ▸ Print Check… draws a check
  for the selected transaction: the outflow from a bank/cash/asset account sets
  the amount and the account, the description is the payee, and the amount is
  spelled out on the legal line (`AmountInWords`, GnuCash's `numeric_to_words`).
  Rendered in the conventional US personal-check layout and saved as a PDF.
- **Business: Australian Tax Invoice layout** (FR-BUS-03) — a second printable
  layout on the invoice PDF (GnuCash `taxinvoice.scm`): the ATO-required "Tax
  Invoice" title, the seller's **ABN** in the header, a per-line **GST Rate**
  column, GST-labelled totals (Subtotal excl GST / GST / Total inc GST), and the
  "Total price includes GST of $X" statement. Chosen from the invoice's
  Save PDF… menu alongside the standard layout.
- **Business: Vendor / Employee / Job summary reports** (FR-BUS) — three new
  business reports joining Customer Summary + Receivable/Payable Aging, one row
  per party (charged / paid / outstanding over its posted documents, most-charged
  first), the shared shape behind GnuCash's per-owner reports. Book-wide, as-of,
  PDF-exportable through the report scaffold.
- **Loan amortization assistant** (FR-SCH-04) — `LoanCalculator.scheduledPayment`
  builds a GnuCash Mortgage/Loan-style scheduled transaction: fixed payment out
  of the funding account, split into a variable **interest** leg (`FR-SCH-02`
  formula, read from the schedule) and the remaining **principal**. Wired into
  the Loan Calculator view via a "Create Scheduled Payment…" sheet that picks the
  three accounts.
- **CI** (NFR-08) — `.github/workflows/ci.yml`: a matrix job builds + tests the
  seven core packages and an SPDX-header gate on every push/PR; the app +
  Intelligence build job rode along `continue-on-error` until a hosted
  macOS-26 / Xcode-26 runner existed. *(Resolved 26 Jul 2026: GitHub ships
  `macos-26` runners — all ten packages test there and the unsigned app build,
  both platforms, is required.)*

Every code item above ships with unit tests (or, for the GnuCash SX/budget
import, a real-book verification); each package suite and the full app build
(`CODE_SIGNING_ALLOWED=NO`) are green. The remaining deferred items are mostly
externally blocked (Apple developer-portal provisioning, real NAS/SMB
hardware, a physical iOS device, human translators) or deliberate
divergences/non-goals — see deferred.md.

## Platform enablement — extension targets & capabilities (18 Jul 2026)

Closed the deferred.md §3 "needs a target / entitlement" gaps: the targets,
entitlements, and feeding code, then **provisioned, signed and verified working**
end-to-end (iCloud, App Group, both extensions) under team *Hello Tham Pty. Ltd.*
(`RPL5R637DS`).

**Bundle-ID change.** `com.hellotham.finvestlens` turned out to be held by an
inaccessible Apple team, so its explicit App ID (which capabilities require)
couldn't be registered — signing failed the moment entitlements were added. The
app's identity moved to `com.hellotham.finvestlensapp` (extensions become
`…finvestlensapp.FinvestLensWidgets` / `.FinvestLensQuickLook`, App Group
`group.com.hellotham.finvestlensapp`, iCloud `iCloud.com.hellotham.finvestlensapp`);
the **`.finvestlens` file extension / document UTI is unchanged**. Provisioning
was staged (app capabilities first, then the two extension targets) to isolate
signing risk. Steps captured in [provisioning.md](provisioning.md).

- **App entitlements** — new `finvestlens.entitlements` (wired via
  `CODE_SIGN_ENTITLEMENTS` on both app configs): the App Group
  `group.com.hellotham.finvestlensapp` and the iCloud CloudDocuments container
  `iCloud.com.hellotham.finvestlensapp` (FR-PLT-02). `Info.plist` gained
  `NSUbiquitousContainers` so the book surfaces as a "FinvestLens" folder in
  iCloud Drive. App Sandbox stays off (the sibling `.lock` needs it off).
- **FinvestLensShared** — a Foundation-only leaf package: the App Group helper
  (`SharedAppGroup`) + the `WidgetSnapshot` the app publishes for its
  extensions. Deliberately dependency-free so a memory-limited extension links
  it without pulling Engine/GRDB/SwiftUI. Unit-tested.
- **Snapshot pipeline** — `AppModel.publishWidgetData()` builds the snapshot
  from the **live in-memory book** (never re-reading the 56 MB document) on
  save / open / close, writes it to the App Group container, and reloads widget
  timelines. `IntentSupport.snapshot()` does the same out-of-process (for
  intents) by reading the last book.
- **FinvestLensWidgets** — a WidgetKit app-extension target with Net Worth and
  Alerts widgets (small/medium), reading only the snapshot (FR-PLT-03).
- **FinvestLensQuickLook** — a Quick Look preview extension: a
  `QLPreviewingController` that reads the previewed `.finvestlens` file with
  read-only system SQLite3 (no GRDB) and shows headline counts (accounts /
  transactions / commodities / prices) (FR-PLT-03).
- **Local notifications** — `AlertNotificationScheduler` delivers the alerts
  engine as `UNUserNotificationCenter` local notifications (FR-PLAN-05), deduped
  by each alert's stable id, warning/critical only; authorization requested once
  at launch. (Remote/APNs push stays a non-goal — FinvestLens is local-first,
  with no server to originate a push.)

The two extension targets were registered in the modern (objectVersion-77,
synchronized-group) `project.pbxproj` by scripted, cross-referenced insertion;
each step was validated with `plutil -lint` + `xcodebuild -list`, and the app
scheme builds and embeds both `.appex` bundles
(`xcodebuild … CODE_SIGNING_ALLOWED=NO`). The `FinvestLensShared` package is
`swift build`/`swift test` green.

## Release 1.0 (P0–P6)

The engine, native `.finvestlens` document + locking, GnuCash import/export,
core UX, everyday finance (reconcile / scheduled / budgets / reports / bank
import / rules / search), investments + multi-currency + quotes, and
sync / dashboard / alerts / lock — with undo/redo, save-on-quit, and a full
menu bar after the usability + HIG passes. Shipped 13 July 2026.

## Functional deficits resolved (P2–P5)

Items that were in scope for a completed phase but were initially deferred or
partial, since implemented:

| Item | FR | Origin |
|---|---|---|
| Tags (model + editor + `tag:` search) | FR-TAG-01 | P2 |
| Operator search language | FR-FIND-01 | P4 |
| Account codes + renumber | FR-COA | P2 |
| Register styles (journal / general ledger) | FR-REG-01 | P2 |
| Transaction Report | FR-RPT-04 | P4 |
| Report PDF export | FR-RPT | P4 |
| Saved searches | FR-FIND-01 | P4 |
| Merchant cleanup + heuristic categorisation | FR-RULE-03 | P4 |
| Default taxonomy / starter chart | FR-COA-03 | P4 |
| Onboarding assistant | FR-PLAN-09 | P4 |
| Bill reminders + Financial Calendar + matching | FR-PLAN-01, FR-BILL-01 | P4 |
| Budget rollover / envelope | FR-BUD-02 | P4 |
| Auto-budget replenish / zero-based | FR-BUD-03, FR-PLAN-04 | P4 |
| Return-of-capital action | FR-INV-04 | P5 |
| Investment Lots + Price Scatter + rate of return | FR-RPT-02 | P5 |
| Stock splits | FR-INV-04 | P5 |
| Security Editor | FR-INV-07 | P5 |
| Watch lists | FR-PLAN-07 | P5 |
| Trading accounts (multi-currency FX balancing) | FR-CUR, FR-REG-07 | P5 |
| Scheduled quote auto-refresh | FR-INV-03 | P5 |
| Rules apply-to-historical + preview | FR-RULE-02 | P5 |
| What-if scenarios on cash flow | FR-PLAN-03 | P5 |
| UTI / document-type registration | FR-PLT-04 | P1 |

## GnuCash round-trip fidelity (14 Jul 2026)

Deep round-trip on a real 8.5 MB book (560 accounts, 46,578 txns, 102,706
prices) is **clean** — full graph + balances identical, double export
byte-identical. Found & fixed: template-transactions ROOT hijacked the book
(orphaning every real account); price/amount precision loss (exporter rounded
to currency SCU; now exact rationals with continued-fraction recovery for FX
cross-rates); book GUID not re-imported. Re-runnable harness:
`FL_ROUNDTRIP_FILE=… swift test --filter LiveFileRoundTripTests`.

**KVP (slot) fidelity.** All slots on book/account/transaction/split are
preserved verbatim through import/export (nested frames, lists, gdate/timespec,
guid, numeric, integer); `notes` is lifted into `Account.notes`/
`Transaction.notes`. Verified on the real book (18,646 notes, 3,944 online_id,
colours, reconcile-info) — round-trip clean including KVP equality.

**Commodity fidelity.** `Commodity` gained `exchangeCode` / `getQuotes` /
`quoteSource` / `quoteTimezone` / `kvp` (identity stays namespace+mnemonic;
backward-compatible Codable + sqlite v2 migration), so `cmdty:xcode`, quote
config, and `cmdty:slots` (`user_symbol`) round-trip. The live harness compares
the export against the **original** file's inventory (slot-key multiset, entity
+ cmdty element counts) — clean on the real book.

**Check & Repair** (offered after import and in the Book menu) removes empty
transactions, houses orphan splits, and posts imbalances — so exports are
cleaner than the source. GnuCash **account colours** render as Finder-tag-style
dots in the sidebar and are editable with a native colour picker.

## GnuCash parity audit — accounts & transactions (15 Jul 2026)

Audited the register and account functions against a real GnuCash 5.x running
the same book, menu by menu. Three **bugs** came out and are fixed
(`EditFidelityTests` pins each; every one was verified to fail with its fix
reverted):

| Bug | Was | Now |
|---|---|---|
| Editing a transaction destroyed share counts and split memos | `EditableSplit` carried only account + amount, so `commit()` rebuilt every split with `quantity: nil` (→ defaults to value) and `memo: ""`. Re-saving an unchanged 100-share/$1,000 buy left **1000 shares**, memo gone. Balance checks can't see it: the *values* still balance. | The editor row carries `quantity`/`memo` through untouched; `asInput` is the single exit point. Verified in the GUI: the 11,600-share AGL buy re-saves with 11,600 shares and Net Worth unmoved. |
| Voided splits still moved the register's running balance | `Book.balance` excludes voided (`Book.matches`), `refreshRegister` did not — so the register's last balance disagreed with the sidebar and every report. | The row still shows with its amount and `v`; it no longer moves the balance. |
| No Unvoid, and the R column silently un-voided | `cycleReconcileState`'s `default` mapped voided → `n`, one split at a time. | `unvoidTransaction`/`isVoided` added (context menu shows Void or Unvoid); the cycle leaves voided **and** frozen alone. |

A note on auditing: five rows of the original gap list were wrong, all
overstating the gap (a hidden-account toggle that existed, an account-tree
filter already written for Find, Journal-style Edit that was present, etc.).
The lesson: a row here is a claim about code and ages like one.

**Data-integrity bug found while auditing (15 Jul 2026):**

| Bug | Was | Now |
|---|---|---|
| Editing a transaction silently un-reconciled it | `updateTransaction` rebuilt every split from `SplitInput`, which carried only account, value, quantity and memo. Everything else came back as a constructor default: `reconcileState` reset to `n`, `reconcileDate`/KVP dropped, `action` lost, the split's guid regenerated. Retyping a description was enough. 34,939 of 46,553 transactions have a reconciled/cleared split, so the status-bar Reconciled balance — which matches GnuCash to the cent — would have walked down as transactions were edited. The values still balanced, so nothing downstream could see it. | The save re-attaches to the split each row came from, keyed by a `splitID` the row carries; what the editor never showed survives because it is never copied. The save also stopped assigning `dateEntered = datePosted` on every edit. |

**Parity gaps found and since built** (all `done`; verified against GnuCash's
own figures where possible):

- **Structured Find (⌘F)** — GnuCash's Split Search: 14 of 16 criteria, all/any,
  add/remove rows. A criterion tests a *split*, not a transaction; results roll
  up to one row per transaction but keep the matched split. Verified: 5,385
  reconciled splits on a real card account, GnuCash's own status-bar
  figure, to the cent. Account picker is a filterable collapsed tree (GnuCash's
  "Select Accounts to Match"); Closing Entries + All Accounts criteria;
  new/refine/add/delete search types replayed as a live pipeline; saved queries
  in book KVP (which GnuCash cannot do).
- **Search results are actionable** — select, Edit-in-place, Show in Register
  (opens the balance-sheet leg, not `Imbalance-*`), and multi-select bulk
  actions (set reconcile state / void / delete, each one edit + one Undo).
- **Find Account (⌘I)** — type, Return; shares the `matching` predicate with Find
  and the sidebar filter. Import Bank File moved to ⌥⌘I.
- **Register Sort By / Filter By** — Sort menu (Standard/Date/Entry/Number/
  Amount/Description/Memo + reverse) and Filter sheet (date range + 5 reconcile
  statuses), mirroring GnuCash's View menu, persisted per account in
  UserDefaults, click-to-sort headers. The balance is computed once in canonical
  order, then filtered, then sorted (both display-only). Verified on a card account
  against GnuCash: identical rows, order and balances (238,358.52 → 294,057.07).
- **Double-line mode** — editor Notes field, per-split memo + action, and View ▸
  Double Line joining notes · memo · action under the description. 18,641/46,553
  transactions carry notes (40%), 10,876 splits a memo, 280 an action.
- **Register ops** — Cut/Copy/Paste (⇧⌘X/C/V), Go to Date (⌘G),
  Schedule-from-transaction, Auto-Split Ledger, a blank entry row at the foot
  (date, description, QuickFill, transfer, signed amount, Return), and editable
  quantity on FX/security legs with the implied rate shown. A Transaction menu
  (Edit ⌘E, Go to Other Account ⌘J, Reconcile State, Duplicate ⌘D, Add
  Reversing, Void/Unvoid, Delete ⌘⌫) via a shared `TransactionActions` view so
  the menu bar and all three context menus can't drift.
- **Account ops** — Cascade Account Properties (opt-in per property), Auto-clear
  (ported from `gnc-autoclear`), Open Subaccounts, the reconcile report; Delete
  Account asks GnuCash's question (where do postings and children go); sidebar
  filter + show-hidden toggle so `isHidden` does something.
- **Data ahead of UI** — Frozen (`f`) reachable via a Reconcile State submenu;
  Rules gained multi-trigger AND/OR, `setNotes`, groups with ordering and
  switches, tag autocomplete from `Book.allTags`. The pattern named: each was
  *implemented and tested* but had no way in, so tests passed while the feature
  did not exist.

## Reports redesign (17 Jul 2026)

The GnuCash reports audit grew into a redesign of the whole surface. The
arithmetic was already good — every report pinned to an identity (trial-balance
columns agree, the equity statement bridges two balance sheets, cash flow's
in − out equals the set's net change) and verified against the reference book —
but the *surface* had five structural problems:

1. **Detached window/modal.** Reports opened in their own window (macOS) / sheet
   (iOS); an analytics surface should live in the detail pane where the data is.
2. **Pregeneration.** Opening Reports immediately computed the default report —
   seconds of work on a 46k-transaction book before the user chose anything.
3. **Recompute-in-`body`.** Reports computed inside SwiftUI `body`, so a
   date-picker interaction recomputed a full-book report per keystroke.
4. **O(accounts × transactions) arithmetic.** Statement reports asked each
   account for its balance and every balance walked the whole book (~26M split
   visits) — the same shape as the `netWorthSeries` bug.
5. **No period vocabulary / configurations / document rendering.** Dates were
   ad-hoc; no financial-year selector, no saved configurations (despite
   FR-RPT-04), and plain `List` rendering that read like another register.

The decisions taken: Reports is an **inline** detail-pane destination (⌘R) with
"Open in New Window" as a secondary command; entering shows a **gallery** and
nothing computes until a report is chosen (`.task(id: configuration)`, never in
`body`); one parameter model (`ReportPeriod` financial-year-aware vocabulary +
Codable `ReportConfiguration` + book-KVP favourites, honouring FR-RPT-04);
**one-pass arithmetic** (`Book.balancesByAccount` gains date bounds); and a
shared **document scaffold** (header, KPI callouts, chart, `Grid` tables with
ruled totals, methodology notes, optional Apple-Intelligence commentary). It
landed across five commits:

| Item | Notes |
|---|---|
| Five new reports | Trial Balance, Equity Statement, Account Summary, Cash Flow with GnuCash semantics (in − out = net change; old projection renamed Forecast), Income & Expense charts. 31 identity tests. |
| One-pass arithmetic | Every statement report walked the book once *per account* (26M split visits). Now one walk per report: accountSummary 15.63s → 0.061s, balanceSheet 7.89s → 0.058s, trialBalance 7.62s → 0.061s, equityStatement 6.77s → 0.129s (debug). Equivalence proven old-vs-new, byte-identical. |
| Period vocabulary + favourites + defaults | `ReportPeriod` named rules resolved against the book's FY start (AUD books default to July); favourites in book KVP, replace-by-name; FY start + default period as book-scoped settings. |
| Inline surface, no pregeneration | Reports live in the detail pane (⌘R); the detached window is an explicit menu item. Nothing computes until a report is chosen; computation runs in a task with a spinner, never in `body`. |
| Document polish + AI notes | Statement reports render through `ReportDocument`: header, KPI callouts, charts, Grid tables with ruled totals, methodology notes, optional on-device commentary (`ReportNarrator`). PDF prints the same value the screen renders. Income Statement FY 2025–26 matches SQL to the cent (233,856.12 / 79,013.41). |
| Commentary live-model check | `ReportNarrator` has a live on-device test (`LiveModelTests.reportCommentary`, ~1s). It surfaced a contract drift (five notes despite a two-to-four guide) — now clamped to four. |
| Average Balance | Daily-weighted average balance per interval (min/max/gain/loss/profit), account-scoped. `FinancialReports.averageBalance` matches GnuCash's chart to zero difference across 15 monthly intervals (4 identity tests). The CY 2025 weighted average agrees across KPI and table. |
| Multicolumn statements | Period-over-period columns via a **Compare: N** stepper on Balance Sheet and Income Statement (0 = single column). Each column reuses the verified per-period computation; the scaffold gained a generic multi-column table (on screen and in PDF). Income Statement FY 2025–26 vs 2024–25 vs 2023–24 align with blanks where an account had no line. |

## Investment reports parity audit (17 Jul 2026)

Figure-verified Advanced Portfolio / Lots / Capital Gains against GnuCash
5.16's own report engine (`gnucash-cli` on an identical copy; a hand-written
saved-report config aligned the options). **Every real holding matches to the
cent** — shares, basis, value, realised, unrealised, under FIFO and average —
and the FIFO grand totals for basis and realised gain matched exactly across
~2,069 disposals spanning 46 years. Total market value and total gain match to
the cent.

| Item | Notes | Status |
|---|---|---|
| Phantom lots after an oversell | An uncovered sale discarded the deficit, so a later buy opened a fresh lot instead of covering the short — four long-exited super accounts showed holdings that don't exist. `CostBasis` now carries the shortfall: covering buys close it (zero proceeds, buy-back cost as basis, dated at the cover) and `remainingQuantity` reflects the true balance. | fixed |
| Brokerage-fee treatment | A `FeeTreatment` option (Ignore / Include in basis) on the cost-basis engine and investment reports, as a **Fees** picker. Include-in-basis matches GnuCash's default on a real holding, to the cent, for both basis and realised gain. Default stays **Ignore** (our GnuCash-"ignore"-exact baseline). *Known divergence:* this book books non-fee amounts (imputation credits, capital loss, contributions tax) as expense splits inside managed-fund transactions; GnuCash's money-in/out accounting washes them out over a closed position while our per-parcel engine subtracts them (~[redacted] realised across ~6 accounts). Matching would require adopting GnuCash's money-flow model — deferred (P8), arguably not more correct. | done |
| Average-method rounding | GnuCash rounds each sale's basis progressively; we keep full precision until the report edge — 2¢ drift on one account over 40 years. | wontfix |

## GnuCash report catalogue — build-vs-skip (17 Jul 2026)

Walked GnuCash 5.16's full report menu (65 entries) against our fifteen
`ReportKind`s. Most are already covered, a chart/register variant of something
we have, or business (deferred). **Average Balance** and **multicolumn
statements** were the two genuine net-new analytics — both built (above). The
rest is recorded so "is there parity?" has a written per-report answer:

- **Covered / alias**: Profit & Loss (= Income Statement), Investment Portfolio,
  Net Worth Bar/Line, Income/Expense Chart & Line, Cash Flow, Transaction
  Report, Reconciliation, Balance Forecast, Future Scheduled Summary, single-
  period account pies.
- **Registers cover**: General Journal, General Ledger (our register forms).
- **Marginal variants (skip)**: Cash Flow Barchart, Transaction Breakdown,
  Over-Time charts, Securities, Price.
- **With budget work**: Budget Report chart/statement variants.
- **Tax/business (defer)**: Income & GST Statement, Tax Schedule / TXF Export
  (→ P9 tax tools), IFRS weighted-average cost basis; all invoice/receipt and
  customer/vendor/employee business reports (P7 surfaces below).
- **Novelty/infra (skip)**: Day-of-Week charts, Sample reports/graphs.

## P7 Business features — GnuCash Business menu audit (17 Jul 2026)

Small-business accounting: engine, native persistence, GnuCash-XML round-trip,
and UI are **built and tested**. The reference book has no business objects, so
the engine is verified by accounting identities and GnuCash's documented
arithmetic, cross-checked by round-tripping through GnuCash 5.16.

| GnuCash menu item | Status | Where |
|---|---|---|
| Customer / Vendor / Employee data model | engine + persist | `Business.swift`; SQLite store |
| Job (under customer or vendor) | engine + persist | `Job`, `BusinessOwner.job` |
| New/Find Customer·Vendor·Employee·Job | built | Business hub (⇧⌘B), `BusinessView.swift` |
| New Invoice / Bill / Expense Voucher | built | `InvoiceEditorSheet`, `InvoiceDetailSheet` |
| Post to A/R–A/P (lots + entries) | built | `postInvoice`/`unpostInvoice`; 6 tests |
| Process Payment (apply to invoices) | built | `processPayment` (oldest-first, partial, over-payment → pre-payment lot); 3 tests |
| Sales Tax Table editor | built | `TaxTablesSheet`; `TaxTable`/`TaxTableEntry` |
| Billing Terms editor | built | `BillingTermsSheet`; `BillTerm` |
| Company / business information | built | `CompanyInfo` book-KVP + `CompanyInfoSheet` |
| Receivable/Payable Aging report | built | `aging(forOwner:)`, `agingByOwner(...)`; 2 tests |
| Customer Summary report | built | `ReportKind.customerSummary`; 1 test |
| Printable / Tax Invoice | built | `PrintableInvoice` → PDF; company header + bill-to + lines |
| GnuCash-XML round-trip of business objects | built + tested + GnuCash-verified | owners, addresses, `<act:lots>`, `<split:lot>`, business KVP slots |

**GnuCash 5.16 reads our exported file and attributes postings to their owners**
— Receivable Aging shows Acme $1,450 / Globex $2,200 and Customer Summary shows
Acme $1,500 / Globex $2,000, matching our aging engine to the cent. The earlier
"No Customer" symptom is fixed: GnuCash resolves a posting's owner via a
`gncInvoice` slot **on the transaction** plus `trans-date-due`; `postInvoice`
now writes both on the transaction (regression-tested, confirmed by re-running
GnuCash's own reports).

Business edits are undoable (they ride the whole-book GnuCash-XML snapshot) and
persist through save/reload (SQLite). Remaining P7 tails (in deferred.md): Bills
Due Reminder surface, vendor/employee/job detail reports, Australian-Tax invoice
layout, time & mileage tracking.

## Full GnuCash-source line-by-line audit (17 Jul 2026)

Audited the whole implementation against the real GnuCash C/C++ source (cloned
at `~/Repositories/gnucash-reference`) with a multi-agent sweep over the engine,
XML backend, and import; every confirmed divergence was fixed and every absent
feature implemented.

**Correctness bugs fixed** (each with a test, verified against source):
- **Frozen (`f`) splits** now count in cleared *and* reconciled balances
  (`Account.cpp:2324`) and fold into the reconcile report's reconciled funds.
- **Price lookup**: nearest-in-time (GnuCash's default `pricedb-nearest`), not
  newest-on-or-before; indirect common-currency chaining; `securityUnitValue`
  tries every quote currency; converted balances round-then-sum.
- **Business invoice arithmetic**: per-entry rounding so postings always balance
  (bug 628903); tax-inclusive back-compute; proximo cutoff + real-month clamp.
- **Auto-clear**: skip zero-amount splits; statement-date cutoff.
- **XML round-trip**: `split:reconcile-date`; list-typed KVP bare-value format.
- **Register order**: `xaccTransOrder_num_action` canonical order (numeric
  num/action, then entered/description/guid).
- **Import dedupe**: match on the OFX FITID via the split `online_id` slot
  (GnuCash's definitive match), not just the transaction number.

Stock-transaction shapes (buy/sell/dividend/reinvest/return-of-capital/split)
were audited and already match GnuCash's split structure — no change.

**Absent features implemented** (model + XML round-trip + native store + UI):
- **Amount expression parser** (`gnc-exp-parser`) — `5*3`, `10.50+2`, `(1+2)/3`.
- **SX advance-create / advance-remind days** — create/remind ahead of due.
- **Invoice discount-how** modes — `PRETAX` / `SAMETIME` / `POSTTAX`.
- **Per-period budgets** — `Budget.numPeriods` + `BudgetLine.periodAmounts`,
  unset-period reads as zero, period picker in the editor. New sqlite migrations
  `v3_billterm_cutoff`, `v3_entry_disc_how`.

**Accepted as non-gaps (documented, not fixed):**
- Currency-commodity export emits `cmdty:fraction`/`name` that GnuCash omits for
  ISO currencies. GnuCash reads it without error; round-trip byte-verified.
  Within FR-EXP-02 tolerance.
- `isBalanced` treats a sub-minor-unit residual as balanced (ADR-1 tolerance).
- Price same-date tie-break: GnuCash's is GUID-nondeterministic; ours is the
  deterministic first-inserted — strictly better.

## GnuCash menu parity — Tools / View gaps (18 Jul 2026)

A full audit of every FinvestLens menu against GnuCash's (File → Help), with
GnuCash 5.x open on the same book. The Actions / Tools / View menus (where the
functional verbs live) were read from the running app; the File / Edit /
Reports / Business menus were cross-referenced against the command tree in
`finvestlens/finvestlensApp.swift`. The audit corrected itself (three items
first read as missing — Sort By, Filter By, Go to Date — were already
implemented) and closed five real gaps. Legend: **=** parity · **+** exceeds · **≈** near · **−** gap.

**File** — New/Open/Recent (=), Save/Revert (=), Import (**+**: adds Smart PDF/AI import), Export GnuCash (=), Print via Reports (=), Properties/Settings (=), Close/Quit (=).
**Edit** — Cut/Copy/Paste (=), Find + Find Account (**+**: saved searches, tag search), Edit/Delete Account (=), Preferences/Settings (=), Tax Report Options (=, flags round-trip via `tax-related`/`tax-US`).
**View** — Toolbar/Status Bar (=), **Summary Bar** (=, added by this audit), Basic/Auto-Split/Journal ledger styles (=), Double Line (=), Sort By (=), Filter By (=), Open Subaccounts (=), Refresh (= automatic).
**Transaction** — Enter/Cancel/Duplicate (=), Delete/Void (=), Add Reversing (=), Jump to other account (=), Associate File/`assoc_uri` (=), Cut/Copy/Paste txn (≈ Duplicate covers it).
**Actions** — Transfer (=), Reconcile (=), Auto-clear (≈), Stock Split (=), View Lots (≈ cost-basis report, not a lot editor), Blank Transaction (=), Go to Date (=), Split Transaction (=), Edit Exchange Rate (≈ via Currency Transfer), Scheduled Transactions (=), Budget (**+** rollover/envelope/zero-based), Check & Repair (**+** proposes/previews/one-undo).
**Business** — Customers/Vendors/Employees (=, in the ⇧⌘B hub), Invoices/Bills/Vouchers (=), Receivable/Payable Aging (=).
**Reports** — Assets & Liabilities / Balance Sheet / Net Worth (=), Income & Expense (=), Investment/Portfolio (=), Business Aging + Customer Summary (=), Transaction Report (=), Print/PDF export (=).
**Tools** — Price Database (=), Security Editor (=), General Journal (= register style), Transaction Linked Documents (=, book-wide list), Import Map Editor (≈ our Rules), Close Book (=, Period-End Close), Loan Calculator (=), Online Banking Setup (n/a — bank-file/PDF import by design).
**Windows / Help** — single-window; Reports opens its own window (=); About + onboarding (≈, no bundled manual).

The five gaps closed by the audit:

| Item | Notes |
|---|---|
| Register summary bar | Present / Cleared / Reconciled from the engine's existing `BalanceFilter`, gated off for a mixed-commodity subtree. Matches GnuCash's status strip on a real card account to the cent, Present and Reconciled both. |
| Linked Documents list (Book menu) | Book-wide roll-up of every `assoc_uri` link, newest first, missing files flagged — the per-transaction link was only reachable one register row at a time. |
| Loan Calculator (Book menu) | Fixed-rate amortisation in the engine (pure `Decimal`), payment + totals + schedule. $300k @ 6% / 30yr → $1,798.65/mo. Totals summed from the schedule so they agree to the cent. |
| Period-End Close (Book menu) | Moves income/expense into equity as of a date, one balanced closing transaction per currency, undoable, with a per-currency preview (AUD and USD shown separately, never blended). |
| Tax Report Options (Edit menu) | Flag income/expense accounts, assign a tax code, see the schedule. Flags stored in GnuCash's exact `tax-related` / `tax-US` slots so they round-trip. |

**Intentionally not built** (rarely relevant to a personal AUD book): Import Map Editor (GnuCash's Bayesian match store — our rules engine serves the purpose), Online Banking Setup (superseded by bank-file/PDF import), and a bundled help manual. **Where FinvestLens exceeds GnuCash:** AI/PDF Smart Import, saved searches and tag search, envelope/zero-based budgets, a previewing Check & Repair with single-action undo, and the home dashboard with alerts.

**Account-scoped undo (18 Jul 2026).** `updateAccount`, `moveAccount`,
`cascadeProperties` and `setAccountTax` went through `editingWholeBook`, which
serialises the whole book (~6.6s / ~115 MB per edit on the reference book).
Added `editingAccounts([ids], named:)` — the account counterpart of the
transaction-scoped `editing` — which snapshots only the named accounts' value
fields (incl. the KVP frame carrying colour and tax slots) plus their tree slot
(parent + sibling index, restored via a new `Account.addChild(_:at:)`). A tax
toggle is now **0.067s, down from ~6.6s (~100×)**; the pre-existing account-undo
tests pass unchanged, plus three new cases (tax flag, cascade subtree,
move-restores-position).

## Apple Intelligence (13 Jul 2026)

Post-1.0 addition of the `Intelligence` package (FR-AI-01…08, Architecture §11):
PDF statement import with light reconciliation, auto-categorisation, invoice
splitting, dividend statements incl. franking credits, budget suggestion, a
forecast outlook, and Smart Import (drop multiple PDFs, each classified and
routed). Applied invoice/dividend PDFs are stored in a configurable document
folder and linked to their transaction GnuCash-style (`assoc_uri`).

Fixed along the way (pre-existing 1.0 bugs uncovered by GUI testing): File-menu
Save/Revert/Import/Export/Close Book were silently missing
(`CommandGroup(after: .saveItem)` has no anchor in a plain WindowGroup —
re-anchored to `.newItem`); bank-file import never presented its picker on macOS
(replaced the unreliable SwiftUI `.fileImporter` with NSOpenPanel, deferred out
of the view-update transaction). The `finvestlens/statement-date` slot rides
through XML export/import so dual-date duplicate detection survives a round-trip.

## Performance work (15 Jul 2026)

All measured against the reference book (46k txns / 102k prices). See
[architecture.md §10](architecture.md#10-derived-state-and-performance) for the
design.

| Was | Now | What |
|---|---|---|
| Opening a book blocked the main thread | isolated to a `DocumentLoader` global actor, returns `sending FinvestLensDocument` | Graph built off the main actor without making `Book` `Sendable`. `open`/`openBook` are `async`; the root view shows "Opening <book>…"; a second click mid-load can't open a second document. |
| `refreshAll` re-sorted every price | 0.158s → 0.041s (release) | `priceRows`/`rateRows` derived on demand behind a cache dropped in `refreshAll()`/`close()`, with a `derivedRevision` counter carrying the observation dependency. |
| `netWorthSeries` = 1.7 billion split visits | 32.329s → 0.066s (~490×, debug) | Rewritten as one pass in date order carrying a running total per account. Still identical to the cent. This *was* the "navigating to the Dashboard blocks" and "main-actor tail of an open" symptoms — an algorithm, not a threading problem. |
| Whole-book undo snapshot per edit | pre-capture, transaction- and account-scoped | Each edit captures only what it changes before changing it; no baseline held between edits, so opening a book pays nothing. Register edit 5.79s → 0.26s; account edit 6.6s → 0.067s. |
| Price lookup scanned 102k prices per call | binary-searched index, invalidated on `prices` change | Preserves the scan's exact tie-breaking (first price of the winning date). |
| `balance(of:)` walked the book per call | `balancesByAccount()` one-pass | Account tree converts each account once and rolls subtree sums up. `refreshAll` 33.7s → 0.25s. |
| Journal / General Ledger unusable on 46k | uniform `JournalRow` in a `Table`, cached | No windowing; jumps to either end instant; ⌘↑ reaches the true oldest. |

Remaining perf note: with prices lazy, the ~0.04s of every `refreshAll()` is
`rebuildAccountTree` + `runSearch`; fast enough to feel instant (subtree-only
rebuild is a P8 option if ever needed).

## Usability review (July 2026)

Resolved: File/Book menu bar (New/Open/Open Recent/Import GnuCash/Export/Close/
Revert + every tool panel with shortcuts), lean toolbar with a Tools menu,
GnuCash import UI (File menu + welcome screen), price-target editor, account
re-parenting, stale-lock Break-Lock recovery, iCloud conflict-version resolution
in the external-change banner, welcome recents.

**iOS documents.** New/Open panels are AppKit on macOS; iOS uses `fileImporter`.
Verified in the simulator: welcome → Open… → Files picker → book opens and
renders. iOS books are created in the app's Documents directory (visible in
Files under "On My iPhone ▸ finvestlens") with non-colliding naming. Opening a
book from iCloud Drive / Files works: coordinated reads materialise dataless
files; security-scoped access held for the session with bookmark-backed recents;
lockless fallback where the sibling `.lock` can't be created (verified Box Drive
+ iCloud Drive incl. an evicted file). Recents drop entries whose file is gone.
GnuCash/bank-file import and export are intentionally macOS/iPadOS-only
(`FR-PLT-06`, PRD §5.15).

## HIG review (13 Jul 2026)

Fixed: undo/redo (pre-capture, Edit menu integrated), save-on-quit via
`NSApplicationDelegate` (⌘Q never loses data, releases the lock), Reports in its
own window, window titled with document proxy icon, Esc/⌘. cancels sheets
(+ Return confirms reconcile), toolbar help tags, Title Case buttons, undo
action names ("Undo Delete Transaction", etc.).

## 1.0 PRD audit (13 Jul 2026)

Full code review against the PRD before tagging 1.0. Fixed: hardcoded AUD in the
transaction editor (now derives the transaction currency from the splits'
accounts), silent save failures on book-switch/quit/conflict resolution (now
surfaced, quit cancels on failure), transaction-editor errors no longer silently
dismissed, lock heartbeat timer (idle books no longer go stale-breakable),
autosave (5-minute interval), stale importer/OFX comments.

## P12 — Modes, sidebar and tabs (15 Aug 2026)

The navigation redesign, all seven sub-phases. Design and rejected alternatives:
[navigation-design.md](navigation-design.md); requirements `FR-NAV-01…12`;
schedule and exit criteria: [plan.md](plan.md) §13d.

**N1 — Modes.** `AppMode`: Overview · Accounts · Investments · Reports ·
Business · Planning · Records, on ⌘1…⌘7, each its own `ToolbarItem(id:)` so the
five-mode default is arranged through the *system's* toolbar customisation
rather than a bespoke pane. Toggles, not buttons: the control's job is
orientation, so VoiceOver has to be able to say which one is on. Each mode owns
its own selection and open tabs. The flat `SidebarSelection` became a view onto
per-mode state, so the `didSet` that drove the register became one explicit
funnel reached identically by a mode switch, a selection, a session restore and
a book close.

**N2 — One sidebar per mode.** Thirteen destinations above 565 accounts became
one kind of thing per mode, two levels deep. Grouping that leads nowhere is a
`Section` header, because a selectable row has to lead somewhere. The
filter-erases-navigation bug is gone rather than fixed: there is nothing left
for a filter to erase. The audit log stopped being a modal sheet — it is a
collection the book keeps. Accounts keeps its four-level tree, the exception the
guidance grants.

**N3 — Tabs.** A tabbed interface in the detail pane, not window tabs: a window
tab carries a whole window, so three open registers would mean three copies of
the account tree. GnuCash's rules throughout — never a duplicate
(`gnc-main-window.cpp:3291`), a new tab is deliberate
(`gnc-plugin-page-account-tree.cpp:987`), a placeholder opens nothing. The home
tab is derived, not stored, so it cannot be closed or lost to a stale desk
state. ⌥⌘W closes a tab; ⌘W stays the window's.

**N4 — Overview as a board of views.** Views with their cards nested beneath, so
the sidebar doubles as the card index. Selecting never switches mode — the door
out is a button that says where it goes. A card selection carries the view it
was picked from, because Net Worth is on Mix *and* on Accounts and two rows with
one tag make selection ambiguous. A favourite is a saved custom view; there is
no second concept. Business contributes no card yet, and its empty view says so.

**N5 — One period.** The dashboard kept a period under its own key while reports
opened on the book's default: two answers to one question, with nothing on
screen saying so. `AppModel.period` is now the only one, in the toolbar, seeding
what a fresh report opens on. `nil` means "the book's default" rather than a
copy, so changing the default in Settings takes effect immediately.

**N6 — All Transactions repaired, and the design corrected.** Checked against
GnuCash before building: `split-register-layout.c:584-620` gives
`GENERAL_JOURNAL` nine columns and every cursor, so forcing journal style was
wrong (fixed); `gnc-split-reg.c:894` says "no anchoring split", so dropping
Transfer from the ⇥ order was **right** and stays; `split-register-model.c:1650`
fills the total cell from the transaction, so a blank amount was wrong (fixed).
A whole-book row now takes reconcile, accounts and total from the transaction.

**N7 — Sidebar sorting.** Six orders, applied per level. The manual order lives
in the account's kvp (`finvestlens-sidebar-order`) so it round-trips; GnuCash
ignores it, which is the right failure mode. "First Transaction" is derived and
says so. Dragging is offered only under manual order.

**Deviations, recorded rather than hidden.** The sort control ships for Accounts
only — balance, code and first-transaction are facts about an account. ⌘-click
is not bound to "open in new tab": in a macOS `List` it is the extend-selection
modifier. **Sidebar dragging was off** at this point in the phase: `reorderAccount` and
the kvp slot existed and were tested, but with no between-siblings drop target
every drag re-parented, so a gesture that looked like sorting was quietly
editing the chart of accounts. That was fixed later in the same phase — see
"Both halves of the sidebar drag are built" below, which is the current state.
The two paragraphs contradicted each other for a fortnight.

**What the review caught (15 Aug 2026).** A ten-angle review of the phase found
fourteen real defects; the ones that mattered are fixed and pinned by test:
`openTab` crashed on a restored index that outran its tab list; ⌘T and the tab
strip's + button were no-ops in every state (they asked for a duplicate of what
was showing, which the never-a-duplicate rule refuses); Overview's home was
`.dashboard`, a destination its own sidebar carries no row for, so nothing was
selected at launch and clicking Mix opened a second tab of the same board;
`.auditLog` encoded but had no decode arm, so that tab vanished on every reopen;
restoring filtered dead tabs without adjusting the index, landing on the tab next
to the one the user left; the whole-book Account/R/Amount columns were still
gated shut by `isHeadingOnly`, so N6's work did not render in Basic Ledger;
Reports showed two period selectors that disagreed; `close()` from the Reports
gallery persisted the wrong mode; every rule in a group shared one SwiftUI
identity; a held-and-watched security produced two rows with one tag; and
`reorderAccount` took a whole-book undo snapshot.

**And the rest of them.** Deleting an account, budget, goal or rule group now
closes its tab — the prune is in the edit funnel, so every delete gets it rather
than the one that used to. The desk-state codec is one table read both ways,
with a test that walks every case through both halves, so `.auditLog`'s drift
cannot recur. The iOS register got N6: it forced journal style and wrote empty
reconcile/transfer/amount, so All Transactions differed between macOS and iPad.
Sorting is offered in every mode, not only Accounts — name order over a mode's
*instances*, never its headings. A saved Overview view captures the cards on the
board rather than copying the view it was saved from. Instance names come from
one place, so a sidebar row and its own tab cannot disagree. And the sidebar
tree, the sort comparators' account lookups, the security index and the
custom-view decode are memoised on the book revision: the tree was pruned and
re-sorted on every keystroke, and the custom-view JSON was re-decoded inside a
`GeometryReader`, once per resize frame.

**Both halves of the sidebar drag are built.** `OutlineGroup` has no move
affordance, which is why the reorder half had no drop target and the only drag
that shipped re-parented; the tree is a recursive `AccountBranch` now. The two
operations are told apart by a `DropDelegate`, which reports the pointer's
position *during* the hover — `.dropDestination` hands over a location only once
the drop has happened, which is too late to draw anything. The top and bottom
quarters of a row reorder and the middle half re-parents, drawn as an insertion
line and a filled row, and the boundaries fall on the safe side: a quarter of
the way in is still the re-parent zone, so a reorder takes deliberate aim.

`reorderAccount` was measuring positions in `parent.children` order while
writing `sidebarOrder` and leaving `parent.children` untouched — right exactly
once, and wrong for every reorder after the first. It works in display order
now, which is what both the drag and the menu mean.

**Move Up and Move Down** are in the row's menu whenever manual order is on.
Dragging is the pointer's way to reorder; under VoiceOver a drag is not a
gesture at all, and `.onMove`'s edit mode was never a route either.

## FX in the register, and four investment defects (15 Aug 2026)

### FX entry moved to the register (`FR-CUR-02`, `FR-REG-07`)

The machinery existed on three surfaces and none of them was the register row
where editing now happens: the converter behind a collapsed "Foreign Amount"
disclosure in the editor sheet, the guided **Currency Transfer** sheet, and the
automatic restructure after a document match. The register could only *show*
FX — its Quantity cell appeared when a transaction was already foreign, and
nothing in the register could make it so.

Verified against the GnuCash source, not its documentation:

- `libgnucash/engine/Split.h:251-265` — `xaccSplitSetAmount` is "the amount of
  the split in the **account's** commodity", `xaccSplitSetValue` "the value of
  this split in the **transaction's** commodity". Both currencies live on the
  split; the ratio is the rate (`xaccSplitGetSharePrice`, `:285`).
- `libgnucash/engine/Transaction.cpp:983-986` — `xaccTransUseTradingAccounts`
  just returns `qof_book_use_trading_accounts`. Trading accounts are an
  **optional book flag** that makes currency gain/loss explicit
  (`Scrub.cpp:715+`); with it off, `gnc_transaction_balance_no_trading` handles
  the transaction (`Scrub.cpp:864`). They are **not** how the two amounts are
  recorded — a correction to the assumption that a foreign purchase needs FX
  clearing accounts.
- `gnucash/register/ledger-core/split-register.h:211` — the register carries one
  `RATE_CELL`, not a per-split currency picker, and asks for a rate only when
  the transfer account's commodity differs from the transaction currency
  (`split-register-control.cpp:1436`), requiring the row to be expanded first
  (`:1487-1490`).

`Engine.Split` already matched this (`value` / `quantity`), so **no model change
was needed**. What was added is the way in:

- `TransactionEditField.currency` and `.rate`, drawn on the tags line — Currency
  under Date beside Tags, Rate under Amount. Reachable only when the row is
  disclosed, as GnuCash requires.
- `TransactionDraft.setCurrency(_:text:)` **moves** the figures rather than
  redenominating them: naming MYR on an AUD 600 transaction puts 600 into each
  leg's `quantity` and clears the value for the foreign figure. Clearing the
  currency puts them back.
- `TransactionDraft.applyRate(_:rounding:)` fills every foreign leg's value from
  its local amount, leaving legs that already carry one alone.
- `impliedRate` is derived from the splits, never stored, so it cannot disagree
  with the amounts.
- A stored rate pre-fills on naming the currency; an unresolvable code blocks the
  save with a message rather than being dropped.
- `RegisterRow.foreignCurrencyCode` marks rows struck in another currency;
  `AppModel.rate(ofTransaction:)` reads the rate back off the splits.

### Document currency: ask, showing the evidence

`currencyHint(in:)` returned the first token found anywhere and refused `$`, `¥`
and `£` outright, so a US or Singapore invoice yielded `nil` — which the caller
read as "domestic". Four further refusals inside `restructureAsForeign` were
silent. Together, the whole of the reported "sporadic" FX on attachment
matching.

- `currencyCandidates(in:)` returns every currency the text could name, with
  per-side letter boundaries (`S$` was matching inside `US$`; `RM` inside
  `FIRM`). Qualified dollars resolve to one; a bare `$` returns its six.
- `restructureAsForeign` returns `ForeignRestructureOutcome` —
  `.restructured` / `.notForeign` / `.tooComplex` / `.nearParity(implied:)` —
  and `adoptDocument` passes it back.
- The editor's `offerConversion(_:outcome:)` opens the converter with the
  amounts, the implied rate and the document's own currency preselected, above a
  sentence saying why the app declined.

### Investment defects

1. **Exchange suffix from the namespace** (`FR-INV-38`). GnuCash keeps the
   exchange in the namespace and the bare ticker in the mnemonic; providers want
   Yahoo's `WMX.AX`. Measured 15 Aug 2026: `WMX` returns an NYSE **index** stub,
   `currency: null`, `regularMarketPrice: 0.0`; `WMX.AX` returns WAM Income
   Maximiser on the ASX at 1.685. Both are HTTP 200, which is why it failed
   silently — 20 of the reference book's 49 ASX securities were in the bare form
   and none had ever been priced. `QuoteService.canonicalTicker(for:)` supplies
   the suffix from exchange namespaces only; `Bond`, `Super` and `FIIG` say what
   a security *is* and are left alone.
2. **A zero is not a price.** `YahooQuoteProvider.parseLatest` guarded only
   against `nil`, so the stub above would have recorded a real security at 0.00
   from a successful-looking fetch. Now refused, naming the symbol.
3. **An ISIN sent to a ticker provider** fails before the request with the
   reason, instead of a generic "no data" indistinguishable from a delisted
   security.
4. **Bond price scale** (`FR-INV-31`). The FIIG provider divided by 100 on the
   evidence that every bond row in the reference book was `1.0` — that sample was
   the hand-entered rows. The *purchases* disagree: ten of the eleven bonds were
   bought at 500 or 1,000 units and ~100.5 per unit ($100 parcels, priced per
   $100), one at 60,000 units and 0.8268 (dollars of face, par-relative). Both
   conventions, one book; dividing valued the ten at a hundredth of their worth.
   The provider now passes FIIG's number through as published and
   `AppModel.normalisedParPercent(_:from:)` picks the scale nearest what that
   security has actually cost, from its own postings.
5. **FIIG history exists** and is now fetched. `bondHistory` is `null` on all 703
   index records, which had been read as "no history"; the series lives at
   `/api/instruments/bonds/{georgiaId}/history` — 1,181 daily rows from
   2021-10-27 for the bond measured. An ISIN 404s there, so a history fetch
   resolves the id from the index first. `QuoteProviderKind.fiig.supportsHistory`
   is now `true`.
6. **Get Info** on a security's context menu (`SecurityDetailView` carries the
   name, ticker override, ISIN and per-security provider). Clicking the row was
   the only route, and a row that navigates on click gives no sign that it will.
7. **Bulk company data** (`FR-INV-39`). `fetchAllFundamentals(force:)` walks
   every security a provider covers, sequentially (the same rate-limited hosts),
   reporting progress and naming what came back empty. Reachable from
   Investments ▸ More. Per-security Fetch buttons had been the only route.

### Not done, and why

`FR0014014MD4` (BNP 7.00% 02Jun31c) cannot be priced by FIIG: its index carries
703 bonds including **eight** BNP Paribas lines (3.695% Feb-28, BBSW+1.50%
Feb-28, 4.80% Aug-31, BBSW+1.55% Dec-31, 4.875% Oct-33, 5.83% Aug-34,
BBSW+2.15% Aug-34, 6.198% Dec-36) and not this one. The security's description
follows FIIG's own naming, so it came from there and has since left the
tradeable index. No code can conjure the price; the book-side remedy (mark it
hand-valued, or No Longer Trading if it was called) is the owner's decision.

## Card fees, foreign accounts and bulk company data (16 Aug 2026)

Three follow-ons from the ANZ VISA repair, each found by running the tool over
the real book rather than by reading it.

**The fee gets its own leg.** A card states its international transaction fee
inside the charge, so a foreign purchase arrives as one figure that is really
two — the goods, and ~3.4% for having bought them abroad. Merged, every foreign
purchase overstates its category and the year's card fees cannot be reported.
`AppModel.splitCardFee(transactionID:feeLocal:feeAccountID:apply:)` moves it,
in both units: the new leg's `quantity` is the fee as charged and its `value`
is that fee at the transaction's own rate, so the transaction still balances in
the currency it was struck in and the card leg keeps the whole charge — which
is what the statement says left the account. `finlab foreign --fee-account`
drives it. Applied to the reference book: **54 fees, $118.31, into
`Expenses:Fees:Bank`**.

**Not every foreign row is a purchase.** Eight of the same book's were cash
moved into an account *already denominated* in MYR, and they had arrived with
the AUD figure copied into both fields — a 249.30 MYR deposit recorded as 91.69
MYR, leaving that account's balance a third of the truth. The transaction's own
currency was never wrong here (the card was charged in AUD); one `quantity`
was. `alignForeignAccountQuantity(…)` corrects it and records the rate the bank
actually gave.

**Company data in bulk** (`FR-INV-39`). `finlab fundamentals` drives the same
`fetchAllFundamentals` as Investments ▸ More, so a headless fill and an in-app
one produce the same book. Running it on the reference book found two things
reading about it would not have:

- **Bonds were asking the wrong service.** Their identifier is an ISIN, which
  every ticker provider answers "no data" to, so all fifteen came back empty.
  `fundamentalsSource(for:)` now routes an ISIN-identified security to FIIG —
  which is a different act from `fiigCandidates`' refusal to auto-apply a
  provider: that one *persists* a choice for prices, where being wrong writes a
  wrong number, while this chooses where to ask for text, once.
- **Yahoo throttles a bulk run.** The first pass filled 29 of 85 and the rest
  returned empty, with `getcrumb` itself answering "Too Many Requests" — and
  those empties were being recorded as "this security has no company data",
  which is the opposite fact. `looksRateLimited(_:)` tells a wall from an
  absence, and a refused security is waited out and retried once with a growing
  pause. Only the securities that hit the wall pay for it.

Unlisted super and managed-fund units (HPA, MLC, WSSP, AT&T, Heritage, BT) have
no ticker and no provider covers them; they stay hand-valued by nature, not by
defect.

### Two lessons the dry runs taught

- **A dry run must share the write's code path.** The fee counter was written
  separately and promised "62 would move" when 54 could; `splitCardFee` now
  takes `apply:` and answers the same question both ways.
- **Converted rows must stay in the scan, flagged.** Filtering them out was the
  first design, and it meant a second run over an already-converted book found
  nothing to do — so the fees would never have come out. `NarrativeFX` carries
  `alreadyForeign`, and `localAmount` reads the split's **quantity**, because on
  a converted transaction `value` is the foreign figure and reading it made the
  fee's rate a hundredfold out.

## Securities nobody quotes (16 Aug 2026)

`FR-INV-40`. A bulk company-data run over the reference book asked 85
securities and 22 of them could never answer: retail superannuation and
managed-fund options — AMP, AT&T, BT, HPA, Heritage, Mercer, MLC, WSSP,
Westpac — which have no ticker and no public feed. Their unit price arrives on
a quarterly statement.

**Recorded, not inferred.** `AppModel.unquotedSecurities` is a per-security
record in the book's KVP, beside `delistedSecurities` and deliberately *not*
part of it: a super option is still trading and its price still moves, so
filing it under "no longer trading" would freeze its last price as final and
take it out of the valuation-confidence figures it belongs in. Both stop the
fetching; only one of them is true.

`isUnquoted(_:)` / `setUnquoted(_:_:)` drive it, `fetchableSecurities` and
`fundamentalsCoveredSecurities` both exclude it, the Investments row context
menu carries **No Public Price** beside No Longer Trading, and
`finlab prices --set-unquoted` / `--set-quoted` set it in bulk.

Applied to the reference book: the 22 `SECURITY:Super` commodities. A bulk
company-data run now considers **63 securities instead of 85** and stops
provoking Yahoo's rate limiter, which is what the 22 hopeless requests per run
were doing. Coverage after: **57 of 63**, the remainder being five bonds
outside FIIG'"'"'s index and one unlisted fund (WAMFF — which *is* priced, 369
Yahoo rows current to 14 Aug, and simply has no company text).

WAMFF is the boundary case worth recording: it failed the profile fetch like
the super options did, but it has a live price series, so it is **not** marked.
The evidence that settles it is the price table, not the fund'"'"'s name.

## Price provenance: one provider default, and prices that cannot lie (16 Aug 2026)

A user question — "I thought we implemented preferred price provider in
settings with a fallback to Yahoo, was this not done?" — turned out to be four
defects, found by reading the reference book's own price table rather than the
code.

**The book said what happened.** EODHD priced 30 securities a day to 11 Aug;
from the 12th Yahoo took over and priced 21. Eleven holdings silently stopped
being valued (AMP, COL, IAG, LLC, PL8, PPT, VAP, VDHG, YMAX, MG, WMX). Nothing
was wrong with them.

1. **There was no setting.** Settings managed API *keys* only.
   `preferredQuoteProvider` is now a per-book preference; absent one, a
   configured **keyed** provider wins, because going to the trouble of storing a
   key is the preference. Yahoo is the answer only when nothing else is set up.
2. **Three hardcoded copies of the default.** `updateAllPrices()` (⌘⇧U), the
   six-hourly `refreshQuotesNow()`, and `preferredProvider` each spelled
   `availableProviders.contains(.yahoo) ? .yahoo : …` — and Yahoo needs no key,
   so that branch always won. One definition now; `preferredProvider` is an
   alias of it. The provider picker also opens on the book's provider rather
   than Yahoo.
3. **Coverage followed the provider.** A security the chosen provider could not
   serve was reported and left unpriced. A fallback sweep now offers anything
   still unpriced to every *other* configured provider before calling it a
   failure, so the priced set is the union of what the book's providers can do
   between them — the same set whichever leads. `Price.source` still records who
   served each row.
4. **A price in the wrong currency was stored anyway.** `QuoteService.price(from:)`
   noted a currency mismatch in the source string —
   `Finance::Quote:yahoo (USD)` — and wrote the provider's number against the
   requested currency regardless. On the reference book that is **1,205 wrong
   rows**: `MG` (Mercer Growth, an Australian super option) sent to Yahoo as a
   bare mnemonic resolves to a US-listed namesake, and 836 of that company's USD
   closes were recorded as the fund's AUD unit price. It now throws. A test had
   asserted the old behaviour and so encoded the bug; it asserts the drop now.

Related, same root cause as `WMX`: **a bare mnemonic finds a US namesake.** Both
`MG` and `WMX` lack an exchange suffix, and Yahoo answers 200 for both. The zero
price guard (`YahooQuoteProvider`) catches one shape of this and the currency
guard catches the other.

### Warnings that were not warnings

- **Gaps counted the tail.** `PriceHealth.gaps` ran from the first priced day to
  *today*, so the stretch after the last price counted as a hole — even though
  that is staleness and already has its own measure and its own worklist entry.
  Sixteen holdings were reported as having gaps while sitting at 154 of 157 days
  priced. Gaps are interior-only now.
- **FIIG was offered to bonds that did not need it.** The offer keyed on the
  identifier's *shape* alone, so bonds already drawing sparklines from prices
  they had were told a new provider might help. It now requires the security to
  be unpriced or stale as well.

## Tabs, and the control that makes one (16 Aug 2026)

The tab strip shipped hidden behind `openTabs.count > 1` — and the strip is
where the `+` lives, so the control that creates a tab appeared only once you
had two. Reported as "I am not seeing the tab in accounts etc, nor the ability
to create a tab". The strip is now always visible in every mode.

Its `+` was also a bare `plus`, which is the sidebar's symbol for "add an item
to this collection" a few pixels away — in Accounts it read as "new account".
It is `plus.rectangle.on.rectangle` behind a divider now, and inactive tabs are
outlined rather than invisible so a lone home tab reads as a tab.

## The toolbar says less and means more (16 Aug 2026)

- **No window title.** HIG *Toolbars*: "If titling a toolbar seems redundant,
  you can leave the title area empty." Here it was redundant three times over —
  the mode button is highlighted, the sidebar header names the mode, the tab
  strip names what is open. Reclaiming ~120pt is what lets the mode buttons keep
  their labels at *every* window width rather than only above 868pt.
- **No unlabelled controls.** `Menu("Update Options", systemImage: "chevron.down")`
  drew as a lone chevron, because a toolbar `Menu` renders its symbol and drops
  its title — it is `ellipsis.circle` now, the More idiom the HIG names. The
  period selector's label was its *value* ("This financial year") with no
  tooltip and no accessible name, so VoiceOver read a period without saying what
  it governed.
- **Stacked labels were measured and not adopted.** Label-below-icon would save
  159pt (329 vs 488), enough for all seven modes at the minimum window. But it
  needs `ExpandedWindowToolbarStyle` — still in the macOS 26.5 SDK, undeprecated
  — and the current HIG Toolbars page describes a single row with
  leading/center/trailing groupings and never mentions stacking, expanded style
  or label-below-icon. Emptying the title area bought the room without the
  legacy chrome, so the stacked layout was not needed.

## A security is not an account (16 Aug 2026)

`FR-INV-41`. The two had been conflated in the UI: the only way to bring a new
security into a book was the **New Account** sheet's Exchange/Ticker fields, so
"add a security" meant "add an account" — and Investments' own `+` offered
*Watch a Security*, which makes a watchlist entry rather than a holding. Several
accounts can hold the same security (the same shares in two portfolios), so the
two acts are separate and now have separate sheets.

**New Security is a lookup, not a form.** `SecuritySearchProvider` +
`YahooQuoteProvider.searchSecurities(matching:)` — `v1/finance/search`, keyless
and crumbless, verified live on 16 Aug 2026 where "WAM Income" returned
`WMX.AX` (ASX), `3RO.F` (Frankfurt) and `WMX.XA` (Cboe Australia). Three
listings of one company, which is why the person picks and the app does not
guess. Choosing one registers the commodity with the provider's **own**
identifier and then fetches its price history and fundamentals in the same act.

That closes the loop on the day's worst data bug at the only point it can be
closed. `WMX` and `MG` were both entered as bare tickers, and both find US
namesakes that answer 200 — one an index stub priced at zero, the other an
industrial-services company whose closes became a super fund's unit price for
836 days. An identifier that is never typed cannot be typed wrongly.

Reachable from Investments' sidebar `+`, the Book menu, and `presentedPanel`.

**New Account links rather than retypes.** Its Exchange/Ticker/Full-name fields
are gone, replaced by a picker over the securities the book already holds plus a
**New Security…** button that opens the lookup. `makeCommodity()` returns the
stored instance, never a freshly built copy — two commodities differing only in
`fullName` or fraction are two securities, and that is the other way a book ends
up holding `WMX` twice. Add stays disabled until a security is picked; before,
an account could be added against an empty ticker.

## The modes are the hero (16 Aug 2026)

The mode buttons carry their names **under** their symbols, at roughly twice an
ordinary toolbar button's height, and the trailing controls sit in two short
rows beside them — search above, the period selector below — so the height the
modes claim is spent rather than padded.

Three measurements decided the shape, each taken on screen at a 986pt window
rather than argued:

- Names **beside** the symbols: five modes = 488pt, and Reports and Business
  went into the system overflow menu.
- Names **under**: 329pt for five, 452pt for all seven — inside the 860pt
  minimum window.
- A plain 150pt `TextField` where `.searchable` used to be: Reports and Business
  went back into the overflow. `.searchable` was cheap because the system
  collapsed it to a magnifier until clicked, so this one collapses too, and
  earns its width only while it is being used.

Two regressions this introduced, both caught before shipping and both worth
recording because neither was visible in a test run:

- **Replacing `.searchable` orphaned `searchSuggestions`**, and with it Save
  This Search and the saved-search list — the only route to either. They are now
  a bookmark menu inside the field, and the dead helper is deleted.
- **`onExitCommand` is unavailable on iOS** and broke that build. The project's
  own `onEscapeCommand` wrapper is cross-platform and is what the field uses.

The window title is gone (HIG *Toolbars*: "If titling a toolbar seems redundant,
you can leave the title area empty"), the tab strip names what is open, and the
sidebar header names the mode.

**Wilson Asset Management (`FR-INV-42`) serves prices and a profile.** It was a
price provider only for a day — the fund pages carry inception, asset class,
benchmark, timeframe, APIR, ARSN and fees, and no parser read them, so
`servesFundamentals` said `false` rather than putting a Refetch on screen that
fails every time. The parser landed in P13.3; see below.

---

# P13 — Remediation: the five-angle scan (16 Aug 2026)

Ordered after a run of defects surfaced one complaint at a time. Five read-only
subagents audited the tree in parallel — reachability, surface parity, P12
spec-vs-build, docs-vs-code, and price-data consistency — and returned **47
issues**. The plan is [plan.md](plan.md) §13e.

**The scan's own lesson.** Three of its findings were in fixes reported complete
the same day: the cross-provider sweep had been added to `fetchLatestQuotes`,
which no button calls; the currency guard could not fire on the four providers
that report no currency, and the sweep tried those first; the zero guard lived
in Yahoo's `latestQuote` alone. A fix is not done because its diff looks right.

## P13.1 — One gate decides what may become a price

Every fetch funnels through `QuoteService.price(from:)`, so that is where the
rules live now: non-positive, epoch-0 sentinel dates, dates more than a year
ahead, and a currency that is not the one asked for. The currency check reaches
the four currency-blind providers through the security's own exchange —
namespace first (NASDAQ implies USD though its tickers carry no suffix), then a
suffix on the symbol in whatever spelling answered. A bare mnemonic implies
nothing: reading "no suffix" as American would refuse every correctly-priced
managed fund and super option.

**One dedup rule, GnuCash's** (`gnc-pricedb.cpp`, `price_is_duplicate`):
canonical day, value, commodity, currency. Two were in use — the latest path
compared day and value, the history path refused any day it already held, which
meant a correction could never land. `Book.addPrices(deduplicating:)` is the
only spelling now, and `Book.latest` returns the **last** row of a day, so an
evening close can outrank the 06:00 refresh that used to own the whole day.

**One day convention.** `Price.init` already normalised to GnuCash's day-neutral
10:59Z; the defect was upstream. Date-only providers parsed at midnight UTC,
which day-neutral then re-read in the *local* calendar — the day before, west of
UTC. `QuoteDate` lands them on 10:59Z directly. Yahoo's instants go the other
way: a 16:00 New York close is 06:00 next morning in Sydney, so quotes now carry
their exchange's GMT offset and the civil day is taken in the exchange's
calendar.

The cross-provider sweep moved into a helper **both** write paths use, and
prefers providers that report a currency — it sorted by `rawValue`, which is
alphabetical, so it tried exactly the four whose answers nothing can check.

## P13.2 — Controls that do nothing

All Transactions ignored its Filter sheet and its own column headers: both sat
inside `if !focusSet.isEmpty`, and the general ledger's focus set is empty by
definition. The headers still wrote the shared `registerSort`, so sorting All
Transactions silently re-sorted every single-account register instead.

"Filter Transactions…" was a **latch**: chosen from a mode with no register, it
set a flag with nothing on screen to clear it, and every later press wrote
`true` over `true` — no change, no callback, dead in every mode for the session.

The period selector appeared in seven modes and governed two. `AppMode.usesPeriod`
records which, and why each of the other five is excluded rather than wired.

Four capabilities existed with no way to reach them: `deleteBudget`,
`renameSecurity` (its sheet was written and presented from nowhere),
`clearFundamentals(for:)`, and `importPrices(csv:)` — `FR-XIO-03` with no caller
at all, the export half of the pair wired and the import half not. The eleven
`inlineSet*` methods went the other way and were **deleted**: superseded by the
register sheet's whole-draft `updateTransaction`, with only their own tests
keeping them alive.

**Ten went in `40ebaec`; the eleventh went on the re-verification.** Asked on
16 Aug 2026 to restart P13 assuming nothing verified, the sweep found
`inlineSetTransfer` still `public` in `AppModel+InlineEdit.swift` with no caller
anywhere in `Packages/` — while the comment left in that same file already
listed it among the methods "**deleted**, not moved". The record and the code
disagreed, and the record was the optimistic one. This is the phase's own lesson
holding a second time: a fix is not done because its diff looks right.

Two of the scan's findings did not survive checking and are recorded as such:
the sidebar is single-selection, so its context menu can never see a
multi-selection, and the sort menu already offers each mode only the criteria
that mean something in it.

## P13.3 — Investments tabs, and the rest of the owner's list

**All Holdings, then one tab per portfolio.** A portfolio is not a type GnuCash
has, so it is derived from the shape a book already keeps — the parent account
of security accounts — and listed in the Investments sidebar, which is where
every tab comes from. None at all when a book has one, because a lone portfolio
row says what All Holdings says.

The tab strip's `+` made a tab you could not keep: `openNewTab()` appended
`mode.defaultSelection`, which *is* the derived home tab, so ⌘T produced a
duplicate that `restoreNavigation` filtered out on reopen. It offers the mode's
unopened destinations now, capped at twelve and saying so.

`ModeLabelFit` measured which mode labels fit and **nothing read it**; the
stacked style was applied unconditionally, so the documented degradation could
not happen.

**Wilson end to end.** Its price table and key-fact block were read from the live
Founders Fund page: the dates confirm the inconsistency the parser works around
— `13/08/2026` then `08/12/2026`, `08/11/2026`, day-first above the 12th and
month-first below — and the profile arrives as eight
`<p class="leader">`/`<p class="details">` pairs, APIR `ETL5957AU` among them.

`FR-NAV-07` is a Must and was unmet. Business held a deliberately empty view;
Reports and Records had no view at all. All three have cards, and the test
asserts the property rather than the three names.

## P13.4 — Register parity

`GeneralLedgerView` rendered the bare sheet: no toolbar, no view-style menu, no
filter button, no ⌘↑/⌘↓, no attachments panel, no summary bar. It is
`RegisterView(wholeBook: true)` now — the fork was in the wrapper, not in
anything either side needed. The entry bar borrows the selected row's account,
since the general journal has no anchoring split (`gnc-split-reg.c:894`); the
summary bar states what a book *has* — how many transactions are showing, and
the debit total the Amount column adds up — rather than a balance it does not.

The Balance column was drawn, headed and permanently blank, taking 112pt from
columns that have an answer; it is hidden for the whole book. Amounts were
labelled in the report currency because `currencyCode` answers from the selected
account and there is none, so every row read AUD including the USD invoices.
`anySplitID` returned `splits.first` — storage order, which a round trip through
GnuCash XML can change — and returns the debit leg now: stable, and the one the
row displays. `addTransaction` gained the `number:` parameter it never had, so a
Num can be set on a new transaction and not only edited on an old one.

**Description autocomplete reaches the third editor.** P13.4 asked for it
"everywhere" and it landed in two of three: `RegisterEntryBar` draws ghost text
after the caret and `TransactionEditorSheet` offers "Fill from recent…", while
the in-place row editor — the one a person types in most — had neither. The
re-verification on 16 Aug 2026 found `descriptionSuggestions` referenced in
`Views.swift` and nowhere else.

`GridCell` now takes an optional `suggest:` closure, supplied only by the
description column; every other cell passes nothing and renders exactly as
before. The completion is drawn as the same `ZStack` ghost `RegisterEntryBar`
already used — a clear-coloured copy of what is typed, then the remainder in
tertiary — accepted on Tab and otherwise ignored, so Tab keeps meaning "next
field". It is **offered, not applied**: autofilling on a prefix match races the
typing.

This deliberately does *not* go through RegisterLab2, and the reason is worth
recording, because register work normally must. The harness rule exists for the
sheet's tap-to-focus mapping and its lazy-container layout, both of which have
failed on real hands. A non-interactive overlay and one `onKeyPress` touch
neither.

## P13.5 — Documentation

`deferred.md` filed the wrong-currency stamping as an accepted won't-fix for
three weeks; that entry is struck through rather than deleted, because it is the
behaviour that wrote 1,205 bad rows. `FR-NAV-02` asked for "one segmented
control" the build deliberately is not — the requirement was describing an
implementation that could not satisfy `FR-NAV-03` beside it. Six `FR-*` ids
cited in shipped code existed in no document (`FR-ACC-02/03/04`,
`FR-FIND-02/03`, `FR-SEC-01`) and now have rows. This file called the navigation
design "still a proposal" 2,700 lines above the section describing it as
shipped, and said "sidebar dragging is off" 35 lines above "both halves of the
sidebar drag are built"; `SidebarSort.allowsDragging` said "nothing reads this
yet" with two call sites.
