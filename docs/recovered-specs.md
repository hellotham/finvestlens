# Recovered specifications — requirements stated but never written down

*Assembled 10 Aug 2026 by reading all 740 of the user's own turns across the six
session transcripts for this project, and cataloguing every durable requirement
found in them.*

## Why this file exists

The user's diagnosis, in their words: *"We have been bitten MANY MANY times by
me articulating a requirement, and you didn't document it in PRD."*

The evidence is conclusive. `FR-AI-08` told implementers to **copy** attachments
into the document folder. What the user had actually said, sessions earlier, was:

> "store a link to the file in the transaction. The way it works in GnuCash is
> that it's a relative link to a folder that can be specified in settings."

The PRD recorded the opposite of the instruction, the code followed the PRD, and
one ingest duplicated 189 receipts onto a NAS and pointed every link at the
duplicate. Nobody was lying; the requirement simply never reached the document
that the next session would read.

This file is the recovered backlog. It is **not** a specification in itself —
`prd.md` remains the requirements spine. Each item here is either (a) already
promoted into the PRD, (b) confirmed implemented, or (c) an open gap awaiting
review. The point is that nothing stays only in a transcript.

Recovery method, so it can be repeated: extract the user's own turns from
`~/.claude/projects/…/*.jsonl`, excluding tool results and hook output, and
catalogue them. 740 turns reduced to ~320 KB of text — a tractable read.

---

## 1. Contradicted the implementation (highest value)

These were stated, then built the other way.

| Recovered requirement | The user's words | Status |
|---|---|---|
| Attachments are **linked**, never copied; relative to a folder set in Settings | *"store a link to the file in the transaction… a relative link to a folder that can be specified in settings"* | **Fixed 10 Aug 2026.** `FR-AI-08` rewritten; every batch path now calls `linkDocument`. |
| A **secondary** document folder, searched when the primary misses | *"add a secondary Document folder so that if attachment links are not found in the primary folder, they are searched in the secondary folder"* | Implemented, but `linkDocument` only relativised against the *primary* until 10 Aug 2026 — anything filed in the second folder got an absolute home path. Fixed. |
| Column widths are **dynamic**, resizing with the window | *"the column widths should be dynamic - resizes when user resizes window"* | Was **not** implemented — seven hardcoded point widths. Fixed 10 Aug 2026; `FR-REG-03` corrected. |
| Give Description the space; squeeze the rest to the minimum that does not truncate | *"be intelligent about column widths. Try and allocate as much space to Description as possible, which means the other columns should be squeezed to min possible (without truncating values)"* | Was **not** implemented. Fixed 10 Aug 2026 (`measureNaturalWidths`). |
| Fully responsive — narrowing must not hide or truncate a column | *"narrowing the width causes entire columns such as Balances to be hidden or truncated. You really need to make this fully responsive."* | Partially: columns can now be hidden deliberately, and widths adapt. **Open** — no explicit narrow-window strategy. |

## 2. Open gaps — stated, never built, not in the PRD

### Dates — **closed 10 Aug 2026**

The user specified a three-part date system. All three parts now exist, and the
requirement is written down as **`FR-PLT-07`** (with `FR-REG-13` reduced to the
register's application of it) so it cannot be lost again.

> "Add date format in Settings. D/M/Y - Australian Date format. M.D.Y - US Date
> format. Y-M-D - Japanese Date format."  ✅ built

> "Include long and short versions of above, including versions that spell out
> the month and include weekday"  ✅ — four forms, each in all three orders:
> `full` / `long` / `short` / `compact`
> ([DateDisplay.swift](../Packages/FeatureUI/Sources/FinvestLensUI/DateDisplay.swift)).

> **"The user only picks the date format - the app intelligently uses
> short/long/full depending on context and available space"**  ✅ built.
> `AppDateFormat.Form` is the ladder, richest first; `fitting(_:width:ceiling:measure:)`
> picks the richest form that fits a measured width and
> `fittingForm(for:width:ceiling:measure:)` does it for a whole column at once.
> **Context is a ceiling** — `Form.table` (= `short`) is the one named decision
> shared by the AppKit register sheet and every SwiftUI `AdaptiveDate`, so a
> dense table never spells a month out however wide the window. Space chooses
> downward from there; when nothing fits, the tersest *whole* date is shown
> rather than a truncation.

> "Find all places that display dates and adhere to date format" ✅ audited.
> Only two renderings bypass `AppDateFormat`, and both are correct: a
> `yyyy-MM-dd` **parser** for search queries
> ([AppModel+Editing.swift:1198](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Editing.swift))
> and an ISO 8601 **audit-log timestamp**
> ([AppModel+Audit.swift:35](../Packages/FeatureUI/Sources/FinvestLensUI/AppModel+Audit.swift)).
> Seven date cells sat in boxes of `96 * appFontScale` while their text was
> sized by `appFontScale` **×** Dynamic Type — the two do not track each other,
> so those dates truncated at accessibility text sizes. They now use
> `AdaptiveDate`: Reconcile, Reports, Intelligence (×2), Import (×2), and the
> user-resizable Date column of the search results table.

**A live data-corruption bug fell out of the audit.** `parseAny` tried
`d/M/yyyy` first and fell back to `d/M/yy` — but `DateFormatter` is lenient
about year width, so `16/12/25` parsed as **16 December 0025** and reported
success, and the fallback never ran. Two-digit years became *reachable* the
moment the narrow register started displaying them earlier the same day: click
that date cell, press Return, and the transaction moves two thousand years.
`parseAny` now decides by round trip — the pattern that reproduces the typed
text is the pattern it was typed in — and the two editors that called
`parseShort` directly ([RegisterTable.swift:541](../Packages/FeatureUI/Sources/FinvestLensUI/RegisterTable.swift),
[Views.swift:2754](../Packages/FeatureUI/Sources/FinvestLensUI/Views.swift)) were
routed through it.

### Register

| Requirement | Words | Status |
|---|---|---|
| Reconcile column as a **symbol**, not a letter | *"Consider showing the Reconciliation column as a symbol/icon/emoji rather than letter"* | **Done** — `ReconcileSymbols` draws SF Symbols with a knockout layer ([RegisterSheet.swift:604](../Packages/FeatureUI/Sources/FinvestLensUI/RegisterSheet.swift)). Verified 10 Aug 2026; this row said "still shows R" long after it stopped being true. |
| Amount and Balance **right-justified** | *"Amount and Balance columns should be right justified"* | **Done** — `column.trailing ? .right : .left` in the cell paragraph style. |
| **Esc deselects** the selected transaction | *"how to unselect a transaction. Esc does not work."* | **Done** — keyCode 53 on macOS, `.onExitCommand` on iOS. |
| Narrow windows may **wrap onto multiple lines** | *"Consider smart strategies on narrow windows - perhaps use multiple lines"* | Open — never built. |
| Minimise **layout shift** when switching views | *"there is still a lot of layout shift when changing views - very annoying"* | Open — never re-verified after the register rewrite. |
| Notes and memo shown in every view **except Basic** | *"you are not showing the notes and the memo associated with the splits even in general ledger view"* | Believed done via disclosure; unverified. |

### Elsewhere

- **All text copyable.** *"text are generally not able to be copied to clipboard… I thought you were going to make all text copyable."* Raised **three times**. Mostly done and one surface missed: `.textSelection(.enabled)` is applied app-wide in `AppearanceModifier`, so every SwiftUI label is selectable — but the register draws itself with Core Text, which that modifier cannot reach, and the register is the surface people actually want to copy from. **⌘C now copies the selected rows as tab-separated text** in the columns currently on screen, in their displayed order (`SheetView.copy(_:)`). Plain ⌘C was free because Copy *Transaction* is ⇧⌘C.
- **Searchable account picker everywhere**, not just the transaction editor.
- **Dashboard performance card**: a *line* chart starting at 0%, one line per holding, portfolio in bold, hover tooltip at any point. **Done** — per-holding `LineMark` with the portfolio in bold and a hover tooltip (DashboardView.swift:790).
- **FX fully automatic**: *"foreign amount auto populated, rate auto calculated, local amount auto filled so the user does not need to do anything."*

## 3. Process rules recovered (several already in CLAUDE.md)

- *"i am hoping you write these out as files for rather reference and review.
  Don't just hold it in memory."* — the instruction this file discharges.
- *"Do not launch chips - launch subagents in this session - you cannot afford
  to lose context."*
- *"@docs/architecture.md and @docs/prd.md are intent documents, they should not
  specify what has or has not been implemented."* — was violated by 16 status
  ticks; corrected 10 Aug 2026.
- *"always use Gnucash source code as reference when implementing."*
- *"absent features must be implemented too. No gaps."*
- One superseded rule, recorded so it is not re-applied: an early session asked
  for a `Co-Authored-By` model trailer on commits. The user later reversed it —
  *"you can remove model attribution (Fable vs Opus etc)"* — and CLAUDE.md now
  forbids it. The later instruction wins.

---

## What to do with this

Sections 1 and 3 are settled. **Section 2 is the review list**: each item was
asked for, none is in the PRD, and each needs a decision — promote it to a
numbered requirement and build it, or record it in `deferred.md` with a reason.
Leaving them here is the one option that reproduces the original failure.
