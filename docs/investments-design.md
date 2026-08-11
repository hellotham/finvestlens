# The Investments hub — design

Status: **design agreed, not yet built** (11 Aug 2026). Supersedes the
"Prices & Securities" destination. Requirement IDs proposed here (`FR-INV-08`
onwards) become PRD rows as each phase lands; nothing below is implemented
until [implemented.md](implemented.md) says so.

---

## 1. What is wrong today

The destination is called **Prices & Securities** and sits in the sidebar's
**Records** section, between *Business* and *Time & Mileage*
([Views.swift:1006](../Packages/FeatureUI/Sources/FinvestLensUI/Views.swift#L1006)).
That placement is the diagnosis, not a detail: the app files investments as a
*filing cabinet* — a thing you go and maintain — rather than as something you
look at to make a decision. Every other defect follows from it.

Measured against the standard test book:

| Observation | Evidence |
| --- | --- |
| The Prices tab renders **every price row in the book** in one flat `List` — 148,458 rows, newest first, no search, no filter, no per-security scoping | [PricesView.swift:113-148](../Packages/FeatureUI/Sources/FinvestLensUI/PricesView.swift#L113) over `model.priceRows` ([AppModel.swift:254](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel.swift#L254)) |
| The destination's two halves are a **segmented picker in the toolbar** — tabs, which the HIG reserves for peer views; here they hide half the feature | [PricesView.swift:43-50](../Packages/FeatureUI/Sources/FinvestLensUI/PricesView.swift#L43) |
| A security row can show only ticker, name, latest price and two buttons. No history, no cost, no return, no indication whether the price is current | [SecuritiesView.swift:66-100](../Packages/FeatureUI/Sources/FinvestLensUI/SecuritiesView.swift#L66) |
| Freshness is **one book-wide date** in the subtitle. It cannot distinguish "everything is current" from "one holding is a year stale and it is 40% of the portfolio" | [PricesView.swift:33](../Packages/FeatureUI/Sources/FinvestLensUI/PricesView.swift#L33) |
| **Update Prices fetches all 87 securities**, including 48 that are no longer held | [PricesView.swift:53](../Packages/FeatureUI/Sources/FinvestLensUI/PricesView.swift#L53) → `pricableSecurities` ([AppModel+Securities.swift:17](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Securities.swift#L17)) |
| **Provenance is recorded and never shown.** The book stores a `source` per price; 68% of rows are hand-entered, 30% came from Yahoo, across six distinct sources | `price.source` column; no reference anywhere in `PricesView`/`SecuritiesView` |
| **All 11 bonds are priced at par.** Every bond price row in the book is exactly `1.0` — min and max — so bond holdings are valued at face regardless of market | `SELECT MIN/MAX(value) … WHERE commodityNamespace='SECURITY:Bond'` → 23 rows, all 1.0 |
| `FR-INV-03a` claims the Yahoo provider returns "dividends, and splits". **It does not.** The provider uses only `v8/finance/chart`; across the whole Quotes package the sole matches for "dividend"/"split" are `String.split` | [YahooQuoteProvider.swift:27-42](../Packages/Quotes/Sources/FinvestLensQuotes/YahooQuoteProvider.swift#L27) |

The shape of the book explains why the page fails:

| Population | Count | What it needs |
| --- | --- | --- |
| Securities total | 87 | — |
| …held right now | 32 | valuation, performance, freshness |
| …no longer held | 48 | history preserved for CGT; **no** daily fetch |
| …held **and** stale | **7** | the only rows that need a human today |
| Marked for quotes | 29 | automatic |
| Super funds (no ticker) | 22 | hand-entered valuations |
| Bonds (ISIN, no ticker) | 11 | FIIG by ISIN — see §9 |
| Price rows | 148,458 | never shown as a list again |

**Seven rows need attention and the page shows 148,458.** That is the defect.
"Ugly" is the symptom.

---

## 2. The reframe

> A price database is not a subject. It is a **precondition**. Nobody wants to
> read it; they want to know whether they can trust the numbers built on top of
> it.

The destination stops being a database editor and becomes a **portfolio
instrument panel**. The test it must pass:

1. **Three seconds to trust.** On arrival you know whether your portfolio's
   valuation is sound, without reading a table.
2. **It volunteers only rows that need a human.** Everything healthy is a
   summary; everything broken is a worklist item with the fix attached.
3. **Every number is traceable.** Any figure can be drilled to the price, the
   provenance of that price, and the transaction it values.

The unfair advantage worth building around: **anyone can show you a price
chart; only this app can draw your buys and sells on it.** The book has the
transactions, the lots and the income. The provider has the market. The
interesting surface is where they meet — and every genuinely novel feature
below (§8) lives there.

---

## 3. Decisions taken

Settled with the user on 11 Aug 2026, before any code:

| # | Decision | Consequence |
| --- | --- | --- |
| D1 | The destination becomes an **Investments hub** — holdings, performance, price health and research in one place | Rename and re-file in the sidebar; prices become one facet of a security |
| D2 | Fetched fundamentals live in a **sidecar cache**, never in the book | The GnuCash XML round-trip invariant is untouched; the document does not bloat |
| D3 | **No global price list at any altitude.** "Nobody wants to see that" | Prices appear only per security. CSV export by security replaces the list as *functionality* |
| D4 | Dormant securities are **hidden with a reveal control**; fetches still cover them **where there are gaps** | The daily run gets cheaper without abandoning historical integrity |
| D5 | Fundamentals come from **Yahoo by default, keyed providers when a key exists** | Yahoo is the only source with good ASX coverage; degrade gracefully, never look broken |
| D6 | Manual valuation is a **first-class category**, not a failure state | 22 Super funds stop being permanent errors and become a short worklist |
| D7 | The hub is **the door**; Investment Review and Capital Gains stay in Reports | One set of numbers computed once in `Reports`, shown at two altitudes |
| D8 | **FIIG becomes a provider**, matching bonds by ISIN | 11 bonds move from "unpriceable" to automatic |

---

## 4. What a person is actually doing here

Ordered by frequency, which is the order the UI should favour:

1. **"Can I trust today's numbers?"** — the precondition job, asked before every
   report. Today: unanswerable.
2. **"Fix what's broken."** — the 7 stale holdings, the 22 manual valuations,
   last run's failures, a price that looks wrong.
3. **"What do I own, what's it worth, how has it done?"** — holdings with
   return since holding.
4. **"Tell me about this one."** — profile, statements, dividends, yield.
5. **"Did I record everything?"** — dividends received vs declared, splits.
6. **"Get the data out."** — CSV per security, for a spreadsheet or an adviser.
7. **"Watch something I don't own."** — the watchlist, and price targets.

Jobs 1, 2 and 5 are *maintenance* jobs that only an accounting app can do —
they need the book. Jobs 3 and 4 are *research* jobs. The current page serves
none of them; it serves an eighth job nobody has ("browse all prices").

---

## 5. Information architecture

```
Sidebar
├── Dashboard
├── Reports ─────────────► Investment Review deck, Capital Gains, Lots  (unchanged)
├── Investments  ◄── NEW destination, promoted out of "Records"
└── …
    Records
    └── (Prices & Securities removed)
```

Two surfaces, one sheet family:

```
L1  Investments overview          the instrument panel — health + holdings
      │
      └── L2  Security detail     one security, everything about it
                │
                └── L3  sheets    price entry, export, fetch scope, identifiers
```

There is no third level of navigation and **no tab bar anywhere**. The
segmented picker that split the old destination is deleted; the split it
encoded (prices ↔ securities) was never a split a person cared about.

---

## 6. Surface A — the Investments overview

```
┌────────────────────────────────────────────────────────────────────────┐
│  Investments                                    [ Update Prices  ▾ ]   │
├────────────────────────────────────────────────────────────────────────┤
│  ╭─ Valuation confidence ─────────────────────────────────────────╮    │
│  │   ◕  98%  of portfolio value priced today                      │    │
│  │       7 holdings need a price · 3 gaps in held periods         │    │
│  │       Last run 09:14 via Yahoo · 2 failed · next in 4h         │    │
│  ╰────────────────────────────────────────────────────────────────╯    │
│                                                                        │
│  Needs attention (7)                                        [ Fix all ]│
│  ▸ 4 holdings stale over 30 days          → refetch                    │
│  ▸ 2 symbols failed last run              → see error, edit ticker     │
│  ▸ 1 manual valuation overdue             → enter price      [ 12.34 ] │
│                                                                        │
│  Holdings                             Held ▾   ⌕ filter    ⇅ Value ▾   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ ▮ SYM   Name              Units   Price  Age  ╱╲╱‾╲  Value  Ret% │  │
│  │ ▮ …                                       ●2d  ▁▃▅▇   …    +12.4 │  │
│  │ ▮ …                                       ⚠31d ▁▃ ⋯▇   …    − 3.1 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│  Manual valuations (22)  ·  Watching (3)  ·  Closed (48) ▸             │
│                                                                        │
│  Exchange rates          3 of 7 currencies priced today   [ Add rate ] │
└────────────────────────────────────────────────────────────────────────┘
```

**Header band — valuation confidence.** One ring and three lines. The ring is
**value-weighted price coverage** (§8.1), not a count: the question is what
fraction of *money* is correctly valued, and a count cannot answer it. The
three lines are the run's state — last run, failures, next scheduled — because
the second question after "can I trust it" is always "when did it last try".

**Needs attention.** A worklist, not a log. Each row is a *class* of problem
with a count and the action that resolves it; expanding shows the securities.
It is empty on a healthy book, and an empty worklist is a feature — it is the
three-second answer. `Fix all` runs the smallest set of operations that empties
it.

**Holdings.** A `Table` (macOS) with sortable columns: symbol, name, units,
last price, **age**, **sparkline**, market value, **return since holding**,
allocation. Age is a dot plus a number, coloured by the freshness model; the
sparkline is 90 days with gaps drawn as breaks (§8.2). Return since holding is
`AdvancedHolding.returnFraction`, which already exists
([AdvancedPortfolioReport.swift:44](../Packages/Reports/Sources/FinvestLensReports/AdvancedPortfolioReport.swift#L44))
and is surfaced nowhere on this page today.

**Grouping.** Held is the default population (D4). *Manual valuations*,
*Watching* and *Closed* are collapsed group headers with counts — one click to
reveal, and the choice is remembered per book.

**Exchange rates** get a single line, because they are the same trust question:
a foreign holding valued without a rate is silently wrong. The book has seven
currencies and 80 FX rows. The old destination's "Add Rate" sheet moves here
intact; there is no rate *list*, for the same reason there is no price list.

**Primary action.** `Update Prices` stays one click (⌘⇧U, unchanged). Its menu
carries scope and provider — *All holdings*, *Only what's stale*, *Include
closed positions with gaps*, *Choose provider…* — so the common case needs no
sheet and the uncommon case needs no separate destination. This is where the
old Quotes sheet's provider picker goes.

---

## 7. Surface B — the security detail

Reached by clicking a holding. One scrolling page with a section jump, not
tabs. Sections adapt to the instrument: an ASX share, a bond and a Super fund
show different things, and pretending otherwise is what made the old page
generic and useless.

```
┌────────────────────────────────────────────────────────────────────────┐
│ ‹ Investments                                    [ Refetch ▾ ] [ ⋯ ]   │
│                                                                        │
│  Company Name                                    ASX · AUD · priced 2d │
│  price  ▲ +1.2% today          Units · Value · Allocation · Avg cost   │
│                                                                        │
│  ── Performance ──────────────────────────────────────────────────────  │
│   Return since holding   Unrealised   Realised   Income   Yield on cost │
│                                                                        │
│  ── Price history ────────────────────────────  1M 6M 1Y 5Y All Held ─  │
│    ╱╲      ▲buy      ▼sell        ▲buy                                 │
│   ╱  ╲╱‾╲ ╱    ╲╱‾╲╱     ╲   ╱‾╲╱                                      │
│   ┈┈┈┈┈┈┈┈┈┈┈┈┈┈ average cost ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈                     │
│   ░░ held period ░░░░░░░░░░░░░░░░░░░░  ▒ gap ▒                         │
│                                                                        │
│  ── Profile ──────────────────────────── Yahoo Finance · as of 3 Aug ─  │
│   Sector · Industry · Market cap · Employees · description…            │
│                                                                        │
│  ── Financials ──────────────────────  Income · Balance · Cash flow ─   │
│  ── Dividends ───────────────────────  declared vs recorded  (§8.4) ─   │
│  ── Your transactions ───────────────  buys, sells, income → register ─ │
│  ── Lots ────────────────────────────  open lots, cost basis, CGT ────  │
│  ── Prices ──────────────────  this security only · source · [Export] ─ │
│  ── Settings ─────────  ticker override · ISIN · provider · target ───  │
└────────────────────────────────────────────────────────────────────────┘
```

Section notes:

- **Price history** is the centrepiece and the thing no competitor can draw:
  the provider's series, *your* buy/sell markers from the book, your average
  cost as a horizontal line, the held period shaded, and gaps hatched. Range
  includes **Held** — the period you actually owned it, which is the only range
  that matters for judging your own decisions.
- **Profile / Financials** are fetched and cached (§10), always stamped with
  the source and an "as of" date, and always able to say *unavailable* without
  looking broken (D5). For a **bond** these sections are replaced by FIIG's
  own fields — coupon type and rate, frequency, maturity, call date, yield,
  sector, issuer description — which is a better profile than Yahoo could give.
- **Prices** is the only place a price table exists: one security, a few
  hundred rows, with the **source column visible**, inline editing, delete, and
  **Export CSV** (D3). This is where hand-entered valuations are typed for
  Super funds.
- **Settings** collects everything per-security that is scattered today: ticker
  override (from the Quotes sheet), **ISIN** (new, editable — GnuCash's
  `cmdty:xcode`), quote provider, price target (from `PriceTargetSheet`),
  valuation policy (auto/manual), watch/unwatch, display name.

---

## 8. The four models that make it work

These are the substance. Everything in §6–§7 is a rendering of one of them.

### 8.1 Freshness is value-weighted, and per holding

`lastPriceUpdate` is one date for the whole book
([AppModel+Quotes.swift:195](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Quotes.swift#L195)).
It answers a question nobody asks. The useful metric:

```
coverage = Σ marketValue(h) for h where price is current
           ─────────────────────────────────────────────
           Σ marketValue(h) for all held h
```

"Current" is **market-aware**, not a fixed number of days: a price is current
if it is the most recent *trading day* for that security's exchange, so a
Monday morning does not report every ASX holding as stale over the weekend.
Bands: current / stale (1–5 trading days) / old (>5) / missing.

The virtue of weighting: a tiny dormant holding cannot drag the number down,
and a large stale one cannot hide behind 30 healthy ones. It is the only
number that answers "can I trust today's valuation".

### 8.2 A gap only matters if you held it

A missing price is not automatically a defect. It is a defect **when it falls
inside a period you held the security**, because that is when it silently
corrupts historical net worth and the performance chart. Outside a holding
period it is irrelevant.

So gap detection intersects the provider's trading calendar with the book's
holding periods, and this directly implements D4: a closed position is not
fetched for *today's* price, but **is** fetched to fill a hole in the period it
was held. The existing fetch already spans holding periods and skips
non-trading days
([AppModel+Quotes.swift:246-277](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Quotes.swift#L246));
what is missing is *reporting* gaps rather than only closing them.

### 8.3 Provenance, and prices that cannot be right

Six sources are recorded in the book and none is shown. Two-thirds of the
prices are hand-entered, which is exactly the population most likely to contain
a typo. The detail page shows source per row and marks it on the chart, and an
**outlier check** flags a price that moves more than a threshold against its
neighbours — a decimal-point slip, a price entered in cents, a price in the
wrong currency. This is cheap to compute and catches the errors that make a
portfolio chart untrustworthy.

### 8.4 Dividend reconciliation — declared vs recorded

The provider knows what was declared. The book knows what was received. **The
difference is a worklist nobody else can produce**, and it finds real money:

| Case | Meaning |
| --- | --- |
| Declared, not recorded | Income never entered — the book understates income |
| Recorded, not declared | A wrong date, wrong security, or a special dividend |
| Amounts differ | Withholding, franking, or a DRP recorded at the wrong price |
| Declared, DRP units missing | Units understated, so every later valuation is wrong |

The same machinery covers **corporate actions**: if the provider reports a
split the book has no transaction for, every price before that date is
inconsistent with the units held, and the historical chart is silently wrong.
Detecting it is a ratio check; fixing it is the existing Stock Transaction
Assistant (`FR-INV-04`).

This section is the strongest argument for the hub existing at all: it is a job
that requires the ledger *and* the market, so no portfolio tracker and no
accounting package can do it alone.

---

## 9. Providers

| Provider | Key | History | Role after this work |
| --- | --- | --- | --- |
| Yahoo | no | yes | Default prices **and** default fundamentals (D5); best ASX coverage |
| Stooq | no | yes | Keyless fallback for prices |
| EODHD / Alpha Vantage / Twelve Data | yes | yes | Preferred for fundamentals when a key exists; EODHD for delisted history |
| Finnhub | yes | no | Latest only, unchanged |
| **FIIG** | **no** | **no** | **New.** Australian corporate bonds, matched by ISIN |

### FIIG — a different provider shape

Verified against the live API on 11 Aug 2026 (curl, from this machine):

- `GET https://bondtickerapi.fiig.com.au/api/instruments/bonds?pageNo=1&pageSize=2000&…`
  returns **703 bonds in a single response**, keyed by `isin`. HTTP 200.
- This inverts the provider protocol: every other provider is *one request per
  symbol*, FIIG is **one request for the whole market**, then a local ISIN
  lookup. The `QuoteProvider` protocol needs a batch path, or FIIG needs an
  internal one-shot cache per run. The batch path is better — it also suits
  future providers.
- `price` is the **clean capital price as a percentage of par** (sample:
  `98.846`). The book stores bond prices par-relative — every bond row in the
  test book is `1.0` — so the conversion is **`price ÷ 100`**, and applying it
  replaces 11 par placeholders with real market prices.
- `bondHistory` is **null** on the list endpoint, so FIIG is
  `supportsHistory: false`. History accrues going forward from daily fetches.
- The record carries fundamentals — `coupon` (type), `couponDetail` (rate, **a
  string**), `couponFrequency`, `maturityDate`, `callDate`, `yield`, `sector`,
  `companyDescription`, `url` — which become the bond profile in §7.
- The WAF rejects requests without browser-like headers; `User-Agent`, `Origin`
  and `Referer` are required, as `HTTPDefaults.userAgent` already does for
  Yahoo.
- **TLS:** the reference implementation
  ([ChristineTham/investalens](https://github.com/ChristineTham/investalens),
  `lib/providers/fiig-bond-rates.ts`) disables certificate verification because
  the server omits an intermediate CA and Node does not chase AIA. curl on this
  machine verified the chain cleanly (`ssl_verify_result=0`), so URLSession is
  expected not to need the workaround. **This must be confirmed against
  URLSession during implementation** — and if it does fail, the answer is to
  pin/supply the intermediate, never to disable verification in a shipping app.
- **Geo:** FIIG appears to firewall non-AU egress. A failure must say so
  plainly rather than reporting a generic network error.

**ISINs are already in the book.** All 11 bonds carry an `exchangeCode` — 10
matching the AU ISIN shape, max length 12 — which is GnuCash's `cmdty:xcode`.
So FIIG matches your holdings with **no data entry**, and the Settings section
(§7) makes the field editable for the eleventh.

---

## 10. Where fetched data lives

Per D2, **nothing fetched beyond prices enters the book.**

```
~/Library/Application Support/…/Fundamentals/
    <namespace>|<mnemonic>.json      profile, statements, dividends, corporate actions
                                      + source, fetchedAt, provider version
```

- Keyed by commodity identity, so it survives a rename and follows a book copy
  only if the user copies it — which is correct, because it is a cache.
- **TTL by kind**: profile monthly, statements quarterly, dividends weekly.
  Every rendering shows source and "as of"; a manual **Refetch** is always
  available.
- Discardable at any time with no data loss, and never written during a save.
- **Prices remain the only fetched thing in the book**, so the two invariants —
  splits balance to zero, GnuCash XML round-trips byte-identically — are
  untouched by this work. That is the whole reason for the sidecar.
- The cache holds third-party licensed content: it is **not** exported, not
  included in reports, and not in any published artifact.

---

## 11. What is deleted

Deleting is half the design:

| Gone | Because |
| --- | --- |
| The global price list (148,458 rows) | D3 — nobody wants to see that |
| The Prices/Securities segmented picker | The split was never one a person cared about |
| The Quotes sheet | Provider → the Update menu; tickers → per-security Settings; keys were already in Settings |
| `AddPriceSheet` | Replaced by inline entry where the price is missing |
| The exchange-rate list | Same reason as the price list; `AddRateSheet` survives |
| "Prices & Securities" in **Records** | Re-filed as **Investments**, a first-class destination |

---

## 12. Accessibility, platforms, localization

Non-negotiable, and checked by `/ui-review` before this is called done:

- The confidence ring is **not** colour-alone: it carries a text percentage and
  a VoiceOver label reading the fraction and the count needing attention.
- Freshness bands use shape **and** colour (dot style differs per band).
- Sparklines are decorative to VoiceOver; the row's accessibility label states
  symbol, price, age and return, so the table is fully usable without them.
- Every chart has an `accessibilityChartDescriptor`-equivalent summary.
- `Table` column order matches keyboard focus order; every action reachable by
  keyboard; no shortcut double-bound (⌘⇧U keeps its meaning).
- Dynamic Type via `scaledFont` throughout; no `Font.system(size:)`.
- `.tint` as a `ShapeStyle` only — `Color.accentColor` stays banned.
- **iPad** gets the same two surfaces, detail pushed rather than side-by-side
  in compact width. **iPhone** gets the holdings list and the detail page; the
  chart drops the transaction markers below a width threshold rather than
  crowding.
- Every new string goes in the app target's catalog, with plural variations —
  no English-suffix hacks, no `String`-typed label parameters.

---

## 13. The full requirement list

Proposed PRD rows. **U** = explicitly requested by the user; **N** = not asked
for, proposed by this design.

| ID | | Requirement |
| --- | --- | --- |
| FR-INV-08 | U | Replace *Prices & Securities* with an **Investments** destination, promoted out of *Records* |
| FR-INV-09 | U | **Price-database health**: value-weighted coverage, per-holding freshness, last run, failures, next scheduled run |
| FR-INV-10 | N | Freshness is computed against the **exchange trading calendar**, not elapsed days |
| FR-INV-11 | U | **Holdings table** with units, price, age, sparkline, market value, allocation |
| FR-INV-12 | U | **Sparklines highlight missing data** as breaks, not interpolated lines |
| FR-INV-13 | N | **Needs-attention worklist**: classes of problem with counts and inline fixes; empty on a healthy book |
| FR-INV-14 | U | **Return since holding** per security, from the existing lot engine |
| FR-INV-15 | U | **Security detail page**: profile, price history, financials, dividends, transactions, lots, prices, settings |
| FR-INV-16 | N | The price chart overlays **your buys, sells, average cost and holding periods** |
| FR-INV-17 | U | **Company profile** fetched from Yahoo, keyed providers preferred when configured |
| FR-INV-18 | U | **Financial statements** (income, balance sheet, cash flow), cached |
| FR-INV-19 | U | **Dividend history**, declared, with yield on cost |
| FR-INV-20 | N | **Dividend reconciliation**: declared vs recorded, with the four discrepancy classes |
| FR-INV-21 | N | **Corporate-action detection**: a provider split with no matching book transaction is flagged |
| FR-INV-22 | U | **Choose the provider** for a refresh, per run and per security |
| FR-INV-23 | U | **Refetch one security or all**, replacing or filling history |
| FR-INV-24 | U | **Hide closed positions** by default, with a reveal control |
| FR-INV-25 | U | Fetches **include closed positions where their held period has gaps** |
| FR-INV-26 | N | **Holding-aware gap detection**: gaps are reported, not just silently filled |
| FR-INV-27 | N | **Provenance is visible** — the source of every price, on the row and the chart |
| FR-INV-28 | N | **Outlier detection** on prices, catching decimal and currency slips |
| FR-INV-29 | U | **Export prices to CSV by security** |
| FR-INV-30 | N | **Manual valuation as a first-class category** with cadence and inline entry (D6) |
| FR-INV-31 | N | **FIIG provider**: Australian bonds by ISIN, batch fetch, `÷100` par conversion |
| FR-INV-32 | N | **ISIN is a first-class, editable identifier** (GnuCash `cmdty:xcode`) |
| FR-INV-33 | N | **FX-rate health** in the same panel; foreign holdings cannot be silently unvalued |
| FR-INV-34 | N | **Run preview**: what a refresh will do — securities, gaps, requests — before it runs |
| FR-INV-35 | N | Fetched fundamentals live in a **sidecar cache**, never in the book (D2) |
| FR-INV-36 | — | Correct `FR-INV-03a`: the Yahoo provider does **not** fetch dividends or splits today |

---

## 14. Phases

Each phase is independently shippable and leaves the app working.

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| **I1** Foundations | Freshness model, gap model, holding-aware coverage, provenance surfacing; pure `Reports`/`Engine` additions with tests. No UI. | Coverage and gaps computed for the test book; suites green |
| **I2** The overview | Investments destination, confidence band, worklist, holdings table with sparklines, grouping, FX line. Old destination removed. | Three-second test passes on the real book; `/ui-review` clean |
| **I3** The detail page | Detail surface, price chart with transaction overlay, per-security price table, CSV export, per-security settings incl. ISIN | A security's whole story on one page; export round-trips |
| **I4** FIIG | Batch provider protocol, FIIG provider, ISIN matching, `÷100` conversion, URLSession TLS check | 11 bonds priced from market instead of par |
| **I5** Fundamentals | Sidecar cache, Yahoo `quoteSummary`, keyed-provider preference, profile + statements + dividends | Profile renders or degrades cleanly; nothing fetched enters the book |
| **I6** Reconciliation | Dividend reconciliation, corporate-action detection, outlier check | Discrepancies found on the real book and explainable |
| **I7** Polish | Manual-valuation cadence, run preview, iOS parity | Both platforms build; compact width verified |

**Help and localization are not a phase.** Documentation here is four things,
not one, and a surface change owes all of them in the same commit:

| Where | What it is |
| --- | --- |
| `docs/` spine | prd (intent) · architecture (decisions) · plan (phases) · implemented (built) · deferred (consciously not) |
| `HelpContent.swift` | the in-app help book — user-facing, localized |
| `website/src/data/manual.json` | the published manual, **generated** from the help book; CI fails on drift |
| `Localizable.xcstrings` | every new string, in eight languages |

A help book describing the previous design is worse than no help book — it is
confidently wrong, and it is *published*. `HelpContent.swift` ▸ *Investments and
prices* already documents the destination this work replaces, so I2 rewrites it
and regenerates the manual in the same commit. (I7 originally collected all of
this; that was a scheduling error — it would have shipped five phases of new
surfaces documented as the thing they replaced, on the website as well as in
the app.)

**Requirements precede code.** `FR-INV-08`…`FR-INV-35` are in the PRD before
their phase is built, so each phase implements a written requirement rather than
the document rationalising what was written. I1 committed its rows alongside its
code, which is the wrong order and is not repeated.

**Verification throughout:** the real book is the acceptance harness
(`FL_PERF_FILE`), because 148,458 prices and 87 securities is the case that
broke the old design. A synthetic fixture cannot reproduce it.

---

## 15. Non-goals

- **No advice.** Nothing recommends buying, selling or holding. The app reports
  what happened and what is inconsistent — the planning doctrine
  ([planning-design.md](planning-design.md)) applies unchanged.
- **No trading, no account linking, no order entry.**
- **No intraday or streaming quotes.** Daily close is the granularity a
  double-entry book values at.
- **No replacement for the Reports surfaces** (D7).
- **No fundamentals in the book file** (D2), and therefore no fundamentals in
  the GnuCash XML round-trip.
