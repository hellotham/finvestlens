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

## 3a — Foundation Models 27 — where each change stands (12 Oct 2026)

Apple's [*Foundation Models updates*](https://developer.apple.com/documentation/Updates/FoundationModels)
page lists what arrived with 27. On 9 Oct 2026 this section was a table headed
"consciously not adopted" that declined seven of them on the implementer's own
judgement, against an instruction to accommodate the new framework. It is
replaced by what was done on 12 Oct — every page the updates page links to was
read that day in a browser, with the 27 SDK's interface and probes of the
installed model — and by what is still open and why. The account of the work is
in [implemented.md](implemented.md); the prompts and the measurements behind
them are in [intelligence-prompts.md](intelligence-prompts.md).

| Change in 27 | Where it stands |
|---|---|
| `LanguageModel` protocol — a session takes any model | **Adopted.** One seam (`LanguageModels`) resolves the model for each request, once, and is the only place a session is created. |
| `SystemLanguageModel.contextSize` / `tokenCount(for:)` | **Adopted.** A document read on its own is cut to the model's window by the model's own count (`LanguageModels.fit`: measure as sent, cut in proportion, measure again). The installed model reports 8,192 tokens. Two bounds are deliberate and are not the window: a *batch* of attachments reads the first 6,000 characters of each file (`AppModel.bulkHeadCharacters` — fifty files are fifty requests), and a bank statement is read 1,000 characters a request so that no row is dropped. An invoice too long for the window is read from the top and the review says so. |
| The error types (`LanguageModelError`, `SystemLanguageModel.Error`, `LanguageModelSession.Error`, `PrivateCloudComputeLanguageModel.Error`), `GeneratedContent.ParsingError`, and a refusal's `explanation` | **Adopted in full** (`IntelligenceError.wrap` / `describing`). Rate limits, timeouts and unsupported languages are their own cases, because they mean different things to a batch: a rate limit stops it, a timeout costs one slice. A refusal's explanation is asked for only where one document is being read and a person will see it, and shown only if it is a sentence — the model has answered that question with the extraction itself. |
| The new on-device model — "test your prompts" | **Done, and it found defects**: see intelligence-prompts.md. Live suites run on every local `swift test`: the eight features in English, the three narrators in each of the seven languages the app is translated into, the budget advisor in Japanese and French. |
| Locale and language instructions | **Adopted**, placed where measurement says they work (224 drafts, judged by an oracle that is not the code's own). |
| `GenerationOptions.ToolCallingMode` | **Adopted as far as it applies**: no feature registers a tool yet, so every request states `.disallowed`. |
| Run-time schemas (`GenerationSchema`) | **Adopted** for the budget advisor and the categoriser, whose answers now have exactly as many rows as the request — as the `@Generable` type's own schema with one count changed (`LanguageModels.countedSchema`), not a second schema written by hand. |
| `PrivateCloudComputeLanguageModel` | **Built, and switched off until Apple grants the entitlement.** Where a build can offer it, it is the default (the owner's decision) for reading a receipt, invoice, dividend statement or attachment and for writing summaries; Auto-Categorise, an import's category suggestions, classifying and reading bank statements stay on the device. The choice is in Settings on every platform; each of the eight commands that can leave the device shows where it runs in the view that starts it (`IntelligenceCommand`, `IntelligenceRunsNote`; a request no command has named stays on the device) — beside the button where there is one to press, and in the sheet as it runs for the three that start when their sheet opens, which is the open decision below — and the daily allowance is shown there. It is compiled in only by the `PRIVATE_CLOUD_COMPUTE` condition, which must land with the `com.apple.developer.private-cloud-compute` entitlement, the help text and the privacy policy — `PrivateCloudComputeBuildTests` fails on any one without the others — and is never offered in the Simulator. **Nothing has run against the cloud model**: a request without the entitlement ends the process. That leaves three things only a granted entitlement can settle: whether the prompts behave as they do on the device; which reasoning level each feature should ask for (Apple: start at `moderate` and evaluate); and how the allowance holds up in a batch. Apple's request form answered "not currently enrolled in the App Store Small Business Program" for this account on 12 Oct, after the approval had arrived; the owner has a support request open. |
| `SystemLanguageModel.Variant` | Read-only (no initialiser takes one). The installed model reports "AFM 3 Core Advanced"; nothing in the app depends on which. |
| `Guardrails.permissiveContentTransformations` | Does not apply: Apple's safety article (re-read 12 Oct) says "This mode only works for generating a string value", and every request here is guided generation. |
| Foundation Models instrument | Recorded on 12 Oct with the owner's consent to its unencrypted capture; see intelligence-prompts.md for what it showed. |

**Open — the owner's decision: the first request off the device.** Three
commands start reading when their sheet opens: Smart Import (once the files
are picked), Suggest Budget, and a review deck (a story is asked for as each
slide is shown). With Private Cloud Compute as the default, the first of
those requests would leave the device before anything on screen had said so:
the note is in the sheet and is drawn as the request is made, and the
sentence in Settings is read only by someone who opens Settings. Three ways
to settle it:

- *Announce it once.* Before the first request of any kind that would leave
  the device, say what Private Cloud Compute is and ask — Private Cloud
  Compute as the default answer, "keep on this device" as the other. One
  extra press, once, and every later request is an informed one.
- *Wait for a press.* Those three commands do not start by themselves while
  they would leave the device: the sheet shows the note and a button. One
  extra press every time.
- *Leave it.* The note beside each command and the sentence in Settings are
  the disclosure.

It is the owner's because making Private Cloud Compute the default was. No
build can reach Private Cloud Compute until Apple assigns the entitlement, so
nothing waits on the answer today, and `PrivateCloudComputeBuildTests` fails
if the build condition is set while this paragraph is still headed "Open".

**Decided by the owner, 12 Oct 2026** — all three since adopted, in this
order, each with what was deliberately left out:

- **Images in prompts, with Vision's `OCRTool` and `BarcodeReaderTool`** —
  *adopted 12 Oct, after this list was written, for the invoice reader.*
  Where one invoice or receipt is read and it is a picture, the model is
  shown the picture with Vision's tools, and that reading is kept unless the
  text's stands better (intelligence-prompts.md has the measurements). The
  barcode reader is offered only when Vision itself finds a code on the
  page, and what it returns is the only thing a payment reference is
  believed from. The tools live in a cross-import overlay
  (`_Vision_FoundationModels`) that the iOS Simulator SDK does not have, so
  there — and for a model that does not see — the text is read as before.
  **Deliberately not done:** a batch (Match Attachments) still reads text,
  because on real receipts the two routes gave the same total every time and
  the picture took twice as long; and the dividend extractor, the attachment
  reader and the classifier are not shown pictures, having not been
  measured.
- **`LanguageModelSession.DynamicProfile`** — *adopted 12 Oct, after this
  list was written.* Every request's session is built from a profile that
  declares its instructions, model, sampling and tool-calling mode
  (`LanguageModels.FeatureProfile`). Keeping one session for a batch, with a
  stateless history transform, was built and measured and is **not**
  adopted: the prefix cache engages and saves about 15 ms on a request that
  takes 2.8 s (intelligence-prompts.md). What is left for a profile to do is
  offer tools only when the request has an image for them, which belongs to
  the item above.
- **A model the person supplies** — *adopted 12 Oct, after this list was
  written.* Settings ▸ Apple Intelligence takes a folder of MLX models and
  lists the ones the app can run; the one chosen there does everything Apple
  Intelligence does here, on the device (`SuppliedModelStore`,
  `MLXModelLoader`, architecture.md §11). The owner's rule covers this one
  in particular — *the publisher provides no APIs and stores no data;
  everything is supplied by the person using the app* — so no model is
  bundled, the app downloads none (the loader is handed a downloader that
  refuses, and is never asked for one by a model given as a folder), and
  there is no key or endpoint of the publisher's. **Deliberately not done:**
  - *Pictures.* A supplied model is declared as guided generation and
    nothing more, so the invoice reader reads text for it, as it does on the
    iOS Simulator. Whether a given open model sees, and whether Vision's
    tools work through MLX's tool calling, has not been measured.
  - *Reasoning.* A model that can reason before it answers is not asked to:
    it is declared without that capability. It would be slower, and it has
    not been measured against what the features need.
  - *A statement reader tuned for it.* A statement is still read a thousand
    characters at a time, which is right for Apple's model and slow on a
    large one: 120 rows took eight to nine and a half minutes on one
    26-billion-parameter model and fourteen on another, every row kept
    (intelligence-prompts.md). A
    larger slice for a larger window has not been tried.
  - *Reading again, for anything but a statement.* An answer that loses its
    place is read again in halves by the statement reader only. An invoice
    or a budget that comes back wrong is checked as it always was and not
    asked for a second time.
  - *Prose in the reader's language.* Every request made of a supplied model
    so far was in English. The language order is sent as it is to Apple's
    model; whether an open model obeys it has not been measured.
  - *iPhone and iPad.* The code is the same and builds for both, and MLX
    cannot run in the Simulator, so nothing there has been run. A phone has
    room for a small model only, and the app says so when one outweighs a
    quarter of the device's memory.
  - *Removing or fetching a model.* The folder is the person's, and other
    tools' besides: the app reads it and writes nothing to it.

**The review decks are in the reader's language** (done 12 Oct, after the
commit that set the order above — it was the one change already in hand).
Their two builders held 133 phrases as bare literals, English on screen in
every language and English in the facts handed to the narrator; each is now a
whole phrase in the catalog, in eight languages.

**The reports are in the reader's language** (done 12 Oct): the 29 report
documents, the annual-report statements, the gallery and an open report,
period names and labels, and what surrounds them — 247 phrases. See
`implemented.md`, "The reports in the reader's language".

**Everything a reader meets is in their language** (done 17 Oct): the
undo names, toasts, errors, the engine's names for things, the open and save
panels, Siri's phrases and what the app writes into a new book — and a gate
that reads the source, so that a `String` a reader sees cannot ship in
English again (`scripts/check-localization.py`, the *unseen* check). See
`implemented.md`, "Everything a reader meets".

**English on purpose**, each line with its reason in
`scripts/localization-exempt.tsv`:

- *Formats other programs read*: GnuCash XML, GnuCash CSV, Ledger, HTTP and
  Box's API, SQL, file signatures, bank-export column names.
- *What a model is told*: the prompts, the words they are checked against,
  and the stability and percent vocabularies the narrators' validators match
  (`docs/intelligence-prompts.md` gives the reasons prompts are English).
- *What GnuCash writes into a book and code reads back*: the root, orphan,
  imbalance and trading accounts; a business payment's action and memo; an
  invoice posting's read-only reason; ISO's English currency names (shown,
  a currency takes the reader's name from the locale). GnuCash's reports are
  the oracle for the business features, so their strings stay as GnuCash
  writes them.
- *The Australian dividend accounts* (`Income:Dividends:Franked Dividends`
  and the rest), which the financial-year pack classifies by their English
  names. A book outside Australia has no use for them.
- *A cheque's legal line*, English by design (`CheckPrinting.swift` says why).
- *Help search keywords*: search matches the reader's language and these
  English synonyms as well, so a term learned from GnuCash still finds its
  page (`HelpView.swift`).
- *What only a developer or `finlab` reads*: GnuCash import notes (the app
  does not show them), debug descriptions, programming errors, a trace file,
  the simulator's note about MLX.

**Not done, and why:** nothing has been looked at on screen in a language
other than English; the App Shortcuts phrases have not been spoken to Siri;
and the gate's idea of "reads as English" does not see a lone lower-case
word or text built without a literal (`Text(kind.rawValue)`), which are for
review — this pass found and fixed the ten such sites it could find.

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
