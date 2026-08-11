# Deferred backlog — open items within P0–P10

Work that was **in scope for the delivered phases (all of P0–P10)** but is
still open: deferred, partial, or not yet built. It is **ranked** — highest
priority / readiest to pick up first.

Two items were **skipped from the plan by decision** (online bank sync from
P8, TXF export from P9) — §5 below. P10 shipped complete (25 Jul 2026); the
ledger surface it deliberately left out (`select`, `convert`, format strings,
`--pivot`, `--anon`, plot and lisp/xml output) is recorded in
[ledger-design.md](ledger-design.md) §5.4, not here — none of it was ever in
scope. The 24 Jul 2026 backlog pass built
everything else that was buildable without external dependencies (credit
notes, the round-trip fidelity tail, load-time warnings, the iOS rename/move
flow, rule link-to-bill), and the 25 Jul 2026 full-codebase review pass closed
the two remaining PRD *Should* gaps it surfaced (the unusual-spend alert and
goal-to-bill links) — see [implemented.md](implemented.md). What remains below
needs hardware, runners, translators, or a judgement call.

Each row cites its PRD `FR-*`/`NFR-*` and the phase it belonged to.

Companions: [Plan](plan.md) · [PRD](prd.md) · [Implemented](implemented.md).

---

## 1 — Release readiness (do first)

Quality automation and validation that a shippable release needs.

| Item | FR / Phase | Notes |
|---|---|---|
| CI: app + Intelligence jobs on a hosted runner | NFR-08 / P0, P3 | ✅ **Done (26 Jul 2026).** GitHub ships `macos-26` arm64 runners; `.github/workflows/ci.yml` now runs there — all eleven packages build and test (Intelligence's live-model tests skip themselves off-device), SPDX headers are gated, and the unsigned app + extensions build (macOS and iOS Simulator) is a required job. |
| Large-book perf validation (local + SMB/NFS) | NFR-02 / P1 | ✅ **Done (10 Aug 2026)** on real hardware — a 46,578-transaction / 103,365-posting / 54 MB book on an SMB share (`//nas3._smb._tcp.local`), measured with `finlab bench` and `finlab import`. **The open architecture decision is closed: always-working-copy stands, and direct mode is not worth building.** On a local volume the working-copy hop costs **0 ms** — it is an APFS clone — so there is nothing to win; over SMB, reading the same book *without* it (SQLite over the wire, as `finlens` does per ADR-L2) took **40.6 s against 3.5 s**, 11.6× worse, of which only 2.0 s was CPU. Numbers in [implemented.md](implemented.md). |
| `finlens` reads a NAS book without a working copy | NFR-02 / P10 | **Open, newly found (10 Aug 2026).** ADR-L2 makes the CLI take no lock and no working copy, which is right for safety and expensive over a network: `finlens stats` on the 54 MB book took **40.6 s** (1.96 s of it CPU) where the app's copy-then-read path took 3.5 s. Copying to a local temp before opening read-only would keep every promise ADR-L2 makes — it still never writes to the book — and remove the gap. Not done here because it changes CLI behaviour outside the task that found it. |
| Real balances in published commit messages | NFR-08 / P0 | ✅ **Rewritten and pushed 11 Aug 2026** (`3a7bb86`); GitHub's collection of the orphaned objects is the only part still outstanding. A commit message is as public as any file in the tree, and `git filter-repo --replace-text` rewrites *blobs only* — messages need `--replace-message`. A first pass on 10 Aug applied the size rule alone and left **thirteen figures across twelve messages**, several in the same sentence as `[redacted]` markers that had already landed, which is what made them easy to skim past. The second pass removed all thirteen: HEAD's tree hash is unchanged, the count is still 367 commits, and the API now serves **zero** real figures across every message. Two of the thirteen were invisible to a size threshold — a net worth in shorthand (`$…k`), and a sub-$10k account movement — and were found instead by asking which lines *assert something about the real book*. `no-figures-in-commits.py` now tests size **or** that context, blocks shorthand, and flags none of the 369 real messages; three regression cases were added (suite: 33). **The one open item:** GitHub serves unreferenced commits until it garbage-collects, and there is no API for it (`…/git/gc` → *Not Found*). Support said on 11 Aug they had cleared the first rewrite's objects, but the sample SHAs still answered **HTTP 200** on the web page, the unauthenticated API and `.patch`. Verified that nothing holds them: the only refs are `main` and `v1.0` (both on current history), 0 forks, 0 pull requests ever, one release targeting `main`. Support has been asked again (11 Aug) and the answer is theirs to give. |
| Localization (string catalogs) | NFR-06 / P6 | ✅ **Done (25 Jul 2026).** `finvestlens/Localizable.xcstrings` carries all 1,126 UI strings in **de, es, fr, it, ja, pt-BR, zh-Hans**, with a second catalog for the Quick Look extension's own bundle. Key set verified against the compiler's `-emit-localized-strings` output — no missing keys, no dead entries. Professional review by native speakers is the remaining (optional) step. |

## 2 — User-facing gaps (high value, tractable)

Common workflows partly built; each is a bounded piece of work.

| Item | FR / Phase | Notes |
|---|---|---|
| Rule actions tail | FR-RULE-01 / P4 | **link-to-bill shipped 24 Jul 2026** (a rule stamps the payment with the schedule's GUID; bill reminders match it exactly before falling back to the name heuristic). Remaining, both left by judgement: **convert-type** (fuzzy in a double-entry model) and **set-budget** (budgets here are per-account planned amounts — a rule "assigning a budget" to a transaction has no coherent target; recorded 25 Jul 2026). |
| Quick Look for `.gnucash` | FR-PLT-03 / P6 | ✅ **Done (9 Aug 2026).** The app now declares `org.gnucash.book` as an *imported* type (the type is GnuCash's; we only read it) and the extension previews all three shapes GnuCash writes, told apart by their first bytes rather than by extension: gzipped XML, plain XML, and its SQLite backend. Interchange was **not** linked in — that would drag Engine into an extension Quick Look launches on a Finder selection. Instead the XML paths read GnuCash's own `<gnc:count-data>` header from an inflated *prefix*, so a 9.6 MB book measured 6.7 ms; the SQLite path reuses the existing reader, telling the two schemas apart by table name (`accounts`/`transactions` vs our `account`/`txn`, read from `libgnucash/backend/sql/`). |

## 3 — Apple Intelligence import caveats (monitor)

Quality limits of the on-device import layer (PRD §5.18), caught by the review screen.

| Item | FR / Phase | Notes |
|---|---|---|
| Scanned-statement OCR quality | FR-AI-01 / P4 | Vision OCR fallback untested against real bank scans; digital-PDF reflow is solid. |
| Statement sign inference without a balance column | FR-AI-01 / P4 | Signs re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (the review screen catches it). |
| iOS file pickers on-device | FR-AI-01/03/04/07 / P4–P7 | iOS keeps `.fileImporter`; not yet exercised on a device. |

## 4 — Platform & HIG — deferred decisions

| Item | Notes |
|---|---|
| App Sandbox | Disabled by decision: sibling `.lock` files at user-selected locations are denied by the sandbox; related-item declaration + coordinated I/O are in place but macOS still refused. Direct (notarized) distribution doesn't need it. Revisit before any Mac App Store submission. |
| Esc inside a focused text field | AppKit's field editor consumes the raw Escape (completion); ⌘. always cancels, Esc works otherwise. SwiftUI offers no clean override (accepted). *The Jul 2026 F19 sweep put `onEscapeCommand` on every sheet — this field-editor caveat is the one remaining Esc limit.* |

## 5 — Skipped from the phase plan (revisit only on demand)

Work removed from a planned phase by decision — neither scheduled nor
won't-fix. It stays recorded here so the reasoning survives.

| Item | FR | Notes |
|---|---|---|
| **TXF export** | FR-PLAN-12 (adjunct) | **Skipped with P9, 24 Jul 2026.** TXF is a US tax-interchange format; the reference book (and the app's AU defaults) has nothing to feed it. The GnuCash `tax-US` code slot still round-trips untouched, so nothing is lost for GnuCash users; build an exporter only if a US user base appears. |
| **Online bank sync** (SimpleFIN / GoCardless (Nordigen); AU **CDR / Open Banking** via an accredited intermediary such as Basiq) | FR-XIO-07 | **Skipped from P8, 24 Jul 2026.** A cloud-mediated, consent-managed connector sits poorly with the app's offline, local-first core (NFR-03/07); the CDR path in particular carries accreditation/intermediary diligence and ongoing API-maintenance burden out of proportion to a document app whose import story (CSV/QIF/OFX files + AI PDF import + the Import Matcher) already covers the data. Revisit only on strong user demand — the design sketch (aggregator → `StagedTransaction` → Import Matcher, credentials user-entered into Keychain) remains valid in [PRD §5.14](prd.md) and the [Frollo study](enhancements-frollo.md). |

---

## Accepted divergences (won't-fix)

Not open work — recorded so they aren't re-raised as bugs. Detail in
[implemented.md](implemented.md).

- Currency-commodity export emits `cmdty:fraction`/`name` that GnuCash omits for
  ISO currencies — within FR-EXP-02 tolerance, round-trip byte-verified.
- `isBalanced` treats a sub-minor-unit residual as balanced (ADR-1).
- Average-cost basis keeps full precision to the report edge where GnuCash rounds
  progressively (~2¢ over 40 years).
- **Managed-fund money-flow realised model** (FR-RPT-02) — our per-parcel engine
  subtracts non-fee expense splits booked inside managed-fund transactions where
  GnuCash's money-in/out model washes them out (~[redacted] realised across ~6
  accounts). Matching would mean adopting GnuCash's money-flow model, which is
  arguably *not* more correct — kept per-parcel by decision.
- **`rebuildAccountTree` subtree-only rebuild / incremental journal rebuild**
  (NFR-02) — the ~0.04s of a refresh spent on a full-tree rebuild is fast
  enough to feel instant; subtree-only and incremental-journal rebuilds are
  micro-optimizations to do only if a profile shows they matter. The Jul 2026
  `Perf` signpost harness now watches exactly these paths, so the trigger is
  a measured number, not a hunch.
- **Investment Review: no benchmark or volatility statistics** (Jul 2026
  report redesign) — fund factsheets carry benchmark-relative performance and
  risk measures (standard deviation, Sharpe); the book holds no benchmark
  series and no return time-series to compute them honestly from, so the
  deck's risk read is **concentration** (largest holding, top-five share) and
  its performance read is return-on-money-in. Revisit only if benchmark data
  ever enters scope.
- **Report computation stays on the main actor** (Jul 2026 redesign) — heavy
  reports are memoised per (parameters, revision) and build behind a
  placeholder after first paint, but the build runs on the main actor: the
  engine `Book` is a non-`Sendable` object graph, and a background read would
  race main-actor edits. Going further needs a book **read-gate** (writers
  wait on in-flight readers) — deliberately deferred until the memoised
  first-build is shown too slow in practice (Architecture §10).
- **Local-time date bucketing** (production review, 2026-07-19) — reports and the
  register bucket dates with `Calendar.current` throughout, an internally
  consistent local-time convention. GnuCash files store dates in UTC, so an
  imported day-only date can appear on the adjacent local day at a period edge;
  aligning would be a project-wide canonical-timezone decision, not a local fix,
  and changing only reports would be the regression.
- **Quotes record the caller-specified currency** (production review) — a fetched
  `Price` is stamped with the currency the caller asked for, not the provider's
  reported `currencyCode` (which rides in `source` for provenance). Multi-currency
  FX valuation is a higher layer by design.
- **GnuCash-XML element text is whitespace-trimmed on import** (production review) —
  leading/trailing whitespace in memos/descriptions/notes/names is dropped so XML
  indentation can't leak into values; byte-for-byte text fidelity is sacrificed by
  choice.
