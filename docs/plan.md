# FinvestLens — Phased Implementation Plan

| | |
|---|---|
| **Document status** | **Phases P0–P12 complete.** v1.0 was P0–P6 (13 July 2026); P7 business, P8 extended import, P9 planning & insights, P10 ledger CLI & interchange and P11 the Investments hub have landed since, **plus the Jul 2026 usability/performance and report-quality redesigns**, and the Aug 2026 register-style restoration and large-book NAS validation that closed the last NFR-02 item (`finlab`, [lab.md](lab.md)). Online bank sync skipped to [deferred.md](deferred.md). |
| **Last updated** | 2026-08-15 |
| **Scope** | The build plan: phases, workstreams, tasks, dependencies, and exit criteria |
| **Companions** | [PRD](prd.md) · [Architecture](architecture.md) · [Porting Strategy](porting.md) · [Implemented](implemented.md) · [Deferred backlog](deferred.md) · [Money study](enhancements-msmoney.md) · [Firefly study](enhancements-firefly.md) · [Frollo study](enhancements-frollo.md) |

This is the authoritative **delivery schedule and status record**. It sequences the requirements from the [PRD](prd.md) (`FR-*`), the architecture decisions ([`ADR-*`](architecture.md)), and the porting map ([Porting §2](porting.md)) into thirteen phases (P0–P12), and records where each one stands. Each phase lists its **objective, workstreams/tasks, dependencies, deliverables, exit criteria, test focus, and risks**.

### Phase status

| Phase | Status | Notes |
|---|---|---|
| **P0 — Foundation** | ✅ Complete | |
| **P1 — Native document & import** | ✅ Complete | |
| **P2 — Core UX** | ✅ Complete | |
| **P3 — Export & round-trip** | ✅ Complete | Lossless round-trip GnuCash-verified. |
| **P4 — Everyday finance & bank import** | ✅ Complete | |
| **P5 — Investments & multi-currency** | ✅ Complete | Investment reports GnuCash-verified to the cent. |
| **P6 — Sync, dashboard, alerts & polish** | ✅ Complete | Plus the post-1.0 **Apple Intelligence** layer (FR-AI-01…08). |
| **P7 — Business features** | ✅ Complete | Engine + persistence + XML round-trip + UI. |
| **Usability & performance redesign** | ✅ Complete (24 Jul 2026) | A post-P7 pass over the P2/P4/P6 surfaces, driven by four audits ([usability-review.md](usability-review.md), [performance-review.md](performance-review.md)): one expandable register, plain language, the non-scrolling tile-board dashboard, auto-clear-first reconcile, one-click prices (⌘⇧U), a single status overlay, session restoration, memoised async reports, and the EOFY Financial Year Pack. Narrative in [implemented.md](implemented.md). |
| **Report-quality redesign** | ✅ Complete (24 Jul 2026) | Statements at annual-report standard — face-and-notes presentation from the user's own tree, ASC 274 ordering, accounting typography, comparatives, incl. the Trial Balance — plus the Financial Review and Investment Review slide decks with validator-grounded on-device insights. Plan/research: [report-redesign.md](report-redesign.md); design: [architecture.md §5.6a](architecture.md); narrative in [implemented.md](implemented.md). |
| **P8 — Extended import** | ✅ Complete (24 Jul 2026) | MT940/MT942 + CAMT.053 importers feed the Import Matcher; format auto-detection incl. content sniffing. Online bank sync (FR-XIO-07) **skipped by decision (24 Jul 2026)** — moved to [deferred.md](deferred.md) §5. |
| **P9 — Planning & insights** | ✅ Complete (24 Jul 2026) | Debt & Lifetime planners, tax estimator, Spending Insights, wellbeing score, passport PDF, savings challenges, Emergency Records, audit log — design in [planning-design.md](planning-design.md). |
| **P10 — Ledger CLI & interchange** | ✅ Complete (25 Jul 2026) — P10a–P10d all delivered | Ledger 3 journal import/export + the read-only `finlens` CLI. Research + phased plan in [ledger-design.md](ledger-design.md) (format spec: [ledger-format-reference.md](ledger-format-reference.md), CLI spec: [ledger-cli-reference.md](ledger-cli-reference.md)). |
| **P11 — The Investments hub** | ✅ Complete (15 Aug 2026) — I1–I7 | Portfolio panel, security detail, FIIG bond provider, fundamentals sidecar, reconciliation. Design: [investments-design.md](investments-design.md). |
| **P12 — Modes, sidebar & tabs** | ✅ Complete (15 Aug 2026) | The navigation redesign, all of it: seven modes on ⌘1…⌘7 with five on the toolbar, one sidebar per mode, a tabbed detail pane, Overview as a board of views, one period selector, All Transactions repaired, sidebar sorting. Design: [navigation-design.md](navigation-design.md); requirements `FR-NAV-01…12`. |

**Every phase P0–P12 is delivered**; a set of low-priority tails deferred *within* them is tracked, ranked, in [deferred.md](deferred.md). The narrative of what was built, with the audits and measurements behind it, is in [implemented.md](implemented.md).

---

## 1. Delivery principles

- **Engine-first, bottom-up.** Nothing is built on an unproven foundation. `Money` and the engine model come before persistence; persistence before UI.
- **Every phase is releasable.** Each phase ends at a usable, demoable, test-green state.
- **Protocol boundaries.** Persistence (`Repository`), file IO, XML interchange, and quotes sit behind protocols (Architecture P4) so layers evolve independently.
- **Test-gated.** A phase is "done" only when its **exit criteria** and quality gates (§14) pass. Round-trip fidelity (`FR-EXP-02`) and the double-entry invariant (`FR-ENG-06`) are hard gates.
- **Vertical slices where possible.** Within a phase, prefer thin end-to-end slices (one account type, one report) over broad-but-shallow work.
- **Native-first.** Reach for Apple frameworks; add a dependency only per the architecture's budget (§9 there).

---

## 2. Module (SPM target) structure — establish in P0

```
FinvestLens/                     (Xcode project, existing)
 └─ Packages/
     ├─ Engine          pure Swift: Money, model, Scrub, Query, GncGUID, KvpFrame
     ├─ Persistence     GRDB store + Repository protocols + Document/FileLock
     ├─ Interchange     GnuCash XML codec · CSV/QIF/OFX parsers · Import Matcher
     ├─ Quotes          QuoteProvider protocol + provider adapters
     ├─ Reports         report computation services (+ chart models)
     ├─ Rules           rules engine + operator search grammar
     └─ FeatureUI       SwiftUI views/view-models (per platform)
FinvestLensApp targets (macOS/iPadOS/iOS) depend on FeatureUI → downward only.
```

Dependencies point downward only; `Engine` builds/tests with nothing above it (`FR-ENG-12`).

Four more packages joined after P0, making **eleven** in all: `Shared` (the
Foundation-only App-Group snapshot leaf, P6), `Intelligence` (the on-device
model layer, P6+), `CLI` (`finlens`, P10c) and `Lab` (`finlab`, Aug 2026). The
app target and `finlab` are both top-level consumers above `FeatureUI`;
`finlens` sits beside them on Engine/Persistence/Interchange/Reports only. The
current graph is [architecture.md §9](architecture.md).

---

## 3. Cross-cutting workstreams (run continuously from P0)

| Stream | What | Starts |
|---|---|---|
| **Testing & CI** | Swift Testing; CI (`ci.yml`) builds and tests all eleven packages plus the unsigned macOS/iOS app on every PR, and gates SPDX headers. Perf and live-book harnesses are env-gated (`FL_*`) and skip in CI. Coverage is **not** currently measured. | P0 |
| **Fixture corpus** | Books synthesized in-test per package, plus env-gated harnesses against the real reference book (`FL_ROUNDTRIP_FILE`, `FL_PERF_FILE`). No committed `.gnucash` corpus and no synthetic generator — real books are gitignored, and a real 46,578-transaction book proved the better instrument. | P1 |
| **Design system** | SwiftUI component kit, dark/light, Dynamic Type; charts per the [dataviz](enhancements-firefly.md) standards | P2 |
| **Performance harness** | Open/scroll/import/save benchmarks vs NFR-02; NAS write-back tests. *An `os_signpost` + DEBUG over-budget harness (`Perf`) now wraps the hot paths (Jul 2026).* | P1 |
| **Accessibility & localization** | VoiceOver, Dynamic Type, locale-aware formatting; string catalogs | P2 (audit in P6) |
| **Security** | Keychain for API keys; optional Face/Touch ID to open a book | P5 (keys), P6 (lock) |

---

## 4. Phase P0 — Foundation (engine core)

**Objective.** A standalone, pure-Swift accounting engine with exact-enough money and enforced double-entry — no persistence, no UI.

**Workstreams & tasks**
- **Project setup:** create the SPM targets (§2); wire Swift Testing + CI; add the GPLv3 file-header template check.
- **`Money`** over `Foundation.Decimal` (+ `Commodity` association): arithmetic, comparison, rounding to commodity fraction via `NSDecimalRound`. *(FR-ENG-01, ADR-1)*
- **`GncGUID`** — 16 bytes with GnuCash 32-hex (no-dash) codec. *(FR-ENG-11, ADR-3)*
- **`KvpFrame`/`KvpValue`** recursive value types covering GnuCash slot types. *(groundwork for FR-IMP-06, ADR-4)*
- **Model:** `Commodity`/`CommodityTable` (`FR-ENG-08`); `Account` + all account types (`FR-ENG-02/03`); `Split` (`FR-ENG-05`); `Transaction` with the **balancing invariant** (`FR-ENG-04/06`); `Book` aggregate.
- **Balances:** raw/cleared/reconciled + running balance. *(FR-ENG-07)*
- **`Scrub`** integrity/repair (imbalance→Imbalance acct, orphans). *(FR-ENG-06, FR-IMP-08)*

**Dependencies.** None.
**Deliverables.** `Engine` package; test suite; CI green.
**Exit criteria.** Engine compiles alone; construct transactions in code and balances are enforced/correct (tolerant asserts); ≥90% coverage of core logic; unbalanced transactions cannot be committed.
**Test focus.** `Money` ops with tolerance; balancing invariant; Scrub on malformed graphs.
**Risks.** ADR-1 rounding choices (PR1) — settle the per-commodity rounding mode here (see §17).

---

## 5. Phase P1 — Native document & GnuCash import

**Objective.** Open/save the native `.finvestlens` SQLite document safely (incl. NAS), and import GnuCash XML into it.

**Workstreams & tasks**
- **GRDB store & schema:** tables mapping the engine model; GUID + `KvpFrame`-as-JSON columns; `DatabaseMigrator`; `meta` (schema version + change counter). *(FR-DAT-01/02/04, ADR-2)*
- **Repository protocols:** `BookStore`, `AccountStore`, `TransactionStore`, `PriceStore`, … isolating GRDB. *(ADR-2, ADR-5)*
- **Document lifecycle:** open→lock→**local working copy**→materialize `Book`; edit locally; **explicit Save/autosave**→checkpoint→atomic write-back; **Discard/Revert**; recent files. *(FR-DAT-03/05/07/09/10, FR-PLT-05, Architecture §3/§6)*
- **`FileLock`:** lock file + holder metadata + heartbeat + stale-lock detection; `NSFileCoordinator`; conflict detection on write-back. *(FR-DAT-06/07/08, ADR-8)*
- **UTI/document type** registration for `.finvestlens` (`public.database`). *(FR-PLT-04)*
- **GnuCash XML importer:** gzip detect (magic `1f 8b`) + zlib; `XMLParser` SAX mappers per object (commodities, accounts, transactions/splits, prices); **preserve slots + GUIDs**; import summary; run **Scrub**. *(FR-IMP-01..08, ADR-2/ADR-4)*
- ✅ **Perf validation (10 Aug 2026):** a real 46,578-transaction / 103,365-posting / 54 MB book, open/scroll/save on a local SSD **and** a real SMB share, measured with `finlab bench` / `finlab import`. The planned synthetic 100k generator was never built — a real book of this size was available and is better evidence. *(NFR-02; §17)*

**Dependencies.** P0.
**Deliverables.** `Persistence` + `Interchange` (import half) packages; a document you can open/edit/save; GnuCash import.
**Exit criteria.** Create/open/save a document on local **and** a network share with working single-writer locking; **discard a session** leaves the on-disk file byte-unchanged; import a real `.gnucash` file with structure/GUIDs/slots intact and Scrub clean; large-book perf meets NFR-02 on local **and** SMB ✅ (46,578 transactions / 54 MB, 10 Aug 2026).
**Test focus.** Locking/write-back/discard (§14.4); import structural fidelity; migration.
**Risks.** PR6 (NAS write-safety, scale) — **closed 10 Aug 2026**: the network load test ran on a real 46,578-transaction / 54 MB book over SMB and settled §17 in favour of always-working-copy.

---

## 6. Phase P2 — Core UX (accounts & register)

**Objective.** A usable app: chart of accounts and a working transaction register.

**Workstreams & tasks**
- **App shell:** SwiftUI document app; `NavigationSplitView` (macOS/iPad) / stacks (iOS); open/save/recent UI; macOS menu-bar mapping. *(FR-PLT-01, Architecture §8)*
- **Chart of accounts:** hierarchical tree + balances; create/edit/reparent/hide/delete with guards; placeholder/hidden; codes + renumber. *(FR-COA-01..06)*
- **Register/ledger:** simple + multi-split entry with live balancing; transfer/duplicate/delete/void; inline reconcile-state; reversing/jump/copy/remove-splits; whole-book journal view. *(FR-REG-01..09.)* *Built with GnuCash's three view styles; Jul 2026 replaced them with one expandable register, and Aug 2026 restored them as **Basic Ledger / Auto Details / Transaction Journal** over a single unified disclosure (PRD FR-REG-03, [register-ux-research.md](register-ux-research.md)). The whole-book journal ships as **All Transactions**.*
- **QuickFill** autofill (payee/description/last-split). *(FR-REG-04)*
- **Find/search (basic)** via GRDB predicates. *(FR-REG-06 — upgraded in P4)*
- **Tags (model + minimal UI).** *(FR-TAG-01, early)*
- **Formatting/prefs:** Foundation formatters; `UserDefaults`/SwiftUI settings. *(NFR-06, replaces GSettings)*

**Dependencies.** P0, P1.
**Deliverables.** `FeatureUI` package; interactive app.
**Exit criteria.** Create accounts; enter/edit balanced (simple & split) transactions; running balances correct; search; everything persists through save/reopen.
**Test focus.** UI round-trips through the store; balancing in the editor; large-register scroll perf.
**Risks.** Register perf at 100k rows — bounded `FetchDescriptor` + cached balances (ADR-5).

---

## 7. Phase P3 — GnuCash export & round-trip

**Objective.** Write GnuCash XML that GnuCash reopens; prove round-trip fidelity.

**Workstreams & tasks**
- **Streaming XML writer:** GnuCash namespaces + exact element order; re-emit preserved slots/GUIDs; gzip + uncompressed. *(FR-EXP-01/03/04, ADR-2)*
- **Round-trip harness + corpus:** import→export→re-import; compare **object graphs** (amounts within tolerance) + order-normalized XML for structure. *(FR-EXP-02, NFR-08)*
- **Import/export UI:** menu commands, share sheet, progress.

**Dependencies.** P1 (import), P2.
**Deliverables.** `Interchange` (export half); CI round-trip gate.
**Exit criteria.** Exported file reopens cleanly in GnuCash desktop; the round-trip corpus passes in CI.
**Test focus.** Round-trip corpus; slot/GUID preservation; GnuCash-desktop reopen smoke test.
**Risks.** PR2 (slot/unknown-element loss) — compare graphs, not just re-render.

---

## 8. Phase P4 — Everyday finance, bank import & automation

> The largest phase — sequence internally as **P4a** (reconciliation, SX, budgets, core reports) → **P4b** (bank import + matcher) → **P4c** (rules, search language, bills/forecast, onboarding).

**Objective.** Daily-driver completeness: reconcile, schedule, budget, report, and import bank files with rule-driven automation.

**Workstreams & tasks**
- **A. Reconciliation** + auto-clear. *(FR-REC-01..03; ports `gnc-autoclear`)*
- **B. Scheduled transactions:** `Recurrence`, "since last run" instance model, expression parser for amounts. *(FR-SCH-01..03; ports `SchedXaction`/`Recurrence`/`gnc-sx-instance-model`/`gnc-exp-parser`)*
- **C. Core reports:** Balance Sheet, Income Statement/P&L, Net Worth, Transaction Report, Cash Flow — Swift services + Swift Charts + PDF/print. *(FR-RPT-01/03/04/05; refactor from Scheme)*
- **D. Budgets:** per-account/period; **rollover/envelope**; projected end-of-period; **auto-budget** replenish; zero-based workflow. *(FR-BUD-01/02/03, FR-PLAN-04)*
- **E. Bank file import (core):** CSV (CodableCSV + mapping profiles), QIF (custom parser), OFX/QFX (custom: v2→`XMLParser`, v1→SGML normalizer); shared **Import Matcher** (duplicate detection, account assignment). *(FR-XIO-01/02/03/05/06/08, ADR-7a; Architecture §5.8a)*
- **F. Rules engine:** rule groups; triggers (strict/non-strict); actions (category/budget/tags/notes/convert/link); stop-processing; run on create/update/import. *(FR-RULE-01; supersedes FR-PLAN-06)*. Ship a **default category taxonomy + heuristic auto-categorisation / merchant-name cleanup** on import. *(FR-RULE-03, Frollo-inspired)*
- **G. Operator search language** + saved searches; shared grammar with rule triggers. *(FR-FIND-01; upgrades FR-REG-06)*
- **H. Bill reminders + Financial Calendar + bill matching** (expected amount/range, paid/unpaid/overdue). *(FR-PLAN-01, FR-BILL-01)*
- **I. Cash-flow forecast** from scheduled bills/deposits. *(FR-PLAN-02)*
- **J. Onboarding / setup assistant** (starter chart of accounts). *(FR-PLAN-09, FR-COA-03)*

**Dependencies.** P2, P3.
**Deliverables.** Reconciliation, SX, budgets, core reports; CSV/QIF/OFX import; rules + search; bills/forecast.
**Exit criteria.** Import a bank CSV/QIF/OFX file → matcher dedupes and rules auto-categorize → reconcile against a statement → core reports render → budgets track → a scheduled transaction posts on due date.
**Test focus.** Parser conformance (vs ofxtools/Quiffen fixtures); matcher dedup; rule engine trigger/action matrix; SX recurrence vs GnuCash; report totals parity.
**Risks.** OFX v1 SGML tolerance; rule-engine scope — ship trigger/action subset first, expand.

---

## 9. Phase P5 — Investments, multi-currency & quotes

**Objective.** Full securities support with prices, lots/cap-gains, multi-currency, and live/historical quotes.

**Workstreams & tasks** — status as of completion.
- ✅ **PriceDB + Price Editor.** *(FR-ENG-09, FR-INV-02)*
- ✅ **Securities** — created with commodity (exchange/ticker/name) in the New Account editor; dedicated **Security Editor** (rename across holdings) shipped later in the backlog sweep. *(FR-INV-01/07)*
- ✅ **Lots + FIFO/LIFO/average + cap-gains + Investment Lots report.** *(FR-ENG-10, FR-INV-05)*
- ✅ **Stock Transaction Assistant** — buy/sell/dividend/reinvest/**split** (lot-rescaling)/**return-of-capital**. Commission is expensed (not capitalised). *(FR-INV-04)*
- ✅ **Multi-currency** transactions + exchange rates + FX valuation + currency-transfer entry + optional **trading accounts**. *(FR-CUR-01..04, FR-REG-07)*
- ✅ **Quote providers:** keyless Yahoo + keyed EODHD/Alpha Vantage/Finnhub; Keychain keys; latest + historical backfill; injectable transport; **scheduled auto-refresh**. *(FR-INV-03/03a–e, FR-CUR-04, ADR-7)*
- ✅ **Investment reports:** Portfolio, Advanced Portfolio (allocation donut, price-history chart), Price Scatter, Investment Lots. *(FR-RPT-02)*
- ✅ **Portfolio enhancements:** asset allocation, rate of return, **watch lists + price targets**. *(FR-PLAN-07)*
- ✅ **What-if scenarios** on cash flow (session-only hypothetical events). *(FR-PLAN-03)*
- ✅ **Rules apply-to-historical + preview** (safe recategorisation of the income/expense leg + notes). *(FR-RULE-02)*

**Dependencies.** P4.
**Deliverables.** Investments module; quote layer; investment reports.
**Exit criteria.** ✅ Record buys/sells/dividends/splits; ✅ fetch latest + historical quotes (keyless and keyed, incl. delisted via EODHD); ✅ compute cap gains via lots; ✅ value a multi-currency portfolio in a base currency.
**Status.** **Complete** — including the once-deferred Security Editor, trading accounts, scheduled quote refresh, watch lists and return-of-capital (all shipped in the functional-backlog sweep).
**Test focus.** Lot/cap-gains, cost-basis methods, splits; quote-provider parsing; FX valuation.
**Risks.** Yahoo endpoint drift (keyed providers as stable fallback); cap-gains subtlety.

---

## 10. Phase P6 — Sync, dashboard, alerts & polish

**Objective.** Ecosystem integration and the guidance layer.

**Workstreams & tasks** — status as of completion.
- ✅ **File-level sync:** `NSFilePresenter` external-change handling + a reload banner; `NSFileVersion` conflict listing/resolution; reuses the P1 SHA256 fingerprint. Storage-agnostic (local / network share / iCloud); the iCloud Documents container is enabled in the app entitlements. *(FR-PLT-02)*
- ✅ **App Intents / Shortcuts:** Net Worth, Upcoming Bills, Financial Alerts intents + `AppShortcutsProvider` (Siri/Spotlight/Shortcuts). ✅ **Widgets / Quick Look** shipped later as extension targets (`FinvestLensWidgets` incl. a Control widget, `FinvestLensQuickLook` for `.finvestlens`; the Apple-modernization pass). *(FR-PLT-03)*
- ✅ **Alerts engine (Advisor-FYI):** bill-due, projected low/negative balance, over-budget, price-target, and unusual-spend (added in the Jul 2026 review pass); severity-ranked; KVP-persisted price targets. Surfaced on the dashboard, via the Alerts intent, and as local notifications (`AlertNotificationScheduler`). *(FR-PLAN-05)*
- ✅ **Home dashboard:** net-worth headline + 12-month trend, alerts, account balances, upcoming bills, budget status. *(FR-PLAN-08.)* *Reworked by the Jul 2026 redesign into a **non-scrolling tile board** — prioritised, content-aware cards packed into the actual window, per-user show/hide, and an Up Next action card.*
- ✅ **Accessibility pass:** VoiceOver labels/values on account rows, dashboard, alerts and every chart. ✅ **Localization** — the string catalogs shipped 25 Jul 2026, eight languages. *(NFR-05/06)*
- ✅ **Optional book lock** (Face/Touch ID via injectable `Authenticating`; Security menu; lock screen). *(NFR-07)*

**Dependencies.** P4 (bills/budgets/alerts data), P5 (portfolio for dashboard/widgets).
**Deliverables.** Sync machinery, Shortcuts, dashboard, alerts, book lock; a11y-labelled UI.
**Status.** **Complete** — the once-deferred extension work (iCloud container, widgets, Quick Look, local notifications) all shipped in the later Apple-modernization pass. Nothing from P6 remains open; professional native-speaker review of the catalogs is the one optional follow-up ([deferred.md](deferred.md) §1).
**Test focus.** Conflict resolution; alert rule correctness.
**Risks.** File-sync conflicts on simultaneous edits — reuses the P1 conflict-detection machinery.

---

## 11. Phase P7 — Business features

**Objective.** Small-business accounting.

**Workstreams & tasks**
- **Customers/Vendors/Employees.** *(FR-BUS-01/02; ports `gncCustomer`/`gncVendor`/`gncEmployee`)*
- **Invoices (A/R) & Bills (A/P)** posting via lots/entries. *(FR-BUS-03; ports `gncInvoice`/`gncEntry`)*
- **Jobs, Billing Terms, Tax Tables.** *(FR-BUS-04; ports `gncJob`/`gncBillTerm`/`gncTaxTable`, `libgnucash/tax`)*
- **Payments + A/R–A/P aging.** *(FR-BUS-05)*
- **Company info.** *(FR-BUS-06)*
- **Time & mileage tracking.** *(FR-PLAN-14)*
- **Import business objects** from GnuCash XML. *(FR-IMP-05)*

**Dependencies.** P4 (engine + reports patterns).
**Deliverables.** Business module; business XML import.
**Exit criteria.** Create/post an invoice and a bill, record payments, see aging; business objects round-trip through GnuCash XML.
**Test focus.** Invoice→A/R posting correctness; business object round-trip.
**Risks.** Business posting depth — port `ScrubBusiness`/lot linkage closely (PR5).

---

## 12. Phase P8 — Extended import

**Status.** ✅ **Complete (24 Jul 2026).** `MT940Importer` (SWIFT MT940/MT942 — tag-line scanner with continuation folding, `:61:` subfield grammar incl. reversals and funds codes, `:86:` narratives with German `?nn` subfield extraction) and `CAMTImporter` (streaming ISO 20022 CAMT.053/052 — signed amounts, PDNG filtering, reference/counterparty/remittance extraction across schema versions) feed `StagedTransaction` into the existing Import Matcher; `BankFileFormat.detect` adds extension mapping (`.sta`/`.940`/`.c53`/…) plus content sniffing for ambiguous `.xml`/`.txt`. Exit criterion verified in `MT940CAMTTests`: both formats through the matcher with correct dedupe (FITID and amount+window) and history-based account assignment. Preceded, same day, by an import-matcher hardening pass validated on four real bank exports (transfer completion, FITID veto, one-to-one claiming — [implemented.md](implemented.md)). (Report PDF export, once listed here as a P4 fallback, was delivered in P4. **Online bank sync was skipped by decision on 24 Jul 2026** — cloud-mediated connectors sit poorly with the app's local-first stance, and the AU CDR path carries a regulatory burden out of proportion to a file-import app; moved to [deferred.md](deferred.md) §5, revisit only on strong demand.)

**Objective.** Broader statement-file interoperability.

**Workstreams & tasks**
- ✅ **MT940/MT942 + CAMT.053 (ISO 20022)** statement import → matcher. *(FR-XIO-04)*

**Dependencies.** P4 (Import Matcher).
**Deliverables.** Bank-statement importers (SWIFT MT + ISO 20022) feeding the existing Import Matcher.
**Exit criteria.** Import a CAMT.053 and an MT940 file through the matcher with correct dedupe and account assignment. ✅
**Risks.** Format variance across banks — parse against published samples from several institutions, as the QIF/OFX parsers were.

---

## 13. Phase P9 — Planning & insights

**Status.** ✅ **Complete (24 Jul 2026).** Design and models in [planning-design.md](planning-design.md); pure calculators in `FinvestLensReports` (`DebtPlan`, `LifetimeProjection`, `TaxEstimate`, `SpendingInsights`, `WellbeingScore`) with fixture tests, the book-facing layer in `AppModel+Planning`, and the UI as a **Planner** sidebar destination (Debt Reduction / Lifetime / Tax Estimate), a **Spending Insights** report, a **Wellbeing** dashboard tile, the **Financial Summary (passport)** PDF, **savings challenges** on goals, the **Emergency Records** destination (local-authentication gate), and a GnuCash-style **audit-log sidecar** with a Tools viewer. Exit criteria verified on the real book (`LivePlanningTests`): SMSF-seeded lifetime buckets and a 51-year projection, a debt payoff plan over the live credit card, and a bracket-computed tax estimate from tagged accounts. **TXF export was consciously skipped** — a US interchange format with no meaning for an AU book; the `tax-US` code slot still round-trips for GnuCash parity ([deferred.md](deferred.md)).

**Objective.** The flagship planning layer.

**Workstreams & tasks**
- ✅ **Debt Reduction Planner** (snowball/avalanche; payoff date, interest saved). *(FR-PLAN-10)*
- ✅ **Lifetime Planner** (long-range projection: income/expenses/assets/retirement/taxes/inflation/life-events → net worth over time, goal feasibility). *(FR-PLAN-11)*
- ✅ **Tax estimator + tax-line tagging + capital-gains estimator.** *(FR-PLAN-12)*
- ✅ **Insights & comparison reports** (trends, period-vs-period, plain-language). *(FR-PLAN-13)*
- ✅ **Financial wellbeing score** (explainable) and **financial summary "passport"** PDF export. *(FR-PLAN-16/17, Frollo-inspired)*
- ✅ **Savings challenges** (gamified goals). *(FR-GOAL-02, Frollo-inspired)*
- ✅ **Emergency Records Organizer** (secure records). *(FR-PLAN-15)*
- ✅ **Audit logging.**

**Dependencies.** P5 (investments/tax data), P6 (dashboard surface).
**Deliverables.** Planners, tax tools, insights.
**Exit criteria.** Produce a debt-payoff plan and a lifetime projection from real book data; estimate tax from tagged tax lines. ✅
**Risks.** Lifetime Planner is large and assumption-heavy — ship a transparent, adjustable model; label projections clearly (not advice, per NG4).

---

## 13b. Phase P10 — Ledger CLI & interchange

**Status.** ✅ **Complete (25 Jul 2026)** — P10a–P10d all delivered. Full research and the
phased plan live in [ledger-design.md](ledger-design.md); the journal-format
and CLI specs (verified against the Ledger 3 manual and its C++ source) are
[ledger-format-reference.md](ledger-format-reference.md) and
[ledger-cli-reference.md](ledger-cli-reference.md).

**Objective.** Bridge to plain-text accounting: read/write Ledger 3 journals
with GnuCash-XML-grade round-trip seriousness, and ship `finlens` — a
ledger-modelled, strictly read-only CLI over `.finvestlens` books, ledger
journals, and GnuCash files.

**Sub-phases** (each releasable; detail + exit criteria in the design doc §7):
- ✅ **P10a** — Ledger codec core in Interchange (parser + canonical writer; fixed-point pinned).
- ✅ **P10b** — Book ⟷ journal mapping, read-only store access, app File ▸ Import/Export menus; real-book round-trip verified byte-identical with zero errors. *(FR-XIO-09/10)*
- ✅ **P10c** — the `finlens` CLI package: core-80 commands, query/period grammars, the interactive REPL, 28 golden/grammar tests, read-only guarantee; 371 real-book balances match the engine. *(FR-CLI-01..03, 05)*
- ✅ **P10d** — depth on demand: valuation flags, periodic grouping, `--budget` family, `xact`, mini value-expressions. *(FR-CLI-04)*

**Dependencies.** P1 (store), P3 (interchange patterns), P5 (PriceDB for valuation).
**Risks.** Grammar breadth; output-fidelity expectations; foreign journals vs the double-entry invariant — mitigations in the design doc §8.

## 13c. Phase P11 — The Investments hub

**Status.** ✅ **Complete (11–15 Aug 2026)** — I1–I7 delivered. Design,
decisions and the full requirement list live in
[investments-design.md](investments-design.md); requirements are `FR-INV-08`
… `FR-INV-35`.

**Objective.** Replace the *Prices & Securities* destination — a database editor
that showed 148,458 price rows when 7 needed attention — with an **Investments**
hub: a portfolio instrument panel that answers "can I trust today's numbers"
in three seconds, volunteers only rows that need a human, and drills to one
security's whole story. Prices stop being a subject and become a precondition.

**Sub-phases** (each releasable; exit criteria in the design doc §14):
- ✅ **I1** — the models: trading-calendar freshness, holding-aware gaps,
  value-weighted coverage, provenance. Pure `Reports` additions, no UI.
  *(FR-INV-09, 10, 26, 27)*
- ✅ **I2** — the overview: destination, confidence band, worklist, holdings
  table with sparklines, grouping, FX line; old destination removed, help book
  and website manual rewritten with it.
  *(FR-INV-08, 11, 12, 13, 14, 22, 24, 33)*
- ✅ **I3** — the security detail page: price chart with buy/sell/average-cost/
  held-period overlay, performance, activity, lots, the app's only price table
  (with provenance and inline editing), CSV export, and per-security settings
  including an editable ISIN. *(FR-INV-15, 16, 27, 29, 32)*
- ✅ **I4** — the FIIG bond provider: `BatchQuoteProvider` (one request for the
  whole 702-bond market), ISIN matching via `cmdty:xcode`, percent-of-par ÷100,
  per-security provider routing. URLSession trusts the chain — no TLS
  workaround. 10 of the reference book's 11 bonds now priced from market
  instead of held at par. *(FR-INV-22, 23, 31)*
- ✅ **I5** — fundamentals: the sidecar cache (never the book), Yahoo's
  cookie-plus-crumb `quoteSummary` handshake for profile and statements, the
  chart endpoint's `events=div|split` for dividends and splits (no handshake),
  and FIIG's own record as a bond's profile. Degrades to "unavailable" without
  looking broken. *(FR-INV-17, 18, 19, 35, 36)*
- ✅ **I6** — reconciliation: declared dividends against recorded income with
  the four discrepancy classes, unrecorded corporate actions, and a
  median-based price-outlier check. Every finding is a discrepancy to look at,
  never a correction applied. *(FR-INV-20, 21, 28)*
- ✅ **I7** — polish: fetch scope (holdings / behind / closed-with-gaps), the
  run preview that counts **requests** rather than securities, manual-valuation
  cadence so a super fund is not stale every trading Tuesday, plus help,
  localization and both platform builds. *(FR-INV-25, 30, 34)*

**Dependencies.** P5 (price DB, providers), P6 (dashboard/alerts patterns),
the lot engine behind `FR-RPT-02a` (return since holding is already computed
there and merely unsurfaced).

**Verification.** The real book is the acceptance harness throughout
(`FL_PERF_FILE`): ~150k prices across ~90 securities, half no longer held, is
the case that broke the old design and the only one worth accepting on. A
synthetic fixture cannot reproduce it.

**Risks.** Yahoo's `quoteSummary` is unofficial and needs a crumb handshake —
fundamentals must degrade to "unavailable" rather than look broken. FIIG
geo-restricts non-AU egress and serves an incomplete certificate chain. Both
are contained: neither can affect prices already in the book.

## 13d. Phase P12 — Modes, sidebar and tabs

**Status.** ✅ **Complete (15 Aug 2026).** All seven sub-phases N1–N7 shipped.
Design, alternatives and the guidance behind each decision live in
[navigation-design.md](navigation-design.md); requirements are `FR-NAV-01` …
`FR-NAV-12`. What was built, and the two places the build corrected the
design, are in [implemented.md](implemented.md).

**Objective.** One sidebar currently holds thirteen functional destinations
above a 565-account tree. The account list is therefore present in Reports where
it means nothing, absent the moment the user types in a field labelled "Filter
accounts", and pinned to the window's bottom edge where the HIG says not to put
what people use most. Replace it with **modes**: an always-visible mode selector
in the toolbar, one sidebar per mode showing one kind of thing two levels deep,
and a tabbed detail pane so several registers or reports share one sidebar.

**All of it ships in 1.1.** The halves are not independent: a mode-scoped
sidebar without a mode selector is unreachable, and a mode selector over the
present mixed sidebar is two navigation models in one window. Shipping part
would leave the inconsistency this phase exists to remove.

**Sub-phases** (ordered by dependency; N1 is the spine):

- **N1 — Mode infrastructure.** `AppMode`; per-mode state *(selection, open
  tabs, sidebar scroll)* replacing the flat `SidebarSelection`
  (`AppModel.swift:150`); migration for stored desk state, with the old flat
  value mapped to its mode; View menu listing every mode with ⌘1…⌘n; toolbar
  segmented control with system toolbar customisation and the five-mode default.
  *(FR-NAV-01, 02, 03)*
- **N2 — Mode-scoped sidebars.** One sidebar component parameterised by mode;
  the six collections wired to their existing model arrays; the mixed sidebar
  deleted. The filter-erases-navigation bug (`Views.swift:994`) disappears with
  the mixing that caused it — there is nothing left for a filter to erase.
  *(FR-NAV-04)*
- **N3 — The tabbed interface.** Tab strip in the detail pane; click replaces,
  double/⌘-click/context-menu/new-tab-button opens; an already-open item is
  focused, never duplicated; a placeholder expands rather than opening an empty
  register; the mode's home tab is first and not closeable; the set persists as
  desk state. *(FR-NAV-05, 06)*
- **N4 — Overview as a board of views.** Sidebar of views with their cards
  nested beneath; card zoom to full window with a close button; toolbar list of
  every card including those not on the board; custom views, favourites as saved
  views; and the navigation rule — selection never switches mode, drill-down and
  the explicit "Open …" button do. *(FR-NAV-07, 08, 09, 10)*
- **N5 — One period selector.** A single control governing every mode and
  seeding report defaults, replacing the dashboard's private period.
  *(FR-NAV-11)*
- **N6 — All Transactions repaired.** It is already `RegisterSheet(wholeBook:)`
  but that flag forks three behaviours: journal style forced over the user's
  choice (`RegisterSheet.swift:81`), reconcile dropped (`:879`), Transfer and
  Amount removed from the ⇥ order (`:2838`). Honour the chosen style, restore
  reconcile and the editing order, add an **Account** column, and make it the
  Accounts home tab. *(FR-REG-09, FR-NAV-06)*
- **N7 — Sidebar manners.** Sort by criterion or by hand, manual order in the
  account's kvp; drag to reorder between siblings versus **re-parent** onto a
  row, with distinct drag feedback and dragging disabled while a criterion sort
  is active. *(FR-NAV-12; the shared context menu shipped 15 Aug 2026.)*

**Exit criteria.**
1. Every mode's sidebar contains exactly one kind of thing, two levels deep, and
   no list of commands.
2. The mode selector is visible in every mode at every supported window width,
   and never reaches the system overflow menu.
3. A mode absent from the toolbar is still reachable from the View menu by
   shortcut; no mode is ever hidden or disabled for having empty content.
4. Switching mode and returning restores that mode's selection and open tabs.
5. No gesture switches mode except a drill-down or an explicit button —
   demonstrated by selecting every Overview view and card in turn with the mode
   selector unchanged throughout.
6. Opening an already-open item focuses its tab; the open set survives relaunch.
7. All Transactions honours the chosen register style, shows reconcile, tabs
   through Transfer and Amount, and carries an Account column.
8. On the reference book: the sidebar renders 565 accounts, and the whole-book
   home tab opens within the measured envelope (20.5 ms cold row supply,
   `LiveWholeBookPerfTests`).
9. Catalogs match the compiler in eight languages; both platforms build; the
   accessibility gate passes on every new surface.

**Dependencies.** None outside the app layer — no engine, persistence or
interchange change. That is what makes a change this visible tractable.

**Risks.**
- **Attribute-graph exhaustion.** Every mode sidebar and the tab strip must stay
  lazy; the 15 Aug 2026 import crash was a non-lazy container holding rows that
  each fanned out. Only the visible tab may build content.
- **Losing the user's place.** Desk-state migration must map every stored
  `SidebarSelection` to a mode; a user who reopens into a different place than
  they left will not trust the release.
- **Localization volume.** Mode names, view names, tab commands and sort
  criteria across eight languages; the catalog gate is the check.
- **Scope pressure.** Records ships with the collections it already has (rules,
  emergency records, audit log). Its new collections — assets, depreciation
  schedules, deductions, logbooks, timesheets — are
  [records-and-rules-design.md](records-and-rules-design.md) and a later phase,
  not 1.1. Business likewise stays thin until invoices and payees fill it.

**Verification.** The reference book is the acceptance case: 565 accounts,
46,831 transactions, and a sidebar that must stay responsive while the mode
selector never moves on its own.

## 14. Quality gates (apply every phase)

1. **Double-entry invariant** — no unbalanced transaction persists (`FR-ENG-06`). *Hard gate.*
2. **Round-trip fidelity** — import→export→re-import preserves structure/GUIDs/slots; amounts within tolerance (`FR-EXP-02`). *Hard gate from P3.*
3. **Numeric sanity (tolerant)** — `Money`/`Decimal` correctness with tolerances (ADR-1).
4. **Locking/write-back/discard** — concurrent openers, stale-lock break, mid-save crash, conflicting write, and discard/revert never corrupt or silently clobber the document (`FR-DAT-06/07/08/09`).
5. **Performance** — 100k-transaction document meets open/scroll/import/save targets (NFR-02).
6. **Accessibility** — VoiceOver + Dynamic Type on new screens (NFR-05); full audit in P6.
7. **Coverage** — engine/interchange core ≥90%; CI green on every PR.

---

## 15. Sequencing & dependency overview

```
P0 Engine ─▶ P1 Document+Import ─▶ P2 Core UX ─▶ P3 Export/round-trip
                                        │
                                        ▼
                         P4 Everyday finance + bank import + automation
                             │                 │
                             ▼                 ▼
                    P5 Investments+quotes   P7 Business
                             │                 │
                             ▼                 ▼
                    P6 Sync/dashboard/alerts   │
                             │                 │
                             ▼                 ▼
                    P9 Planning & insights   P8 Extended import
```

- **Critical path to a daily-driver release:** P0 → P1 → P2 → P3 → P4.
- P5/P7 branch off P4 and can proceed in parallel given capacity.
- P6, P8, P9 layer on the earlier phases; P9 depends on P5 (investments/tax) and P6 (dashboard).

---

## 16. Traceability

Every task cites its PRD `FR-*` (or NFR/ADR). Requirement → phase mapping is the `Phase` column of PRD §5 and the [Porting §2](porting.md) map; this plan is the inverse view (phase → tasks). The two hardest gates — round-trip fidelity (`FR-EXP-02`) and the double-entry invariant (`FR-ENG-06`) — have dedicated harnesses from P1/P3 onward.

## 17. Decision checkpoints

The architecture's open decisions and their resolutions:

| Decision | Resolution |
|---|---|
| Per-commodity rounding mode | ✅ Half-up per commodity fraction. |
| WAL vs DELETE journal for the working copy | ✅ Rollback (DELETE) journal — the write-back artifact is always one self-contained file. |
| Default quote providers shipped | ✅ Keyless Yahoo default; keyed EODHD / Alpha Vantage / Finnhub. |
| Target GnuCash XML schema version | ✅ GnuCash v5-era (`gnc:book` 2.0.0), round-trip verified against GnuCash 5.16. |
| Lock heartbeat interval & stale threshold | ✅ Periodic heartbeat + a stale threshold that offers Break-Lock; stable on provider drives. |
| GRDB direct-mode vs always-working-copy at scale | ✅ **Always working-copy; direct mode not built** (10 Aug 2026). Measured on a 46,578-transaction / 54 MB book: locally the working-copy hop costs **0 ms** (an APFS clone), so there is nothing to win; over SMB, reading the same book without it took **40.6 s against 3.5 s**. No upside on one side and 11.6× on the other. [architecture.md](architecture.md) §10, numbers in [implemented.md](implemented.md). |

## 18. References

- [PRD](prd.md) · [Architecture](architecture.md) · [Porting Strategy](porting.md) · [Money study](enhancements-msmoney.md) · [Firefly study](enhancements-firefly.md) · [Frollo study](enhancements-frollo.md) · [README](../README.md)
