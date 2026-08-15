# Navigation design — modes, sidebar, tabs

Status: **proposal for decision** (15 Aug 2026, revised same day after review).
Nothing here is built yet.

Companions: [PRD](prd.md) · [Architecture](architecture.md) ·
[Usability review](usability-review.md) · [Register UX research](register-ux-research.md)

---

## 1 What is there now

`AccountsSidebar` (`Views.swift:928`) is one `List` holding, top to bottom:

| Band | Contents |
|---|---|
| Header | "Filter accounts" field + show-hidden toggle |
| Section (untitled) | Dashboard · Reports · All Transactions · Investments |
| Planning | Planner · Budgets · Scheduled · Savings Goals |
| Records | Business · Time & Mileage · Rules · Emergency Records |
| Favourites | pinned accounts, flat |
| Accounts | the whole tree — 565 accounts on the reference book, 4+ levels |

Thirteen functional destinations, then data. Two things not obvious from
looking at it:

- **The filter erases the app's navigation.** Every functional section is
  wrapped in `if trimmedFilter.isEmpty` (`Views.swift:994`), so typing one
  character into a field labelled "Filter accounts" removes Dashboard, Reports,
  Planning and Records from the window. The conflation showing through as a
  bug: one search field owning two kinds of content.
- **This shape was a deliberate fix.** The code says so: *"App areas that used
  to be modal sheets are now destinations shown inline in the detail pane
  (HIG: minimise modality)"*. The Jul 2026 redesign moved feature areas out of
  modal launchers into the sidebar. That was right, and this proposal does not
  undo it — it re-homes the navigation and keeps the modality win.

## 2 Three different things, often confused

Naming them separately, because the design depends on which is which:

| | What it is | Platform | Job here |
|---|---|---|---|
| **Toolbar** | Controls along the window's top edge | macOS + iPadOS | **Mode switching** — always visible |
| **Tab bar** | Bottom/top bar switching app areas | iOS/iPadOS only | Not used on macOS |
| **Tabbed interface** | Document tabs inside the content area, as in a code editor | any | **Several open items** within a mode |

The HIG draws the first two apart itself: *"In contrast to a toolbar, a tab bar
is specifically for navigating between areas of an app."* The third is not a
HIG control at all — it is an application-level pattern for holding several
open documents in one window, and it is a separate decision from the other two.

## 3 What Apple says

Read 15 Aug 2026 from the current HIG.

**Toolbars** — https://developer.apple.com/design/human-interface-guidelines/toolbars

> "A toolbar provides convenient access to frequently used commands, controls,
> **navigation**, and search."

> "Toolbars act on content in the view, **facilitate navigation, and help orient
> people in the app.** They include three types of content: The title of the
> current view · **Navigation controls**, like back and forward, and search
> fields · Actions, or bar items"

> "The system automatically adds an overflow menu in macOS or iPadOS when items
> no longer fit. Don't add an overflow menu manually, and avoid layouts that
> cause toolbar items to overflow by default."

**Sidebars** — https://developer.apple.com/design/human-interface-guidelines/sidebars
(revised 8 June 2026)

> "A sidebar … lets people navigate between areas of your app **or** top-level
> collections of content, like folders and playlists."

> "In general, show no more than two levels of hierarchy in a sidebar. When a
> data hierarchy is deeper than two levels, consider using a split view
> interface that includes a content list between the sidebar items and detail
> view."

> "Consider letting people hide the sidebar."

> "Avoid putting critical information or actions at the bottom of a sidebar."

**Tab bars** — https://developer.apple.com/design/human-interface-guidelines/tab-bars
(revised 8 June 2026)

> "Make sure the tab bar is visible when people navigate to different sections
> of your app. **If you hide the tab bar, people can forget which area of the
> app they're in.**"

> Platform considerations: "**No additional considerations for macOS.**"

The current sidebar breaks three sidebar rules at once: it is areas **and**
collections rather than either; the account tree is four levels where two is the
guidance; and the most-used content sits on the bottom edge.

## 4 The design

### 4.1 Modes live in the toolbar

Mode buttons in the window toolbar, at the leading edge with the other
navigation controls.

The deciding argument is **persistence**, not taste. A sidebar is expected to be
hideable — the HIG says to allow it — so anything living in a split-view column
disappears with it. A mode selector that can vanish is the failure the tab-bar
page names: *"If you hide the tab bar, people can forget which area of the app
they're in."* The toolbar is the only always-visible chrome in a macOS window,
and the HIG lists navigation and orientation among its three jobs.

A **mode rail as the leading split-view pane was considered and rejected** for
exactly this reason: in `NavigationSplitView` the rail *is* the sidebar column,
so the standard sidebar toggle would hide the mode selector.

Watch: the HIG warns the system moves toolbar items into an overflow menu when
they stop fitting. Modes must never overflow — so they are one segmented
control (a single item that cannot be split up), sized for the narrowest window
the app supports, with labels short enough to survive it.

### 4.2 The sidebar shows one mode's instances, two levels deep

**Every mode has real instance collections**, so no mode's sidebar has to be a
menu. Verified against the model:

| Mode | Sidebar | Backing collection |
|---|---|---|
| Overview | *(none — the board is the whole window)* | — |
| Accounts | Favourites, then the account tree | `accountTree`, `favouriteAccountNodes` |
| Investments | Securities by type; portfolios | `securityAccountNodes`, commodities |
| Reports | Standard · Custom · Favourites | report catalogue, saved reports |
| Planning | Budgets · Goals · Scheduled | `budgets`, `savingsGoals`, `scheduledTransactions` (`AppModel.swift:609-638`) |
| Business | Customers · Vendors · Invoices · Jobs · Employees · Time & Mileage | `businessCustomers` et al., `billableEntries` |
| Records | Rules · Emergency Records · Audit log | `ruleGroups`, `emergencyRecords` (`AppModel.swift:608-644`) |

Each is a section header plus its instances — **exactly two levels**, which is
what the sidebar guidance asks for. Selecting a budget shows that budget;
selecting a rule shows that rule. What used to be a destination ("Budgets")
becomes a heading over the things themselves.

**The test for whether something is a mode: does it have a collection?**
That is what settles "should there be a Tools mode" — no. Repair Book, Close
Financial Year, Import, Export and the like are *commands*, and a sidebar full
of commands is the menu this design exists to remove. Commands belong in the
menu bar, where they already are. Only the audit **log** is a collection, and it
sits in Records.

**Time & Mileage goes to Business**, not Records: billable time and mileage
exist to be invoiced, so they belong beside the invoices.

**Accounts stays four levels deep.** GnuCash users expect the tree, and the
two-level rule is written "in general". If it proves unwieldy the HIG's own
remedy — a content column between sidebar and detail — can be added later
without disturbing anything else.

Seven modes is a lot for one segmented control. At narrow widths it must drop
to icons only rather than let the system push it into the overflow menu.

**How many modes is too many? The test is whether you work there.** A mode is a
place you settle into for a session — its own sidebar, its own open tabs, its
own state to come back to. Ask of each: *would you spend twenty minutes in it?*

| | Working session? | |
|---|---|---|
| Accounts, Investments, Reports, Planning, Business, Records | yes | modes |
| Overview | no, you glance — but it is the landing | mode by exception |
| **Rules** | **no** — you adjust one and leave | **not a mode** |

Rules fail it, and they fail it twice over: you almost never *go* to Rules, you
arrive from somewhere else, usually because an import categorised something
wrongly. That is a destination reached in context, not a top-level place. They
become a **collection inside Records** — the book's own paperwork, alongside
assets, deductions and the audit log.

So: **seven modes, and Rules is not one of them.** The alternative worth
naming is Settings — rules that transform incoming data are configuration, and
that is where several mail clients put them — but Records keeps them
inspectable next to the records they classify, and the app's rules already do
more than classify (they allocate to goals and link to bills).

### 4.3 Overview is a board of views, not a board of tiles

Overview is the app's front page: it opens there, and it reports across every
mode rather than about accounts.

It is already less account-bound than it looks. Of the seventeen tiles
(`DashboardView.swift:141`), `allocation`, `performance` and `topMovers` are
investment tiles and `goals`, `bills` and `wellbeing` are planning ones. But
nine of seventeen — netWorth, income, expenses, cashflow, savingsRate, accounts,
recentActivity, composition, spendingTrend — are account-centric, and
**Business contributes no tile at all**: nothing shows receivables, payables or
an overdue invoice.

So: **every mode must be able to contribute at least one tile**, and Business
needs a receivables/overdue tile before it can hold up its end.

**Overview's sidebar is views, with their cards nested under them.** Clicking a
view shows the board; clicking a card under it shows that card full-window.
Section → instances, the same two-level shape as every other mode, and it means
the sidebar doubles as the card index — no separate "which cards are on this
view?" affordance is needed.

```
▾ Mix                 ← click: the board
    Net Worth         ← click: that card, full-window
    Cash Flow
    Allocation
▾ Accounts
    …
▾ Custom
  ▾ Tax Time          ← a saved view
      Deductions
```

Standard views (Mix · Accounts · Investments · Business · Planning), then the
user's own. **A favourite is just a saved custom view** — no separate concept.
A view is a named selection of cards; the board-packing algorithm already
decides placement from window size, so a view only says which cards are
eligible and in what priority.

**Every card can be opened full-window**, with a close button returning to the
board. A card *not* on the current view is still reachable — a toolbar button
lists every card, and choosing one opens it full-window until closed. Nothing
is unreachable merely because it did not fit the board.

**One timescale, everywhere.** A single period selector governs the board, and
is the same control every other mode uses — and the default period a report
opens with. Today the dashboard has its own period and reports have their own;
one selector removes the "which period am I looking at?" question the app
currently asks twice.

Consequences: a view is desk state (`UserDefaults`, per book, never the
document); tiles must render at two sizes, which most already do since the board
packs them at 1–3 columns; and "zoomed" is a state of the board rather than a
sheet, so ⌘W does not close the window.

### 4.4 The Accounts landing is All Transactions — and it is affordable

The performance worry was real and unmeasured, so it was measured
(`LiveWholeBookPerfTests`, on the reference book, release build):

```
transactions in book : 46831
splits in book       : 104195
whole-book rows      : 46831
whole-book build     : 0.0205 s   (cold — cache invalidated first)
whole-book warm      : 9.6e-07 s  (memoised hit)
busiest account      : 9162 splits, cold build 0.0098 s
```

**20.5 ms cold, about twice the busiest single account register**, and a
microsecond warm because `journalTransactions` memoises on `derivedRevision`.
That is affordable for a landing tab.

A caution on how that number was obtained: the first attempt looped three times
and reported **84 nanoseconds**, because runs two and three hit the memo and the
last assignment won. Any future measurement of a memoised derivation must
invalidate first or it measures a dictionary lookup.

What is *not* measured is the view: 20.5 ms is the model supplying rows, and the
register is virtualised so visible-row cost should be independent of book size.
That holds only while it stays virtualised — the same property whose loss caused
the import sheet's attribute-graph crash.

Not another card page. Investments and Reports are *reading* modes, so a hub
suits them; Accounts is a *working* mode, and Overview already carries the
reading layer for the whole app. A second summary page in Accounts would
duplicate Overview and delay the thing people came for.

All Transactions is the ledger's inbox — the newest activity across every
account, which is where a categorise or reconcile session starts. It becomes
the first tab of Accounts mode, and is not closeable.

**But it has to stop being a journal.** It is already the same component —
`RegisterSheet(model:wholeBook: true)` (`Views.swift:1590`) — yet `wholeBook`
changes three things that make it read as an anachronism:

| `RegisterSheet.swift` | What `wholeBook` does | Why it is wrong here |
|---|---|---|
| `:81` | `style: wholeBook ? .journal : style` | The chosen register style is ignored; every transaction is fully exploded whether or not the user asked for Basic Ledger |
| `:879` | `guard !wholeBook else { return [] }` — no reconcile | Each row *is* a split of some account, so its reconcile state is meaningful and needed |
| `:2838` | Transfer and Amount dropped from the ⇥ order | Editing behaves differently from every other register |

The fix is to make the whole-book register a register **scoped to every
account** rather than a separate dialect: honour the chosen style, show
reconcile, keep the editing order, and add an **Account** column — the one
thing it genuinely needs that a single-account register does not.

### 4.5 Tabs are a tabbed interface, not window tabs

Several open items within a mode — registers, reports, portfolios — as document
tabs across the top of the **detail pane**, in the manner of a code editor.

**Not macOS window tabs.** A window tab carries a whole window, so each would
bring its own sidebar and toolbar; three open registers would mean three copies
of the account tree, and switching tabs would switch modes. In-window tabs keep
**one sidebar serving many open items**, which is the requirement.

**Behaviour, following GnuCash** (read 15 Aug 2026 from
`~/Repositories/gnucash-reference` after adding `gnucash/gnome` and
`gnucash/gnome-utils` to the sparse checkout):

- **Single click selects; it does not open a tab.** GnuCash opens a register
  from the account tree on *double*-click — `gnc_plugin_page_account_tree_double_click_cb`
  → `gppat_open_account_common` (`gnc-plugin-page-account-tree.cpp:987`).
  Here, single click *replaces* the current tab's content, which is today's
  behaviour and worth keeping.
- **A new tab is a deliberate act**: double-click, ⌘-click, or the row's
  context menu — "Open in New Tab" — or a new-tab button on the strip.
- **Never open a duplicate.** GnuCash checks first:
  `if (gnc_main_window_page_exists(page)) { gnc_main_window_display_page(page); return; }`
  (`gnc-main-window.cpp:3291`). Opening something already open focuses its
  existing tab.
- **A placeholder account opens nothing.** GnuCash expands or collapses the row
  instead, because a placeholder has no register — worth copying rather than
  showing an empty one.
- Tabs persist across relaunch: desk state, so `UserDefaults`, never the book.
- The mode's home tab (All Transactions; the Investments and Reports hubs) is
  first and not closeable.

### 4.6 Sidebar behaviour common to every mode

The sidebar is one component with one set of manners, whatever collection it is
showing.

**Sorting.** Each section sorts by a criterion or by hand:

- *By criterion* — name, code, balance, type, and for accounts the date of the
  earliest transaction (the book has no opening-date field, so "opened" is
  derived, and that should be said in the UI rather than implied).
- *By hand* — a persisted order per parent. Stored in the account's own kvp so
  it round-trips like everything else; GnuCash has no such slot and will ignore
  it, which is the right failure mode.

Sorting is per section and per mode, and it is desk state.

**Dragging** does two different things and the design must not blur them:

| Drop target | Meaning | Risk |
|---|---|---|
| Between siblings | reorder — sets the manual order | none |
| Onto another account | **re-parent** — changes the tree | real; the book changes |

Re-parenting is a book edit, undoable, and it already exists behind
`validParents(forAccount:)`. It must look different from a reorder while
dragging — an insertion line versus a highlighted row — or people will move
accounts they meant to sort. Dragging is disabled while a criterion sort is
active: dropping something "between" a sorted list is a promise the sort will
immediately break.

**One context menu.** A per-row `.contextMenu` is only consulted when the row
is *outside* the current selection; right-clicking the selected row goes through
the `List`'s own selection machinery, which with no selection-typed menu
supplied fell back to the system default. That is why the same account offered
two different menus depending on whether it happened to be selected.

The fix is `contextMenu(forSelectionType:)` on the List — one definition serving
both paths by construction, and multi-selection for free. Applied 15 Aug 2026
(`Views.swift`, `AccountsSidebar.sidebarMenu(for:)`). Rows that are not accounts
get an empty menu, which is correct: offering an account's Delete on a
destination row would be worse than offering nothing.

## 5 Consequences to plan for

- **Session state changes shape.** `SidebarSelection` (`AppModel.swift:150`) is
  one flat enum persisted per book. It becomes *(mode, selection-within-mode,
  open tabs)*, with a migration for stored values — the same courtesy already
  given to the old `prices` spelling.
- **The toolbar splits in two.** Mode buttons on the leading edge; the current
  create actions become mode-specific on the trailing edge.
- **Two search fields resolve.** The window's `.searchable` searches
  transactions while the sidebar header filters accounts. The sidebar filter
  becomes "filter this mode's list"; transaction search belongs to Accounts.
  The `if trimmedFilter.isEmpty` bug disappears with the mixing that caused it.
- **Shortcuts.** ⌥⌘1–3 currently pick destinations; they become mode switches
  (⌘1…⌘6 is the more usual spelling), which also answers the usability review's
  "no ⌥⌘n for sidebar destinations" finding.
- **Timing.** This is surgery on the app's spine and 1.1 is close. The
  sub-parts are separable: fixing the filter bug and reordering the current
  sidebar is a day's work, ships independently, and is not thrown away by the
  full design.

## 6 Settled

- **Seven modes**: Overview · Accounts · Investments · Reports · Planning ·
  Business · Records. Business is its own mode; Time & Mileage joins it.
  **Rules are not a mode** — they fail the working-session test and become a
  Records collection (§4.1). Business stays thin until invoices and payees fill
  its sidebar, which is expected rather than a gap.
- **No Tools mode** — its contents are commands, and commands belong in the
  menu bar. A mode needs a collection.
- **Overview is the launch page** and reports across every mode.
- **Accounts lands on All Transactions**, repaired into a real register.
- **Single click replaces the tab; a new tab is deliberate**; an already-open
  item focuses rather than duplicates.

Records is no longer thin — see [records-and-rules-design.md](records-and-rules-design.md):
assets, depreciation schedules, deductions, logbooks and timesheets are real
collections with an external requirement behind them. Its sidebar is the
fullest of any mode.

## 7 Still open

1. **How much of this ships before 1.1.** The sidebar's context menu is fixed
   already; repairing All Transactions (§4.4) and the filter-erases-navigation
   bug are small and independent. The mode structure is not, and 1.1 is close.
