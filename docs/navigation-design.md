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

The point missed on the first pass: **every mode has real instance
collections**, so no mode's sidebar has to be a menu. Verified against the
model:

| Mode | Sidebar | Backing collection |
|---|---|---|
| Overview | *(none — the dashboard is the whole window)* | — |
| Accounts | Favourites, then the account tree | `accountTree`, `favouriteAccountNodes` |
| Investments | Securities grouped by type; portfolios | `securityAccountNodes`, commodities |
| Reports | Standard · Custom · Favourites | report catalogue, saved reports |
| Planning | Budgets · Goals · Scheduled | `budgets`, `savingsGoals`, `scheduledTransactions` (`AppModel.swift:609-638`) |
| Records | Rules · Time & Mileage · Emergency Records | `ruleGroups`, `billableEntries`, `emergencyRecords` (`AppModel.swift:608-647`) |

Each is a section header plus its instances — **exactly two levels**, which is
what the sidebar guidance asks for. Selecting a budget shows that budget;
selecting a rule shows that rule. What used to be a destination ("Budgets")
becomes a section heading over the things themselves.

Two places this does not fall out cleanly:

- **Business** is a hub of its own — customers, vendors, invoices, jobs,
  employees. Under Records it would need three levels. It is a mode of its own,
  or Records is renamed and Business moves out.
- **Accounts** is four levels deep and stays that way. GnuCash users expect the
  tree, and the two-level rule is written "in general". If it proves unwieldy,
  the HIG's own remedy — a content column between sidebar and detail — can be
  added without disturbing anything else.

### 4.3 Tabs are a tabbed interface, not window tabs

Several open items within a mode — registers, reports, portfolios — as document
tabs across the top of the **detail pane**, in the manner of a code editor's
file tabs.

**Not macOS window tabs.** A window tab carries a whole window, so each one
would bring its own sidebar and toolbar; opening three registers would mean
three copies of the account tree, and switching tabs would switch modes too.
That defeats the point of a mode-scoped sidebar. In-window tabs keep **one
sidebar serving many open items**, which is the actual requirement.

Consequences to design deliberately: what opens a tab versus replacing the
current one (a single click replaces, ⌘-click or double-click pins, as editors
do); how tabs are closed and reordered; whether the set survives relaunch
(it should — it is desk state, so `UserDefaults`, never the book); and
"All Transactions" / "All Investments" as a first, permanent tab.

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

## 6 Questions still needing an answer

1. **Six modes or seven** — does Business come out of Records into its own mode?
   It is the one collection that will not fit two levels under anything else.
2. **Does Overview stay a mode**, or become the Accounts landing page? It is the
   app's front page and a lot of work went into the tile board, which argues for
   its own mode.
3. **Tab behaviour on single click** — replace the current tab (editor-style
   preview) or always open a new one?
