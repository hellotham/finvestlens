# FinvestLens — Technical Architecture

| | |
|---|---|
| **Document status** | Design baseline v1.3 (Aug 2026 — closes the working-copy decision (§10), restores the three register styles (§10.1), adds the two command-line consumers (§9)) |
| **Companions** | [PRD](prd.md) · [Porting Strategy](porting.md) · [Report redesign](report-redesign.md) |
| **Scope** | Target architecture, technology choices, native file format, and how the hard problems are solved |

This document evaluates implementation alternatives, recommends specific technologies and Swift packages, and defines the module layout and the **native document format**. Decisions are recorded ADR-style: **context → options → decision → rationale**. It describes the intended design; the record of what has been built, and the measurements behind the performance choices, live in [implemented.md](implemented.md).

FinvestLens is **native-first above all else**. Two consequences: (1) money uses **Swift-native `Decimal`**, and there is no goal of bug-for-bug numeric parity with GnuCash — rounding discrepancies are acceptable and tests tolerate them; (2) the app is a **document-based app with its own native file format** (a single SQLite file) that can live on a NAS, with **application-level locking**. The in-memory engine model is the source of truth, persisted through GRDB/SQLite; SwiftData is not used. GnuCash XML is an **import/export interchange format**, not the app's save format.

---

## 1. Principles (priority order)

- **P1 — Native first, always.** Prefer first-party Apple frameworks and idiomatic Swift over anything that imports foreign runtimes or models. This principle **outranks** fidelity and engine-purity concerns when they conflict.
- **P2 — Own document format.** The app opens and saves its **own** native file. Interoperability with GnuCash is achieved by import/export, not by adopting GnuCash's on-disk format as our store.
- **P3 — Good-enough fidelity.** Match GnuCash's *data and semantics* well enough to be useful and round-trip the important objects; do **not** chase bit-exact arithmetic. Tests accept small rounding differences.
- **P4 — Swap-able boundaries.** Persistence, file IO, XML interchange, and quotes sit behind protocols so implementations can change without touching the engine or UI.
- **P5 — Engine independence.** The accounting engine has no UI or persistence dependencies (it may use Foundation value types like `Decimal`/`Date`). It is deterministic and unit-tested.
- **P6 — Data safety on shared storage.** A document may live on a network share accessed by multiple machines; the app must never let two writers corrupt it.

---

## 2. Layered architecture and module (SPM target) layout

```
FinvestLensApp (macOS / iPadOS / iOS)          ← SwiftUI, per-platform
finlab (Lab)                                   ← headless maintenance, writes
finlens (CLI) → Engine · Persistence · Interchange · Reports   (read-only, ADR-L2)
   │
   ├── FeatureUI          SwiftUI views + AppModel (@Observable view model)
   ├── Reports            report computation (Swift) + Swift Charts rendering
   ├── Interchange        GnuCash XML · CSV/QIF/OFX · MT940/CAMT.053 · Ledger 3 journal · import matcher
   ├── Rules              rules engine · merchant heuristics
   ├── Shared             App-Group snapshot shared with the widget/Quick Look extensions
   ├── Quotes             pluggable price/quote providers (URLSession)
   ├── Cloud              Box OAuth + file transport; depends on nothing, by design
   ├── Intelligence       Apple Intelligence (FoundationModels) features (§11)
   │                      PDF text/OCR extraction · statement/invoice/dividend
   │                      readers · categoriser · budget advisor · forecast outlook
   │
   ├── Persistence        ★ native file format: open/save/lock
   │     ├── FinvestLensDocument   lifecycle, dirty-tracking, autosave
   │     ├── FileLock              NAS-safe advisory locking (§6)
   │     └── SQLiteDocumentStore   GRDB schema + snapshot read/write
   │
   └── Engine  ★ pure Swift, no persistence/UI deps
        ├── Money           Decimal-based amounts + Commodity
        ├── model           Account · Split · Transaction · Commodity · Book
        ├── PriceDB · Lot · Policy · CapGains
        ├── ScheduledTxn · Recurrence · Budget
        ├── Scrub           integrity/validation
        └── Core            GncGUID · KvpFrame · Query
```

Dependencies point **downward only**. `Engine` builds and tests with nothing above it. The UI and interchange layers talk to the engine's in-memory model; the `Persistence` layer persists that model to the native file.

---

## 3. The source-of-truth model

FinvestLens follows a **check-out → edit locally → explicit save** document model:

1. **Open** a `.finvestlens` document → acquire the lock (§6) → copy it to a **local working copy** (§6) → open the SQLite store on the *local* copy → materialize the observable in-memory **`Book`**. Retain a pristine snapshot of the opened state for Revert.
2. **Edit** against the in-memory model + local working copy (the working session). The engine `Book` is a plain (non-observable) model; the UI binds via **Observation on `AppModel`** (FeatureUI), which snapshots derived state after each mutation. Edits accumulate **locally only** — the document on the share is untouched.
3. **Write-back is explicit.** The local working copy is flushed back to the document location (atomically, under lock; §6.2) **only** on **File ▸ Save** (⌘S), **autosave** (a periodic interval while dirty), or **automatic save on switch/close/quit** (switching books, Close Book, and ⌘Q save first — failures surface and abort the switch/quit). There is **no continuous background sync** to the share.
4. **Discard / Revert.** Because the share only changes on an explicit save, the user can **abandon a working session**: **closing without saving** (or **File ▸ Revert**) discards unsaved changes and the on-share document reflects only the last save. The retained opened-state snapshot enables **Revert to the version that was opened**, even if autosave has run since.
5. **Close** → (prompt to save if dirty) → release the lock → drop the working copy (kept briefly only for crash recovery).

This keeps the engine free of persistence concerns, gives SQLite's scalability for large books, sidesteps the hazards of running SQLite directly over SMB/NFS, and — crucially — makes every write to shared storage a **deliberate, discardable** act.

---

## 4. Technology decisions at a glance

| Concern | Decision | Alternatives rejected | ADR |
|---|---|---|---|
| Money arithmetic | **Swift-native `Foundation.Decimal`**, wrapped in a `Money` type | hand-written rational (GnuCash parity); `Double`; BigInt/rational libs | §5.1 |
| Numeric fidelity vs GnuCash | **Good-enough**; tests tolerate rounding | bit-exact `gnc_numeric` port | §5.1 |
| Native file format | **Single SQLite file** (`.finvestlens`) via **GRDB** | SwiftData store; flat compressed file; file bundle | §5.2 |
| Persistence framework | **GRDB** (SQLite) behind `Repository` protocols | SwiftData; Core Data; Realm | §5.2 |
| Source of truth | **In-memory `Book`** + local working copy; document written back **only on explicit Save/autosave** (sessions are discardable) | SwiftData-managed context; direct-on-NAS SQLite; continuous auto-sync | §3, §5.2 |
| NAS concurrency | **App-level lock file + heartbeat + local copy + explicit atomic write-back** | trusting SQLite/POSIX locks over network | §6 |
| Coordinated file IO | **`NSFileCoordinator` / `NSFilePresenter`** | raw `FileManager` writes | §6 |
| GnuCash interoperability | **Import/export interchange** (XML), not the store | GnuCash XML as save format | §5.3 |
| Object identity | **Custom `GncGUID`** (32-hex, no dashes) for imported data | `Foundation.UUID` string form | §5.4 |
| Extensible metadata | **`KvpFrame`** value type, stored as JSON column | dropping unknown slots | §5.4 |
| Object framework | **Swift protocols + Observation** (replaces QOF) | porting QOF/GObject | §5.5 |
| Reports rendering | **Swift compute + Swift Charts** | Guile/HTML/WebKit | §5.6 |
| Quotes | **URLSession + pluggable providers** | Finance::Quote (Perl) | §5.7 |
| Sync | **File-level (iCloud Documents / Files / NAS)** | SwiftData+CloudKit | §8 |
| Tests | **Swift Testing** + tolerant comparisons + fixtures | XCTest-only; exact-match | §7 |

---

## 5. Key decisions — options and rationale

### 5.1 Money arithmetic — Swift-native `Decimal`

**Context.** Native-first (P1) and good-enough fidelity (P3) supersede matching GnuCash's `gnc_numeric` exactly. We need a correct, native, decimal money type; small divergences from GnuCash's rounding are acceptable.

**Options.** (1) **`Foundation.Decimal`** — native base-10, 38 significant digits, value type, `Codable`. (2) Hand-written `Int64`/`Int128` rational to mirror GnuCash — rejected: violates native-first, and we do not need bit-parity. (3) `Double` — rejected: binary rounding error. (4) BigInt/rational packages — rejected: non-native dependency for precision we don't require.

**Decision → `Foundation.Decimal`**, wrapped in a `struct Money { var amount: Decimal; var commodity: Commodity }`. Rounding uses `Decimal`'s `NSDecimalRound` with **half-up rounding** to the commodity's fraction (e.g. 2 dp for most currencies). Share quantities and prices are `Decimal`. Transaction balancing sums `Decimal`s and rounds to the transaction currency's scale; a residual within one minor unit is treated as balanced (an explicit imbalance beyond that is surfaced, not hidden).

**Rationale.** `Decimal` is the idiomatic Apple money type, exact for decimal values within range, and free of binary-float error — sufficient for double-entry bookkeeping. Where GnuCash used odd denominators (e.g. 1/3-share fractions), `Decimal` rounds to 38 digits; per P3 this is acceptable and tests are written with tolerances.

> ADR-1: Money = `Decimal` wrapped in `Money`. No bit-exact GnuCash parity; tests tolerate rounding.

### 5.2 Native file format & persistence — SQLite via GRDB

**Context.** The app must open and save its **own** file, that file may live on a **NAS**, and it must scale to 100k+ transactions (NFR-02). SwiftData's store is an app-container SQLite database not meant to be treated as a portable, user-placed, cross-machine-locked document, and offers no story for network-share locking.

**Options.**
1. **GRDB (SQLite) single file** — a real, portable SQLite database as the document; fast, mature; full control over schema, migrations, journaling, and locking.
2. **SwiftData** — native and SwiftUI-friendly, but not designed for user-placed documents on network shares; multi-file store (`.sqlite`/`-wal`/`-shm`); no locking control. Rejected given P2/P6.
3. **Flat compressed snapshot** (whole book in RAM, atomic whole-file save) — simplest and very NAS-safe, but full rewrite per save and whole book in memory.
4. **File package/bundle** — multi-file semantics complicate atomic network writes; rejected.

**Decision → a single SQLite file (`.finvestlens`) managed by [GRDB](https://github.com/groue/GRDB.swift)**, with **whole-book snapshot semantics** (a hybrid of options 1 and 3): `read()` materializes the full graph and `write()` rewrites all tables in one transaction — SQLite file format, snapshot IO. This is simple and NAS-safe; incremental per-row persistence remains an available optimization. The 10 Aug 2026 validation (§10) measured the whole-book write at **8.8 s, identical on local and SMB** — so a save is bound by serialisation rather than by IO, and incremental persistence is the lever if save latency ever needs one. It has not yet been judged slow enough to justify the complexity.

- **UTI / document type:** `com.hellotham.finvestlens.document` conforming to `public.database`; extension `.finvestlens`.
- **Schema & migrations:** GRDB `DatabaseMigrator`, versioned; a `meta` table records the app/schema version and a change counter. Conflict detection uses a **SHA-256 file fingerprint** of the shared document.
- **Journaling:** the working copy uses GRDB's default `DatabaseQueue` (rollback journal), so the artifact written back to the NAS is inherently a single self-contained file.
- **Document lifecycle:** a custom document controller (not SwiftUI `FileDocument`/`ReferenceFileDocument`, which assume whole-file snapshots) manages open/lock/copy/save/close so the app works against a live database.

**Rationale.** GRDB gives a genuine portable single-file database — ideal as a document — with the maturity and speed SwiftData lacks at scale, and the low-level control (journaling, checkpointing, coordinated IO) required to be safe on a NAS. The `Repository` abstraction (P4) keeps the engine and UI ignorant of GRDB.

> ADR-2: The document is one SQLite file via GRDB; SwiftData is not used; repositories abstract the store.

### 5.3 GnuCash interoperability — interchange only

**Context.** With our own native format, GnuCash's XML is not our store; it is an **import/export** path (PRD `FR-IMP-*`, `FR-EXP-*`).

**Decision.** The XML codec lives in the `Interchange` layer: Foundation `XMLParser` (SAX, streaming) to read, a hand-written streaming writer to write. The gzip container is native, over Apple's Compression framework (a small header/trailer wrapper around raw DEFLATE) — no third-party gzip package. Round-trip fidelity is a goal for supported objects, but **arithmetic differences from `Decimal` rounding are tolerated** (P3). GUIDs and KVP slots (§5.4) are preserved so re-export stays faithful. Export targets the **GnuCash v5-era** schema (`gnc:book` 2.0.0).

> ADR-3: GnuCash XML is interchange (import/export), read via `XMLParser`, gzip via Apple Compression.

### 5.4 Identity & extensible metadata (for imported GnuCash data)

- **`GncGUID`** — a value type wrapping 16 bytes with GnuCash's exact **32-hex, no-dashes** encoding, so imported objects re-export with identical ids. Native objects created in FinvestLens may use `UUID` internally, but anything imported/exported through GnuCash XML preserves its `GncGUID` verbatim. Never round-trip through `Foundation.UUID`'s dashed string.
- **`KvpFrame`** — a recursive `[String: KvpValue]` value type covering GnuCash slot types (`int64, double, decimal, string, guid, gdate, timespec, frame, list`). Stored as a **JSON blob column** on the owning row. On import, **all** slots (including unrecognized keys) are retained and re-emitted on export, protecting round-trip fidelity.

> ADR-4: `GncGUID` + `KvpFrame` preserve imported identity/metadata; slots stored as JSON, never dropped.

### 5.5 Replacing QOF

QOF's guarantees are provided natively rather than ported: identity → Swift type + id; `QofBook`/collections → `Book` aggregate + repository fetches; `QofBackend` → `Repository` (GRDB) + XML codec; `QofQuery` → Swift predicates / GRDB query interface; class registration → protocols + generics; event bus → Observation/Combine; GObject refcount → ARC + value semantics.

> ADR-5: QOF is replaced by Swift protocols, GRDB, and Observation — not ported.

### 5.6 Reports — compute in Swift, render natively

Port each GnuCash report's **computation** (account/date selection, roll-ups, multi-currency) into Swift services over the engine; **discard** the Scheme/HTML/eguile/WebKit presentation and render with **SwiftUI + Apple Swift Charts** (`FR-RPT-03`), PDF via the platform. Core reports (Balance Sheet, Income Statement, Net Worth, Transaction Report, Cash Flow) in P4; investment reports in P5.

> ADR-6: Report logic → Swift services; rendering → Swift Charts/SwiftUI.

### 5.6a Statement presentation layer & review decks (Jul 2026)

**Context.** The report arithmetic is verified to the cent, but flat per-account lines (`Income:Distributions:VGAD:Distribution`) are working-paper presentation, not statement presentation (PRD FR-RPT-01/07; research and judgement rules in [report-redesign.md](report-redesign.md)).

**Decision.** A **presentation layer that only arranges** sits above the verified engine reports:

- `StatementBuilder` (FeatureUI) projects engine lines onto the user's account tree and applies the judgement rules — top-level groups as face captions, trivial-chain collapse, ≤3-leaf captions inlined, 2% materiality folding into "Other" (cash-and-equivalents and Uncategorised protected), ASC 274 liquidity/maturity ordering, numbered notes whose totals tie to the face. One `StatementSheet` view renders screen and PDF so they cannot drift. The Trial Balance reuses the same machinery with Debit/Credit columns and per-category sections. **Identity tests are the contract:** face totals ≡ engine totals, notes tie, folding conserves, no path-like captions.
- The **review decks** (`ReviewSlide` + slide builders for the Financial and Investment Reviews) arrange the same verified computations into content-gated 16:9 slides with deterministic action titles; the shared sheet handles paging and landscape PDF (`ReportExport.pdfPage`).
- On-device narration (`ReviewNarrator`, §11) may rewrite a slide's title/insight but its output is **disposed by `ReviewStoryValidator`**: every numeric token must round-match a listed figure (raw or k/m-scaled), a listed delta percent, a label numeral, or a calendar year — anything else discards the story. This exists because the live model invented YoY percentages on first run.

> ADR-6a: Presentation arranges, never computes — statements via a face-and-notes builder with identity tests; decks via grounded facts packs; model narration survives only if a deterministic validator finds every quoted number in the slide's facts.

### 5.7 Quotes and exchange rates

GnuCash shells out to the Perl **Finance::Quote**; FinvestLens replaces it with a **native, pluggable provider layer** over `URLSession` + `Codable`. Two capabilities matter beyond "latest price": **historical backfill** (populate `PriceDB` across a date range) and **delisted securities** (prices for tickers no longer trading).

**Protocol.**

```swift
protocol QuoteProvider {
    var id: String { get }                     // "yahoo", "eodhd", "alphavantage", …
    var requiresAPIKey: Bool { get }
    var capabilities: QuoteCapabilities { get } // latest / historical / delisted / fx / search
    func latest(_ symbols: [SecuritySymbol]) async throws -> [Quote]
    func history(_ symbol: SecuritySymbol, range: DateInterval, interval: BarInterval) async throws -> [PricePoint]
    func search(_ query: String) async throws -> [SecurityMatch]   // optional
}
```

Results are written into `PriceDB` (`FR-INV-03`, `FR-CUR-04`); users pick a default/fallback order and can refresh on demand or on a schedule.

**API-key management.** Keyed providers store their key in the **Keychain** (never in the document, never in plists). The user enters keys in Settings; per the safety rules the *user* enters credentials — the app never solicits them from observed content. Requests go **directly** from the device to the provider over HTTPS.

**Providers.** The keyless **Yahoo (yfinance-like)** client is the default out-of-box source; keyed providers are **EODHD** (delisted / deep history), **Alpha Vantage**, **Finnhub**, and **Twelve Data**; **Stooq** is a keyless CSV EOD fallback. The list is extensible; adding a provider is a new `QuoteProvider` conformance.

**The "yfinance-like" Yahoo provider.** A native reimplementation of the approach used by [ranaroussi/yfinance](https://github.com/ranaroussi/yfinance) — **no API key**, hitting Yahoo's unofficial public endpoints:

- **History / OHLCV + dividends + splits:** `GET https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?period1=…&period2=…&interval=1d&events=div,splits` — the chart endpoint generally needs **no crumb**, so historical backfill is straightforward.
- **Latest quote / fundamentals:** `v7/finance/quote` and `v10/finance/quoteSummary` — these require a **cookie + crumb**. The client fetches a session cookie, then `GET /v1/test/getcrumb`, and appends `&crumb=…`. An EU-consent variant is handled if needed.
- **Symbol search:** `v1/finance/search?q=…`.
- Parsed with `Codable`; retry/backoff and rate-limit friendliness built in.

> **Legal/ToS note.** The Yahoo endpoints are unofficial and **not affiliated with or endorsed by Yahoo**; this provider is for personal/research use, mirroring what Finance::Quote/yfinance do. Keyed providers (EODHD, etc.) are the sanctioned path for redistribution or heavier use. The UI surfaces this and lets users choose their provider accordingly.

> ADR-7: Native pluggable `QuoteProvider`s over URLSession — a keyless **yfinance-like Yahoo** client plus keyed providers (**EODHD** for delisted/deep history, Alpha Vantage, Finnhub, Twelve Data), with **historical backfill**, keys in Keychain, and user-selectable default/fallback.

### 5.8a Bank/financial file import — CSV, QIF, OFX/QFX (native)

**Context.** CSV, QIF, and OFX/QFX import are **core features** (PRD `FR-XIO-01/02/03`), not afterthoughts — they are how most users get bank/card/brokerage data in. They are **reimplemented natively in Swift**, not ported from GnuCash's GTK importers. There is a good Swift **CSV** package, but **no Swift package for QIF or OFX/QFX** — mature parsers live in Python/JS/Ruby/.NET and serve as *format specifications*, not dependencies.

**Design.** A small `ImportParser` protocol yields a normalized `[StagedTransaction]` (date, amount, payee, memo, ref, optional splits/security/action), which flows into the shared **Import Matcher** (`FR-XIO-05`) for duplicate detection and destination-account assignment — one matcher, many front-end parsers.

| Format | Approach | Package / basis |
|---|---|---|
| **CSV** | Custom Swift parser: RFC-4180-style with a configurable column mapping in the import UI. | Hand-written; CodableCSV remains an option if needs outgrow it. |
| **QIF** | Custom Swift parser. QIF is line-oriented: single-letter tag per line (`D` date, `T`/`U` amount, `P` payee, `M` memo, `L` category/transfer, `N` number/action, `C` cleared, `S/E/$` splits), records terminated by `^`, section headers like `!Type:Bank`, `!Account`, `!Type:Invst`. | Spec/oracles: [Wikipedia QIF](https://en.wikipedia.org/wiki/Quicken_Interchange_Format), [Quiffen (Py)](https://quiffen.readthedocs.io/), [hazzik/qif (.NET)](https://github.com/hazzik/qif). |
| **OFX / QFX** | Custom Swift parser handling both flavors: strip the OFX header block, then **OFX v2 (XML)** → reuse `XMLParser`; **OFX v1 (SGML)** → a tolerant tokenizer that auto-closes value-only leaf tags (OFX v1 omits closing tags) to normalize into the same element tree. Handles bank (`STMTRS`), credit-card (`CCSTMTRS`), and investment (`INVSTMTRS`) statements; QFX is OFX plus Quicken extensions. | Spec/oracles: [ofxtools (Py)](https://github.com/csingley/ofxtools), [ofx-js](https://github.com/bradenmacdonald/ofx-js), [salt-parser (Ruby)](https://github.com/saltedge/salt-parser). |

**Why custom for QIF/OFX.** No maintained Swift implementations exist; both formats are small and well-documented; owning the parsers avoids a non-native/unmaintained dependency (Principle P1) and lets all three share one staging model and matcher. The libraries in other languages are used as **conformance references and test-fixture generators**, not linked code.

> ADR-7a: CSV/QIF/OFX are native, core importers over a shared `ImportParser` → Import Matcher pipeline; QIF and OFX/QFX are hand-written (no Swift package exists), specced against mature non-Swift parsers.

---

## 6. Native file format on a NAS — locking & write safety

Running SQLite **directly** over SMB/NFS is unsafe: network filesystems implement POSIX/byte-range locking incompletely, and WAL/shared-memory files misbehave. SQLite's own guidance is to avoid network filesystems. So FinvestLens does **not** rely on SQLite/OS locking across the network. Instead:

### 6.1 Application-level lock (single-writer across machines)

Modeled on GnuCash's `.LCK` approach, hardened:

- Beside `Book.finvestlens` we create **`Book.lock`** (same base name, different extension — required for the macOS sandbox related-item grant, which also needs the `lock` type declared with `CFBundleTypeRole = Editor`: `None` is granted read-only, the 9 Oct 2026 refusal) whose contents are JSON: `{ host, user, instanceID, pid, acquiredAt, heartbeatAt, machineID }`. `machineID` (since 12 Oct 2026) is a digest of the Mac's hardware UUID — the same for every tool on that Mac, sandboxed or not — or, on iOS, a value minted once and kept in the Keychain as a this-device-only item, so a backup restored to another device does not bring it along; a lock from an earlier version has none.
- **Acquire on open** using an **atomic create-if-absent** (`.withoutOverwriting`). All lock IO goes through **`NSFileCoordinator`** with a related-item presenter.
- If the lock exists and its `heartbeatAt` is **fresh**, the document is in use elsewhere → the open fails showing the holder; if the heartbeat is **stale** (older than the staleness threshold), the UI offers **Break Lock and Open**.
- **A dead process on this machine is not a question.** A lock whose `machineID` is this machine's and whose `pid` no longer exists — a crash, a force-quit, an installer replacing the app while a book was open — is broken on open without asking (`FileLock.canBreakWithoutAsking`): nobody holds the book, and its owner is the person opening it. The break removes only the holder that was judged (`breakLock(heldBy:)`), so a lock taken by someone else between the judgement and the removal survives it. "This machine" is the identity, never the host name alone — one Mac reported two different host names on consecutive days, and two Macs of one model share a default name. A lock with no `machineID` whose host name matches and whose pid is gone may be broken at once, but by the person; any other machine's lock is judged by its heartbeat only.
- **Heartbeat:** while open, `heartbeatAt` is refreshed periodically (a background task in `AppModel`) and on every save, distinguishing a live holder from a crashed one.
- **Release on close;** crash recovery relies on stale-heartbeat detection.
- **Lockless fallback (iOS providers).** Where the sibling `.lock` cannot be created — an iOS file-provider grant (iCloud Drive, Box, Dropbox via the Files picker) covers only the document, and the related-item mechanism is macOS-only — the document still opens, with `advisoryLockHeld == false`; saves remain guarded by the §6.2 fingerprint conflict check. A **live** lock held by someone else still refuses the open.

### 6.2 Local working copy + atomic write-back

To get SQLite's speed/scale without trusting it over the network, and to make write-back an explicit, discardable act:

1. **On open** (after acquiring the lock): copy `Book.finvestlens` from the share to a **local working copy** (a per-session file under the app's temporary directory); note the source's SHA-256 fingerprint, and keep a **pristine opened snapshot** for Revert.
2. **Edit** against the local SQLite (fast, reliable local semantics). Nothing is written to the share during editing.
3. **Write-back happens only on explicit Save, autosave, or save-on-switch/close/quit** (lock still held): the consolidated single file is written back to the share atomically (replace-item semantics) under `NSFileCoordinator`, and the `meta` change counter is bumped.
4. **Discard / Revert:** closing without saving (or File ▸ Revert) discards the working copy's unsaved changes; the share is left as it was at the last save. Reverting to the pristine opened snapshot restores the session's start state.
5. **Conflict defense in depth:** before overwriting, re-read the document's SHA-256 fingerprint on the share; if it changed unexpectedly (someone bypassed the lock, or an out-of-band edit), **do not clobber** — the save throws a conflict which the UI surfaces.
6. **On close:** if dirty, prompt to Save or Discard; then release the lock and drop the working copy (retained briefly only for crash recovery).

For **genuinely local volumes** the hop was considered as an optimization and then **measured and rejected** (10 Aug 2026 — §10): copying on APFS is a clone, so it costs **0 ms** and there is nothing left to skip. The working copy is unconditional; the explicit-save/discard semantics and locking apply everywhere.

### 6.3 iCloud / Files integration

Because the document is a file, sync is **file-level**: place it in iCloud Documents or any Files-accessible location. FinvestLens implements **`NSFilePresenter`** to react to external changes and uses **`NSFileVersion`** for conflict resolution, consistent with the NAS write-back path (`FR-PLT-02`).

- **Dataless placeholders.** The open-time copy-in and every fingerprint go through a **coordinated read**, which downloads and materialises a not-yet-local file (iCloud eviction, File Provider online-only) before it is touched.
- **iOS security scope.** Books picked on iOS are security-scoped; `AppModel` holds the grant for the whole session (saves write back to the shared file) and stores a **bookmark** per recent so Open Recent can regain the grant after a relaunch.
- **macOS provider drives** (`~/Library/CloudStorage`: Box, Dropbox, OneDrive) behave like local folders — for the sandboxed app (since 11 Oct 2026) through the book's own grant plus the related-item grant for its sidecars, verified on Box Drive; the sibling `.lock` syncs through the provider and extends single-writer protection across machines (heartbeat staleness is approximate under sync latency).

> ADR-8: NAS safety = app-level lock file + heartbeat + local working copy + **explicit (Save/autosave) coordinated atomic write-back** + discardable sessions, never direct SQLite-over-network.

---

## 7. Testing architecture

1. **Money/rounding** — tests assert correctness of `Money`/`Decimal` operations and balancing with **explicit tolerances**; parity with GnuCash is checked only approximately (P3).
2. **Round-trip interchange** — books synthesized in-test (`RoundTripTests`, `BusinessRoundTripTests`, `PriceRoundTripTests`, `LedgerRoundTripTests`) plus env-gated runs against the real reference book (`LiveFileRoundTripTests`, `FL_ROUNDTRIP_FILE`); import→export→re-import compares **object graphs** with numeric tolerance and exact GUID/slot preservation (`FR-EXP-02` for structure; amounts within tolerance). Real `.gnucash` books are gitignored and never committed, so there is no fixture corpus in the repository.
3. **Invariants** — every persisted transaction balances within tolerance (`FR-ENG-06`); `Scrub` reports nothing on a clean import.
4. **Locking, write-back & discard** — simulate concurrent openers (two lock acquirers), stale-lock breaking, mid-save crash (working copy intact, document untouched), conflicting external writes, and **discard/revert** (edit → close without saving → assert the on-disk document is byte-unchanged from the last save; Revert restores the opened snapshot). Assert the document is never corrupted or silently clobbered.
5. **Performance** — a large-book document gates open/scroll/import/save against NFR-02.

Framework: **Swift Testing** throughout, including the perf harnesses. XCTest
survives only in `finvestlensUITests`, because XCUITest has no Swift Testing
equivalent.

6. **Live-book acceptance (env-gated)** — harnesses that skip themselves unless
   an `FL_*` variable names a real book (`FL_PERF_FILE`, `FL_ROUNDTRIP_FILE`,
   `FL_FINLENS`, `FL_STATEMENT_PDF`, `FL_SCAN_PDF`, `FL_RECEIPT_DIR`), so CI
   stays deterministic while the reference book still gets real coverage.
   `finlab bench` ([lab.md](lab.md)) is the NFR-02 instrument.

7. **A test never inherits the runner's time zone.** Anything whose behaviour
   depends on *local* time takes the calendar as an argument
   (`repostLinkedTransactionDays(apply:in:)`, `postingDay(from:in:)` — both
   defaulting to `.current`, so no caller changes) and the test states the zone
   it is reasoning about. The posting-day repair is the sharp case: it moves
   rows whose UTC day and local day disagree, which at UTC is **unreproducible**
   — the two never disagree there. A test that hard-coded a Sydney instant
   therefore passed on the maintainer's machine (UTC+10) and failed on CI (UTC),
   and because nobody read the run, the pipeline stayed red for **five
   consecutive commits** while every local preflight came back green. The
   divergence between a local sweep and CI is the entire reason CI exists;
   `/preflight` now reads the previous run before pushing and watches the new
   one after.

CI (`ci.yml`) builds and tests all twelve packages plus an unsigned macOS and
iOS app on every push and PR — on GitHub's `xcode-27` image, macOS 27 with
Xcode 27 — and gates SPDX headers, the string catalogs against the compiler's
own extraction, and real-looking figures in published files. The test count
is whatever `swift test` reports; this document does not carry it.

---

## 8. Concurrency, sync, and cross-platform

- **Engine** is synchronous/deterministic. **IO is async at the edges** (open/copy, save/write-back, import/export, quotes) with progress reporting; the UI stays responsive. Building the in-memory `Book` on open runs off the main actor and is transferred to it via `sending`, so `Book` need not be `Sendable`.
- **GRDB** access uses its `DatabaseQueue`/`DatabasePool` (serialized writes); the UI reads via observations.
- **Sync** is file-level (§6.3) — iCloud Documents, Files, or the NAS — not SwiftData/CloudKit.
- **One shared codebase.** `Engine`/`Persistence`/`Interchange`/`Reports`/`Quotes` are platform-agnostic. `FeatureUI` adapts: `NavigationSplitView` on macOS/iPadOS, compact stacks on iOS. macOS maps GnuCash-style menus to a native menu bar.

---

## 9. Dependencies

**External SPM dependencies — exactly one.**

| Package | Use | License |
|---|---|---|
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) (7.x) | The native SQLite document store; the `Persistence` target's only external dependency | MIT (GPLv3-compatible) |

Everything else is first-party Apple frameworks or hand-written native code — money (`Decimal`), GnuCash XML read (`XMLParser`) and gzip (Apple **Compression**), the CSV/QIF/OFX parsers (hand-written; no maintained Swift package exists for QIF/OFX), coordinated file IO (`NSFileCoordinator`/`NSFilePresenter`/`NSFileVersion`), the file fingerprint (**CryptoKit** SHA-256), quotes (`URLSession`), Keychain (**Security**), and tests (**Swift Testing**).

**Apple frameworks used** (by area): `SwiftUI` + `AppKit`/`UIKit` (UI), `Swift Charts` (`Charts`), `FoundationModels` + `Vision` + `PDFKit` (Intelligence — §11), `AppIntents` (Shortcuts), `LocalAuthentication` (book lock), `UniformTypeIdentifiers` (the `.finvestlens` UTI), `Observation`, `CryptoKit`, `Compression`, `Security`, `CoreGraphics`.

**Internal package graph** (Swift Package targets; arrows = "depends on", downward only):

```
Engine        (no dependencies — pure Swift + Foundation)
Persistence   → Engine, GRDB
Interchange   → Engine
Quotes        → Engine
Reports       → Engine
Rules         → Engine
Shared        (no dependencies — Foundation-only App-Group snapshot leaf)
Cloud         (no dependencies — Box OAuth and file transport)
Intelligence  → Engine, Interchange
FeatureUI     → Engine, Persistence, Interchange, Reports, Rules, Quotes, Cloud, Intelligence, Shared
CLI           → Engine, Persistence, Interchange, Reports        (finlens — read-only)
Lab           → Engine, Persistence, Interchange, Quotes, Intelligence, FeatureUI  (finlab)
FinvestLensApp (macOS/iPadOS/iOS targets) → FeatureUI
Widget/QuickLook extension targets → Shared
```

`Lab` is the only package above `FeatureUI` besides the app, and that is
deliberate: `finlab` drives `AppModel` headlessly so a maintenance run
exercises the code the app runs rather than a parallel implementation free to
drift from it (rationale in `Packages/Lab/Package.swift`'s header and
[lab.md](lab.md)). Dependencies still point strictly downward — `finlab` is a
top-level consumer, a sibling of the app target, not a layer inserted beneath
one.

---

## 10. Derived state and performance

The engine `Book` is the source of truth and is held **entirely in memory**, as GnuCash does; everything the UI shows is *derived* from it. On a large book the cost of re-deriving state dominates how the app feels, so the architecture follows one rule:

> **Derive on demand, cache what is expensive, and invalidate on the same signal that drives the redraw.** A cache that outlives its data is a correctness bug, not a performance win — so every derived cache hangs off the refresh path that already runs after every mutation, never a second invalidation path that can drift.

The concrete techniques this implies — an indexed price database rather than a per-call scan; single-pass balance derivation; uniform, `Table`-backed register rows; and **pre-capture undo** that snapshots only the objects an edit touches — are design constraints on the engine and view-model. `Book` is deliberately **not `Sendable`** (a cyclic class graph); concurrency safety is achieved by isolating the load and transferring ownership (§8), not by locking the hot path.

**Undo scopes** (narrowest that covers the edit): *transaction*-scoped (`editing`) for register edits; *account*-scoped (`editingAccounts`) for account metadata; *price-database*-scoped (`editingPrices`: the book records what the edit adds and removes and the undo is the inverse of that log — not a copy of the price array, which is 163k rows on the reference book) for quote fetches and rate edits; *kvp*-scoped (`editingBookKvp`, restoring the frame **and** reloading the mirrored collections) for settings and saved collections; the whole-book GnuCash-XML snapshot (`editingWholeBook`) only for structural and business operations. The scoped tiers exist because the whole-book export costs seconds on the reference book, and price fetches and settings commits used to pay it per edit.

**Derived-state caches, one invalidation signal.** Every cache keys on the same `derivedRevision` that drives the redraw: the register's status-strip totals are folded into the row-building pass (never recomputed per body pass); QuickFill reads a per-revision recency list of distinct descriptions; the flattened `postableAccounts` picker list follows the account tree; and every report memoises through one `cachedReport(key:)` layer keyed by *(parameters, revision)* — with "now" quantised to end-of-day, because a live `Date()` in a key defeats the memo.

**Reports build off the body, on the main actor.** Heavy reports render behind a placeholder and compute in a `.task` keyed by the report's configuration after first paint (`ReportsHome.swift`), but the computation itself stays on the main actor: `Book` is a non-`Sendable` object graph, and a genuinely background read would race main-actor edits. Moving further requires a read-gate (writers wait on in-flight readers) — deliberately deferred until the memoised first-build is shown to be too slow in practice. A `Perf` signpost + DEBUG over-budget harness wraps the hot paths (tree/register rebuilds, search replay, report builds, whole-book snapshots) so regressions surface in the console, not in reviews.

The measurements that justified each of these choices — on the reference book, in a stated build configuration — are recorded in [implemented.md](implemented.md).

### 10.1 UI-shell decisions (Jul 2026 redesign)

The four-audit usability/performance review ([usability-review.md](usability-review.md), [performance-review.md](performance-review.md)) reshaped the UI shell; the durable decisions:

- **One register, three disclosure styles.** The account register is a single table whose rows disclose their whole detail at once — notes, tags and every leg. The Jul 2026 decision to drop GnuCash's view styles was reversed in Aug 2026: **Basic Ledger** / **Auto Details** / **Transaction Journal** are back as `RegisterStyle`, because one boolean could express Basic and Journal but had no way to say Auto. The separate "Show Details" toggle is gone — it revealed a single field (Notes) and split a transaction's detail across two unrelated controls. The whole-book journal remains the *All Transactions* destination. Register controls live in the window toolbar in two groups — `[View ▾, Filter]` then `[Actions ▾]` — with editing on the row, not in the toolbar; rationale and sources in [register-ux-research.md](register-ux-research.md).
- **The dashboard is a board, not a page.** It never scrolls: columns come from the window width, unit rows from its height (row height stretches so the board lands flush on the bottom edge), and panels place in priority order into the emptiest column that fits — what doesn't fit is dropped. Panels are *content-aware*: a card whose whole message would be "nothing in this period" yields its tile. Leftover rows stretch the column's last tile; adaptive cards (Recent Activity) size their row count from the tile they were dealt.
- **A repeated row gets a field, never a `Picker` over accounts** (added 15 Aug 2026, after the second crash). A screen showing one row per statement line must use a **lazy `List`** — not a `Form`, which materialises every row at once — and each row's account chooser must be `AccountField`, which draws one button until it is clicked. A `Picker` builds one menu item per account per row, and rows × accounts overruns SwiftUI's attribute graph: the process aborts inside `AG::data::table::grow_region()` with a backtrace containing no frame of ours, because the failure is in graph allocation rather than in any `body`. Measured in a standalone harness at the reference book's scale (550 postable accounts): `Form` + `Picker` survives 150 rows and aborts at 175, where a two-month card statement runs to 220; `List` + `Picker` survives 2000 rows but still aborts once the account list reaches 5000, because the ceiling only moves to *visible* rows × accounts; `List` + `AccountField` survives both axes. **Both halves are required** — the lazy container alone just buys headroom. This cost the Categorise sheet first and the Import sheet second, so it is written here rather than as a third code comment.
- **One feedback surface.** A single bottom-of-window status overlay carries determinate progress (quote fetches), a Saving… chip, and transient completion/failure toasts (`AppModel.showToast`). Long operations and previously-silent `try?` failure paths route through it.
- **Desk state is not book data.** Where the user *was* — sidebar destination, selected account (per book, keyed by file path), dashboard period, register sort/filter — lives in `UserDefaults` and is restored on open. It never dirties the document and never appears in an export.
- **Plain language is a UI-string concern only.** GnuCash vocabulary survives in the engine, the file format, and the code; the sweep (Repair Book, Close Financial Year, Group, All Transactions) is confined to user-facing strings.

**The open decision is closed (10 Aug 2026): always working-copy.** Whether to skip the working-copy hop on genuinely local volumes (direct mode, §6.2) was measured on real hardware — a 46,578-transaction, 54 MB book on a local SSD and on an SMB share — and direct mode turns out to have nothing to offer at either end. On the local volume the hop costs **0 ms**, because copying a file on APFS is a clone rather than a copy, so the optimisation would save nothing measurable. Over SMB, reading the same book without the hop — SQLite talking to the file across the wire — took **40.6 s against 3.5 s**, and only 2.0 s of that was CPU: the rest is SQLite's small random reads paying network latency each time, exactly the hazard §6 opens with. A trade-off with no upside on one side and an 11.6× penalty on the other is not a trade-off, so direct mode is **not built**, and ADR-8 stands unqualified. Measurements in [implemented.md](implemented.md); `finlens` paid that cost until 15 Aug 2026, when `SourceLoader.readBook` gained the same hop for network volumes only — no lock, no write to the book, so ADR-L2 is unchanged.

---

## 11. Apple Intelligence integration (Intelligence package)

All Intelligence features run on Apple's Foundation Models framework (27.0 minimum), **on the device** in every build shipped so far — no financial data leaves it — and follow one contract:

1. **The model proposes; deterministic code disposes.** Model output is typed (`@Generable` guided generation, greedy sampling for extraction), parsed tolerantly (`IntelligenceParsing`), resolved against the real chart of accounts (`AccountNameMatcher`), and cross-checked arithmetically (statement signs re-derived from the running balance column; invoice line sums reconciled against the printed total). Prose is disposed too (`FigureGrounding`): every number a narrator writes — review slide, report note or forecast outlook — must be one it was given, and it is read **with its unit**. A number followed by a percent sign has to be one of the percentages given; "66.6k" is checked as 66,600; an amount with the currency after it is never a day, a month or a year; a number that cannot be read at all is not thereby true. Numbers are read in the person's language's format as well as English's, separators are tried as separators first and as punctuation second ("66 611" is one number in French, "26 450" two in "FY 2025–26 450 AUD"), and a forecast may only name dates the forecast contains. A sentence that fails is dropped, as is one carrying the debris of the model's own output format. Only reviewed results mutate the book.
2. **One seam between a feature and a model.** `LanguageModels` (Intelligence package) is the only place a session is created, and a request is resolved **once**: which model the feature runs on, how much that model can read, and — for the document readers — how much of the document fits beside the instructions, the answer's schema and the answer, all against that one model. A document is cut by the model's own count (`tokenCount(for:)`): measured as it will be sent, cut in proportion, measured again. `TokenBudget.estimate` stands in only where a model has a window and no counter, and its weights are fitted to the model's measured counts — a bank statement is 1.5 characters a token where English prose is 5.8, so no single rate serves. The seam also tells the model the person's locale and, for prose, the language to answer in, and translates every Foundation Models 27 error into `IntelligenceError`. Nothing about a model is remembered in a table: the window on the reference Mac is 8,192 tokens where Apple's own article says 4,096.
3. **Availability is asked per feature.** `LanguageModels.availability(for:)` reports the state of the model a feature would run on, in a sentence that names the right Settings app for the platform; menus disable (with the reason as a tooltip) and every entry point degrades gracefully. Guardrail refusals surface a friendly message, and where one document is being read and a person is waiting, the model's own explanation — shown only if it *is* an explanation, because the model has answered that question with the extraction itself. The budget advisor retries with simplified phrasing and falls back to a deterministic average-based plan when the model will not write one; a model that is simply not there is reported as that.
4. **Chunked work, exact answers, honest failures.** PDF pages are extracted via PDFKit with a geometric reflow (rows rebuilt from per-character bounds — content-stream order scrambles tables) and a Vision-OCR fallback for scans; each slice or batch is one fresh session. Where the number of rows in an answer is known from the request (one per category, one per transaction) the request is made against the `@Generable` type's own schema with that one count fixed (`LanguageModels.countedSchema`) — a ceiling alone let the model pad its answer until the window overflowed. A failure about one slice (a block the model declines, a request that times out) costs that slice; a failure of the model itself (unavailable, rate-limited, out of allowance, cancelled) stops the run, because a statement's first two pages returned as the statement is worse than an error (`IntelligenceError.endsABatch`).
5. **Prose is drafted up to three times, by one policy** (`LanguageModels.firstSoundDraft`): a draft that fails the number check is never shown; a sound draft in the wrong language is kept in hand while the model is asked again and shown if nothing better arrives; a draft that fails does not cost the one in hand. The language of an answer is judged by script where the language has its own, and otherwise from the words the model chose rather than the account names it was handed.
6. **Private Cloud Compute is a build decision before it is a setting.** Apple's server-side model (32K tokens, reasoning) conforms to the same `LanguageModel` protocol, and where a build can offer it the seam routes single-document reading (invoices, dividend statements) and prose to it by default — the owner's decision — with the device as the alternative in Settings ▸ Apple Intelligence, which every platform now has. Work done by the hundred stays on the device whatever is chosen: Auto-Categorise and an import's category suggestions, classifying, and reading bank statements, which is dozens of requests a file against a daily allowance. **Leaving the device is granted by the command, not assumed from the feature.** A request runs on the person's choice only inside `LanguageModels.permittingOffDevice(_:)`, which a command enters through `AppModel.running(_:)` with its `IntelligenceCommand` — the list of features it may send — and the view that starts the command shows `IntelligenceRunsNote` for the same case; a request reached any other way runs on the device (`LanguageModels.route`, a pure rule, tested with the cloud assumed present, and `requestRoute`, which is what joins the task's leave to it). It was the feature's business alone until the review of `73b2bd6` found Categorise from Attachment gated and described as attachment insight, which stays on the device, while it also read the attachment as a dividend statement and as an invoice, which do not; no build could reach the cloud, so nothing was sent. `IntelligenceCommandTests` reads the sources for it: every file that calls one of the model's nine entry points must show that command's note, every grant goes through `running`, and nothing else grants. What a source test cannot see is whether a note is on screen *before* its request — three commands start when their sheet opens — and that is an open decision of the owner's (deferred.md §3a), which `PrivateCloudComputeBuildTests` holds the entitlement to. The framework reports the cloud model as available even without Apple's managed entitlement, and the first request then ends the process — so it is compiled in only by the `PRIVATE_CLOUD_COMPUTE` condition, added in the same change as the `com.apple.developer.private-cloud-compute` entitlement (`PrivateCloudComputeBuildTests` fails if they disagree, and fails again until the help and the privacy policy say where requests go); on the Mac the signed entitlement is read back as well, and the Simulator is never offered it. No build has had either yet (12 Oct 2026), so nothing here has run against the cloud model.

| Feature | ID | Flow |
|---|---|---|
| PDF statement import | FR-AI-01 | `StatementExtractor` → `StagedTransaction` → ImportMatcher/review; duplicate rows can mark the matched register split cleared (light reconciliation) |
| Auto-categorisation | FR-AI-02 | `TransactionCategorizer` fills gaps after rules → history → heuristics, in import review and the Auto-Categorise panel |
| Invoice splitting | FR-AI-03 | `InvoiceAnalyzer` line items → categorised splits in the transaction editor ("Split from Invoice…") |
| Dividend statements | FR-AI-04 | `DividendExtractor` (franked/unfranked/franking credits) → reviewed booking incl. gross-up |
| Budget suggestion | FR-AI-05 | Deterministic spending stats → `BudgetAdvisor` → reviewed per-line apply |
| Forecast outlook | FR-AI-06 | Computed `cashFlowForecast` facts → `ForecastNarrator` headline + insights in the Cash Flow report |
| Smart Import (multi-PDF) | FR-AI-07 | `DocumentClassifier` triages each PDF, then routes: statements → FR-AI-01 review; dividend statements → verified against the register; invoices → matched to their transaction, split by line items, and re-dated to the invoice date |
| Document links | FR-AI-08 | Applied dividend statements and invoices are copied into the document folder and linked to their transaction via the `assoc_uri` KVP slot as a relative path |
| Slide narration | FR-AI-09 | `ReviewNarrator` writes each review-deck slide's action title + insight from that slide's deterministic facts pack; `ReviewStoryValidator` rejects any story quoting an unlisted number — the deterministic title always stands as the fallback |

**Dual dates (FR-AI-07).** When Smart Import adopts a document's true economic date, the bank's posted date moves to a preserved KVP slot (`Transaction.statementDate`, `finvestlens/statement-date`) — matching considers *both* dates, so re-importing the same bank statement never duplicates a re-dated transaction. The slot lives in the native document; GnuCash XML export carries the adjusted `datePosted` (no schema breakage — GnuCash sees the economic date).

**Document links (FR-AI-08).** `Transaction.documentLink` uses GnuCash's own slot key (`assoc_uri`), round-tripped in `trn:slots`, so links attached in FinvestLens open in GnuCash and vice versa. Resolution follows GnuCash semantics: absolute paths and `file://` URIs open as-is; anything else is relative to the configured document folder (or the book's folder when unset).

Testing: deterministic parts are unit-tested, including every sentence the number check was found to pass or reject wrongly. Live suites exercise the real on-device model end to end — the eight features on synthetic documents in English; the three narrators in each of the seven languages the app is translated into; the budget advisor in Japanese and French; and the document cut against the model's own count on four kinds of text — and self-skip where Apple Intelligence is unavailable, which keeps CI deterministic. They run one at a time under a single parent suite, because there is one model. Two surveys print rather than assert, and are run by hand when a prompt or the model changes (`FL_GROUNDING_SURVEY`, `FL_LANGUAGE_SURVEY`): every draft with the check's verdict, and where the language order works. What the prompts did on the current model, and why each is worded and placed as it is, is recorded in [intelligence-prompts.md](intelligence-prompts.md).

---

## 12. References

**Persistence / SQLite**
- [groue/GRDB.swift](https://github.com/groue/GRDB.swift) · [Core Data vs SwiftData 2025](https://distantjob.com/blog/core-data-vs-swiftdata/) · [SwiftData slow with large data (Apple Forums)](https://developer.apple.com/forums/thread/740517) · [SwiftData vs Realm perf](https://www.emergetools.com/blog/posts/swiftdata-vs-realm-performance-comparison)
- SQLite over network filesystems (avoid) — https://www.sqlite.org/whentouse.html · `NSFileCoordinator` — https://developer.apple.com/documentation/foundation/nsfilecoordinator

**Money**
- `Foundation.Decimal` — https://developer.apple.com/documentation/foundation/decimal

**XML / compression**
- Foundation `XMLParser` (native SAX) · Apple Compression framework

**Quotes / market data**
- Keyless (yfinance-like) — [ranaroussi/yfinance](https://github.com/ranaroussi/yfinance) (approach reference); Yahoo endpoints `query1/query2.finance.yahoo.com`
- Keyed — [EODHD](https://eodhd.com/) ([delisted data](https://eodhd.com/financial-apis/delisted-stock-companies-data)) · [Alpha Vantage](https://www.alphavantage.co/) · Finnhub · Twelve Data

**Import formats**
- CSV — [dehesa/CodableCSV](https://github.com/dehesa/CodableCSV) · [yaslab/CSV.swift](https://github.com/yaslab/CSV.swift)
- QIF (custom; specs) — [Wikipedia QIF](https://en.wikipedia.org/wiki/Quicken_Interchange_Format) · [Quiffen](https://quiffen.readthedocs.io/) · [hazzik/qif](https://github.com/hazzik/qif)
- OFX/QFX (custom; specs) — [csingley/ofxtools](https://github.com/csingley/ofxtools) · [bradenmacdonald/ofx-js](https://github.com/bradenmacdonald/ofx-js) · [saltedge/salt-parser](https://github.com/saltedge/salt-parser)

**Project docs** — [PRD](prd.md) · [Porting Strategy](porting.md) · [README](../README.md) · [LICENSE](../LICENSE)

> GRDB — the single external dependency (§9) — is MIT-licensed (GPLv3-compatible); the CSV/QIF/OFX links above are conformance references, not linked code. FinvestLens is licensed GPLv3 and is not affiliated with or endorsed by the GnuCash project.
