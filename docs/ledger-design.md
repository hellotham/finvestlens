# FinvestLens — Ledger CLI & Ledger Interchange Design

| | |
|---|---|
| **Document status** | Design baseline v1.1 (25 Jul 2026) — **P10a/P10b built and green**; P10c (CLI) next |
| **Scope** | A ledger-modelled command-line interface (`finlens`) over FinvestLens books, plus import/export of the [Ledger 3](https://ledger-cli.org) plain-text journal format |
| **Research** | [ledger-format-reference.md](ledger-format-reference.md) (journal grammar, verified against the v3.4.1 manual + parser source) · [ledger-cli-reference.md](ledger-cli-reference.md) (CLI surface, verified against the manual, man page and C++ source) |
| **Companions** | [PRD](prd.md) §5.14/§5.19 · [Architecture](architecture.md) · [Plan](plan.md) §13b |

Ledger is the origin of plain-text accounting: a double-entry journal in a
human-editable text file, reported on by a fast, composable, read-only CLI.
FinvestLens shares its ancestry (GnuCash-style double entry) but not its
surfaces. This design adds both halves of the bridge:

1. **Ledger interchange** — read and write Ledger 3 journal files with the
   same round-trip seriousness as GnuCash XML (`FR-XIO-09/10`), so a
   FinvestLens book can move to/from the entire plain-text-accounting
   ecosystem (ledger, hledger, beancount converters, editors, git).
2. **A ledger-modelled CLI** (`finlens`) — `balance`, `register`, `print`
   and friends over a `.finvestlens` book (read-only), a `.ledger` journal,
   or a `.gnucash` file (`FR-CLI-*`) — scriptable, pipeable, and familiar to
   anyone who has used `ledger`.

---

## 1. Goals and non-goals

**Goals**

- **G-L1** — `finlens print`/export emits a Ledger 3 journal that the real
  `ledger` binary parses cleanly, and that FinvestLens re-imports to an
  equivalent book (GUIDs, amounts, states, tags preserved).
- **G-L2** — Import the common core of hand-written Ledger journals (the
  grammar people actually use) with clear per-line errors and an import
  summary in the FR-IMP-07 style; never silently alter data (NFR-03).
- **G-L3** — The CLI is **strictly read-only** — ledger's own contract
  ("Ledger never changes your data") — and safe to run against a book the
  app has open.
- **G-L4** — Familiarity over cloning: same commands, same query idioms,
  same report *shapes* as ledger; byte-identical output to the C++ binary is
  a non-goal (documented divergences instead).

**Non-goals**

- **NG-L1** — Ledger's full value-expression language, format strings
  (`-F`), `select`, `python`, timeclock, and `convert` (we have a real bank
  importer). A small predicate subset ships instead (§7.4); the rest is
  recorded out of scope.
- **NG-L2** — Applying **automated transactions** (`= EXPR`) on import.
  They synthesize postings via predicate + multiplier semantics that would
  make the imported book depend on a rules engine re-run; v1 parses and
  reports them as skipped (with counts), and `print` on a journal source
  re-emits them verbatim.
- **NG-L3** — A writable CLI (no `finlens add`/`xact --write`). Editing
  stays in the app; the CLI's `xact` (if built, P10d) prints a draft only.
- **NG-L4** — Windows/Linux. The CLI is a macOS SPM executable (same
  platform floor as the packages it links).

---

## 2. What the research settled

The two reference documents are the parser/CLI spec. The load-bearing facts:

- The journal grammar dispatches on the **first character of each line**;
  postings need a **hard separator** (two spaces / tab) between account and
  amount, and account names may contain single spaces.
- **Costs** come as per-unit `@` or total `@@` — total cost is exactly our
  split's `(quantity, value)` pair, which makes the security/FX mapping
  lossless in the `@@` direction.
- **Auxiliary dates** (`DATE=EDATE`) are ledger's native slot for exactly
  what our `statementDate` KVP records — the mapping is 1:1.
- **Metadata comments** (`; key: value`, `; :tag:`) give us a standard,
  ledger-legal place to carry GUIDs, account types, and split actions —
  round-trip identity without inventing syntax.
- **Balance assertions run in file order, not date order**; they are a
  verification channel, not data — import verifies and reports, never stores.
- **Unbalanced virtual postings** legally violate the zero-sum invariant our
  engine enforces (`FR-ENG-06`); they cannot become real splits.
- The CLI's option processor is order-independent (options interleave with
  query terms), queries are regex-with-implicit-OR, period expressions are a
  small English grammar, and `-e/--end` is **exclusive** (unlike our
  reports' inclusive `to` — the CLI keeps ledger's convention; the mapping
  layer, not the user, absorbs the difference).
- Exit codes are 0/1 only; warnings never change the exit status.

---

## 3. Architecture

```
Packages/
 ├─ Interchange            ← + Ledger codec (parse / write / Book mapping)
 │    ├─ LedgerJournal.swift        parsed-journal model (+ extras: directives,
 │    │                             periodic/automated entries, assertions)
 │    ├─ LedgerParser.swift         lexer/parser, file:line errors, include/year/apply state
 │    ├─ LedgerAmountStyle.swift    per-commodity display-style learning
 │    ├─ LedgerWriter.swift         canonical journal output (shared by export & `print`)
 │    └─ LedgerBookMapping.swift    LedgerJournal ⟷ Book (import result + summary)
 └─ CLI                    ← NEW package, macOS-only
      └─ Sources/finlens            executable target
           ├─ main / CommandLineDriver     option+command dispatch (hand-rolled)
           ├─ SourceLoader                 -f: .finvestlens (read-only) / .ledger / .gnucash
           ├─ Query.swift                  ledger query grammar subset → predicate
           ├─ PeriodExpression.swift       period grammar subset → date ranges
           ├─ ReportPipeline.swift         filter → group → value → sort over Book
           └─ Renderers/                   balance, register, print, csv, … layouts
```

- **Dependency edges (downward only):** `Interchange → Engine` (unchanged);
  `CLI → Engine, Persistence, Interchange, Reports`. The CLI is a second
  aggregation point beside FeatureUI; nothing depends on it.
- **No new external dependencies.** Argument parsing is hand-rolled —
  ledger's interleaved options-and-query model, `-X A:B` styles, and query
  shorthands (`@`, `%`, `#`) don't fit `swift-argument-parser`'s declarative
  model anyway, and the dependency budget (Architecture §9: GRDB only)
  stays intact.

> **ADR-L1:** Ledger codec lives in Interchange (it is an interchange
> format, exactly like GnuCash XML); the CLI is a new leaf package with a
> hand-rolled command-line layer and zero new external dependencies.

- **Read-only store access.** `SQLiteDocumentStore` gains
  `init(path:readOnly:)` using GRDB's `Configuration(readonly: true)`. The
  CLI opens the book file **directly** (no lock acquisition, no working
  copy, no heartbeat — it never writes), which makes `finlens bal` safe
  while the app holds the advisory lock. A rollback-journal SQLite file
  always admits readers; the one caveat (a reader racing the app's atomic
  save-replace sees the old file — fine) is documented in the CLI help.

> **ADR-L2:** The CLI never takes the advisory lock and never writes:
> read-only GRDB configuration, no working copy. Ledger's own "never
> changes your data" contract, kept literally.

- **One report engine.** Every `-f` source converts to an Engine `Book`
  first (`.ledger` via LedgerBookMapping, `.gnucash` via the existing
  importer, `.finvestlens` via the store). The report pipeline then has one
  input type; journal-only extras (periodic entries, skipped virtuals,
  automated rules) ride alongside in a `SourceExtras` struct for the
  commands that need them (`print --raw`, `--budget` later).

> **ADR-L3:** Convert every source to `Book` + `SourceExtras`; one pipeline,
> not per-format report code.

- **Binary name: `finlens`.** Short, evokes FinvestLens, doesn't shadow the
  real `ledger` binary users may also have. (Alternatives considered:
  `flledger` — clunky; `ledger` — collision.) Built with
  `swift build --package-path Packages/CLI`; `swift run finlens …` during
  development.

---

## 4. Data-model mapping (Book ⟷ Ledger journal)

| FinvestLens | Ledger | Notes |
|---|---|---|
| `Account` tree, colon full names | colon-separated account names | 1:1 — both allow single spaces in components. |
| `Account.type` | `account` directive + `; finvestlens.type: bank` metadata in its `note` | Export writes an `account` block per account (name, note, type, code, GUID). Import reads ours back; for foreign journals, infer from the top-level name (Assets/Bank→asset/bank, Liabilities→liability, Income→income, Expenses→expense, Equity→equity; else asset) — the GnuCash convention ledger files follow anyway. |
| `Account.guid` / `Transaction.guid` | `; guid: <32-hex>` metadata | Round-trip identity, ledger-legal, ignored by ledger itself. Foreign journals without it mint GUIDs on import (stable within one import). |
| `Commodity` (namespace, mnemonic, fraction) | commodity symbol + `commodity` directive with `format` | Export always writes **suffix style with a space** (`100.00 AUD`, `10 BHP`) — unambiguous, locale-free, round-trip-stable; `format` carries the display precision from `smallestFraction`. Import: symbols in the ISO-4217 set → currency namespace, else security; quoted symbols (`"BRK.B"`) accepted. |
| `Split.value` + `Split.quantity` (same commodity) | plain posting amount | `quantity == value` for same-commodity cash legs. |
| `Split.value` ≠ quantity (security / FX leg) | `QTY CMDTY @@ ABS(VALUE) CUR` | **Total cost (`@@`)**, not per-unit — it is exactly the (quantity, value) pair, no division rounding. Ledger's "cost may not be negative" rule holds: sign rides on the quantity, `@@` takes the magnitude (ledger negates internally, matching our value's sign). Import accepts both `@` and `@@` (`@` multiplies out to value). |
| Zero-quantity/zero-value stock-split leg | `QTY CMDTY @@ 0.00 CUR` posting | Survives balancing on both sides (contributes 0). |
| `datePosted` | primary date `%Y/%m/%d` | Import accepts all five ledger date forms + `.`/`-` separators + `year` directive inference. |
| `statementDate` KVP | auxiliary date `=EDATE` | Semantics align: primary = economic date, aux = bank/effective date. Both directions. |
| `number` (cheque no.) | `(CODE)` on the first line | |
| `transactionDescription` | payee | |
| `notes` | transaction note (`; …` after payee / indented first) | |
| `tags` KVP | `; :tag1:tag2:` metadata line | |
| Split `memo` | posting note (`; …` after the amount) | |
| Split `action` | `; action: VALUE` posting metadata | |
| Reconcile state (n/c/y) | none / `!` (pending) / `*` (cleared) | Whole-transaction flag when every split agrees (ledger's `*` shorthand); per-posting flags otherwise. |
| `PriceDB` | `P DATE HH:MM:SS SYMBOL PRICE` lines | Export in `pricedb` form (second granularity); import fills the Book's price database. `@`/`@@` costs also imply prices on import — recorded like GnuCash's `price` from splits (source `ledger`). |
| `ScheduledTransaction` | `~ PERIOD` periodic entry | **Export-only, best effort**: our Recurrence subset maps onto `every N …/monthly/…` with `from`; anything richer (nth-weekday, weekend adjust) exports its nearest period plus a `; finvestlens.recurrence: …` metadata note. Not imported back into schedules (they live in app KVP); parsed into `SourceExtras` for `--budget` later. |
| `Budget` | `~ Monthly` periodic entries (one posting per budgeted account) | Same export-only, best-effort status. |
| Business objects, lots, goals, rules, planners | — | Out of ledger's model; not exported. Lots need no export: our engine derives them from postings, and ledger users get `--lots` semantics from their own tool. |
| — | balance assertions `= AMOUNT` | Import **verifies in file order** and reports pass/fail counts in the import summary (warnings, FR-IMP-08 style); never stored; not exported in v1. |
| — | balance **assignments** (empty amount `= AMOUNT`) | Materialised to the concrete amount at import (running balance at that file position), counted in the summary as "assignments resolved". |
| — | balanced-virtual `[Account]` postings | Imported as **real** splits (the bracketed subset sums to zero, so FR-ENG-06 holds); the bracket is recorded as `; virtual: balanced` metadata so export can restore it. |
| — | unbalanced-virtual `(Account)` postings | **Skipped with a per-line warning** and a summary count — they violate the double-entry invariant. `print` on a journal source still re-emits them (from `SourceExtras`). |
| — | automated `= EXPR` entries | Parsed into `SourceExtras`, **not applied** (NG-L2); counted in the summary. |
| — | elided amounts | Resolved at parse time (ledger's inference rules, incl. the multi-commodity copy); export always writes explicit amounts. |
| — | expression amounts `($10 + $20)`, `define`, lot annotations `{…}`, `capture`, `apply fixed`, timeclock, `python` | Not supported in v1: amounts must be literal; each occurrence is a clear per-line error (grammar recognised, feature named). Lot annotations are parsed and **preserved as posting metadata** (`; lot: {…} […]`) so print/export don't destroy them, but they don't affect balancing (documented divergence from ledger's `{…}` balancing rule). |

**Directives on import**: `include` (globs, relative-to-includer), `year`/`Y`/`apply year`,
`account` (+ subdirective `note`, `alias`), `alias`, `apply account`,
`apply tag`, `bucket`/`A`, `commodity` (+ `format`, `note`), `D`
(decimal-comma/style), `N`, `P`, `comment…end comment`, `payee alias` — the
set the format reference marks as living. Everything else parses to a
warning ("directive X ignored") rather than an error.

**Determinism**: export orders transactions by (datePosted, book order),
accounts depth-first, prices by (date, symbol); output is byte-stable for an
unchanged book — same property the GnuCash exporter has, same reason
(diffable in git, testable).

---

## 5. The `finlens` CLI

### 5.1 Invocation

```
finlens [OPTIONS…] COMMAND [QUERY…]
finlens -f Book.finvestlens bal ^Assets ^Liabilities
finlens -f journal.ledger reg groceries -p "last month"
finlens -f Book.finvestlens print > journal.ledger      # export, composably
```

- Options interleave with query terms, ledger-style; `-f` is repeatable
  (multiple journals merge; multiple books are an error in v1).
- Source by extension + content sniff: `.finvestlens` (read-only store),
  `.ledger`/`.journal`/`.dat` (parser), `.gnucash`/`.xml`/gzip (existing
  importer). `-` reads a journal from stdin.
- No `-f`: `$FINLENS_FILE`, else error. (We do **not** read `LEDGER_FILE`
  or `~/.ledgerrc` — pointing another tool's environment at a different
  engine invites silent confusion; a `finlensrc` init file can come later
  if wanted.)
- Exit codes: 0 success, 1 any error; warnings to stderr never change it.
  Color auto-detects a TTY (`--color`/`--no-color` override); `-o FILE`
  writes the report to a file; no pager in v1.

### 5.2 Commands (v1 — the core-80 set)

`balance` (bal, b) · `register` (reg, r) · `print` · `csv` · `accounts` ·
`payees` · `commodities` · `prices` · `pricedb` · `stats` · `equity` ·
`cleared` · `source` (parse-check, exit 0/1) · `--version` / `--help`

Layout fidelity follows the CLI reference: balance's right-justified
20-column totals, 2-space tree indent, single-child **chain elision**, and
the 20-dash separator before the grand total; register's
date/payee/account/amount/running-total columns with width distribution and
smart account abbreviation; `cleared`'s three-column layout; `print`'s
canonical re-parseable output (shared with the exporter — they are the same
code path, ADR-L3). `print` of a `.finvestlens` book **is** ledger export.

### 5.3 Filters, dates, valuation

- **Query terms**: bare account regex (implicit OR), `and`/`or`/`not` +
  parentheses, `@payee`/`payee`, `%tag`/`tag` (incl. `tag K=V`),
  `#code`/`code`, `=note`/`note`. `expr` is recognised and rejected with a
  "value expressions not supported" error naming this document.
- **Dates**: `-b`/`-e` (end exclusive, ledger convention), `--now`, smart
  dates (`today`, `last month`, `2026/07`, `10/1`, `3 weeks ago`), `-p`
  period expressions in the `[interval] [from|since …] [to|until …]|[in …]`
  grammar, and `-D/-W/-M/--quarterly/-Y` shortcuts producing grouped
  register/balance rows.
- **States**: `-C/--cleared`, `-U/--uncleared`, `--pending`; `-R/--real`
  (only meaningful for journal sources — book sources are all real).
- **Valuation**: `-V` (latest price), `-X CODE` (specific commodity, incl.
  the `A:B` pair form), `-B` (cost basis), `-H` (historical) — all over the
  book's PriceDB plus prices implied by journal `@` costs, matching how the
  app values portfolios today.
- **Display**: `--flat`, `--depth N`, `-E/--empty`, `--no-total`,
  `-n/--collapse`, `-s/--subtotal`, `-S key[,key…]` with `-key` reversal
  (keys: `date`, `amount`, `total`, `payee`, `account`), `--head/--tail N`,
  width overrides + `--columns`/`-w`.

### 5.3a Interactive REPL (decided in — ships with P10c)

`finlens -f FILE` with no command enters ledger's interactive mode: a
version banner, the sources loaded **once**, then one report command per
prompt (same grammar as argv, options interleaved). REPL-only commands per
ledger: `push [options]` (layer option settings onto subsequent reports),
`pop`, `reload` (re-read the sources — the one place the CLI re-reads a
live book). This is cheap by construction: the driver already separates
"load sources" from "run one command"; the REPL is a readline loop over the
second half.

### 5.4 Deliberately out (recorded, not forgotten)

Value expressions beyond the query subset (`-l`, `-d`, `-F`, `--bold-if`),
`select`, `xact` drafts, `convert`, `--budget`/`--forecast`,
`--pivot`, `--anon`, plot outputs (`-j/-J`), `lisp`/`xml` outputs. Each is
independently addable in P10d+ without reshaping the pipeline; the CLI
reference documents their exact semantics for that day.

### 5.5 App integration

- **File ▸ Export ▸ Ledger Journal…** — the LedgerWriter over the open book
  (macOS/iPadOS, per FR-PLT-06).
- **File ▸ Import ▸ Ledger Journal…** — LedgerBookMapping with the standard
  import-summary sheet (counts: transactions, accounts created, assertions
  checked/failed, assignments resolved, virtuals skipped, autos ignored).
- The CLI itself is not bundled in the app; it's a developer/power-user
  build product (`swift build -c release --package-path Packages/CLI`).

---

## 6. Testing

1. **Grammar conformance** — the manual's own examples (collected in the
   format reference) as parser fixtures: parse → canonical print → reparse
   equals; every documented error case errors with file:line.
2. **Round-trip** — Book → journal → Book graph-equality (GUIDs, amounts to
   the cent, states, tags, aux dates, prices), on synthetic fixtures **and**
   the real reference book (env-gated `LiveLedgerRoundTripTests` beside the
   existing live harnesses).
3. **External acceptance (manual, once per phase)** — feed the exported
   journal of the real book to the actual `ledger` binary (`ledger -f
   book.ledger bal`) and tie its grand total to the app's net worth. Not in
   CI (no third-party binaries there); scripted for local runs.
4. **CLI golden outputs** — per command, fixture journal + expected text
   (widths, elision, separators pinned); `finlens bal` on the real book must
   equal the engine's balances to the cent (env-gated).
5. **Read-only guarantee** — a CLI run against a book leaves the file
   byte-identical (fingerprint before/after) and never creates a `.lock`.

---

## 7. Phases

Sequenced so every phase lands releasable and testable on its own.

| Phase | Theme | Exit criteria |
|---|---|---|
| **P10a ✅ — Ledger codec core** | Journal model + parser + canonical writer in Interchange (grammar per the format reference: postings, amounts incl. decimal-comma + quoted commodities, costs, assertions, virtuals, metadata/tags, the living directive set, include/year/apply state machines; periodic/automated into extras; style learning for output) | Manual-example corpus parses and reprints stably; all error cases report file:line; unit suite green. |
| **P10b ✅ — Book mapping + app import/export** | LedgerBookMapping both ways per §4 (guid/type metadata, `@@` legs, states, aux dates, assertion verification, virtual policy, import summary); deterministic export incl. `account`/`commodity` directives, P lines, `~` best-effort; File ▸ Import/Export menu items | Real-book export→import graph-equal (GUIDs/amounts/states/tags); real `ledger` binary reads the export (manual check); live round-trip harness green. |
| **P10c — `finlens` core** | New CLI package: option/query/period parsing, three source loaders (read-only store init), report pipeline + renderers for the §5.2 command set, the interactive REPL (§5.3a), color/`-o`, exit codes | Golden-output suite green; `finlens bal` total == app net worth on the real book to the cent; read-only guarantee test green; REPL runs the same commands against once-loaded sources; `swift run finlens --help` documents every shipped flag. |
| **P10d — Depth (demand-ordered)** | Valuation flags (`-V/-X/-B/-H`), periodic grouping (`-M --subtotal` …), `--budget` family over `~` extras/app Budgets, `xact` drafts, `-l/-d` mini-expressions, init file, man page (`docs/cli.md`) | Each item ships with its own goldens; none blocks the others. |

**Delivered so far (25 Jul 2026).** P10a: `LedgerJournal`/`LedgerParser`/
`LedgerWriter`/`LedgerAmountStyle` in Interchange — the full living grammar
(postings, costs, assertions/assignments, virtuals, metadata/tags, directive
set with include/year/apply state, periodic+automated capture, decimal-comma
inference, per-commodity style learning), file:line diagnostics with
per-entry recovery, and parse→write→parse as a fixed point. P10b:
`LedgerBookMapping` both ways, `SQLiteDocumentStore(readOnlyPath:)`, and
File ▸ Import/Export Ledger Journal… menu items. **Verified on the real
reference book**: 46,553 transactions / 559 accounts / 159,871 prices export
to a 16.4 MB journal in ~3.0 s, re-import in ~7.1 s with **zero errors**,
every account balance matching to the cent and export→import→export
byte-identical (`LiveLedgerRoundTripTests`, env-gated). Two real-book
findings shaped the codec: commodity mnemonics contain spaces
(`AT&T Top-up`), so metadata values are quoted and symbols emit quoted; and
the `commodity … format` sub-directive is authoritative for precision on
import (a whole-unit security can still hold fractional units).

**Estimated shape**: P10a and P10c are the two big lifts (a real parser; a
real terminal report engine). P10b is mostly mapping tables + tests. P10d is
à la carte.

## 8. Risks

- **Grammar breadth** — ledger's parser is 20 years of accretion. Mitigated
  by the first-character dispatch table (small closed set), the living-vs-
  deprecated directive split in the reference, and error-not-crash handling
  for everything unrecognised.
- **Output-fidelity expectations** — users may diff `finlens` against
  `ledger` byte-for-byte. G-L4 sets the bar at familiar-not-identical; the
  golden tests pin *our* layout so it can't drift, and divergences get a
  documented list (as the GnuCash accepted-divergences do).
- **Foreign journals stress the invariant** — unbalanced virtuals,
  assignments, autos. The §4 policies (skip/materialise/ignore, all
  counted) keep FR-ENG-06 absolute while telling the user exactly what
  happened.
- **Reading a live book** — benign by design (read-only connection,
  rollback journal), but a reader mid-save sees the pre-save file; the help
  text says so.

## 9. Decisions (resolved 25 Jul 2026)

1. **Binary name** — `finlens`. ✅
2. **Ledger environment compatibility** — `FINLENS_FILE` only; we do not
   read `LEDGER_FILE`/`.ledgerrc`. ✅
3. **`--budget`/`--forecast`** — stays in P10d. ✅
4. **Interactive REPL** — **in scope**, ships with P10c (§5.3a). ✅
