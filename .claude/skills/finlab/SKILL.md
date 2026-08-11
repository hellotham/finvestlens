---
name: finlab
description: Drive finlab, the headless write tool — GnuCash import, price refresh, document ingest, relink and repair — including the lock timing and the waiter trap that have each cost real time. User-invoked only; it writes to a real book.
disable-model-invocation: true
---

# finlab — the headless write tool

`finlens` is read-only **by design**; everything headless that writes is
`finlab` (`Packages/Lab`, manual in [docs/lab.md](../../../docs/lab.md)). It is
the only package that depends on `FeatureUI`, deliberately: it drives the real
`AppModel`, so a maintenance run exercises the shipping matcher and
categoriser rather than a copy that can drift.

Verbs: `import`, `bench`, `prices`, `repair`, `relink`, `documents`.

```bash
swift build -c release --package-path Packages/Lab   # → Packages/Lab/.build/release/finlab
```

## It writes to a real book

The working book is real financial data
(see the `standard-test-book` memory for its current location). Changes may be
left permanent — the user is fine with test runs mutating it — but **quit the
app first**: both take the advisory lock, and the app writing over a headless
run's changes is silent data loss, not an error.

## The monthly document ingest, as actually run

```bash
B="$HOME/Library/CloudStorage/Box-Box/finvestlens/Ashley Bears.finvestlens"
./Packages/Lab/.build/release/finlab documents --file "$B" \
  --root ~/Library/CloudStorage/Box-Box/Invoices \
  --since 2026-01-01 --until 2026-04-30 --batch 16 \
  --cash-account "Assets:Chris Tham:Cash" --apply
./Packages/Lab/.build/release/finlab documents --file "$B" \
  --root ~/Library/CloudStorage/Box-Box/Finance --kind dividend --batch 8 --apply
```

Drop `--apply` first: without it the run reports what it *would* do and
changes nothing. Read that before applying.

`--cash-account` is required for cash receipts and is **never inferred** — a
receipt says notes changed hands, not whose, and this book has both
`Assets:Chris Tham:Cash` and `Assets:Lyn Cheah:Cash`.

## Two traps that have each cost real time

- **A run holds the book lock for minutes, and a headless session drives no
  heartbeat.** A leaked lock therefore stays *fresh* for its whole 90-second
  staleness window and refuses the next run outright. `documents` releases it
  in a `defer` now; if a run is killed anyway, wait ~95 s before retrying.
  Never delete a lock whose pid is alive, and never one from another host —
  the `.lock` **syncs by design** (architecture.md:257), so a lock you see may
  belong to a different machine.
- **Do not wait on it with `until ! pgrep -f "finlab documents"`.** The waiter
  shell's own command line contains that string, so it matches itself and
  spins forever. Poll on the output file, or on `pgrep -f 'release/finlab'`.

## Attachments are linked, never copied

`relink` and `documents` store a path **relative** to a configured document
root — primary `finvestlens.documentFolderPath`, secondary
`…PathSecondary` — so links survive the book moving between machines and sync
paths. An earlier build copied instead, which duplicated 189 receipts onto a
NAS and pointed every link at the duplicate. If links stop resolving, check
those two defaults keys before suspecting the book.

## After a run

Report what changed by count, never by amount, and say what was **not** done.
Then hand the app back with `/relaunch` — the user does the looking.
