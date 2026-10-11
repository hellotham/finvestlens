# Deferred backlog — open items

> **This file holds open work only.** Anything finished belongs in
> [implemented.md](implemented.md); a row that has been done is moved, not
> ticked. Five completed rows were carrying ✅ markers here on 11 Aug 2026 and
> have been moved.

Work that was in scope for the delivered phases (P0–P10, and P11 in progress)
but is still open: deferred, partial, or not yet built. It is **ranked** — highest
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

*(Empty. The one entry here — `finlens` reading a NAS book across the wire —
was built on 15 Aug 2026: `SourceLoader.readBook` takes a local copy first when
the book is on a network volume, keeping both of ADR-L2's promises. Local books
read in place, because the hop is 0 ms on APFS where a copy is a clone.)*

## 2 — User-facing gaps (high value, tractable)

Common workflows partly built; each is a bounded piece of work.

| Item | FR / Phase | Notes |
|---|---|---|
| Rule actions tail | FR-RULE-01 / P4 | **link-to-bill shipped 24 Jul 2026** (a rule stamps the payment with the schedule's GUID; bill reminders match it exactly before falling back to the name heuristic). Remaining, both left by judgement: **convert-type** (fuzzy in a double-entry model) and **set-budget** (budgets here are per-account planned amounts — a rule "assigning a budget" to a transaction has no coherent target; recorded 25 Jul 2026). |

## 3 — Apple Intelligence import caveats (monitor)

Quality limits of the on-device import layer (PRD §5.18), caught by the review screen.

| Item | FR / Phase | Notes |
|---|---|---|
| Scanned-statement OCR quality | FR-AI-01 / P4 | Vision OCR fallback untested against real bank scans; digital-PDF reflow is solid. |
| Statement sign inference without a balance column | FR-AI-01 / P4 | Signs re-derived from the running balance; statements with unsigned debit/credit columns *and* no balance column may import with wrong signs (the review screen catches it). |
| iOS file pickers on-device | FR-AI-01/03/04/07 / P4–P7 | iOS keeps `.fileImporter`; not yet exercised on a device. |

## 3a — Foundation Models 27 — consciously not adopted (9 Oct 2026)

What the 27 SDK added (Apple's *Foundation Models updates* page and the SDK
interface, both read 9 Oct 2026) and why the Intelligence package does not
use it. The doctrine in architecture.md stands: everything runs on the
on-device model and no financial data leaves the device.

| Feature | Why not (yet) |
|---|---|
| `PrivateCloudComputeLanguageModel` — more reasoning, larger context | Sends the prompt to Apple's Private Cloud Compute. Off-device by definition; ruled out by the doctrine, not by capability. |
| `LanguageModel` protocol, `CoreAILanguageModel`, `MLXLanguageModel` | Lets any model stand in for the system one. Nothing to gain while the on-device model does the job; a third-party model would need its own privacy case. |
| Image attachments in prompts + Vision `OCRTool` / `BarcodeReaderTool` | The import pipeline already OCRs with Vision and feeds *text* to the model, which is what the real-document harnesses validate. A multimodal rewrite needs re-validation against the real bank files before it could replace that. |
| `LanguageModelSession.DynamicProfile` (agentic sessions), `GenerationOptions.ToolCallingMode` | No session here uses tools or multi-turn agency; every call is one guided-generation request. |
| `SystemLanguageModel.Variant` (`core3`, `coreAdvanced3`) | Read-only: it *reports* which on-device model backs the instance (Apple's doc page, read 9 Oct 2026); there is no initializer to choose one. |
| `Guardrails.permissiveContentTransformations` | Tried and reverted the same day: Apple's safety article says it applies only to string responses, and every session here is guided generation, which keeps the default guardrails regardless. The classifier's guardrail refusals were fixed by re-phrasing instead (see implemented.md). |
| `SystemLanguageModel.contextSize` / `tokenCount(for:)` (26.4) for pre-sizing statement chunks | The extractor's split-and-retry on `contextOverflow` already works, and the 27 model's context is 8,192 tokens (measured 9 Oct 2026), twice the 4,096 the loop was tuned on. Worth revisiting only if overflow retries show up in real imports. |

## 4 — Platform & HIG — deferred decisions

| Item | Notes |
|---|---|
| App Sandbox | **Enabled 11 Oct 2026** for the Mac App Store and TestFlight. The earlier refusal of the sibling `.lock` had a plain cause: the related item was declared with `CFBundleTypeRole = None`, which the sandbox honours as a *read-only* grant — the coordinator ran the accessor and the write itself was denied (`NSCocoaErrorDomain 513`). With `Editor` (and `LSHandlerRank = None`) the same presenter and coordinated I/O write the lock and the `.audit` sidecar beside a book, verified on a local folder and on the Box Drive folder. See `docs/app-store.md`. |
| The phone keeps less than the iPad | Still open in the compact shell (`CompactShell.swift`, shipped 12 Oct 2026): no account editing, deleting, cascading, favouriting or reordering from the account list — those live in the sidebar's context menu and drag, which the phone's list does not carry (a posting's row actions do work, on a long press); no filter over the account tree; no saved-searches menu (the search field remains); the Import menu and the board's "Import…" row are not shown (`FR-PLT-06` leaves import off the phone; an iPad window narrowed to the compact shell loses them with the rest of the regular toolbar), while a report's PDF export and Share remain; the loan calculator's schedule is a `Table` and shows one column; the phone editor edits date, description, notes and each split's account, amount and (where its account is held in another commodity) quantity — tags, the transaction number, a split's memo and action, and the currency the transaction was recorded in are kept as they were but are edited on the Mac or iPad. |
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

- **Apple's `secondaryLabelColor` / `tertiaryLabelColor` below WCAG AA in light
  mode** — measured 16 Aug 2026: 3.95:1 and 1.88:1 on a white row, against the
  4.5:1 body text needs (dark mode passes at 5.89:1). macOS's Increase Contrast
  does not change them: all three of `secondaryLabelColor`, `tertiaryLabelColor`
  and `systemRed` resolve to identical components under
  `accessibilityHighContrastAqua`, which was checked rather than assumed.
  **Kept, by the owner's decision on 16 Aug 2026**, over darkening them app-wide
  or only under Increase Contrast: they are platform semantic colours used as
  the platform intends, at several hundred call sites, and nothing they carry is
  the only place a fact appears. The places where the shortfall *did* matter
  were fixed rather than accepted — a figure coloured by its sign
  (`Color.negativeAmount` / `.positiveAmount`) and the planning disclaimer;
  see [implemented.md](implemented.md) ▸ Accessibility review.
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
- ~~**Quotes record the caller-specified currency**~~ (production review) —
  **reversed 16 Aug 2026. This was not a deferral, it was the bug.** The entry
  read: "a fetched `Price` is stamped with the currency the caller asked for,
  not the provider's reported `currencyCode` (which rides in `source` for
  provenance)". Stamping a USD number as AUD is not a missing feature that a
  higher layer could add later; it is a wrong price, and the provenance note in
  `source` was legible to nothing that valued a holding. Measured on the
  reference book: **1,205 rows across two securities**, including 836 USD closes
  of a US-listed namesake recorded as an Australian super fund's AUD unit price.
  `QuoteService.price(from:)` now refuses the mismatch outright (`FR-INV-40`),
  and infers the currency from the security's own exchange for the four
  providers that report none. Filed here as a won't-fix for three weeks, which
  is why it is left visible rather than deleted.
- **GnuCash-XML element text is whitespace-trimmed on import** (production review) —
  leading/trailing whitespace in memos/descriptions/notes/names is dropped so XML
  indentation can't leak into values; byte-for-byte text fidelity is sacrificed by
  choice.


## P12 review findings (15 Aug 2026) — all acted on

The ten-angle review of the navigation redesign produced twenty findings. Every
one is fixed; nothing from it is outstanding. What the fixes were, and the two
places the design itself was corrected, is in [implemented.md](implemented.md)
▸ P12.

Nothing from the review is outstanding, and nothing from P12 ships narrower than
the design: both halves of the sidebar drag are built, with the feedback that
tells them apart.
