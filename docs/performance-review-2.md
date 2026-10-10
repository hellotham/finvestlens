# Performance Review 2 (9 Oct 2026)

> **Status (10 Oct 2026):** every finding R1–R10 is closed, the §3 items are
> done, and the §4 acceptance figures are measured (§4, below). The 10 Oct
> session closed the items 9 Oct left open — R7's lazy legs and resize memo,
> R8's price-scoped invalidation (and, found while measuring it, the price
> index rebuild that was the real cost of a price edit), R9's remaining memos,
> R10's keystroke patch and rotor memo, the §3 dead probe — plus the sweep's
> smaller items (Linked Documents, Apply Rules, the security page's export and
> chart, the tax, lifetime and last-price memos). All of it is in the working
> tree, uncommitted. Receipts are per finding; the 10 Oct test and build
> receipts are in `implemented.md`.

*Audited at HEAD on 9 Oct 2026 against a temporary copy of the reference book
(46,831 transactions / 104,249 splits / 559 accounts / 163,561 prices / 41
holdings), **Release** build, Xcode 27.0, macOS 27.0.1. Method: the three live
harnesses in `Packages/FeatureUI/Tests` (`FL_PERF_FILE`), throwaway timing
tests run once and deleted, and four read-only sweeps of the view layer whose
every citation was re-read before it was kept. Debug-build numbers, which are
what a developer running from Xcode feels, are 2–4× every figure here.
Companion to [performance-review.md](performance-review.md) (July 2026), whose
status header records what was already done; nothing accepted there is
re-flagged here.*

**Targets** (unchanged from July): register/account open **<100 ms**; any body
pass **<16 ms** of main-thread work; anything over ~300 ms shows progress and
never blocks the rest of the window.

---

## 1. Measurements

Release build on the reference-book copy. Every number was produced on 9 Oct
2026 by the harnesses or a throwaway test; the Debug column is from the same
harnesses in a Debug build where it was run.

| Operation | Release | Debug |
|---|---|---|
| Open — document load alone (`loadReadOnly`) | 2.37 s | — |
| Open — whole `AppModel.open` | 2.54 s | 29.1 s¹ |
| Save — whole synchronous `FinvestLensDocument.save` | 9.59 s | — |
| Whole-book XML snapshot (`gnuCashExportData`) | 6.65 s | — |
| `monthlyIncomeAverage()` (Suggest Budget sheet, per body pass) | 1.97 s | — |
| `investmentRows()` cold / warm | 430 ms / 15 ms | — |
| Dashboard: `recentJournalHeadings` per revision | 198 ms | — |
| Dashboard: `upNextState` / `wellbeingScore` / `netWorthSeries` / `balanceSheet` / `alerts` | 54 / 49 / 47 / 18 / 14 ms | 264 / 198 / 85 / 58 / 85 ms |
| Dashboard: performance series (first lookup builds the price index) | 93 ms | 408 ms |
| `recentDistinctDescriptions` cold (first keystroke after an edit) | 139 ms | — |
| `refreshAll` per edit — ledger / busiest account (9,162 splits) | 18 / 76 ms | 43 / 134 ms |
| `rebuildAccountTree` steady | ~18 ms² | 42–61 ms |
| Register split gather — `transactions.flatMap.filter` vs `splits(for:)` | 13 ms vs 0.001 ms | — |
| `legRows` for every transaction (sheet base build, All Transactions) | 57 ms | — |
| `wholeBookRegisterSummary()` per body pass | 21 ms | — |
| `securityCommodities` per call | 0.33 ms | 0.84 ms |
| Widget publish: `netWorthSeries` at `Date()` + `alerts(asOf: Date())` | 48 + 17 ms | — |
| `taxAccounts(from:to:)` one year | 3 ms | — |

¹ Debug opens include a 0.7 s first `rebuildAccountTree`; the Release ledger
refresh (18 ms) is the remainder after the document load.
² Inferred from the ledger `refreshAll` figure; the Debug signpost print is
not emitted in Release.

**Not measured:** hover and resize re-render rates (need Instruments or the
`FLRegisterTrace` log on screen) and the macOS sheet's `measureNaturalWidths`
(now memoised per rows and font, §R7). The Linked Documents gather was
measured on 10 Oct: 38 ms for 770 links with the file checks inline, which is
what the sheet's body used to pay on the main thread.

### After the fixes (10 Oct 2026, Release, same book copy, quiet machine)

| Operation | 9 Oct | 10 Oct |
|---|---|---|
| Open — whole `AppModel.open` | 2.54 s | 2.45 s |
| Save — main-actor share (`stageSnapshot`) | 9.59 s (whole save) | 0.24 s |
| `refreshAll` per edit — ledger / busiest account | 18 / 76 ms | 19 / 66 ms |
| New Account / Change Colour / Delete Account, busiest account selected | whole-book XML snapshot (6.65 s) | 68 / 68 / 95 ms |
| Price edit (`addExchangeRate`) end to end | — | 377 ms → 34 ms → **19 ms** (change-log undo, 11 Oct) |
| `refreshAll(scope: .prices)` after a price mutation | — | 372 ms → **18 ms** |
| `addPrices(deduplicating:)` — the start of every quote or rate fetch | — | 145 ms → **62 µs** (11 Oct) |
| Price-only refresh vs full, busiest account | — | 19 vs 77 ms |
| `legRows` for every transaction (no longer paid in Basic style) | 57 ms | 54 ms |
| Whole-book journal build cold / warm | — | 41 ms / 0.5 µs |
| `monthlyIncomeAverage()` (once per Suggest Budget sheet) | 1.97 s | 13 ms |
| `availableProviders` cold (Keychain) / memo | — | 6 ms / 0.8 µs |
| `lastPriceUpdate` cold / memo | — | 21 ms / 1.5 µs |
| `taxEstimateResult` cold / memo | — | 28 ms / 9 µs |
| `lifetimeAssumptions` seed cold / memo | — | 5.7 ms / 9 µs |
| Dashboard tiles cold (`upNext` / `wellbeing` / `netWorth` / `balanceSheet` / `alerts`) | 54 / 49 / 47 / 18 / 14 ms | 52 / 49 / 47 / 18 / 14 ms |
| Dashboard performance series cold (deferred to a task) | 93 ms | 95 ms |

The tile costs are unchanged by design: R5 memoised them per revision and
declined to gate them (see R5), so a post-edit pass still pays them once.

---

## 2. Findings, in the order they are being fixed

### R1 — Save freezes the window for about nine seconds  *(critical)*

`saveWithStatus` ([AppModel.swift:2367](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel.swift))
runs `stageSave` on the main actor: the shared-file fingerprint (SHA-256 of
68 MB) and `store.write(book)`, the full DELETE + INSERT rewrite of every table
into the working copy. Only the final copy to the shared file is detached, and
on a local volume that copy is an APFS clone. Measured 9.59 s for the whole
synchronous save. Every autosave tick while dirty (300 s) and every ⌘S pays it.
July's P10 routed the status chip and moved the copy; the write stayed.

**Fix.** Snapshot the book into value rows on the main actor, then fingerprint,
write and copy on a background thread from the snapshot — no read gate needed,
because the snapshot is immutable and an edit made during the write simply
leaves the document dirty for the next save (the change-token logic already
does this). Status: **fixed** — `BookSnapshot` + `stageSnapshot`/`commitStaged`
(Persistence), table-driven `GncGUID` hex and a hoisted decimal locale.
Measured on the reference book, Release: main-actor share of a save 9.6 s →
0.18 s; background write 3.3 s; XML export 6.65 s → 1.54 s; open 2.54 s →
2.20 s; export before/after a snapshot save byte-identical (157 MB). Tests:
Persistence `snapshotCommitsOffThread`, Engine `encoderMatchesReference`.

### R2 — Everyday account edits take a whole-book XML snapshot for undo  *(critical)*

`editingWholeBook` ([AppModel.swift:2905](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel.swift))
captures undo state with `gnuCashExportData()`: 6.65 s before the edit, and
Undo re-imports it. 24 call sites remain: add / delete / renumber accounts,
account colour (`CheckRepair.swift`), close book, ten business operations,
smart import, securities, scheduled, currency. July's P9 scoped prices and kvp
only. File ▸ Export runs the same call synchronously before the panel appears
([Views.swift:122](../Packages/FeatureUI/Sources/FinvestLensUI/Views.swift)).

**Fix.** Scoped snapshots: account add/delete/colour/renumber through the
existing `AccountSnapshot` with a "did not exist" state; business edits through
a business-tables snapshot; export built behind the toast after the panel is
presented. Status: **fixed for the everyday sites** — add/delete/renumber
account, colour, dividend details, currency transfer, rename/identifier/add
security now go through `editing(accounts:transactions:prices:named:)` or
`editingCommodity`; the account editor's three edits are one undo group; the
three exports build after a toast and a painted frame. Left whole-book by
design: ten business operations, Close Financial Year, Post Scheduled
Transactions, Repair Book. Tests: `UndoScopedOperationTests` (6).

### R3 — Suggest Budget recomputes a two-second scan on every checkbox  *(critical for that sheet)*

[IntelligenceViews.swift:494](../Packages/FeatureUI/Sources/FinvestLensUI/IntelligenceViews.swift)
calls `monthlyIncomeAverage()` in the body; its loop
([AppModel+Intelligence.swift:1620](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Intelligence.swift))
walks every transaction once per income account per month window. Measured
1.97 s. **Fix.** Compute once per window with `balancesByAccount`, and once per
sheet into state. Status: **fixed** — `FinancialReports.periodActuals` (one
walk per window, equivalence test in `ReportTests`), computed once per sheet.

### R4 — Broker import refreshes once per row  *(major for imports)*

[ImportView.swift:628](../Packages/FeatureUI/Sources/FinvestLensUI/ImportView.swift)
posts each investment row through its own `editing` block, so a file of
hundreds of rows pays the per-edit refresh (76 ms on the busiest account) and a
register rebuild per row; the cash path already batches. **Fix.** Build all
transactions, then one `editing(ids:)` block. Status: **fixed** —
`recordStagedInvestments` builds every row, posts once; test
`stagedInvestmentBatch`.

### R5 — The dashboard rebuilds every tile synchronously after every edit  *(major)*

All cards ask the model inside the body
([DashboardView.swift:703](../Packages/FeatureUI/Sources/FinvestLensUI/DashboardView.swift)
onward); only the performance series is deferred. With the default board the
synchronous pass after an edit is about 380 ms in Release, over half of it the
Recent Activity tile, which builds the whole general ledger to keep forty
headings ([DashboardView.swift:101](../Packages/FeatureUI/Sources/FinvestLensUI/DashboardView.swift)).
Two smaller items: hover state for two charts lives on the board root, so every
mouse move re-evaluates all card bodies ([DashboardView.swift:130](../Packages/FeatureUI/Sources/FinvestLensUI/DashboardView.swift)),
and the performance series keys only on the period, so it stays stale after a
quote refresh ([DashboardView.swift:244](../Packages/FeatureUI/Sources/FinvestLensUI/DashboardView.swift);
unverified on screen).

**Fix.** Recent Activity from a top-40 pass over `book.transactions`; cards
gated on a warmed revision with per-card placeholders while a yielding task
fills the memo; hover state keyed only on what the tooltip draws; the series
keyed on the book revision too. Status: **fixed** except the warm-gating,
which is deliberately not done: after R5 the post-edit pass is under the
300 ms line the July review set for showing progress, and placeholders that
flicker for ~150 ms read worse than a hitch. Not re-measured.

### R6 — The Investments hub re-walks all prices many times per body pass  *(major)*

`investmentRows` has no memo ([AppModel+Investments.swift:235](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Investments.swift));
the hub reads it per group and header probe, and its body re-runs on every
quote-progress tick because the toolbar reads `quoteProgress`. 15 ms warm per
call, 430 ms cold. The sparkline-period and Show Closed Positions toggles go
through the full refresh and drop every memo, including `priceHealth`
([AppModel+Investments.swift:508](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Investments.swift)).
**Fix.** `cachedReport` keyed on window and the closed-positions flag; rows
read once per body. Status: **fixed** — memo keyed on window and the
closed-positions flag; the two toggles are `.preference`-scoped kvp edits that
bump `preferencesRevision` and nothing else.

### R7 — Per-click register costs on macOS  *(major, cumulative)*

The macOS register is the AppKit `RegisterSheet`
([Views.swift:1890](../Packages/FeatureUI/Sources/FinvestLensUI/Views.swift));
`RegisterTableView` is iPad-only.

- The register gather walks every split in the book instead of the per-account
  index ([AppModel.swift:3098](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel.swift)):
  13 ms wasted per account click or edit against 0.001 ms.
- The sheet's base build fetches legs and tags for every row even in Basic
  style, with a recursive `fullName` per leg
  ([RegisterSheet.swift:1368](../Packages/FeatureUI/Sources/FinvestLensUI/RegisterSheet.swift)),
  which `legRows`' own comment warns against: 57 ms on All Transactions per
  edit or account switch.
- Leaving Accounts mode blanks the register; returning rebuilds it up to five
  times through the view-state setters
  ([AppModel.swift:1081](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel.swift)).
- Live resize re-measures every row per width change
  ([RegisterSheet.swift:1516](../Packages/FeatureUI/Sources/FinvestLensUI/RegisterSheet.swift)).
- The recency list re-sorts and re-folds 46k descriptions on the first keystroke
  after every edit and every save: 139 ms
  ([AppModel.swift:502](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel.swift)).
- All Transactions' summary bar reduces every split per click: 21 ms
  ([AppModel+Journal.swift:381](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Journal.swift)).

Status: **fixed** for the gather (`splits(for:)`), the recency fold cache,
the summary memo (keyed on the register filter) and the mode switch (rows
kept when leaving for a non-register destination; view-state restore under
one suspended refresh; a build key skips identical rebuilds). **Fixed 10
Oct:** the sheet's base rows no longer carry legs — `SheetRowCache` fetches a
row's legs on first disclosure and memoises them beside the rows, so Basic
style pays for the one row it opens and Journal pays the same total it did
(the eager build measured 54 ms for all 46,831 transactions); and the
row-derived inputs to `measureNaturalWidths` (`RowFacts`) are memoised per
rows and font, so each rung of the date-form ladder on a live resize
measures a dozen strings instead of walking every row. Tags stay in the base
(one dictionary lookup per row). The sheet's symbol builder also takes its
accent colour as an autoclosure, so a cache hit no longer converts a colour
per paperclip, pencil and caret drawn.

### R8 — Invalidation is all-or-nothing  *(major by multiplication)*

Kvp and price edits, a favourite star, a tax-code keystroke
([ParityViews.swift:167](../Packages/FeatureUI/Sources/FinvestLensUI/ParityViews.swift))
and every save call `refreshAll`, which drops the register, the recency list
and every report memo. The save also publishes widget data under a live
`Date()` key, a guaranteed memo miss
([AppModel+Widgets.swift:97](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Widgets.swift)).
**Fix.** Scoped invalidation for kvp- and price-only edits; no refresh after a
save; day-stable keys for the widget publish; tax code committed on submit.
Status: **fixed** for the save (no `refreshAll`; `documentStateRevision`
keeps the Save menu honest), the widget keys and the tax code. **Fixed 10
Oct:** `AppModel.RefreshScope` — `editingPrices` now refreshes with
`.prices`, which bumps the book revision and rebuilds the account tree
(valuations) but leaves the split lookup indexes, the journal caches, the
register and the search alone, none of which read a price; the two register
surfaces key their rows on a new `registerRevision` that moves only when
`refreshRegisterBody` actually rebuilds, so a quote refresh no longer costs
them a rebuild either (19 ms against 77 ms on the busiest account; test
`RefreshScopeTests`). Measuring that exposed the real cost of a price edit:
`Book.prices` dropped its lookup index on *every* mutation, and the next
account-tree refresh rebuilt it — bucket and sort 163k prices — at 0.35 s.
The Engine now maintains the index in place (`indexInsert`/`indexRemove`,
with a wholesale replacement or a 256-row removal still dropping it), and an
exchange-rate edit end to end fell from 377 ms to 34 ms (`refreshAll(.prices)`
after a mutation: 372 → 18 ms; Engine test `incrementalMaintenance` checks
the maintained index against the linear scan). The code review of these
changes (§4) then took the same path two steps further on 11 Oct: the undo
snapshot `editingPrices` took of the whole price array forced a copy of
163k rows on the first append (21 ms per edit) — the book now records what
an edit adds and removes and undo replays the inverse (`Book.PriceChange`;
the composite `editing(accounts:…prices:)` uses the same log), which is also
what CLAUDE.md's undo rule asks for; and `addPrices(deduplicating:)` opened
every quote and rate fetch by building a set of every price's identity, two
calendar computations each — 145 ms — where the maintained index answers
the same question per candidate in 62 µs. An exchange-rate edit end to end
is now 19 ms. Kvp collections (favourites, saved searches, rules, budgets…)
stay `.book`-scoped: their consumers read the published arrays and the
report memos alike, and no measured cost justified auditing each.

### R9 — Cheap memo wins  *(small, cumulative)*

- `securityCommodities` scans accounts before every portfolio cache hit
  ([AppModel+Prices.swift:27](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Prices.swift)).
- Five report builders bypass `cachedReport`
  ([AppModel+Reports.swift:55](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Reports.swift))
  and `netWorthPoints` does an O(n) minimum first.
- The security page reads and decodes its fundamentals file about seven times
  per body pass ([SecurityDetailView.swift:386](../Packages/FeatureUI/Sources/FinvestLensUI/SecurityDetailView.swift)).
- `DecimalFormat.units` allocates a `NumberFormatter` per call
  ([SecurityDetailView.swift:1263](../Packages/FeatureUI/Sources/FinvestLensUI/SecurityDetailView.swift)).
- `availableProviders` hits the keychain per keyed provider per read, per
  security during a fetch ([AppModel+Quotes.swift:32](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Quotes.swift)).
- `Color.appAccent` reads `UserDefaults` per call, on the reconcile-badge
  per-row path ([Appearance.swift:50](../Packages/FeatureUI/Sources/FinvestLensUI/Appearance.swift)).
- `receivablesCard` recomputes aging per body pass (negligible on a book with
  few invoices).

Status: **fixed** for `securityCommodities`, the five builders and
`netWorthPoints`, the fundamentals read, `DecimalFormat.units`. **Fixed 10
Oct:** `availableProviders` is memoised on an `apiKeysRevision` that the one
write path, `setAPIKey(_:for:)`, bumps — the Pricing settings pane used to own
a second Keychain store the model could not see, and now goes through the
model (6 ms per Keychain read → 0.8 µs); `aging(receivable:asOf:)` is
memoised per side and day (its default `asOf` is now the end of today, not a
live `Date()`). `Color.appAccent` was **measured and left alone**: a defaults
read plus a `Color` costs about 2 µs, so the 34 call sites are under 0.1 ms
per body pass, and a cache would need invalidation the accent picker does not
have. The one per-row path — the sheet's symbol cache evaluating
`NSColor(Color.appAccent)` before checking its cache — is fixed under R7.

### R10 — iPad only  *(moderate; one can hang)*

Select-all in a large register is quadratic through `registerSplitID`
([AppModel+Editing.swift:780](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Editing.swift));
every keystroke recomposes all rows ([RegisterTable.swift:977](../Packages/FeatureUI/Sources/FinvestLensUI/RegisterTable.swift));
the Unreconciled rotor rebuilds its entries per body pass. The macOS sheet is
unaffected. Status: **fixed** for select-all (a per-rebuild dictionary).
**Fixed 10 Oct:** the composed-rows cache now carries a *structure* key (base,
selection, style, disclosure, the drafted transaction's identity) beside the
composed key; when only the draft's content moved, the drafted transaction's
block is recomposed from its own base rows and spliced in place of the old
block (`Array.replacingBlock(of:with:)`, tested in `RegisterTableSpliceTests`)
instead of recomposing every row; the rotor entries are memoised on the base
key in the same cache. Unverified on a device — the table is iPad-only and
no iPad was driven; `FLRegisterTrace` logs `patch` timings beside `compose`.

---

## 3. Found on the way, not performance

- The report screen seeds `configuration` from `model.period` once
  ([ReportsHome.swift:185](../Packages/FeatureUI/Sources/FinvestLensUI/ReportsHome.swift))
  while its toolbar binds `$model.period`
  ([ReportsHome.swift:701](../Packages/FeatureUI/Sources/FinvestLensUI/ReportsHome.swift));
  nothing syncs them, so changing the period inside an open report appears not
  to recompute it. Not driven on screen. Status: **fixed** — the screen now
  syncs its configuration from the window's period.
- `RegisterTableStyleProbe` and `paintTick` in `RegisterTable.swift` were dead
  on both platforms (compiled for macOS, hosted only on iPadOS). Status:
  **deleted** 10 Oct.
- From the sweep's smaller findings, all done 10 Oct: the Linked Documents
  sheet gathers off its body (`linkedDocumentsOffMain()` runs the ~770 file
  checks in a detached task behind a placeholder); Apply Rules previews in a
  `.task` behind a placeholder instead of blocking its first frame; the
  security page builds its CSV export when Export is pressed rather than on
  every redraw, and its price chart is `Equatable` with precomputed marks and
  runs thinned to 600 points (each bucket keeps its low and high, so peaks
  survive — `PriceChartThinningTests`); `taxEstimateResult`, the lifetime
  seed and `lastPriceUpdate` are memoised per revision (28 ms, 5.7 ms and
  21 ms per body pass before).

---

## 4. Code review of the fixes (10–11 Oct 2026)

Seven of the review's ten angles completed (line-by-line and cross-file
tracing were twice cut off by the session limit; the removed-behaviour,
pitfall, cache, reuse/simplification, efficiency/altitude and conventions
angles covered the same ground). Everything confirmed was fixed the same
day, with a test where one could be written:

- The iPad table's per-keystroke splice assumed one heading per
  transaction; a transaction with two legs in the focus account has two, so
  rows would have duplicated per keystroke. The splice now declines that
  case (full compose) — `RegisterTableSpliceTests`.
- `.equatable()` on the price chart would have kept the old accent after a
  theme change, because the colour was read in the body; it is `.tint` now.
- All Transactions inherited the last account's sort and filter, and kept
  its rows when reached through Overview (a 9 Oct regression); it resets and
  refreshes on arrival — `generalLedgerResetsTheView`.
- The register build key did not carry the day its present/future split was
  taken on, so a register built yesterday stayed stale today; it does.
- Undoing Add Account left the new security registered; the composite undo
  unregisters what the edit registered.
- The Linked Documents gather could land a superseded result after a newer
  one, and re-ran on price edits; cancellation is checked and it keys on
  `transactionRevision`. Its first version also still stat'ed every
  candidate path on the main actor; the resolution is now pure and the
  stats run detached.
- A refused Keychain read (locked, or a rebuilt app's ACL prompt declined)
  would have been memoised as "no key" for the session; the store now tells
  "not found" from "could not read" and only a definite answer is kept —
  `providersNotMemoisedOnFailure`. A failed key write still moves the
  revision, since the old item is already gone.
- The tax-code field could lose a code typed just before Done or Escape.
- `lastPriceUpdate`'s `nil` (rates, no securities) was never memoised.
- Appending a split line did not move the composed cache's content key.
- An emptied index bucket kept its key, so `pricedAgainst` listed pairs
  with no prices — `emptiedBucketGoes`.
- The whole-database undo snapshot and the dedupe set (R8 above).

Taken as simplifications: the composed cache keyed as (structure, content);
the sheet's own leg memo replaced by the model's (`legRows` memoised on
`transactionRevision`, so Journal style and the iPad base share it); the
row-facts memo keyed on the sheet's own key; integer bucket bounds in the
chart thinning; the settings pane reading provider presence from the model;
one `LoadingPlaceholder`; the index insert computing its position without
holding a second reference to the bucket; grouped index removals with no
threshold; `latest(in:on:)` sharing the insertion search.

Declined, with the reason: a change-set invalidation model in place of the
revision counters (the right direction, not this round's work); memoising
`fullName` on `Account` (the `legRows` memo removes the measured cost);
moving the key-change signal into the store (one model, one writer today);
the display series in Reports and a block map for the splice (both costs
unmeasured on the only device that runs that code); `cacheKey`/`rowsKey`
fingerprints kept beside the revisions as belt and braces; `rebuildAccountTree`
under `.prices` (18 ms, price-dependent when any account is foreign);
`linkedDocuments()` kept synchronous for the Lab commands; a shared test
fixture and a `RevisionMemo` helper (test-only and cross-cutting cleanups).

## 5. Measurement, so the numbers stay numbers

- The three live harnesses (`LiveDashboardPerfTests`, `LiveRefreshPerfTests`,
  `LiveWholeBookPerfTests`) with `FL_PERF_FILE` pointing at a book; run with
  `-c release` for the shipped experience.
- `Perf.measure` signposts around `refreshRegister`, `rebuildAccountTree`,
  `searchReplay`, `wholeBookSnapshot` and every `cachedReport` build print
  over-budget passes in Debug.
- The macOS sheet's own trace: `defaults write com.hellotham.finvestlens
  FLRegisterTrace -bool true` logs base rebuilds and compose timings to
  `/tmp/fl-register-perf.log`.
- Acceptance for this round, on the reference book in Release: autosave never
  blocks the window for more than the snapshot (target under 0.5 s); New
  Account, Delete Account and Change Colour under 100 ms; Suggest Budget
  toggles under 16 ms; the Overview's post-edit pass under 100 ms with the
  default board; register click on the busiest account under 60 ms.
- **Measured 10 Oct 2026** (Release, quiet machine, temp copy of the book):
  main-actor share of a save 0.24 s — **met**; New Account 68 ms, Change
  Colour 68 ms, Delete Account 95 ms with the busiest account's register open
  — **met**; Suggest Budget's figure is computed once per sheet (13 ms) and a
  toggle recomputes nothing — **met**; register rebuild for the busiest
  account 18 ms cold (the whole-book harness; an *edit* there costs 66 ms
  because the tree and the search refresh too) — **met for the click**; the
  Overview's synchronous post-edit pass is the sum of its cold tiles, about
  190 ms with the performance series deferred — **not met**, and left so on
  purpose: R5 records why the tiles are not gated behind placeholders, and
  the 100 ms line here was written before that decision. Lowering it means
  making `upNextState`, `wellbeingScore` and `netWorthSeries` (≈50 ms each)
  cheaper, which is new work rather than a gate.
