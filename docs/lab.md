# finlab — headless book maintenance

`finlab` is the **write** side of FinvestLens on the command line. It imports a
GnuCash file into a book, refreshes prices, ingests folders of receipts and
statements, and times the open/save path against whatever volume the book
lives on.

It is a separate binary from [`finlens`](cli.md) on purpose. `finlens` is
strictly read-only (ADR-L2) and that promise is worth keeping: a tool you can
point at a book knowing it cannot write is a different kind of tool from one
that rewrites it. So `finlens` gained no new commands; everything here is new.

```bash
swift build -c release --package-path Packages/Lab
./Packages/Lab/.build/release/finlab help
```

## Why it depends on FeatureUI

Surprising for a command-line tool, and deliberate.

Attachment matching, smart categorisation and quote fetching all live on
`AppModel`, which despite its home in `FinvestLensUI` imports no SwiftUI — it
is an `@Observable` model class the views sit on top of, already driven
headlessly by that package's own test suites. Reaching for it means a
maintenance run exercises *the code the app runs*. The alternative — a second
implementation of the matcher inside the CLI — would be a copy free to drift
from the one users actually get, which for a tool whose purpose is validating
matching quality would defeat the point.

So the app target and `finlab` are two thin shells over one model.

## Commands

### `import` — GnuCash XML → `.finvestlens`

```bash
finlab import --from Book.gnucash --to Book.finvestlens [--force] [--break-lock]
              [--mode document|direct]
```

Prints the phase split: XML parse, then write. `--mode document` (the default)
is exactly what the app does — lock, local working copy, coordinated atomic
write-back. `--mode direct` points SQLite at the destination and writes there;
on a network share that is what ADR-8 forbids, and running it is how you find
out what the safety costs.

An existing destination is never overwritten silently: without `--force` the
command refuses, and with it the old book is **moved aside** under a dated name
rather than deleted, and its stale sibling `.lock` is removed.

### `bench` — where open and save time goes

```bash
finlab bench --file Book.finvestlens [--save] [--repeat N]
```

Splits an open into copy / SQLite open / materialise, and measures the
whole-book write. `--save` additionally does a real read-write open and save
against the file in place, which is the number a person feels when they press
⌘S on a book that lives on a NAS. Reports whether the volume is local or a
share — read from the filesystem, not guessed from the path.

### `prices` — refresh every security

```bash
finlab prices --file Book.finvestlens [--provider yahoo|stooq|…] [--dry-run]
```

Goes through `AppModel.updatePriceHistory`, the same call ⌘⇧U makes. Yahoo (the
default) and Stooq need no API key; keyed providers read
`FINLAB_<PROVIDER>_KEY` from the environment. It deliberately never touches the
Keychain — the app's keys carry an ACL naming the app binary, and a differently
signed tool asking for them raises exactly the prompt a headless run cannot
answer.

Failures are per-security and reported, not thrown: a book full of super-fund
units, corporate-bond ISINs and delisted tickers will report a long 404 list,
and that is the correct outcome rather than a fault.

### `documents` — ingest receipts and statements

```bash
finlab documents --file Book.finvestlens --root ~/Documents/Receipts \
                 [--since 2026-01-01] [--until 2026-04-30] \
                 [--kind any|invoice|dividend] [--limit N] [--batch N] \
                 [--attachments DIR] [--apply] [--report out.csv]
```

Each document is OCR'd, its amount and date read, and the book searched for an
unlinked transaction with a money leg of that amount near that date — then the
file is attached and the transaction categorised. Without `--apply` nothing is
written and the run is a survey.

Three things it does that the app's Match Attachments sheet does not need to:

- **Deduplicates by content hash.** Receipt folders accumulate byte-identical
  copies; matching both copies of one purchase would claim two transactions,
  and the second is necessarily wrong.
- **Skips documents already attached** before paying for OCR, so improving the
  matcher and running the folder again costs only what is left to place.
- **Applies and saves per batch.** `matchAttachments` stops two files in one
  call claiming one transaction, but across calls its only defence is the set
  of transactions that already carry a link — which is true only once the
  previous batch has been applied.

Attachments are copied beside the book unless `--attachments` names a folder.
Leaving it unset is usually right: the stored link is a bare filename resolved
against the book's own folder, so the app finds them with no configuration.

## Dating a document

Modification time lies, and the failure is not random. In a real statement
tree, most genuine January–April documents carried May–July mtimes (bulk
downloaded later), while a pile of 2024–2025 statements carried January 2026
mtimes (bulk downloaded then). Sorting on mtime gets both halves wrong.

Names are written by whoever issued the document, so the rules run
most-semantic first:

| Order | Rule | Example |
| --- | --- | --- |
| 1 | Leading `YYYY-MM-DD` | `2026-01-02 Hardware Store.png` |
| 2 | `period end <D Month YYYY>` | `…period end 31 january 2026 eft-…-2026-05-01_17-25-58.pdf` |
| 3 | `_YYYY_MM_DD` | `CBA_Dividend_Advice_2026_03_30.pdf` |
| 4 | Compact `YYYYMMDD` | `Statements20260111.pdf` |
| 5 | Spelled date | `17 Mar 2026 Dist payt.pdf` |
| 6 | Any ISO date | usually a download stamp — hence last of the name rules |
| 7 | Enclosing folder `YYYY-MM` | `2026-01 VISA/` |
| 8 | Modification time | last resort |

Rules 2 and 6 are the interesting pair: a registry writes both the period it is
paying for *and* the moment the PDF was generated into one filename, and on a
January statement downloaded in May those are four months apart. Reading the
wrong one pulled nineteen 2024–2025 statements into a 2026 period in testing.
Rule 4 excludes scanner output (`img20260207_20452286.png`) for the same
reason — that is when it went on the glass, not when the purchase happened.

## What it does not do

No command creates transactions. `documents` links and categorises what is
already in the book; a receipt with no matching transaction is reported, never
invented. Adding the missing transaction is a decision for a person.
