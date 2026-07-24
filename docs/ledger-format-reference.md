# Ledger 3 Journal File Format — Implementation Reference

> Companion to [ledger-design.md](ledger-design.md). Basis: the Ledger 3
> manual (`doc/ledger3.texi` at tag **v3.4.1**, the source of
> https://ledger-cli.org/doc/ledger3.html — the site 403-blocks robotic
> fetchers, so the texinfo source was used verbatim), cross-checked against
> the v3.4.1 parser (`src/textual.cc`, `src/amount.cc`, `src/times.cc`).
> Quotes are the manual's own wording. This is the spec the FinvestLens
> ledger parser/writer is written against.

Ledger dispatches **on the first character of each line**:

| First char | Meaning |
|---|---|
| digit `0-9` | start of a transaction |
| whitespace | continuation of the current transaction (posting or note) — an error outside one |
| `;` `#` `%` `|` `*` | comment line (ignored, not preserved by `print`) |
| `P` | historical price line |
| `=` | automated transaction |
| `~` | periodic transaction |
| `-` | option setting (same syntax as CLI, e.g. `--decimal-comma` on its own line) |
| `@` or `!` | deprecated prefix; stripped, remainder parsed as a directive (`!include`) |
| `i I o O b h` | timeclock lines (timelog support) |
| `A C D N P Y` | one-character legacy directives |
| any letter | word directive (`account`, `include`, …) |

---

## 1. Transaction syntax

First-line grammar (quoted from "Journal Format"):

```
DATE[=EDATE] [*|!] [(CODE)] DESC
```

- `DATE` must start **at column 0** ("the start of the transaction (the date typically) is at the beginning of the first line"). Parser splits the first whitespace-delimited token at the first `=`: left part = primary date, right part = auxiliary (effective) date.
- State flag: `*` = cleared, `!` = pending; default state is uncleared. Appears after the date(s), before code/payee. "What these mean is entirely up to you."
- `(CODE)` — free text in parentheses, e.g. a check number: `2012-03-10 (#100) KFC`. "This has no meaning and is only displayed by the print command."
- `DESC` — payee/description: the rest of the line, up to an optional note.
- Transaction note: after the payee and a **hard separator** — "at least one tab or two spaces (or a space and a tab)" — a `; note`. Further note lines may follow on indented lines beginning `;`. A transaction's note (and its metadata) is shared by **all** its postings.
- Continuation lines: every subsequent line beginning with whitespace belongs to the transaction; each is either a posting or an indented `;` note. Indentation must be ≥ 1 space ("accounts are indented by at least one space"); the amount of indentation is otherwise free.
- Posting grammar (quoted): `ACCOUNT  AMOUNT  [; NOTE]` — "the AMOUNT must be preceded by at least two whitespace characters" (two spaces or a tab). An indented `;` line after a posting attaches the note to that posting; before the first posting, to the transaction.

```
2012-03-10=2012-03-08 * (#100) KFC  ; xact note
    ; more xact note / metadata
    Expenses:Food                $20.00  ; posting #1 note
    Assets:Cash
      ; posting #2 note, extra indentation is optional
```

Marking the transaction `*` "is really just shorthand for clearing all of its postings."

## 2. Postings

- **Account names**: colon-separated hierarchy (`Expenses:Food`); **may contain single spaces** (`Assets:Credit Union:Joint Checking Account`). The account ends at the first hard separator (2+ spaces or tab) or end of line; a **single** space is part of the name. No escaping/quoting exists for account names. Surrounding `(...)`/`[...]` marks a virtual posting (§5); `<...>` is an undocumented "deferred" posting (§11). Leading `*` or `!` before the account = per-posting state flag.
- **Amount syntax**: commodity before or after the quantity, with or without a space: `$20.00`, `-$20.00`, `$-20.00`, `20.00 AUD`, `-15.50 CAD`, `100 "crab apples"`. All negative placements parse; print reproduces the style the commodity was first observed with.
- **Precision inference**: "display precision … is determined by the most precise value seen for a given commodity" — but only from **observed** amounts (posting amounts). Costs after `@`/`@@`, `P` lines, and D-directive amounts are *unobserved*: they contribute value only, never display style. Thousands separators (`$1,519.95`) are legal and set a per-commodity thousands flag. Internally every number is an infinite-precision rational (no floats).
- **Elided amount**: "if exactly one posting has no amount specified, Ledger will infer the inverse of the other postings' amounts." With multiple commodities the null posting is copied N times, one per commodity. Exactly one null posting is allowed per transaction (sole exception: balance-assignment reset, §4).
- Per-posting comments and per-posting dates: see §6.

```
2012-03-10 KFC
    Expenses:Food                $20.00
    Expenses:Tips                 $2.00
    Assets:Cash              EUR -10.00
    Liabilities:Credit                   ; infers $-22.00 and EUR 10.00
```

## 3. Costs & prices

Order on a posting line: `ACCOUNT  AMOUNT [{LOT-PRICE}] [[LOT-DATE]] [(LOT-NOTE)] [@ AMOUNT | @@ AMOUNT] [= ASSERT] [; NOTE]`. Lot annotations "can be specified in any combination … in any order. They are all optional."

- `@ AMOUNT` — **per-unit** cost: `10 AAPL @ $50.00`. For balancing, the posting contributes `quantity × per-unit cost` (10 AAPL ≙ $500.00). Cost may be an expression: `@ ($500.00 / 10)`.
- `@@ AMOUNT` — **total** cost: `10 AAPL @@ $500.00`; "Ledger reads this as if you had written `10 AAPL @ ($500.00 / 10)`". A cost "may not be negative" (parser error); with a negative amount, `@@` is negated internally.
- `(@)` / `(@@)` — **virtual cost**: same balancing effect but the exchange rate is *not* recorded in the internal price history: `1000 AAPL (@) $1`.
- `{PRICE}` — **lot price** annotation: `10 AAPL {$50.00}`. Equivalent to `@` for balancing ("the following two transactions are equivalent") but is an attribute of the commodity itself and identifies the lot on later sale: `-50 AAPL {$30.00} @ $50.00` requires a capital-gains posting or the transaction fails to balance.
- `{{TOTAL}}` — total lot price; "Ledger just divides that value by 10 and sees {$50.00}. … The double braces price form is a shorthand only" (print emits single braces; rounding can shift gains by a cent).
- `{=PRICE}` / `@ =PRICE` — **fixated** price/cost: `11 GAL {=$2.299}` — the lot "will now always be reported as being worth" that price, disregarding the price database. `{=P} @ C` with P≠C makes Ledger "auto-generate a balance posting … to Equity:Capital Losses" (or Gains).
- `[DATE]` lot date, `(NOTE)` lot note (note "cannot begin with an `@`"), `((EXPR))` lot value expression (per-lot valuation function/amount).

## 4. Balance assertions & assignments

"If at the end of a posting's amount (**and after the cost too, if there is one**) there is an equals sign, then Ledger will verify that the total value for that account as of that posting matches the amount specified." Both forms are evaluated **in file/parse order — dates are irrelevant** ("the order in which these are evaluated is the order in which they appear in the ledger file").

- **Assertion** — amount present: `Assets:Cash  $-20.00 = $500.00` asserts the account's running total after this posting. Scope: only the asserted commodity is checked; the special value `0` (no commodity) asserts **all** commodities are zero. The check includes earlier postings *within the same transaction* to the same account; real and virtual balances are tracked separately. `--permissive` downgrades failures ("Quiet balance assertions").
- **Assignment** — amount empty: `Assets:Cash    = $500.00` — "sets the amount of the second posting to whatever it would need to be for the total … to be $500.00 after the posting." A second null posting is then allowed to absorb the inverse (balance reset idiom):

```
2012-03-10 Adjustment
    Assets:Cash                         = $500.00
    Equity:Adjustments
```

- Combined with balanced-virtual: `[Assets:Brokerage]  = 10 AAPL` assigns, then requires the assigned amount to be zero — i.e. asserts the account already holds 10 AAPL.
- There is **no `==` operator** in Ledger 3 (single `=` only; `==`/`=*` are hledger extensions). "Partial" (per-commodity) semantics is simply the default behavior of `=`.

## 5. Virtual postings

- `(Account)` — **unbalanced virtual**: "transfer amounts to an account on the sly, bypassing the balancing requirement." Excluded from the zero-sum check entirely.
- `[Account]` — **balanced virtual**: virtual postings that "*should* balance against one or more other virtual postings" — the bracketed subset must itself sum to zero.
- `--real (-R)` removes all virtual postings from reports ("these postings are not considered 'real', and can be removed from all reports using `--real`"); `--actual (-L)` removes automated-generated postings. `print` preserves the parens/brackets.

```
2012-03-10 * KFC
    Expenses:Food                $20.00
    Assets:Cash
    [Budget:Food]               $-20.00
    [Equity:Budgets]             $20.00
```

## 6. Comments & metadata

- **Line comments** (column 0): `;` plus `#`, `%`, `|`, `*` "if used at the beginning of a line". Global comments are not attached to transactions and are dropped by `print`/`output`.
- **Block comments**: `comment` … `end comment` (and synonym `test` … `end test`).
- **Inside a transaction** only indented `;` lines are comments/notes and they are *preserved*. Notes hold metadata:
  - **Flag tags**: `; :TAG:` — "any word not containing whitespace between two colons"; gang multiple: `; :TAG1:TAG2:TAG3:`.
  - **Tag/value**: `; Key: Value` — "Whitespace is needed after the colon, and cannot appear in the Key"; value = rest of line, stored as string.
  - **Typed**: `; Key:: VEXPR` — "If a metadata tag ends in ::, its value will be parsed as a value expression and stored internally as a value rather than as a string" (parsed once at load, e.g. `; AuxDate:: [2012/02/30]`).
  - **Posting dates**: `; [DATE]`, `; [=EDATE]`, `; [DATE=EDATE]` inside a note set the posting's actual and/or auxiliary date, overriding the transaction's (used to spread costs: `$ 37.50  ; [=2008/11/01]`). There is no `Date:` key — brackets are the mechanism.
  - **Special keys**: `Payee: NAME` overrides the payee per posting (affects `register`, `payees`, `--by-payee`; must be declared under `--strict`); `Value:: EXPR` overrides commodity valuation per posting/xact; `UUID:` is matched by the `payee … uuid` directive.
- Transaction-level notes/metadata apply to all its postings; posting-level notes only to that posting.

## 7. Directives

"Command directives must occur at the beginning of a line. Use of `!` and `@` is deprecated." Word directives (parser also accepts these preceded by `@`/`!`):

| Directive | Syntax / effect |
|---|---|
| `account NAME` | Pre-declares an account (only enforced under `--strict`/`--pedantic`). Indented sub-directives: `note TEXT`; `alias NAME` (usable in place of the account, repeatable); `payee REGEX` (repeatable — reroutes a posting whose account ends in "Unknown" when payee matches); `check VEXPR` / `assert VEXPR` (warn/error on every posting in this account); `eval VEXPR` (aka `expr`, run at definition); `value VEXPR` (default valuation for the account); `default` (make this the "balancing account" for single-posting transactions). |
| `alias A=Full:Name` | Account alias: `alias Checking=Assets:Credit Union:Joint Checking Account`. Applies to later lines only; `--recursive-aliases` expands repeatedly; `--no-aliases` disables. |
| `apply account NAME` … `end apply account` | Prefixes all account names in the block: postings go to `Personal:Expenses:…`. |
| `apply tag TAG[: VALUE]` … `end apply tag` | Applies the tag/metadata to every transaction in the block; nestable (stack). |
| `apply fixed COMM AMOUNT` … `end apply fixed` | (alias `apply rate`) All amounts in COMM in the block behave as if annotated `{=AMOUNT}`. |
| `apply year YEAR` | Scoped form of `year`. Plain `end` closes the innermost `apply`; `end apply X` must match the open directive. |
| `assert VEXPR` | Error if the expression is false. `check VEXPR` — same but a warning. |
| `bucket NAME` (legacy `A NAME`) | "Defines the default account to use for balancing transactions" — any unbalanced transaction auto-balances against it. |
| `capture ACCOUNT REGEX` | "replace any account matching a regex with the given account": `capture  Expenses:Deductible:Medical  Medical` (hard separator between the two fields). |
| `comment` … `end comment` | Block comment (also `test` … `end test`). |
| `commodity SYM` | Pre-declares a commodity (`--strict`/`--pedantic`). Sub-directives: `note TEXT`; `format $1,000.00` (canonical display format); `nomarket` (never auto-download quotes); `alias SYM2`; `value VEXPR` (valuation function); `default` (mark as default commodity). |
| `define NAME=VALUE` (alias `def`) | Defines a value-expression variable: `define var_name=$100`, then `Expenses  (var_name*4)`. |
| `expr VEXPR` / `eval VEXPR` | Evaluate a value expression at parse time ("Same as eval"). |
| `include PATH` | Splices a file "as if it were part of the current file"; PATH may contain glob `*` (`bank/*.ledger`); relative paths resolve against the *including file's* directory; `~` expands. |
| `payee NAME` | Sub-directives: `alias REGEX` (parsed payees matching REGEX are renamed to NAME); `uuid HEX` (transaction with metadata `; UUID: HEX` gets payee NAME). |
| `python` … (indented block) | Embeds Python; defined functions become valexpr functions (Python builds only). `import MODULE` — imports a Python module (Python builds only; undocumented in the manual). |
| `tag NAME` | Pre-declares a tag; sub-directives `check VEXPR` / `assert VEXPR` run against each *use* of the tag (`value` bound to the tag's value). |
| `value VEXPR` | Sets the journal-wide default commodity-valuation function. |
| `year YYYY` (legacy `Y`) | "Denotes the year used for all subsequent transactions that give a date without a year." |

One-character legacy directives ("for backwards compatibility with older Ledger versions"):

- `A NAME` → `bucket`. `Y YYYY` → `year`.
- `N SYM` — "pricing information is to be ignored for a given symbol, nor will quotes ever be downloaded" (≙ `commodity` + `nomarket`).
- `D AMOUNT` — default commodity **and** its format flags: `D $1,000.00` (used by the `xact` command; last one wins).
- `C AMOUNT1 = AMOUNT2` — commodity equivalence/conversion: `C 1.00 Kb = 1024 bytes`.
- `P DATE SYMBOL PRICE` — price history (§10 for the time-of-day form).
- `i I o O b h` — timeclock check-in/out lines.
- A line starting with `-` sets a CLI option from within the file (this is how `~/.ledgerrc` works, one option per line).

There is **no** journal `import` directive for data files (only the Python-module form above); file composition is `include` only.

## 8. Periodic (`~`) and automated (`=`) transactions

**Periodic**: `~ PERIOD-EXPRESSION` in place of `DATE PAYEE`, followed by normal postings. "Periodic transactions are used for budgeting and forecasting only, they have no effect without the `--budget` option specified" (or `--add-budget`, `--unbudgeted`, or `--forecast EXPR`, which generates future postings from them).

```
~ Monthly
    Expenses:Rent               $500.00
    Assets
```

Period grammar: `[INTERVAL] [BEGIN] [END]` with INTERVAL ∈ `every day|week|month|quarter|year`, `every N days|weeks|months|quarters|years`, `daily weekly biweekly monthly bimonthly quarterly yearly`; BEGIN = `from|since SPEC`; END = `to|until SPEC`; or `[in] SPEC` alone (`monthly from 2005/04/06`, `weekly last august`).

**Automated**: `= EXPR` where EXPR is a predicate in "the same query syntax as the Ledger command-line" (`= expr true`, `= food`, `= /^Income:Taxable/`, `= ^Income`), followed by postings. Applied **during parsing, unconditionally** (no option required): for every posting of a real transaction matching the predicate, the automated postings are appended to that transaction. Rules:

- Postings must balance (unless virtual). "One thing you cannot do, however, is elide amounts in an automated transaction."
- A **commodity-less amount is a multiplier** on the matched posting's amount: `Foo  50.00` against a $20.00 posting generates `Foo  $1000.00`; signed multipliers allowed (`(Liabilities:Tithe Owed)  -0.1`).
- Amount expressions see the matched posting: `(Foo)  (amount * 2)`.
- `$account` inside the generated account name expands to the matched account; `%(VEXPR)` interpolates value expressions (e.g. `Liabilities:Tax:%(tag(/Tax/))`).
- A note on the automated *transaction* is copied to every **matched** posting; a note on an automated *posting* is copied to the **generated** posting.
- Postings may carry `*`/`!` flags (carried to generated postings); the automated transaction itself cannot.
- `--actual (-L)` hides generated postings in reports; `--raw` makes `print` show the file text untransformed.

## 9. Amounts & commodities details

- **Commodity names**: "Most characters are allowed in a commodity name, except for": any whitespace, digits, `. , ; : ? !`, `- + * / ^ & | =`, `< > [ ] ( ) { }`, `@`. Any of these are allowed inside **double quotes**: `100 "EUN+133"`, `49.957 "Arcancia Équilibre 454"`; quoted commodities print quoted.
- **Style learning**: prefix/suffix position, attached/spaced, thousands marks, decimal mark, and display precision are learned per commodity from observed amounts and reused for all output of that commodity ("commoditized amounts … are reported back in the same form as parsed"). Uncommoditized ("integer") amounts keep their own full precision (division precision starts at 6 digits; multiplication adds precisions).
- **Comma/period disambiguation** (parser, scanning the quantity right-to-left): by default `.` is the decimal mark and `,` a thousands mark that must sit at 3-digit groups; a comma at a non-3-digit offset in an otherwise unpunctuated number switches that amount (and its commodity) to decimal-comma style — so `10,5 EUR` parses as 10.5. Mixed misuse raises errors ("Too many periods in amount", "Incorrect use of thousand-mark comma"). With `--decimal-comma` (or a commodity's learned/declared decimal-comma style, e.g. via `D 1.000,00 EUR` or `commodity … format`), the roles invert: `,` is decimal, `.` is thousands. Ledger *never* guesses per-file; the flag/state is global or per-commodity.
- **Negatives**: sign may precede the whole amount (`-$20.00`, `-15.50 CAD`) or the quantity (`$-20.00`); no parentheses-negative form.

## 10. Dates

- **Accepted transaction-date formats** (parser reader list): `%m/%d`, `%Y/%m/%d`, `%Y/%m`, `%y/%m/%d`, `%Y-%m-%d` — and before matching, `.` and `-` separators are normalized to `/`, so `2010/05/31`, `2010-05-31`, `2010.05.31`, `10/05/31`, `9/29` all parse. A date without a year (`%m/%d`) takes the year from the `year`/`Y`/`apply year` directive, else the current year. `--input-date-format FMT` replaces the whole list with one strptime-style format (and disables separator normalization).
- **Auxiliary (effective) date**: `DATE=EDATE` on the transaction line; `; [DATE=EDATE]`-style bracket notes per posting (§6). "The only use Ledger has for it is that if you specify `--aux-date` (or `--effective`), then all reports and calculations (including pricing) will use the auxiliary date as if it were the primary date." Convention from the manual: primary = accrual/invoice date, auxiliary = cash/effective date.
- **Price lines**: `P DATE SYMBOL PRICE` with an optional time of day: `P 2004/06/21 02:17:58 TWCUX $27.76`. The `pricedb` command re-emits history in this parseable format. Datetime input format is `%Y/%m/%d %H:%M:%S`.

## 11. Deprecated / rarely used, and file locations

**Deprecated or consciously descopeable** (flagged by the manual or undocumented):
- `@`/`!` prefixes on directives ("Use of `!` and `@` is deprecated").
- One-character directives `A Y N D C` ("for backwards compatibility with older Ledger versions"); timeclock chars `i I o O b h`.
- `<Account>` deferred postings — parsed (POST_DEFERRED) but absent from the manual.
- `((lot value expressions))`, `value`/`commodity value`/`account value` valuation functions, `python`/`import`, `define`, `C` equivalences, `capture`, `expr`/`eval` — powerful but rare; all require a value-expression engine.
- `--getquote` script hook — commented out of the 3.4.1 manual (only `--download (-Q)` remains).
- `--explicit` exists as a session option in the binary but is undocumented in the 3.4.1 manual.

**File locations / environment**:
- No built-in journal path: give `--file/-f FILE` (repeatable; `-` = stdin) or set `LEDGER_FILE`. "Typically, the environment variable `LEDGER_FILE` is set, rather than using this command-line option."
- Init file search order: `--init-file FILE`, else `$XDG_CONFIG_HOME` (ledger/ledgerrc), `~/.config/ledger/ledgerrc`, `~/.ledgerrc`, `./.ledgerrc` (also `LEDGER_INIT`). It "may not contain any postings, but it may contain option settings", one per line (`--price-db ~/finance/.pricedb`).
- Every long option maps to a `LEDGER_*` env var (e.g. `LEDGER_DATE_FORMAT`); CLI beats env beats init file; `--args-only` ignores env+init.
- Price database: `--price-db FILE`; the `N` doc says the price file "defaults to `~/.pricedb`".

## Round-trip pitfalls

The features hardest to map onto a double-entry engine whose splits are (value, quantity) pairs:

1. **Unbalanced virtual postings `(Account)`** — legal postings that violate the zero-sum invariant; a strict engine must quarantine them (separate "virtual" balance domain) or refuse, and must re-emit the parens on export.
2. **Balance assignments `= AMOUNT` with empty amount** — the split's quantity is a function of the running balance *at that file position*; importing materializes a number, but faithful export must remember it was an assignment (and file order becomes load-bearing).
3. **Balance assertions** — evaluated in file order, not date order; any importer that re-sorts, merges, or renumbers transactions silently breaks or falsifies them on export.
4. **Automated transactions `= EXPR`** — postings that exist only after parse-time predicate application; storing the *effect* loses the rule, storing the *rule* requires a query-language + value-expression engine to reproduce the effect.
5. **Periodic transactions `~ PERIOD`** — not ledger data at all but report-time templates (budget/forecast); they have no splits to import yet must survive export.
6. **Expression amounts/costs `($10.00 + $20.00)`, `(amount * 2)`, `define` variables** — the parsed value is representable, the expression is not; round-trip loses the formula unless source text is preserved verbatim.
7. **Elided amounts with multiple commodities** — one written posting expands to N splits; re-exporting N explicit splits changes the text (and re-eliding requires proving the inference is unique).
8. **Lot annotations `{price} [date] (note)` / `{=fixated}`** — commodity identity includes the annotation (10 AAPL {$50.00} ≠ 10 AAPL), so a (commodity, quantity) pair is insufficient: the engine needs per-split lot metadata, plus the `{=p} @ c` case where Ledger *synthesizes* an Equity:Capital Losses split nobody wrote.
9. **Commodity display-style learning** — rendering any amount identically requires global state accumulated across the whole journal (prefix/suffix, thousands, decimal-comma — `10,5` can flip a commodity's style mid-file), so export formatting depends on import order.
10. **Posting-level date/payee overrides (`; [=DATE]`, `; Payee:`)** — per-split effective dates and payees diverge from the transaction header; engines with transaction-level date/payee must carry split-level metadata and reconstruct the bracket/tag syntax on export.
