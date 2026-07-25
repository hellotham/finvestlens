# `finlens` — the FinvestLens command-line reporter

> The manual page for the `finlens` binary built by `Packages/CLI`.
> Design: [ledger-design.md](ledger-design.md). Ledger's own surface, which
> this follows: [ledger-cli-reference.md](ledger-cli-reference.md).

## Name

`finlens` — read-only ledger-style reporting over FinvestLens books, Ledger
journals, and GnuCash files.

## Synopsis

```
finlens [OPTIONS] COMMAND [QUERY...]
finlens -f Book.finvestlens                # no command: interactive REPL
```

Options may appear **anywhere** — before the command, after it, or interleaved
with query terms. Any argv token starting with `-` is an option; everything
else after the command is a query term. This is ledger's rule, and the reason
the parser is hand-rolled (ADR-L1).

## Building and installing

```bash
swift build -c release --package-path Packages/CLI
```

The binary lands in `Packages/CLI/.build/release/finlens`; copy it onto your
`PATH` (`/usr/local/bin` is the usual place).

## Sources

`-f, --file FILE` names a source. Repeatable for journals — several journals
merge into one book. Recognised by extension, then by content sniff:

| Source | Extensions | Notes |
| --- | --- | --- |
| FinvestLens book | `.finvestlens` | Opened **read-only**: no lock is taken, no working copy is made, nothing is ever written (ADR-L2). Only one book at a time. |
| Ledger journal | `.ledger` `.journal` `.dat` `.txt` `-` (stdin) | Full Ledger 3 grammar — see [ledger-format-reference.md](ledger-format-reference.md). |
| GnuCash | `.gnucash` | XML, compressed or plain. |

With no `-f`, `$FINLENS_FILE` is used. With neither, `finlens` exits 1 with
`no source file given`.

Because a book is read without a lock, a read that races the app's save sees
the pre-save file — never a half-written one.

## Commands

| Command | What it prints |
| --- | --- |
| `balance` (`bal`, `b`) | Account balances as an indented tree, 20-column right-justified totals, single-child chains elided, a dashed grand total. |
| `register` (`reg`, `r`) | One line per posting: date, payee, account, amount, running total. |
| `print` | The matching transactions as a Ledger journal (round-trippable). |
| `csv` | One CSV row per posting, every field quoted, in ledger's column order. |
| `accounts` / `payees` / `commodities` | Sorted names; `--count` prints tallies. |
| `prices` / `pricedb` | Price history; `--latest` keeps only the newest per commodity. |
| `stats` (`stat`) | A summary of the matched postings: spans, counts, uniques. |
| `equity` | The balances restated as one opening-balances transaction. |
| `cleared` | Outstanding vs cleared balances, with the last cleared date. |
| `budget` | Actual vs budgeted, remaining, and percent used — see [Budget](#budget-and-forecast). |
| `xact` | A draft transaction modelled on a past one — see [xact](#xact). |
| `source` | Parse-check the sources and exit 0/1. A lint command. |

Exit status is **0** on success and **1** on any error. Warnings go to stderr
and never change the status.

## Query

Bare terms are account regexes, **ORed** together — `finlens bal Food Transport`
shows both. Beyond that:

```
and / or / not          with parentheses
payee REGEX  @REGEX     the transaction description
tag REGEX    %REGEX     a tag; `tag KEY=VALUE` matches a valued tag
code REGEX   #REGEX     the transaction code/number
note REGEX   =REGEX     the memo, falling back to the transaction note
```

Trailing `for PERIOD`, `since DATE`, `until DATE` and `show TERMS` sections are
honoured, as in ledger.

## Dates and periods

```
-b, --begin DATE      on or after DATE
-e, --end DATE        before DATE — EXCLUSIVE, as in ledger
-p, --period EXPR     "monthly", "last month", "from 2026/01 to may", …
-D -W -M --quarterly -Y     interval shortcuts
--now DATE            treat DATE as today (for valuation and smart dates)
```

A period expression is `[INTERVAL] [from|since SPEC] [to|until SPEC]`, or a
bare span like `2026` or `last quarter`. `to`/`until SPEC` uses the **start**
of the named span, matching `-e`.

## Filters and valuation

```
-C --cleared   -U --uncleared   --pending   -R --real   -r --related
-V --market    -X CODE (or A:B)   -B --basis   -H --historical
```

`--related` reports the *other* postings of the matched transactions.

## Display

```
--flat  --depth N  -E --empty  --no-total  -% --percent  -n --collapse
-s --subtotal  -A --average  -S KEY[,KEY]  --head N  --tail N
--columns N  -w --wide
--date-width / --payee-width / --account-width / --amount-width N
-y --date-format FMT    -o --output FILE    --color / --no-color
```

`--depth N` folds by **account path components**: `--depth 1` reports
`Expenses`, not `Expenses:Food`. `-S` takes `date`, `amount`, `abs(amount)`,
`payee`, `account`, each optionally prefixed `-` to reverse.

Running totals are computed over the whole filtered set before `--head`,
`--tail`, `-S` and `-d` reshape it — so a hidden or reordered row still
contributes exactly once.

## Value expressions

```
-l, --limit EXPR      keep only postings where EXPR holds (affects totals)
-d, --display EXPR    show only rows where EXPR holds (totals unchanged)
```

That distinction is the whole point of having both: `-l` removes a posting from
the calculation, `-d` removes it only from the view.

**Vocabulary** — `amount`, `total` (the running total at that posting), `date`,
`account`, `payee`, `note`, `code`, `cleared`, `pending`, `real`, `depth`
(account path components), and `abs(EXPR)`.

**Literals** — `123.45`, `"text"`, `/regex/`, `[2026/07/01]` or `[last month]`.

**Operators** — `== != < <= > >=`, `=~` and `!~` for regex match, `+ - * /`,
`and`/`&`, `or`/`|`, `not`/`!`, and parentheses.

```bash
finlens -f book.finvestlens reg Expenses -l 'amount > 500'
```

```bash
finlens -f book.finvestlens reg Expenses -d 'amount > 500 and payee =~ /Coles/'
```

An unknown name or a syntax error exits 1 with the parser's message — a typo
never silently matches nothing.

## Budget and forecast

A Ledger journal's `~ PERIOD` entries are budget templates. A `.finvestlens`
book has none, so its own Budgets collection is offered in the same shape:
one monthly template built from the budget lines.

```
--budget          balance/register: only accounts a template covers
--unbudgeted      only the accounts none covers (that have actuals)
--add-budget      budget: add those unbudgeted accounts to the table
--forecast EXPR   project the templates forward while EXPR holds
--forecast-years N  hard stop for the projection (default 5)
```

The `budget` command prints four columns — actual, budgeted, remaining, and
percent used — over the reporting window, for the budgeted accounts:

```
       Actual      Budgeted     Remaining  Used  Account
------------- ------------- ------------- -----
 1,023.45 AUD  1,000.00 AUD    -23.45 AUD  102%  Expenses:Food
   140.00 AUD    240.00 AUD    100.00 AUD   58%  Expenses:Transport
```

`--forecast` generates postings from the templates **after the last real
posting** — the bucket the last real posting falls in is already history — and
keeps generating while the predicate holds:

```bash
finlens -f budget.ledger --forecast 'date < [2027/01/01]' reg Expenses:Food
```

Forecast rows are reported alongside the real ones and are never added to the
book: the CLI does not write, and the REPL reuses one loaded book.

## xact

```
finlens xact [DATE] PAYEE [ACCOUNT-REGEX] AMOUNT …
```

Finds the most recent transaction whose description matches `PAYEE` and prints
a draft modelled on it, dated `DATE` (today if omitted). Bare amounts fill the
non-funding legs in order; an amount preceded by an account regex replaces that
leg specifically. The funding leg is left with no amount, so the draft always
balances.

```bash
finlens -f book.finvestlens xact 2026/08/01 Coles 99.95
```

The draft is printed, never saved — paste it into a journal, or type it into
the app.

## Interactive mode

With no command, `finlens` reads the sources once and prompts:

```
finlens> bal Expenses
finlens> push --monthly
finlens> reg Expenses:Food
finlens> pop
finlens> reload
finlens> quit
```

`push [OPTIONS]` layers option settings onto later reports, `pop` removes the
top layer, `reload` re-reads the sources, `help` prints the option summary.

## Defaults: the init file and the environment

Precedence, weakest to strongest: **init file → environment → command line**.
A flag typed at the prompt always wins.

The init file is `--init-file PATH`, else `$FINLENS_INIT_FILE`, else
`./.finlensrc`, else `~/.finlensrc`. It holds one option per line; the leading
`--` is optional, `;` and `#` start comments, and a quoted value is kept whole:

```
; ~/.finlensrc
file /Users/me/Ledger/book.finvestlens
--wide
depth 2
--period "this year"
```

`FINLENS_*` variables map to options name-for-name, with `_` for `-`:
`FINLENS_DEPTH=3` is `--depth 3`, `FINLENS_WIDE=true` is `--wide`,
`FINLENS_DATE_FORMAT=%Y-%m-%d` is `--date-format %Y-%m-%d`. `FINLENS_FILE`
names the source; `FINLENS_INIT_FILE` names the init file.

`--no-init-file` ignores both. An unreadable or stale rc file warns on stderr
and is otherwise ignored — it can never lock you out.

## Not implemented

`select`, `convert`, and format strings (`-F`/`--format`). See
[ledger-design.md](ledger-design.md) §5.4 for why, and what the core-80 subset
covers instead.

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | The command ran. Warnings may have been printed to stderr. |
| 1 | Any error: unreadable source, journal errors, bad option, bad expression, unknown command. |
