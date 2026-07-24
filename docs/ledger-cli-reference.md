# Ledger 3 CLI Reference (for the FinvestLens ledger-modelled CLI)

> Companion to [ledger-design.md](ledger-design.md). Verified against the
> official Ledger 3 manual source (`doc/ledger3.texi`), man page
> (`doc/ledger.1`), and C++ source (`src/report.cc|.h`, `query.cc`,
> `session.cc`, `global.cc`, `main.cc`) from `ledger/ledger` master
> (July 2026), cross-checked against tag `v3.3.2`. Flags marked **✦** exist
> on master but not in released 3.3.2. This is the spec the `finlens` CLI is
> written against.

## 1. Invocation model

```
ledger [OPTIONS...] COMMAND [ARGS...]
```

- **Options may appear anywhere** — before the command, after it, or interleaved with query terms. Any argv token starting with `-` is consumed by the option processor; everything else after `COMMAND` is a query term (except for `xact`/`convert`, whose args have special meaning).
- **No COMMAND** → interactive REPL: prints version banner, reads the journal once, then accepts one command line per prompt. REPL-only commands: `push [options]` (layer option settings onto subsequent reports), `pop` (remove them), `reload` (re-read journals).
- **Journal selection**: `-f FILE` / `--file FILE` (repeatable; `-` = stdin). If absent → env `LEDGER_FILE` (legacy: `LEDGER`) → `~/.ledger` if it exists → hard error `No journal file was specified (please use -f)` (exit 1).
- **Precommands** run without reading any journal or init file (debug/utility aids): `parse VEXPR` (alias `expr`) — print lexed/compiled expression tree and its value against a built-in model transaction; `eval VEXPR` — evaluate expression, print result; `format FORMAT_STRING` — explain a format string and render it against the model transaction; `period PERIODEXPR` — print period tokens, stabilized range, start/finish, sample dates; `query` (alias `args`) — show how query arguments translate into a predicate expression; `template` — show the `xact` insertion template; `generate` — emit random valid journal data (`--seed INT`); `script FILE`. `source FILE` parses the named journal and exits 0/1 — a lint command.

## 2. Reporting commands

### `balance` (aliases `bal`, `b`)
Per-account balances as an indented tree. Layout: right-justified total in a **20-character column** (balance-specific default; register uses 15.8% of width), two spaces, account name. Children indent 2 spaces per displayed depth. A parent line shows the rolled-up subtotal of its subtree. Multi-commodity balances stack one line per commodity, account name on the last line. **Chain elision**: an intermediate account that has no postings of its own and only a single displayed child is merged with that child as `Parent:Child` on one line (e.g. `Equity:Opening Balances`, and `Food:Groceries` shown as one child of `Expenses`). After all accounts, a separator of exactly 20 dashes, then the grand total (sum of top-level displayed lines; prints `0` when balanced). Query terms both filter and re-root what's displayed.

Options: `--flat` (full account names, no tree, only accounts with own activity, no elision), `--depth INT` (display-only fold of deeper accounts into ancestors), `-E`/`--empty` (include zero-balance accounts), `--no-total` (suppress dashes+grand total), `-%`/`--percent` (subtotals as % of parent; single-commodity only), `-n`/`--collapse` (top-level accounts only), `--collapse-if-zero`, `--collapse-if EXPR` ✦, `--dc` (three columns: debit, credit, net; separator under each), `-S VEXPR` sort (e.g. `-S "-abs(total)"`), `--balance-format FMT`, `--time-report` (timelog columns).

```
$ ledger -f drewr3.dat bal Assets Liabilities
          $ 1,396.00  Assets:Checking
             $ 30.00    Business
            $ -63.60  Liabilities
            $ -20.00    MasterCard
--------------------
          $ 1,332.40
```

### `register` (aliases `reg`, `r`)
One line per posting, chronological (journal) order, with running total. Columns: **date, payee, account, amount, running total**. Date uses the "printed" format `%y-%b-%d` (e.g. `10-Dec-01`); print/csv/xml use the "written" format `%Y/%m/%d`. Default widths at `--columns` total (TTY width, else `COLUMNS` env, else 80): payee ≈ 26.3%, account ≈ 30.2%, amount ≈ 15.8%, total = amount width; account/payee auto-shrink to fit; account names abbreviated (`Expense:Food:Groceries`, `..` truncation) to fit, controlled by `--truncate leading|middle|trailing` (default: smart per-component "abbreviate") and `--abbrev-len INT`. **Multi-posting transactions**: first posting carries date+payee; the transaction's remaining postings follow on lines with those columns blank. Final total = last line's running-total cell (no separator line).

Options: `-r`/`--related` (show the *other side* postings of matched transactions), `--related-all` (all postings of matched transactions), `-s`/`--subtotal` (collapse everything to one subtotaled entry; date=first date, payee shows `- <last-date>`), `-n`/`--collapse` (one line per transaction, posting to `<Total>`), periodic grouping `-D/--daily`, `-W/--weekly`, `-M/--monthly`, `--quarterly`, `-Y/--yearly`, `-p PERIOD` (period rows show start date + `- <end-date>` in the payee column, one line per account per period), `--dow`/`--days-of-week`, `-P`/`--by-payee`, `--group-by EXPR` + `--group-title-format FMT` + `--no-titles`, `--no-group-by` ✦, `-A`/`--average` (running average instead of running total), `--deviation` (per-posting deviation from average), `-c`/`--current` (≡ `--limit "date <= today"`), `--head INT`/`--first INT` and `--tail INT`/`--last INT` (whole transactions; negative inverts meaning; combinable), width overrides `--date-width`, `--payee-width`, `--account-width`, `--amount-width`, `--total-width`, `--columns INT`, `-w`/`--wide` (=132), `--meta TAG` + `--meta-width INT` (prepend metadata column), `-j`/`--amount-data` and `-J`/`--total-data` (plot output: `date value` pairs only), `--dc` (debit/credit/total columns), `--invert`, `--register-format FMT`.

```
$ ledger -f drewr3.dat reg Groceries
10-Dec-20 Organic Co-op         Expense:Food:Groceries      $ 37.50      $ 37.50
11-Jan-02 Grocery Store         Expense:Food:Groceries      $ 65.00     $ 102.50
```

### `print`
Full matching transactions, re-emitted in canonical, re-parseable journal syntax: dates normalized to `%Y/%m/%d` (aux date as `=DATE`), state flags/code/payee on the first line, postings indented four spaces, amounts aligned into a column, notes/metadata preserved, amounts in "the most economic form possible". Useful for cleanup and extraction; output order is journal order unless sorted. `--raw`: emit the exact original source text of each matched transaction, no massaging.

```
$ ledger print groceries
2011/01/02 Grocery Store
    Expenses:Food:Groceries              $ 65.00
    Assets:Checking
```

### `csv`
One CSV line per matching posting, every field double-quoted. Default column order: **date, code, payee, display_account, commodity, quantity, state, note** — state is `*` cleared, `!` pending, empty otherwise. Override with `--csv-format FMT` (full format-string language; `quoted()` helper).

### `accounts`, `payees`, `commodities`, `tags`
Sorted unique-name lists drawn from matching postings. All accept `--count` (append usage counts). `payees` filtering requires the payee prefix: `ledger payees @Nic`. `tags` also accepts `--values` (list each tag's values).

### `prices`, `pricedb`, `pricemap`
`prices` — price history for matching commodities, day granularity; default line `DATE COMMODITY PRICE`. With `-A`/`--average` show running average; `--deviation` per-price deviation; `--latest` only the most recent price per commodity. `pricedb` — same data as `P DATETIME COMMODITY PRICE` directive lines (second granularity), re-parseable; `--latest` works; `--both-directions` ✦ also emits computed inverses. `pricemap` — Graphviz "dot" graph of commodity price relationships.

### `stats` (alias `stat`) — exists
Summary of matching postings: time range, unique accounts, unique payees, total postings, uncleared postings, days since last posting, posts in last 7 / last 30 days, posts this month.

### `xact` (aliases `entry` [2.x compat], `draft`)
Draft-transaction generator: `ledger xact 2004/4/9 viva food 11 tips 2.50`. Finds the most recent prior transaction whose payee matches the regex (`viva`), then substitutes accounts/amounts by matching the remaining args (account regex/amount pairs; a bare trailing account regex sets the funding account). Prints the new transaction to stdout (doesn't write the journal). If no match can be generated: error, **exit code 1**.

### `equity`
Prints current account balances as one transaction (payee `Opening Balances`), one posting per account, balanced into `Equity:Opening Balances` — for closing books / starting new files. (Related `--equity` option renders the equity output in register form.)

### `cleared`
Balance-style tree with **three columns: outstanding (total) balance [16 wide], cleared balance [18 wide], date of most recent cleared posting [9]**, then the account tree. Separator line: `----------------  ------------------    ---------`, then column totals. Misformats for multi-commodity accounts. `--cleared-format FMT` overrides.

```
      $ 1,396.00            $ 775.00    10-Dec-20      Checking
```

### `budget` (command)
Balance-style report with four columns: **actual spent, budgeted amount, remaining (actual+budget), percent of budget spent** (>100% = over budget). Requires periodic transactions. Separator: `------------ ------------ ------------ -----`. `--budget-format FMT`.

### `select` — exists
SQL-ish queries: `ledger select date,amount from posts where account=~/Income/`. Columns from the expression vocabulary; `where` clause is a value expression.

### `convert` (CSV import)
`ledger convert FILE.csv` parses a CSV whose **first line names the fields**: recognized (case-insensitive) `date`, `posted`, `code`, `payee`/`desc`/`description`, `amount`/`credit`, `debit`, `cost`, `total`, `note`; blank names skip columns; unrecognized names become posting metadata tags. Single signed amount column supported (use `credit` alone). Emits ledger transactions against `Expenses:Unknown` unless: `--account STR` (balancing account), `--auto-match` (guess the other account from the existing journal), `--invert` (flip sign), `--rich-data`/`--detail` (adds `CSV`, `Imported`, `UUID` metadata; postings whose `UUID` already exists in the `-f` journal are skipped — idempotent re-import), `--input-date-format "%m/%d/%Y"`. `payee`/`alias` and account `payee` directives can rewrite payees/assign accounts during conversion.

### `lisp` (alias `emacs`), `xml`
`lisp`: Emacs sexp per transaction `((BEG-POS CLEARED DATE CODE PAYEE (ACCOUNT AMOUNT)...) ...)`; `--lisp-date-format seconds|epoch|STRFTIME` ✦. `xml`: `<ledger><xact>` document with `en:date` (`YYYY/MM/DD`), `en:cleared`/`en:pending`, `en:code`, `en:payee`, `en:postings`/`<posting>` with `tr:account`, `tr:amount` (typed values: boolean/integer/amount/balance; commodity display flags `P` prefixed, `S` space-separated, `T` thousands, `E` European).

There is **no `org` command** (the manual's Org-mode chapter covers Emacs Babel integration only). Developer commands: `echo`, `reload`, `source`.

## 3. Query language

Grammar (from `query.cc`): `query = or_expr { section or_expr }` with **implicit OR between adjacent top-level terms**; `and`/`&` binds tighter than `or`/`|`; `not`/`!` negates the following term; `( ... )` groups (escape parens from the shell). Precedence low→high: `or`, `and`, `not`, atom.

- Bare term → PCRE regex on the **full account name**: `ledger bal asset liab` = assets OR liabilities.
- `payee REGEX` (alias `desc`), shorthand `@REGEX` → match payee.
- `code REGEX`, shorthand `#REGEX` → match transaction code.
- `note REGEX`, shorthand `=REGEX` → match note text.
- `tag REGEX` (aliases `meta`, `data`), shorthand `%REGEX` → `has_tag(/REGEX/)`; `tag NAME=VALUE` → `has_tag(/NAME/, /VALUE/)` (value regex); `tag NAME==VALUE` → `tag(/NAME/) == "VALUE"` (exact).
- `expr 'VEXPR'` → raw value-expression predicate (e.g. `expr 'amount > 100'`). Terms containing `>[`/`<[` comparisons are auto-parsed as expressions.
- Patterns may be quoted `/food/`, `'grocery'`, `"..."`.
- **No `-term` negation** — a leading `-` is always an option; use `not term`.
- **Trailing sections** split off separate predicates: `show TERMS` → display predicate (like `-d`), `only TERMS` → `--only`, `bold TERMS` → `--bold-if`, `for PERIOD-WORDS` / `since DATE` / `until DATE` → report period. Example: `ledger reg food for last month show @Safeway`.
- Examples: `ledger bal Fuel and @Chevron`; `ledger bal Expenses and not (Drinks or Candy)`; equivalently `--limit 'account=~/Fuel/ and payee=~/Chevron/'`.

`-l EXPR`/`--limit EXPR` filters what enters **calculation** (running totals start from the filtered set). `-d EXPR`/`--display EXPR` filters only what is **shown** (totals still include hidden postings), e.g. `-d "date>=[last month]"`. `--only EXPR` is a posting predicate applied after transforms (e.g. after periodic gathering). `-r`/`--related` makes the report show postings *related to* the matches (the other side of each matched transaction; balance shows accounts touched by related postings).

## 4. Date & period options

`-b DATE`/`--begin DATE` (include on/after; running totals start at 0 there), `-e DATE`/`--end DATE` (**exclusive**), `-p`/`--period PERIOD_EXPRESSION`, `--now DATE` (override "today"). Master also accepts datetimes: `2018/12/16@08:12:33`.

**Period expression grammar**: `[INTERVAL] [BEGIN] [END]`
- INTERVAL: `every day|week|month|quarter|year`, `every N days|weeks|months|quarters|years`, `daily`, `weekly`, `biweekly`, `monthly`, `bimonthly`, `quarterly`, `yearly`.
- BEGIN: `from SPEC` | `since SPEC`; END: `to SPEC` | `until SPEC`; or a bare `SPEC` / `in SPEC` meaning that whole span (`oct` = all of October).
- SPEC: `2004`, `2004/10`, `2004/10/1`, `10/1`, month names (`october`, `oct`), `this|next|last day|week|month|quarter|year`.
- Examples: `monthly`, `monthly in 2004`, `weekly from oct`, `from sep to oct`, `from 10/1 to 10/5`, `monthly until 2005`, `monthly from 2005/04/06`, `last oct`, `weekly last august`, `every 2 weeks`.
- Intervals align to natural period starts (week/month/quarter/year); `--align-intervals` ✦ aligns to the expression's begin date instead. `--start-of-week INT|DAY` (1=Monday) sets weekly grouping start; `--period-shift INT` ✦ shifts monthly/quarterly/yearly period starts by N days. `--exact` reports period bounds by first/last actual posting. Period end dates are exclusive instants.

Shortcuts: `-D/--daily`, `-W/--weekly`, `-M/--monthly`, `--quarterly`, `-Y/--yearly` ≡ `--period "daily|weekly|monthly|quarterly|yearly"`.

**Smart dates** (usable in `-b/-e`, `[...]` expression literals, periods): `today`, `tomorrow`, `yesterday`/`yday`, `N days|weeks|months|quarters|years ago|hence`, `this|last|next PERIOD`, partial dates (`2004` = that year, `10/1` = that day in the current year). `-y FMT`/`--date-format FMT` sets report date format (default `%Y/%m/%d` written / `%y-%b-%d` printed); `--input-date-format FMT` for parsing; `--datetime-format FMT`.

## 5. State & flag filters

- `-C`/`--cleared` — only postings of cleared (`*`) transactions; `-U`/`--uncleared` — only uncleared; `--pending` — only pending (`!`).
- `-R`/`--real` — exclude virtual postings (`(...)`/`[...]`); `-L`/`--actual` — exclude postings generated by automated transactions; `--generated` — include generated postings explicitly.
- `--aux-date` (alias `--effective`) — use auxiliary dates (`DATE=AUXDATE`, posting-level `; [=DATE]`) as *the* date for all calculations/reports; `--primary-date` (alias `--actual-dates`) restores primaries. There is **no `--date2`** (that's hledger's spelling for the same concept).

## 6. Valuation options

Default is `-O`/`--quantity` (raw commodity totals). Alternatives:
- `-B`/`--basis`/`--cost` — report cost basis.
- `-V`/`--market` — value at latest known price. Register: value at each posting's date, plus a final `<Revalued>` posting if today's value differs; Balance: value as of today (or `--now DATE`). Target commodity auto-chosen (most common pricing target).
- `-X COMM`/`--exchange COMM` — value in a specific commodity. `"-X A,B"`: values already in a listed commodity stay; others convert to the first possible. `-X A:B` converts only A into B (repeatable: `-X EUR:USD -X BTC:USD`).
- `-H`/`--historical` — value each amount as of the date it was encountered (combine with `-X`, `-B`, `-I`).
- `-I`/`--price` — use the recorded lot price.
- `-G`/`--gain` (alias `--change`) — net gain/loss (market − basis); implies revalued postings. `--gain-since DATE` ✦ re-baselines pre-DATE lots at their DATE market value. `--plopen` ✦ unrealized P/L snapshot without synthetic postings.
- Price sources: `P DATE[TIME] COMMODITY PRICE` directives plus prices implied by `@`/`@@` transaction costs; `--price-db FILE` names the price file (auto-appended by `-Q`/`--download` via the `getquote` script; `--getquote PATH` ✦; `-Z DURATION`/`--price-exp`/`--leeway` freshness, default 24h).
- Valuation is programmable via `VALUE::` metadata / `value` directives (`market(amount, date, exchange)` is the default expression); `--unrealized`, `--unrealized-gains STR`, `--unrealized-losses STR` control gain accounts; `--revalued`/`--no-revalued`/`--revalued-only`/`--revalued-total` control `<Revalued>` postings; `--no-rounding` drops `<Adjustment>` postings.

## 7. Sorting, collapsing, output

- `-S VEXPR`/`--sort` — sort report by expression value; comma-separated keys sort hierarchically (`--sort 'date, amount'`); leading `-` reverses (`--sort '-date'`). Common keys: `date`, `amount`, `total`, `payee`, `account`, `abs(total)`. `--sort-all`; `--sort-xacts`/`--period-sort VEXPR` sorts within transactions/periods only.
- `-n`/`--collapse` (register: one line per multi-posting transaction; balance: top level only); `--depth INT`; `--head/--tail INT`.
- `-o FILE`/`--output FILE`; `--pager PROG` (used only when stdout is a TTY; default via `LEDGER_PAGER`), `--no-pager`, `--force-pager`.
- Color: automatic when stdout is a TTY; `--color`/`--ansi` request it (ignored if not a TTY unless `--force-color`); `--no-color` suppresses.
- `-F FMT`/`--format FMT` sets the current report's format; per-report defaults overridable via `--balance-format`, `--register-format`, `--csv-format`, `--cleared-format`, `--budget-format`, `--prices-format`, `--pricedb-format`, `--plot-amount-format`, `--plot-total-format`, `--group-title-format`, plus `--prepend-format`/`--prepend-width`/`--append-format` ✦. Format-string syntax: `%[-][MIN][.MAX](VALEXPR)` substitutions (right-justified by default, `-` = left), `\n`/`\t` escapes, `%/` separates the format for a transaction's subsequent postings, `%$1…%$N` reuse earlier field expressions. Default balance format justifies `display_total` into 20 columns, prints `depth_spacer` + `partial_account` (tree mode), and ends with the 20-dash total separator; default register format justifies date/payee/account/amount/total per the width options above.
- Misc: `-w`/`--wide` (132 cols), `--columns INT`, `--truncate CODE`, `--abbrev-len INT`, `--flat`, `--no-total`, `-E/--empty`, `-%/--percent`, `--invert`, `--anon` (anonymize for bug reports), `-t EXPR`/`--amount` (transform the amount column), `-T VEXPR`/`--total` (transform the totals column), `--display-amount`/`--display-total`/`--display-account` ✦, `--bold-if VEXPR`, `--pivot TAG` (prefix hierarchy with `TAG:value`), `--pivot-only TAG` ✦ (replace hierarchy), `--dc`, `--date EXPR`, `--account STR` (prepend to all reported accounts), `--master-account STR`, `--base`, `--decimal-comma`, `--decimal-places INT` ✦, `--round`/`--unround`, lot display `--lots`, `--lot-dates`, `--lot-prices`, `--lot-notes`/`--lot-tags`, `--lots-actual`, `--lots-fifo`/`--lots-lifo`, `--average-lot-prices`.

## 8. Budget & forecast

Periodic transactions — `~ PERIODEXPR` header with a posting list — are inert unless activated:
- `--budget`: report only budgeted accounts; register interleaves generated budget postings (negated) with actuals so the running total shows performance vs. budget per period (`ledger --budget -M reg ^expenses`).
- `--add-budget`: actuals **and** budget postings, including unbudgeted accounts.
- `--unbudgeted`: only postings in accounts with no budget. All three work with `balance` too; the `budget` command gives the 4-column comparison table.
- `--forecast VEXPR` (canonical `--forecast-while VEXPR`; no `--projected` alias in Ledger 3): after real postings end, keep generating postings from periodic transactions while the expression holds — against the running total for register (`--forecast 'T>{$-500.00}'`; one extra posting is shown past the limit) or by date for balance (`--forecast 'd<[2010]'`). `--forecast-years INT` caps the horizon.

## 9. Exit codes & error behavior

- **0** success; **1** any error — parse errors (unbalanced transaction, bad amount, unknown include), invalid option/command, failed `xact` generation, `--pedantic` violations, balance-assertion failures. There are no other exit codes (`--help`/`--version` exit with their internal count, effectively 0).
- Warnings go to stderr and do **not** affect exit status: `--strict` (undeclared account/commodity/tag in a *non-cleared* transaction → warning with file:line; cleared transactions are trusted), `check` directive failures.
- `--pedantic` upgrades undeclared-entity warnings to hard errors; `--strict-commodity` / `--pedantic-commodity` ✦ apply only to commodities; `--check-payees` extends strict/pedantic to payees (requires one of them); `--explicit` is accepted but is a **no-op** in current Ledger (historical). `--permissive` quiets balance-assertion failures to warnings. `--check-in-file-order` ✦ evaluates assertions in parse order rather than date order.
- Declared entities come from `account`, `commodity`, `tag`, `payee` directives.

## 10. Environment & config

- **Init file**: first of `$XDG_CONFIG_HOME/ledger/ledgerrc`, `~/.config/ledger/ledgerrc`, `~/.ledgerrc`, `./.ledgerrc` (or `-i FILE`/`--init-file FILE`). Contains one command-line option per line (no postings); e.g. `--price-db ~/finance/.pricedb`. Precedence: **command line > environment > init file**. `--args-only` ignores env and init entirely.
- **Environment**: every long option maps to `LEDGER_` + name uppercased with `-`→`_` (e.g. `LEDGER_DATE_FORMAT="%d.%m.%Y"` ≡ `--date-format`). Well-known: `LEDGER_FILE`, `LEDGER_PRICE_DB`, `LEDGER_PAGER`, `LEDGER_INIT` (legacy: `LEDGER` = file). `COLUMNS` sets default report width.
- Global/session/report option scoping exists internally but is inert for CLI use; `--options` prints effective options with their sources.

## Core-80 subset

Commands: ☐ `balance` (bal/b) ☐ `register` (reg/r) ☐ `print` (+`--raw`) ☐ `accounts` ☐ `payees` ☐ `commodities` ☐ `prices` ☐ `pricedb` ☐ `csv` ☐ `equity` ☐ `cleared` ☐ `stats` ☐ `xact` ☐ `source`
Query: ☐ bare account regex, implicit OR ☐ `and`/`or`/`not` + parens ☐ `@`/`payee` ☐ `%`/`tag` (+`=value`) ☐ `#`/`code` ☐ `=`/`note` ☐ `expr`
Dates/periods: ☐ `-b` ☐ `-e` ☐ `-p` with `[interval] [from|since] [to|until|in]` + smart dates ☐ `-D/-W/-M/--quarterly/-Y` ☐ `--now`
Filters: ☐ `-C` ☐ `-U` ☐ `--pending` ☐ `-R` ☐ `-L` ☐ `-l EXPR` ☐ `-d EXPR` ☐ `-r`
Valuation: ☐ `-O` ☐ `-B` ☐ `-V` ☐ `-X COMM` (incl. `A:B`) ☐ `-H` ☐ `-G` ☐ `--price-db`
Display: ☐ `--flat` ☐ `--depth` ☐ `-E` ☐ `--no-total` ☐ `-%` ☐ `-n` ☐ `-s` ☐ `-S` (with `-key`, comma lists) ☐ `--head/--tail` ☐ `-A` ☐ `-o` ☐ `--pager/--no-pager` ☐ color auto/`--color`/`--no-color` ☐ width flags + `--columns`/`-w` ☐ `-y`
Budget: ☐ `~` periodic txns ☐ `--budget` ☐ `--add-budget` ☐ `--unbudgeted` ☐ `--forecast`
Infra: ☐ `-f`/`LEDGER_FILE`/`~/.ledger` fallback ☐ init-file lookup chain ☐ `LEDGER_*` env mapping ☐ exit 0/1 + warn-vs-error (`--strict`/`--pedantic`) ☐ `--version`/`--help`

## Deliberately hard parts

- **Value expressions**: a full expression language (typed values, `[date]`/`{amount}` literals, ~80 functions/variables, lambdas, scopes) backing `-l/-d/-S/-t/-T/--bold-if` and formats — implement a small typed-AST subset (comparisons, and/or/not, `account/payee/amount/total/date/cleared`, regex match, `[date]` literals) and grow it.
- **Format strings**: `%[-][MIN][.MAX](expr)` plus `%/`, `%$N`, justification/color/scrub semantics — the default reports can be hard-coded first; full user-supplied `-F` is a later layer.
- **`select`**: SQL-ish façade over the expression engine with its own parser — low usage, skip initially.
- **Automated transactions in reports** (`= EXPR` posting generation, amount multipliers, `--forecast`/`--budget` synthesis): a transform pipeline stage that fabricates postings before filtering — the budget/forecast features depend on it.
- **`convert`**: CSV field-mapping DSL, `--auto-match` account inference, UUID dedupe idempotence — self-contained but effectively a small import product of its own.
