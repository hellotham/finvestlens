# Navigation design — modes, sidebar, tabs

Status: **proposal for decision** (15 Aug 2026). Nothing here is built yet.

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

Thirteen functional destinations, then data. Two things worth noting because
they are not obvious from looking at it:

- **The filter erases the app's navigation.** Every functional section is
  wrapped in `if trimmedFilter.isEmpty` (`Views.swift:994`), so typing one
  character into a field labelled "Filter accounts" removes Dashboard, Reports,
  Planning and Records from the window.
- **This shape was a deliberate fix**, not an accident. The code says so:
  *"App areas that used to be modal sheets are now destinations shown inline in
  the detail pane (HIG: minimise modality)"*. The Jul 2026 redesign moved
  feature areas out of modal launchers and into the sidebar. That was the right
  move and this proposal does not undo it — it only re-homes the navigation.

## 2 What Apple says

Read 15 Aug 2026 from the current HIG (Sidebars and Tab bars both revised
8 June 2026).

**Sidebars** — https://developer.apple.com/design/human-interface-guidelines/sidebars

> "A sidebar appears on the leading side of a view and lets people navigate
> between areas of your app **or** top-level collections of content, like
> folders and playlists."

> "In general, show no more than two levels of hierarchy in a sidebar. When a
> data hierarchy is deeper than two levels, consider using a split view
> interface that includes a content list between the sidebar items and detail
> view."

> "Avoid putting critical information or actions at the bottom of a sidebar.
> People often relocate a window in a way that hides its bottom edge."

**Tab bars** — https://developer.apple.com/design/human-interface-guidelines/tab-bars

> "A tab bar lets people navigate between top-level sections of your app…
> They also let people quickly switch between sections of the view **while
> preserving the current navigation state within each section**."

> "Use a tab bar to support navigation, not to provide actions."

> Platform considerations: "**No additional considerations for macOS.**"

**Split views** — https://developer.apple.com/design/human-interface-guidelines/split-views

> "It's common to use a split view to display a sidebar for navigation, where
> the leading pane lists the top-level items or collections in an app, and the
> secondary and optional tertiary panes can present child collections and item
> details."

Scored against those, the present sidebar breaks three: it is areas **and**
collections rather than either; the account tree is four levels where two is the
guidance; and the most-used content sits at the bottom edge.

## 3 The proposal, and where it holds up

Modes (Accounts, Investments, Reports, Planning, Records), each with its own
sidebar showing one kind of thing, each landing on a mode dashboard, each able
to show several tabs; a mode switcher common to all of them.

**Right, and HIG-backed:**

- One kind of thing per sidebar is exactly the "areas **or** collections" split.
- Per-mode state that survives switching is the stated benefit of the tab-bar
  pattern ("preserving the current navigation state within each section").
- Mode dashboards are already proven here — Reports and the Investments hub
  both land on one, and both work.

**Three problems the proposal does not yet solve.**

**(a) Two of the five modes have no data to put in a sidebar.** Accounts →
accounts, Investments → securities, Reports → reports: all collections.
But Planning is *Planner, Budgets, Scheduled, Goals* and Records is *Business,
Time & Mileage, Rules, Emergency Records* — those are functions. Their sidebars
would be menus, which is the thing being removed. The rule cannot be "the
sidebar shows data"; it has to be "the sidebar shows one kind of thing, scoped
to its mode". That is still a real improvement — a menu of four related tools is
not a menu of thirteen unrelated ones — but it should be stated honestly rather
than discovered during implementation.

**(b) macOS has no tab bar.** The HIG's tab-bar page ends "No additional
considerations for macOS" because it is an iOS/iPadOS control. A "mode toolbar"
in the window toolbar also fights the toolbar's job: the same page says tab bars
are "to support navigation, not to provide actions", and the converse holds —
the toolbar is where actions on the current view live, and this app's toolbar
already carries them. Putting navigation there blurs both.

**(c) The account tree is still four levels deep inside Accounts mode.**
Scoping the sidebar to accounts does not by itself satisfy "no more than two
levels"; the HIG's answer is a content list between sidebar and detail.

## 4 Options

### A — Mode rail as the leading pane of a three-column split *(recommended)*

```
┌────┬──────────────┬─────────────────────────┐
│ ▣  │ Favourites   │                         │
│ 📖 │ ▸ Assets     │   register / report /   │
│ 📈 │ ▸ Liabilities│   hub / planner         │
│ 📊 │ ▸ Income     │                         │
│ 🗓 │ ▸ Expenses   │                         │
│ 🗄 │              │                         │
└────┴──────────────┴─────────────────────────┘
  rail    mode sidebar          detail
```

A narrow icon+label rail carries the modes; the sidebar carries that mode's one
kind of thing; the detail carries content. This is the shape the split-view page
describes almost verbatim, it keeps the toolbar for actions, and it leaves the
account tree room to gain a content column later without another redesign.

On iPad the same structure is what `sidebarAdaptable` produces — the HIG says
iPadOS "displays a tab bar near the top" with a button converting it to a
sidebar — so one model gives the idiomatic control on both platforms.

Cost: a new column of chrome (~64pt), and every destination has to declare its
mode. Risk: with a 565-account tree the window gets wide; the rail must collapse
to icons and the sidebar must stay hideable.

### B — Mode switcher in the sidebar header

Keep two columns; put a compact switcher (segmented control or pop-up menu) at
the top of the sidebar where the filter field is now, and scope everything below
it to the chosen mode.

Cheaper — no new column, no window-width pressure — and it fixes the mixing, the
bottom-edge problem and the filter-erases-navigation bug. Weaker on
discoverability: a pop-up hides the other modes, and a segmented control with
six segments in a 240pt column is cramped.

### C — One mode per window, leaning on macOS window tabs

Modes become windows. The app already does this for Reports, Help and Reconcile
(`finvestlensApp.swift:397`), so the machinery exists. macOS then supplies
tabbing, the tab overview, drag-a-tab-out, and ⌘⇧[ / ⌘⇧] for free.

Best fit for "several registers at once" and zero custom tab chrome. Weakness:
modes stop being switchable *in place* — the thing the tab-bar pattern is for —
and window management becomes the user's problem.

### D — Minimal: reorder and scope, no modes

Move Accounts to the top, push the thirteen destinations into a collapsed
"Go to" disclosure or the menu bar, and fix the filter so it stops hiding
navigation. A day's work, no architecture change, and it removes the two
concrete HIG violations without answering the "why are accounts here in Reports"
question.

## 5 Recommendation

**A, with C for tabs.**

- **Modes:** six — Overview, Accounts, Investments, Reports, Planning, Records.
  Overview is the existing dashboard, which is too much work and too good to
  demote into a mode's landing page; it is the app's front page and deserves to
  be first.
- **Switcher:** the rail (option A), not the toolbar. Actions stay in the
  toolbar; navigation stays out of it.
- **Tabs:** macOS window tabs first, because they are free, native and already
  half-adopted. Build in-window tabs only if living with window tabs shows a
  concrete need — specifically, wanting one sidebar shared across several open
  registers, which window tabs cannot give.
- **Planning and Records** keep function lists in their sidebars, and the design
  says so out loud rather than pretending they are collections.
- **Accounts mode** keeps its tree for now. GnuCash users expect it, and the
  two-level guidance is "in general". If it proves unwieldy, the third column
  from option A is already there to take a content list.

## 6 Consequences to plan for

- **Session state changes shape**: `SidebarSelection` (`AppModel.swift:150`) is
  one flat enum persisted per book. It becomes *(mode, selection-within-mode)*,
  with a migration for stored values — the same courtesy already extended to the
  old `prices` spelling.
- **The toolbar becomes mode-specific.** Create actions differ per mode; a
  single global set stops making sense.
- **Two search fields resolve.** The window's `.searchable` searches
  transactions while the sidebar header filters accounts. Under modes the
  sidebar filter is naturally "filter this mode's list", and the transaction
  search belongs to Accounts mode.
- **Shortcuts**: ⌥⌘1–3 currently select destinations; they become mode
  switches, and the usability review's "no ⌥⌘n for sidebar destinations"
  finding is answered by the rail.
- **Timing.** This is surgery on the app's spine and 1.1 is close. Option D is
  a strict subset of the work — reorder, scope, fix the filter — and could ship
  first without being thrown away.

## 7 Open questions for the user

1. Six modes, or fold Planning + Records into one "Manage" mode (five)?
2. Does Overview stay a mode of its own, or become the Accounts landing page?
3. Window tabs first, or is one sidebar shared across several registers a
   requirement rather than a nice-to-have?
