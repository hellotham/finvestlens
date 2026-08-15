# Navigation design — modes, sidebar, tabs

Status: **accepted 15 Aug 2026**, scheduled in [plan.md](plan.md) as **P12**.
Requirements are `FR-NAV-01` … `FR-NAV-12` in [prd.md](prd.md). All of it lands
in 1.1: the present design is internally inconsistent, and shipping half of it
would leave two navigation models in one app.

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

Five on the toolbar at a time (§4.1a) keeps the segmented control honest; at
narrow widths it drops to icons rather than letting the system push it into the
overflow menu.

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

So Rules is not a mode. The alternative worth naming is Settings — rules that
transform incoming data are configuration, and that is where several mail
clients put them — but Records keeps them inspectable next to the records they
classify, and the app's rules already do more than classify (they allocate to
goals and link to bills).

That leaves six *working* modes; with Overview — a mode by exception, since you
glance at it rather than work in it — there are seven, which is more than feels
comfortable. §4.1a is that argument, and ⌘1…⌘7 is the count it settles on.

### 4.1a How many modes, and what to do about it

Six passes the working-session test and still feels like too many. Both things
can be true: the test says what *qualifies*, not what should be **on screen at
once**. The options, against what the HIG actually says.

**The two quotes that rule things out.** On overflow, from Tab bars:

> "**Avoid overflow tabs.** … The More tab makes it harder for people to reach
> and notice content on tabs that are hidden, so limit scenarios in your app
> where this can happen."

and from Toolbars:

> "Don't add an overflow menu manually, and **avoid layouts that cause toolbar
> items to overflow by default**."

And on hiding by circumstance, from Tab bars:

> "**Don't disable or hide tab bar buttons, even when their content is
> unavailable.** Having tab bar buttons available in some cases but not others
> makes your app's interface appear unstable and unpredictable. If a section is
> empty, explain why its content is unavailable."

So "5 + More", "4 + Other", and "hide Business when the book has no business"
are all specifically discouraged — the last one being tempting and wrong.

**The quote that opens the door**, from Toolbars:

> "In iPadOS and macOS apps, **consider letting people customize the toolbar** to
> include their most common items. Toolbar customization is especially useful in
> apps that provide a lot of items — **or that include advanced functionality
> that not everyone needs** — and in apps that people tend to use for long
> periods of time."

That is this app exactly: a lot of areas, several of which a given person never
touches, used for long sessions.

#### The options

| | Shape | Cost |
|---|---|---|
| **A** | 5 fixed + a **More** menu holding the rest | The documented anti-pattern, twice over. Planning and Records become the areas nobody finds |
| **B** | 5 fixed; **Planning folds into Accounts** (its sidebar gains Budgets · Goals · Scheduled) and **Records dissolves** — assets are already accounts, deductions and logbooks hang off transactions, listing happens in Reports | Coherent: everything in Accounts' sidebar is account-anchored. But it discards the Records design, and tax-time browsing becomes report-shaped when it wants to be editable |
| **C** | 5 fixed; **Planning and Records become Overview *views*** — boards of cards — with editing by zooming a card and listing via Reports | Most consistent with the Overview design. But a budget wants a real editor, and a card that is secretly an editor is a worse budget screen than a mode |
| **D** | Accept **6**, sized so the segmented control never overflows | Honest; nothing is hidden. Against the instinct that six is too many, and tight at narrow widths |
| **E** | **5 by default, the set is customisable**, and *every* mode is always in the View menu with a shortcut | Recommended — below |

#### Recommended: E

- **Default toolbar: Overview · Accounts · Investments · Reports · Business.**
  Five, as asked, and the five most people use.
- **Planning and Records are modes** — full sidebars, tabs, state — but not on
  the toolbar by default. Someone who budgets adds Planning once and it stays.
- **Every mode is always in the View menu** with ⌘1…⌘7. Nothing is hidden, which
  is the objection to A: an item in a menu with a shortcut is discoverable and
  permanent, where an item behind "More" is neither.
- Customisation is the **system's** toolbar customisation, not a bespoke
  settings pane — the mechanism the HIG points at, and one macOS users already
  know.

This dissolves the argument rather than settling it. "How many modes" stops
being one number for everyone and becomes each person's own, which is what the
customisation guidance is for. It also protects the Planning and Records designs
— they are not cut to make a count work, they are simply not in everyone's way.

The risk to watch: a default that hides something people need means they never
learn it exists. Mitigated by the View menu, and by Overview — a Planning card
on the default board is the advertisement for a mode not on the toolbar, and a
click on it can offer to add it.

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

#### Selecting changes what you see; drilling in changes where you are

The views are named after modes, which raises a fair question: does choosing
Overview's "Accounts" view *go to* Accounts mode? **No — and the rule is worth
stating as a rule, because the alternative is a trapdoor.**

| Gesture | Effect | Mode |
|---|---|---|
| Pick a view in the sidebar | the board changes | unchanged |
| Pick a card under a view | that card, full-window | unchanged |
| Click **through** a card — an account row, a holding, an overdue invoice | the underlying data | **switches** |
| Press the board's **"Open Accounts"** button | that mode | **switches**, explicitly |

Three reasons selection must not navigate:

1. **It would rebuild the fault this whole design removes.** Overview's sidebar
   holds views with cards nested under them. If the parent row navigated away
   while the child row showed content, that is one list doing navigation *and*
   data — the exact conflation being deleted from the account sidebar, rebuilt
   at smaller scale in the mode meant to demonstrate the pattern.
2. **It would make the mode selector lie.** Its whole job is orientation —
   *"if you hide the tab bar, people can forget which area of the app they're
   in."* A control that moves because you clicked something else is worse than
   one that is hidden: you did not ask to go, and the indicator you rely on
   shifted underneath you.
3. **It would empty Overview.** If every named view is a doorway, only "Mix" is
   really Overview, and the front page becomes a launcher rather than the
   cross-mode report it is meant to be.

This also closes a loop opened in §4.4: Accounts mode lands on All Transactions
rather than a hub *because Overview already carries the reading layer*. So
Overview's "Accounts" view **is** the accounts hub that Accounts mode
deliberately does not duplicate — not a doorway to it.

Mode switching from Overview is still wanted; it belongs on the **drill-down**,
where the user asked for the underlying data, and on an **explicit button**, so
the door is visible rather than sprung. A navigation rule people must get
comfortable with is one they will get wrong for a while, and that cost lands on
the least confident users. Nothing here moves you except a click that asks to
move.

*(Rejected alternative: views genuinely switch modes. Its honest form is
Overview with **no view list at all** — one board, and the mode buttons as the
only way to change area. Coherent and simpler, but it discards custom views and
the card index. What does not work is the middle: mode-named views that
sometimes navigate.)*

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

#### What the oracle said (built 15 Aug 2026)

The table above was written from this app's code. Checked against GnuCash's own
source before building it, two rows survive and one does not — recorded here
because the correction is the more useful half.

| Read from `~/Repositories/gnucash-reference` | Verdict |
|---|---|
| `split-register-layout.c:584-620` — `GENERAL_JOURNAL` gets **nine columns**, the same as `BANK_REGISTER`, and every cursor: `SINGLE_LEDGER`, `DOUBLE_LEDGER` **and** `SINGLE_JOURNAL` | Forcing journal style **is** wrong. Fixed |
| `gnc-split-reg.c:894`, `:1420` — `if (reg->type != GENERAL_JOURNAL) // no anchoring split` | Dropping **Transfer** from the ⇥ order is **right**, and stays. With no anchoring split there is no "other side" for `gnc_split_register_get_mxfrm_entry` to name and nothing for ⇥ to edit |
| `split-register-model.c:1650-1657` — the general journal's total cell comes from `get_trans_total_value_subaccounts`, not one split's amount | Amount should not be blank. A whole-book row now shows the **transaction total** |

So a whole-book row takes from the *transaction* the three facts a
single-account row takes from *its split*: reconcile is the flag every leg
agrees on (nothing where they differ — a state the legs disagree about is not a
fact), the account column names both ends of a two-legged transaction and falls
back to the register's existing "— Split —", and the amount is the transaction
total. `isHeadingOnly` stays: there are facts to read, still no split to edit
through.

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

- **Seven modes exist; five are on the toolbar by default** (§4.1a): Overview ·
  Accounts · Investments · Reports · Business, with Planning and Records added
  by the user through standard toolbar customisation. Every mode is always in
  the View menu with a shortcut, so nothing is hidden — the objection to a
  "More" menu. **Rules are not a mode** — they fail the working-session test and
  become a Records collection. Business stays thin until invoices and payees
  fill its sidebar, which is expected rather than a gap.
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

## 6a Build order

Scheduled as **P12** in [plan.md](plan.md) §13d, where the exit criteria and
risks live. The order, and why it is this order:

| | Sub-phase | Why here |
|---|---|---|
| **N1** | Mode infrastructure — `AppMode`, per-mode state, desk-state migration, View menu, toolbar control | The spine. Nothing else can be reached without a mode selector |
| **N2** | Mode-scoped sidebars | Needs N1 to know which mode it is in. Deletes the mixed sidebar, and the filter bug with it |
| **N3** | The tabbed interface | Needs N2: a tab is opened *from* a sidebar row |
| **N4** | Overview as a board of views | Needs N1 only; can run beside N2/N3 |
| **N5** | One period selector | Independent; touches every mode, so it lands after the modes exist |
| **N6** | All Transactions repaired | Independent of the rest — could ship first, and is the Accounts home tab N3 needs |
| **N7** | Sidebar sorting and drag | Last: it refines N2's component rather than shaping it |

**The one-way doors.** N1's desk-state migration and N2's deletion of the old
sidebar are the changes that cannot be half-shipped, which is why the phase is
all-or-nothing for 1.1 rather than staged across releases.

**What is deliberately *not* in P12:** Records' new collections (assets,
depreciation, deductions, logbooks, timesheets) and the Rules work — both are
[records-and-rules-design.md](records-and-rules-design.md), both are feature
work rather than navigation, and Records ships in P12 with the collections it
already has. Business likewise stays thin until invoices and payees fill it.

## 7 Still open

**Built 15 Aug 2026** — all seven sub-phases. What shipped, and where the build
corrected this document, is in [implemented.md](implemented.md).

Two things this design asks for that the build did not deliver, recorded here
rather than left to be rediscovered:

- **Re-parenting by drag.** The reorder half of §4.6 is built: `.onMove` on
  each level of the tree, gated on manual order, with the system's insertion
  line as the feedback. Dropping *onto* a row to re-parent is not offered.
  It was briefly shipped as the *only* half, which meant every drag re-parented
  — a book edit from a gesture that looked like sorting. Bringing it back needs
  a `DropDelegate` that distinguishes "between" from "onto" during the hover and
  draws each differently; until then re-parenting is in the account editor,
  where it is deliberate.
- *(Sorting outside Accounts is done: every mode offers Original Order and
  Name; Accounts additionally offers code, balance, type and first
  transaction, which are facts only an account has.)*

Two things to decide *during* the build rather than before it:

1. **View names.** Overview's views are currently named after modes (Mix,
   Accounts, Investments, Business, Planning). §4.3 makes that unambiguous with
   an explicit "Open …" button rather than a rename, but if the collision still
   misleads in use, renaming views after *questions* — Everything, Spending,
   Wealth, Business, Plans — is the fallback: modes are nouns, views are
   questions.
2. **Whether Accounts needs the third column.** Its tree stays four levels deep
   in P12. The HIG's remedy, a content list between sidebar and detail, is
   additive and can follow if the tree proves unwieldy in the new layout.
