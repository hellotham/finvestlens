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

### `repair` — corrections for data this tool got wrong

```bash
finlab repair --file Book.finvestlens [--apply]
```

One repair so far: **posting days**. A transaction entered from a receipt took
its date from the filename, which is midnight *local*; the book stores a
posting day as midnight UTC (`GnuCashDate` writes `00:00:00 +0000`), so those
rows sat a day early to anything reading in UTC and would have exported to
GnuCash on the wrong day.

It moves only rows whose calendar day read in UTC *disagrees* with the day read
locally. That distinction is the whole safety of it: an earlier version asked
merely "is the time midnight?" and selected 759 transactions on a real book
instead of the 4 that were wrong, because GnuCash stores plenty of dates at
10:59 UTC — late evening here, and the same day either way. Nothing is written
without `--apply`, and the dry run lists every row it would touch.

### `relink` — point document links back at the filed originals

```bash
finlab relink --file Book.finvestlens --primary DIR [--secondary DIR] \
              [--apply] [--prune]
```

The second repair, and like the first it exists because this tool got it wrong.
`documents` attached matches with `attachDocument(named:data:to:)`, whose
contract is to **copy** the file into the document folder — and that folder
defaults to the folder holding the book. One ingest of the real book therefore
duplicated 189 receipts onto the NAS beside it and pointed every link at the
duplicate rather than at the file the user had filed. Attachments are supposed
to be *links*: the book records where a document is, not a second copy of it.

`relink` rewrites every link to its original's path **relative to whichever
configured root contains it** — `--primary`, else `--secondary` — so nothing
embeds a home directory or a cloud-provider path that differs on the next
machine. Names index the archive; the SHA-256 decides, so a copy is only ever
matched to an original it is byte-identical to.

`--prune` then deletes the copies beside the book, but only after every link in
the book has been re-resolved successfully, and only for a file whose bytes are
confirmed present under a root. The two roots belong in **Settings ▸ Documents**
as the primary and secondary document folders, which is what the app resolves
relative links against.

The source-side fix landed with it: `documents`, the app's Match Attachments
sheet, Attach File…, and the cash-receipt path all now call
`linkDocument(at:to:)`. Only Smart Import still copies, because pasted or
scanned bytes have no original to point at.

### `documents` — ingest receipts and statements

```bash
finlab documents --file Book.finvestlens --root ~/Documents/Receipts \
                 [--since 2026-01-01] [--until 2026-04-30] \
                 [--kind any|invoice|dividend] [--limit N] [--batch N] \
                 [--attachments DIR] [--fx NZD=0.905] \
                 [--cash-account "Assets:Someone:Cash"] [--apply] [--report out.csv]
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

### Receipts bought overseas

A card charged abroad posts in the book's currency, so the receipt says
NZD 72.11 and the transaction says AUD −64.51. Nothing needs configuring for
this: most issuers write the original into the narrative
(`THE SQUARE RESTAURANT CHRISTCHURCH 72.11 NZD 2.18 AUD`), the matcher indexes
it, and the receipt's own figure matches exactly.

`--fx NZD=0.905,MYR=0.34` is the fallback for issuers that record nothing —
book currency per unit of the foreign one, and only for the run you pass it on,
because a card's rate moves daily and carries the issuer's margin. It is off by
default and stays approximate: a match is reported only when **exactly one**
transaction in the window falls inside the tolerance band, and rate-derived
matches are counted separately in the summary so they can be reviewed.

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

### Receipts paid in cash

A cash receipt is not an unmatched document — there is nothing to match. The
money left a wallet and, unless someone enters it, the purchase never appears
in the book at all.

`--cash-account "Assets:Someone:Cash"` enters those: date and vendor from the
document, the named account credited, the file attached, and the category left
to the ordinary categoriser. It is off unless the account is named, and the
name is never guessed — a receipt records that notes changed hands, not *whose*
notes, and a household with a cash account each produces identical dockets.
That fact is not in the document, so the operator states it once per run.

Only receipts that say cash **and** say nothing about a card qualify. The two
mistakes are not equal: missing a card leaves a receipt unmatched, which costs
nothing, while calling a card purchase cash invents a transaction that will
double-count when the real statement is imported. So card detection reads
broadly and cash narrowly, and anything ambiguous is left alone.

A receipt reported as `[card]` with no matching transaction means the opposite
thing and needs the opposite response: that purchase *did* go through an
account, and the statement carrying it has not been imported.

## What it does not do

It does not invent transactions to make a receipt match. `documents` links and
categorises what is already in the book, and the single exception —
`--cash-account` — creates only what a person has explicitly asked for, only
for receipts that say they were paid in cash, and only into an account they
named. Everything else that fails to match is reported, never guessed at.
