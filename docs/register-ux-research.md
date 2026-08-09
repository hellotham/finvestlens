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
6. **Row height is measured from the display, and overridable in two places.**
   See §4 below — this closes what was the first item on this document's
   still-open list.

## 4. Row height: measured, not chosen for you

The register's row was a constant 21pt, scaled only by the app's Text Size
slider — so the only way to get a roomier row was to enlarge every label in the
app. Two measurements say that constant was the wrong shape of answer.

| Measurement | Value | How |
|---|---|---|
| AppKit's own default table row | **24.0 pt** | a bare `NSTableView()` reports `rowHeight == 24.0` |
| Default line height of the 13pt system font | 16.0 pt | `NSLayoutManager().defaultLineHeight(for:)` |
| This project's built-in display | 1470 × 956 pt across 290.6 mm → **128.5 points per inch** | `NSScreen.frame` ÷ `CGDisplayScreenSize` |
| The old 21pt row, on that display | **4.15 mm** | 21 ÷ 128.5 in |
| The same 21pt row, on a 109 ppi desktop monitor | **4.89 mm** | 21 ÷ 109 in |

A macOS point is nominally 1/72 inch and no shipping display honours that, so
the identical register was **15% physically smaller** on the laptop than on the
monitor — a legibility difference the app can measure and the reader cannot
control. `NSScreen.deviceDescription[.resolution]` looks like the way to see
this and is not: it reports the nominal 72 dpi times the backing scale
(`{144, 144}` on the 128.5 ppi display above). Only `CGDisplayScreenSize`, which
reads the display's EDID, knows the physical size.

**The default is therefore computed.** `RegisterRowHeight.automatic` starts from
AppKit's 24pt, corrects **half-way** towards a row of constant physical height,
then refuses to be so tall that a full-height window could not show thirty
transactions; the result is clamped to 21…30pt. The half-way correction is a
deliberate compromise, not a derivation: full normalisation is right in
isolation and wrong in company, because macOS itself treats a point as a point
and a fully normalised register would stand out of step with every other app on
the same screen — and would quietly undo the choice of someone running "More
Space". Displays that report no physical size (virtual displays, capture
devices, some projectors) drop that term rather than the calculation.

Worked values: 109 ppi → 24pt; 128.5 ppi → 26pt; 92 ppi → 22pt.

**Text and glyphs scale with the row**, because a taller row holding the same
small text is white space, not legibility: every font, symbol and offset in the
sheet is a multiple of the 24pt base, so one number moves the lot. Moving the
window to another display re-measures (`NSWindow.didChangeScreenNotification`).

**Overriding it is available in two places**, which the HIG asks for from
opposite directions: Settings ▸ Appearance ▸ Register is where a preference
belongs, and the register's own View ▾ menu is where you are standing when you
form an opinion about it — with the menu-bar mirror that *Toolbars* (macOS)
requires, "Make every toolbar item available as a command in the menu bar".
`Compact` is exactly the 21pt the register shipped with, so nobody who preferred
it loses it.

iOS and iPadOS publish no physical display size at all. There, Dynamic Type
already carries the accessibility contract — `scaledFont` multiplies every
register font by it — so `automatic` resolves to the 24pt base and the person's
own text setting moves it.

## 5. Still open

- ~~**Column visibility** — Finder, Mail and Quicken all offer it by
  Control-clicking a heading. Not implemented.~~ **Closed (9 Aug 2026).**
  Control-click any heading; the same list is on the register's View ▾ menu and
  the View menu bar, because HIG *Context menus* asks that context-menu items
  "always" be available in the main interface too. Num, Transfer, Reconciled and
  Balance may be switched off; Date, Description, Amount and the handle column
  may not — they are what makes this a register rather than a list. A hidden
  column is laid out at zero width, which is what makes the rest fall out for
  free: nothing draws, no point can land in it, Description takes back the
  space, and its editor leaves the ⇥ order with it. Worth knowing for Balance:
  on a leg row that column carries the foreign or share quantity (FR-REG-07),
  so hiding it hides that editor too. macOS only — as with column resizing,
  which is also the AppKit sheet's.
- **Option-click expands everything** (Finder) has no analogue: our model has one
  expandable level, and the Journal style *is* expand-all.
- **Expansion state across sessions** — Outline views asks for it; we follow GnuCash
  instead, which drops the flag when the cursor leaves the transaction.
- ~~Banktivity's single-line/two-line density toggle (⌘⇧\) has no equivalent
  here.~~ **Closed** — see §4. Ours is a five-way row height rather than a
  two-way toggle, and its default is measured rather than picked. It carries no
  keyboard shortcut; Banktivity's ⌘⇧\ has no obvious counterpart that is not
  already taken.
