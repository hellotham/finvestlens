<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Register UX research — toolbar, row controls, columns

**Date:** 9 August 2026.
**Why this exists:** an audit of this repo found competitor/UX research documented
for Microsoft Money ([enhancements-msmoney.md](enhancements-msmoney.md)), Firefly III
([enhancements-firefly.md](enhancements-firefly.md)) and Frollo
([enhancements-frollo.md](enhancements-frollo.md)), plus
[usability-review.md](usability-review.md) — **but nothing on Banktivity, Quicken,
Moneydance or MoneyWiz**. Those were never studied. This document closes that gap for
the register surface and records the decisions it drove, so the next change argues with
evidence instead of taste.

Everything below was read in the session that produced it. Apple HIG pages are
JavaScript-rendered, so they were read through the Browser pane — `WebFetch` on them
returns the page title and nothing else, which is a *silent* empty fetch and has caused
fabricated citations before.

## 1. What Apple's HIG actually requires

| Topic | Guidance | Source |
|---|---|---|
| Toolbar groups | "Minimize the number of groups… in general, aim for a maximum of three" | [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |
| Group separation | "Add separation by inserting fixed space between the buttons" — space, not a drawn rule | Toolbars |
| Menu-bar duty | "Make every toolbar item available as a command in the menu bar" | Toolbars → macOS |
| Row buttons | "Square buttons aren't intended for use in toolbars"; view-scoped buttons live *in the view* | [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) → macOS |
| Disclosure | A triangle "points inward from the leading edge when its content is hidden and down when its content is visible" | [Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls) |
| Hierarchy column | "Expose data hierarchy in the first column only" | [Outline views](https://developer.apple.com/design/human-interface-guidelines/outline-views) |
| Hierarchical data | "Use an outline view instead of a table view to present hierarchical data" | [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) → macOS |
| Editing | "people expect to be able to single-click a cell to edit its contents" | Outline views |
| Column resizing | **"Let people resize columns."** | Lists and tables → macOS |
| Sorting | Click a heading to sort; clicking an already-sorted heading reverses it | Lists and tables, Outline views |
| Search/filter | "Put a search field at the trailing side of the toolbar" | [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) |
| Context menus | "Always make context menu items available in the main interface, too" | [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus) |

Two things the HIG does **not** say, recorded so they are never cited as if it did:

- It never endorses a **chevron** as a macOS row-expansion affordance. The trailing
  chevron is the iOS/iPadOS *disclosure indicator*, which means **navigate into**, not
  **expand in place**.
- It says nothing about revealing per-row controls **on hover**. The only hover-reveal
  guidance concerns chrome that already fades (Safari's minimized toolbar, video
  controls). It does warn that a table row "can't expand without overlapping adjacent
  rows", so row hover effects should tint, not scale.

## 2. What shipping apps do

| App | Toolbar | Row controls | Columns |
|---|---|---|---|
| **Mail** (macOS) | Filter and View Options are both toolbar items, and both duplicate menu-bar commands ("This setting is also available from the View menu") | none documented | Control-click a header to sort |
| **Music** (macOS) | Sort pop-up and Filter field sit at the **top-right of the list**, not in the window toolbar; the search field is window-level with scope buttons to its right | none | Click a heading to sort; View Options chooses columns |
| **Finder** list view | View buttons collapse to a pop-up when the window narrows | none | "drag the line that's between the column headings"; Control-click a header to choose columns; Option-click a triangle expands everything below |
| **Banktivity 9** | Window toolbar holds only Add / Update Everything / Send Payment / Post Scheduled. Register controls (add, filter, reconcile, summary) sit **above the register** | none — Enter opens a transaction editor | Click a heading to sort |
| **Quicken for Mac** | Filter bar on top of the register; a **ten-button toolbar at the bottom** (New, Edit, Split, Delete, Schedule, Paid, Print, Reconcile, Columns, Settings) | **yes** — "the Split button on the register row", "the Edit Details button on the selected row" | Control-click a heading or the Columns button; drag headers to rearrange |
| **GnuCash 5** | Twelve register buttons (Save, Close, Duplicate, Delete, Enter, Cancel, Blank, **Split**, Jump, Schedule, Transfer, Reconcile). Split is "Not highlighted if View → Auto-Split Ledger is enabled" | **none** — every action is a toolbar button acting on "the current transaction" | "resized by left-clicking and dragging the dividers in the header" |

**Corrections to assumptions we held.** Music's filter is *not* beside the search field —
it belongs to the list, while search belongs to the window. And Apple documents no
vertical bar between Mail's toolbar groups; the HIG mechanism is fixed space, which the
system renders as a separator on macOS 26.

**Where they disagree.** Per-row action buttons are a Quicken idea; GnuCash and
Banktivity document none, and the HIG never endorses them. Quicken deliberately
duplicates Split three ways; GnuCash deliberately does not duplicate at all.

## 3. Decisions

1. **Disclosure is a triangle in the leading gutter of the first column** (Date), not a
   chevron and not a column of its own — Outline views, "first column only". It appears
   only in Basic, because the other two styles have already decided what is disclosed
   (GnuCash greys its Split button in Auto-Split for the same reason).
2. **Edit stays on the row, and leaves the toolbar.** A per-row image button belongs in
   the view, not the window frame. Quicken is the precedent for an edit control on the
   selected row; single-click-a-cell remains the primary editing path, as Outline views
   describes.
3. **The toolbar is two groups**: `[View ▾, Filter]` then a spacer then `[Actions ▾]`.
   Sort folds into View (GnuCash keeps Sort By in its View menu; Music folds sort and
   columns into one pop-up). Stock Transaction and Currency Transfer leave the toolbar —
   they are guided transaction editors, not app-level actions.
4. **One disclosure reveals everything.** The old "Show Details" toggle revealed a single
   field (Notes) and sat orthogonal to a separate splits control, so a transaction's
   detail arrived in two unrelated halves. Now notes, tags and every leg (memo, action,
   share/foreign quantity) come together. `Auto Split` is renamed **Auto Details**
   accordingly, and Journal discloses all detail rather than only splits.
5. **Columns are resizable**, dragging the divider in the header, persisted across
   launches. This was a HIG directive we were failing and is universal in the field.

## 4. Still open

- **Column visibility** — Finder, Mail and Quicken all offer it by Control-clicking a
  heading. Not implemented.
- **Option-click expands everything** (Finder) has no analogue: our model has one
  expandable level, and the Journal style *is* expand-all.
- **Expansion state across sessions** — Outline views asks for it; we follow GnuCash
  instead, which drops the flag when the cursor leaves the transaction.
- Banktivity's single-line/two-line density toggle (⌘⇧\) has no equivalent here.
