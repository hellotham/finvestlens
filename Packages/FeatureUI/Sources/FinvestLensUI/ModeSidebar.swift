//
//  ModeSidebar.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  One sidebar, parameterised by mode (`FR-NAV-04`).
//  Design: docs/navigation-design.md §4.2, §4.6.
//
//  What this replaces: a single `List` holding thirteen functional
//  destinations, a Planning menu, a Records menu, favourites, and then 565
//  accounts. HIG *Sidebars* asks a sidebar to show areas **or** collections;
//  that one was both, four levels deep, with the most-used content pinned to
//  the window's bottom edge.
//
//  The filter-erases-navigation bug goes with it rather than being fixed:
//  every destination used to be wrapped in `if trimmedFilter.isEmpty`, so one
//  character typed into a field labelled "Filter accounts" removed Dashboard,
//  Reports, Planning and Records from the window. With one kind of thing per
//  sidebar there is nothing left for a filter to erase — the filter now means
//  "filter this mode's list", which is the only thing it can mean.
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensEngine

/// One row: a collection, or an instance inside one.
///
/// The two labels are separate on purpose. A collection's name is ours and is
/// localized; an instance's name is the user's — an account, a budget, a
/// customer — and must reach `Text` as a verbatim `String`. Routing user text
/// through `LocalizedStringKey` would look for it in the catalog, and a
/// `String`-typed label parameter silently opts our own names *out* of
/// localization: the two traps CLAUDE.md ▸ Localization names, one either side.
struct SidebarRow: Identifiable {
    let id: SidebarSelection
    let key: LocalizedStringKey?
    let text: String?
    let symbol: String?
    /// Trailing value — a balance, a count, a date.
    let detail: String?
    /// Instances beneath a collection that is *itself* a destination. Where a
    /// grouping is only a grouping (a commodity's exchange, a report's
    /// category) it is a ``SidebarGroup`` header instead, because a selectable
    /// row has to lead somewhere.
    var children: [SidebarRow]?
    /// A collection's name as the *reader* sees it, resolved through the
    /// catalog. Filtering against a `LocalizedStringKey`'s English source would
    /// be wrong in seven of the eight languages.
    var resolvedName: String?

    init(id: SidebarSelection, key: LocalizedStringKey?, text: String?,
         symbol: String?, detail: String?, resolvedName: String? = nil,
         children: [SidebarRow]? = nil) {
        self.id = id
        self.key = key
        self.text = text
        self.symbol = symbol
        self.detail = detail
        self.resolvedName = resolvedName
        self.children = children
    }

    /// A collection, or one of a mode's own destinations.
    @MainActor
    static func collection(_ id: SidebarSelection, _ key: LocalizedStringKey,
                           in model: AppModel,
                           symbol: String, detail: String? = nil,
                           children: [SidebarRow]? = nil) -> SidebarRow {
        SidebarRow(id: id, key: key, text: nil, symbol: symbol,
                   detail: detail, resolvedName: model.tabTitle(for: id),
                   children: children)
    }

    /// One thing in a collection, named by the user.
    static func instance(_ id: SidebarSelection, _ text: String,
                         symbol: String? = nil, detail: String? = nil) -> SidebarRow {
        SidebarRow(id: id, key: nil, text: text, symbol: symbol,
                   detail: detail, children: nil)
    }

    /// One thing in a collection, named the way its tab names it.
    ///
    /// The two used to be spelled separately — fourteen rules in two files,
    /// including the invoice's "number, or the owner if it has none" and the
    /// employee's "address name, or the username" — so a row and its own tab
    /// could disagree in the same window.
    @MainActor
    static func instance(_ id: SidebarSelection, in model: AppModel,
                         symbol: String? = nil, detail: String? = nil) -> SidebarRow {
        SidebarRow(id: id, key: nil, text: model.tabTitle(for: id), symbol: symbol,
                   detail: detail, children: nil)
    }

    /// The plain-text name, for filtering and for VoiceOver.
    var searchText: String { text ?? resolvedName ?? "" }
}

/// A titled band of rows. Its header is *not* selectable, which is the point:
/// a grouping that leads nowhere must not look like a destination.
struct SidebarGroup: Identifiable {
    let id: String
    let key: LocalizedStringKey?
    let text: String?
    let rows: [SidebarRow]

    static func untitled(_ rows: [SidebarRow]) -> SidebarGroup {
        SidebarGroup(id: "", key: nil, text: nil, rows: rows)
    }

    static func titled(_ id: String, _ key: LocalizedStringKey,
                       _ rows: [SidebarRow]) -> SidebarGroup {
        SidebarGroup(id: id, key: key, text: nil, rows: rows)
    }

    /// A group named by the data — a commodity's exchange, say.
    static func named(_ id: String, _ text: String, _ rows: [SidebarRow]) -> SidebarGroup {
        SidebarGroup(id: id, key: nil, text: text, rows: rows)
    }
}

/// The sidebar for whichever mode the window is in.
struct ModeSidebar: View {
    @Bindable var model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var sheet: AccountSheet?
    /// Live drag state, shared down the tree — a drag crosses levels.
    @State private var drag = AccountDragState()
    @State private var filter = ""
    /// GnuCash's "show hidden accounts". `isHidden` has been settable, stored
    /// and round-tripped all along, and the tree showed every account anyway —
    /// so marking one hidden greyed its name and changed nothing else.
    @AppStorage("showHiddenAccounts") private var showHidden = false
    @Environment(\.appFontScale) private var appFontScale
    /// Read through `@AppStorage` so choosing a criterion redraws the list —
    /// the model writes the same key, and the two stay in step by construction
    /// rather than by remembering to bump a revision.
    // The key comes from `SidebarSort.storageKey(for:)`; `@AppStorage` needs a
    // literal, so it is asserted equal to it in `SidebarSortTests` rather than
    // spelled twice and hoped about.
    @AppStorage("sidebar.sort.accounts") private var accountSortRaw = SidebarSort.manual.rawValue

    private var accountSort: SidebarSort {
        SidebarSort(rawValue: accountSortRaw) ?? .manual
    }

    private var trimmedFilter: String { filter.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .navigationSplitViewColumnWidth(min: 200 * appFontScale,
                                        ideal: 240 * appFontScale,
                                        max: 400 * appFontScale)
        // The filter belongs to the list it filters; carrying one mode's text
        // into another mode's list would hide rows for a reason nobody typed.
        .onChange(of: model.mode) { filter = "" }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let id): EditAccountSheet(model: model, accountID: id)
            case .reconcile(let id): ReconcileView(model: model, accountID: id)
            case .delete(let id): DeleteAccountSheet(model: model, accountID: id)
            case .cascade(let id): CascadeAccountSheet(model: model, accountID: id)
            }
        }
    }

    // MARK: Header

    /// The filter, and — in Accounts only — GnuCash's show-hidden toggle.
    ///
    /// The prompt names the mode, because the field's scope is the mode's list
    /// rather than "accounts" wherever you happen to be. HIG *Text fields*:
    /// placeholder text is not a label, which is why the field also carries an
    /// accessibility label naming what it filters.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The mode, in words, permanently.
            //
            // The mode row is chrome on the detail column, so it goes with any
            // window state that hides it, and it is off screen entirely
            // whenever the detail pane is — so orientation cannot rest on it
            // alone. (It said the buttons "drop to symbols when the window
            // cannot hold their labels"; they never do — `ModeLabelFit` is
            // retained but unconsulted.) HIG *Toolbars* counts "the title of
            // the current view"
            // among a toolbar's three jobs and *Tab bars* warns that when the
            // selector is hidden "people can forget which area of the app
            // they're in"; this is the answer that costs no toolbar width.
            HStack(spacing: 6) {
                Image(systemName: model.mode.symbol)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(model.mode.title)
                    .scaledFont(.headline)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(model.mode.title))
            .accessibilityAddTraits(.isHeader)

            controls
        }
        .padding(8)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            TextField(filterPrompt, text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(filterPrompt)
            if model.mode == .accounts {
                Toggle(isOn: $showHidden) {
                    Image(systemName: showHidden ? "eye" : "eye.slash")
                        .accessibilityLabel("Show hidden accounts")
                }
                .toggleStyle(.button)
                .help("Show hidden accounts")
            }
            addMenu
            // Every mode, not just Accounts: name order means something over a
            // list of budgets or customers too, and a control that appears in
            // one sidebar and not the others is the inconsistency this phase
            // exists to remove.
            sortMenu
        }
        .padding(8)
    }

    /// Adds to this mode's collection.
    ///
    /// A sidebar that lists a collection has to be able to add to it. Every one
    /// of these commands already existed, buried in the detail view that owns
    /// its editor; this puts it where the list is. Absent, not disabled, in a
    /// mode with nothing to add — Reports' catalogue is fixed, and a saved
    /// report is saved *from* a report.
    @ViewBuilder
    private var addMenu: some View {
        let creations = model.mode.creations
        if creations.count == 1, let only = creations.first {
            Button {
                model.requestCreate(only)
            } label: {
                // The command's own glyph, not a blanket `+` — see
                // `SidebarCreation.symbol`.
                Image(systemName: only.symbol)
                    .accessibilityLabel(only.title)
            }
            .buttonStyle(.borderless)
            .help(only.title)
        } else if !creations.isEmpty {
            Menu {
                ForEach(creations) { creation in
                    Button(creation.title) { model.requestCreate(creation) }
                }
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Add to this list")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add to this list")
        }
    }

    /// How this mode's list is ordered (`FR-NAV-12`).
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: sortBinding) {
                ForEach(SidebarSort.cases(for: model.mode)) { candidate in
                    Text(candidate.title(in: model.mode)).tag(candidate.rawValue)
                }
            }
            .pickerStyle(.inline)
            // The book has no opening-date field, so "First Transaction" is
            // derived — said here rather than implied by the name.
            if let note = currentSort.note {
                Divider()
                Text(note)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .accessibilityLabel("Sort this list")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose how this list is ordered")
    }

    /// Accounts reads through `@AppStorage` so its (expensive) tree redraws on
    /// a change; the other modes read the same key space through the model,
    /// which is cheap and needs no second storage property per mode.
    private var currentSort: SidebarSort {
        model.mode == .accounts ? accountSort : model.sidebarSort(for: model.mode)
    }

    private var sortBinding: Binding<String> {
        Binding(
            get: { currentSort.rawValue },
            set: { raw in
                let sort = SidebarSort(rawValue: raw) ?? .manual
                if model.mode == .accounts {
                    accountSortRaw = raw
                } else {
                    model.setSidebarSort(sort, for: model.mode)
                }
            })
    }

    private var filterPrompt: LocalizedStringKey {
        switch model.mode {
        case .dashboard: "Filter views"
        case .accounts: "Filter accounts"
        case .investments: "Filter securities"
        case .reports: "Filter reports"
        case .business: "Filter business records"
        case .planning: "Filter plans"
        case .records: "Filter records"
        }
    }

    // MARK: The list

    /// The sidebar's selection, **written off the render pass**.
    ///
    /// Reported 16 Aug 2026: "Clicking on reports in the sidebar does not
    /// work", and reproduced — with Balance Sheet showing, clicking All Reports
    /// left the selection, the tab and the content exactly where they were,
    /// while clicking the *tab* of the same name worked.
    ///
    /// `$model.sidebarSelection` is a computed binding whose setter calls
    /// `navigate(to:)`, and a `List` writes its selection **during** SwiftUI's
    /// update. `navigate` then mutates `currentMode`, `tabsByMode`,
    /// `activeTabByMode`, and runs `applyNavigationChange` — which restores
    /// register view state and can call `refreshRegister()`. Those are observed
    /// properties this very view is reading as it is being built, so the write
    /// is made in a pass that is already reading them and is discarded.
    ///
    /// The model was never wrong: `ModeTabTests.homeRowIsSelectable` drives the
    /// identical sequence through `navigate` and passes. Only the delivery was.
    /// This is the same hop the register already makes for the same reason —
    /// `RegisterSheet.swift`: "Consuming mutates the model — hop off the render
    /// pass first."
    private var navigationSelection: Binding<SidebarSelection?> {
        Binding(
            get: { model.sidebarSelection },
            set: { new in
                guard let new, new != model.sidebarSelection else { return }
                Task { @MainActor in model.navigate(to: new) }
            })
    }

    @ViewBuilder
    private var list: some View {
        List(selection: navigationSelection) {
            // Accounts keeps its own shape: a tree four levels deep, which the
            // two-level guidance ("in general") explicitly tolerates and
            // GnuCash users expect. Every other mode is collections and their
            // instances — exactly two.
            if model.mode == .accounts {
                accountsSidebar
            } else {
                let groups = ModeSidebarRows.groups(for: model.mode, model: model)
                    .map { SidebarGroup(id: $0.id, key: $0.key, text: $0.text,
                                        rows: model.sortedRows($0.rows, by: currentSort)) }
                ForEach(filtered(groups)) { group in
                    section(group)
                }
            }
        }
        // A fresh list per mode. Even with sections namespaced, one mode's
        // rows and another's are different vocabularies — an account tree
        // against a list of budgets — and diffing between them is how remnants
        // appeared. Switching mode is a change of subject, not an animation.
        .id(model.mode)
        .contextMenu(forSelectionType: SidebarSelection.self) { selection in
            sidebarMenu(for: selection)
        } primaryAction: { selection in
            // Double-click opens a tab, as it does in GnuCash — a register is
            // opened from the account tree on *double*-click
            // (`gnc-plugin-page-account-tree.cpp:987`). Single click replaces
            // the current tab, which is this app's existing behaviour.
            //
            // ⌘-click is deliberately not bound: in a macOS `List` it is the
            // extend-selection modifier, and taking it would fight the platform
            // for a gesture the context menu and ⌘T already offer.
            guard let target = selection.first else { return }
            model.navigate(to: target, inNewTab: true)
        }
    }

    @ViewBuilder
    private func section(_ group: SidebarGroup) -> some View {
        if let key = group.key {
            Section(key) { rows(group) }
        } else if let text = group.text {
            Section(text) { rows(group) }
        } else {
            Section { rows(group) }
        }
    }

    private func rows(_ group: SidebarGroup) -> some View {
        ForEach(group.rows) { row in outline(row) }
    }

    /// A collection and the things in it. `DisclosureGroup` builds its children
    /// only while expanded, which is what keeps a mode with hundreds of rows
    /// from fanning the attribute graph out over rows nobody can see — the
    /// failure that crashed the import sheet on 15 Aug 2026.
    @ViewBuilder
    private func outline(_ row: SidebarRow) -> some View {
        if let children = row.children, !children.isEmpty {
            DisclosureGroup {
                ForEach(children) { child in label(child) }
            } label: {
                label(row)
            }
        } else {
            label(row)
        }
    }

    private func label(_ row: SidebarRow) -> some View {
        HStack {
            if let symbol = row.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // Branch rather than a ternary inside `Text`: a ternary settles on
            // one initializer for both arms, which would take the user's own
            // name through the catalog or take ours past it.
            if let key = row.key {
                Text(key).scaledFont(.body)
            } else {
                Text(row.text ?? "").scaledFont(.body)
            }
            Spacer()
            if let detail = row.detail {
                Text(detail)
                    .scaledFont(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(row.id)
    }

    private func filtered(_ groups: [SidebarGroup]) -> [SidebarGroup] {
        ModeSidebarRows.filtering(groups, by: trimmedFilter,
                                  keeping: model.mode.defaultSelection)
    }

    // MARK: Accounts

    private var visibleTree: [AccountNode] {
        model.sidebarTree(showingHidden: showHidden, sortedBy: accountSort)
    }

    /// Drops hidden accounts and everything under them. Hiding a parent hides
    /// the subtree, as in GnuCash — a visible child of a hidden parent would
    /// have nowhere to hang.
    static func pruningHidden(_ nodes: [AccountNode]) -> [AccountNode] {
        nodes.compactMap { node in
            guard !node.isHidden else { return nil }
            guard let children = node.children else { return node }
            var copy = node
            copy.children = pruningHidden(children)
            return copy
        }
    }

    @ViewBuilder
    private var accountsSidebar: some View {
        // The mode's home, first — the ledger's inbox, and the tab that cannot
        // be closed.
        // The mode's home stays put while filtering. Hiding the way back
        // whenever someone types is the fault the old sidebar earned, in
        // miniature — and All Transactions is not something a filter over
        // *accounts* has any business removing.
        Section {
            Label("All Transactions", systemImage: "text.book.closed")
                .tag(SidebarSelection.generalLedger)
        }
        // Pinned accounts, flat, in the order they were favourited — the
        // shortcut past three disclosure triangles for the handful of
        // registers someone lives in. Same row (and context menu) as the tree,
        // so selecting one is selecting the account. Filtered like everything
        // else rather than hidden by the presence of a filter.
        let favourites = model.favouriteAccountNodes.filter {
            trimmedFilter.isEmpty
                || $0.name.localizedCaseInsensitiveContains(trimmedFilter)
        }
        if !favourites.isEmpty {
            Section("Favourites") {
                ForEach(favourites) { node in
                    accountRow(node, label: node.name)
                }
            }
        }
        Section("Accounts") {
            if trimmedFilter.isEmpty {
                AccountBranch(model: model, nodes: visibleTree,
                              canReorder: accountSort.allowsDragging, drag: drag)
            } else {
                // Filtering flattens to matches and shows full names — the same
                // shape as Find's account picker, and the reason typing
                // "everyday" beats opening three disclosure triangles on 559
                // accounts.
                let matches = AccountMatchPicker.matching(visibleTree, filter: trimmedFilter,
                                                          includingPlaceholders: true)
                if matches.isEmpty {
                    Text("No accounts match “\(trimmedFilter)”.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches) { node in
                        accountRow(node, label: node.fullName)
                    }
                }
            }
        }
    }

    private func accountRow(_ node: AccountNode, label: String) -> some View {
        AccountSidebarRow(node: node, label: label)
    }

    // MARK: Context menu

    /// One menu for every sidebar row, whether or not it is the selected one.
    ///
    /// A per-row `.contextMenu` is only consulted when the row is *outside* the
    /// selection; right-clicking the selected row goes through the `List`'s
    /// selection machinery instead, which — with no selection-typed menu
    /// supplied — fell back to the system's default. That is why the same
    /// account offered two different menus depending on whether it happened to
    /// be selected. Attaching the menu to the selection type is the API meant
    /// for this: one definition, both paths.
    @ViewBuilder
    func sidebarMenu(for selection: Set<SidebarSelection>) -> some View {
        // Every row can be opened in a tab; only accounts carry account
        // actions.
        if selection.count == 1, let target = selection.first {
            Button("Open in New Tab") { model.navigate(to: target, inNewTab: true) }
            Divider()
        }
        // Account rows carry account actions. Other rows have none, and an
        // empty menu is correct — better than offering an account's Delete on
        // a row that is not an account.
        if selection.count == 1, case let .account(id)? = selection.first {
            let hasChildren = !(model.book?.account(with: id)?.children.isEmpty ?? true)
            Button(model.isFavouriteAccount(id) ? "Remove from Favourites" : "Add to Favourites",
                   systemImage: model.isFavouriteAccount(id) ? "star.slash" : "star") {
                model.toggleFavouriteAccount(id)
            }
            if accountSort.allowsDragging {
                // Everything the mouse can do must be reachable from the
                // keyboard. Dragging is the pointer's way to reorder; these are
                // everyone else's, and they are the only route under VoiceOver.
                Button("Move Up") { model.nudgeAccount(id, by: -1) }
                    .disabled(!model.canNudgeAccount(id, by: -1))
                Button("Move Down") { model.nudgeAccount(id, by: 1) }
                    .disabled(!model.canNudgeAccount(id, by: 1))
                Divider()
            }
            Button("Edit…") { sheet = .edit(id) }
            Button("Reconcile…") {
                #if os(macOS)
                openWindow(id: "reconcile", value: id)
                #else
                sheet = .reconcile(id)
                #endif
            }
            // Only where there is a subtree to cascade onto.
            if hasChildren {
                Button("Cascade Properties…") { sheet = .cascade(id) }
            }
            // Always offered. It used to appear only for an account with
            // nothing in it, which on a real book is almost none of them — so
            // the answer to "why can't I delete this?" was a button that wasn't
            // there.
            Button("Delete…", role: .destructive) { sheet = .delete(id) }
        }
    }
}

// MARK: - What each mode lists

/// The collections behind each mode's sidebar.
///
/// A pure function of the model, split out of the view so `ModeSidebarTests`
/// can assert the shape of every mode's sidebar without a window — which is
/// what makes "does this mode show one kind of thing, two levels deep?" a
/// question with an answer rather than an intention.
@MainActor
enum ModeSidebarRows {

    static func groups(for mode: AppMode, model: AppModel) -> [SidebarGroup] {
        // Namespaced by mode. Every mode's first band is `.untitled`, whose id
        // was the empty string — so `ForEach` saw *the same section* in Planning
        // as in Records and diffed one mode's rows into the other's, leaving
        // remnants of the sidebar you just left. Ids are identity here, not
        // decoration: two sections may not share one.
        build(for: mode, model: model).map {
            SidebarGroup(id: "\(mode.rawValue)/\($0.id)", key: $0.key,
                         text: $0.text, rows: $0.rows)
        }
    }

    /// Narrows a mode's rows to `filter`, keeping a collection whose *children*
    /// match so the match stays reachable — and **always keeping `home`**.
    ///
    /// That last clause is the fix this function was extracted for. Accounts had
    /// pinned All Transactions outside the filter since the sidebar was built —
    /// "hiding the way back whenever someone types is the fault the old sidebar
    /// earned, in miniature" — and the other six modes had not, because their
    /// home row is just the first row of the first group and went through the
    /// filter with everything else. Typing `BHP` in Investments removed *All
    /// Holdings*; typing anything in Reports removed *All Reports*. One rule,
    /// written once, for all seven — and out of the view, so a test can hold it
    /// there.
    static func filtering(_ groups: [SidebarGroup], by filter: String,
                          keeping home: SidebarSelection) -> [SidebarGroup] {
        guard !filter.isEmpty else { return groups }
        let needle = filter.lowercased()
        func matches(_ row: SidebarRow) -> SidebarRow? {
            let kept = (row.children ?? []).filter {
                $0.searchText.lowercased().contains(needle)
            }
            if !kept.isEmpty {
                var copy = row
                copy.children = kept
                return copy
            }
            if row.searchText.lowercased().contains(needle) { return row }
            // The way back, kept — narrowed to nothing rather than removed, so
            // the row does not offer a disclosure triangle over no matches.
            guard row.id == home else { return nil }
            var stripped = row
            stripped.children = nil
            return stripped
        }
        return groups.compactMap { group in
            let kept = group.rows.compactMap(matches)
            guard !kept.isEmpty else { return nil }
            return SidebarGroup(id: group.id, key: group.key, text: group.text, rows: kept)
        }
    }

    private static func build(for mode: AppMode, model: AppModel) -> [SidebarGroup] {
        switch mode {
        case .dashboard: overview(model)
        case .accounts: []          // built in the view — a tree, not a list
        case .investments: investments(model)
        case .reports: reports(model)
        case .business: business(model)
        case .planning: planning(model)
        case .records: records(model)
        }
    }

    /// Views, with their cards nested beneath — section then instances, the
    /// same two-level shape as every other mode. It doubles as the card index,
    /// which is why no separate "which cards are on this view?" affordance is
    /// needed (navigation-design §4.3).
    ///
    /// Selecting a view changes the board; selecting a card shows it
    /// full-window. Neither switches mode: the views are named after modes, and
    /// if the parent row navigated away while the child row showed content,
    /// that is one list doing navigation *and* data — the exact conflation this
    /// redesign deletes from the account sidebar, rebuilt at smaller scale in
    /// the mode meant to demonstrate the pattern.
    private static func overview(_ model: AppModel) -> [SidebarGroup] {
        func row(_ view: OverviewView) -> SidebarRow {
            let cards = view.overviewCards.map { card in
                SidebarRow.instance(.overviewCard(view: view.id, card: card.rawValue), in: model)
            }
            if let key = view.title {
                return .collection(.overviewView(view.id), key, in: model,
                                   symbol: "square.grid.2x2", children: cards)
            }
            return SidebarRow(id: .overviewView(view.id), key: nil, text: view.displayName,
                              symbol: "bookmark", detail: nil, children: cards)
        }
        var groups: [SidebarGroup] = [
            .untitled(OverviewView.standards.map(row)),
        ]
        // A favourite *is* a saved custom view — there is no second concept.
        let custom = model.customOverviewViews
        if !custom.isEmpty {
            groups.append(.titled("custom", "Custom", custom.map(row)))
        }
        return groups
    }

    private static func investments(_ model: AppModel) -> [SidebarGroup] {
        var groups: [SidebarGroup] = [
            .untitled([.collection(.investments, "All Holdings", in: model, symbol: "chart.pie")]),
        ]
        // One row per portfolio — the parent accounts that hold securities.
        // These are what make "All Holdings, and then each portfolio" a set of
        // tabs: a tab here is a sidebar row opened in one, the same mechanism
        // every other mode uses, so nothing new had to be invented for it.
        //
        // Only when there is more than one. A book whose holdings all sit under
        // a single parent would get one portfolio row saying exactly what All
        // Holdings already says.
        let portfolios = model.portfolioAccounts
        if portfolios.count > 1 {
            groups.append(.titled("portfolios", "Portfolios", portfolios.map {
                .instance(.portfolio($0.id), in: model, symbol: "briefcase")
            }))
        }
        // Securities by type, using the grouping the book already carries:
        // GnuCash's commodity namespace (ASX, NASDAQ, FUND…). The exchange is
        // data, so its name is shown verbatim rather than looked up.
        // Grouped by the namespace itself, and headed by its `displayName` —
        // the string interpolation that used to do both printed the enum's own
        // description, so the heading read `security("ASX")`. The group id
        // keeps that interpolation deliberately: sidebar ids are persisted.
        let byNamespace = Dictionary(grouping: model.securityCommodities, by: \.namespace)
        for namespace in byNamespace.keys.sorted(by: {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }) {
            let holdings = (byNamespace[namespace] ?? [])
                .sorted { $0.mnemonic < $1.mnemonic }
                .map { security($0, model) }
            guard !holdings.isEmpty else { continue }
            groups.append(.named("ns-\(namespace)", namespace.displayName, holdings))
        }
        // Watch-only, or a security held *and* watched appears twice with the
        // same tag — and two rows carrying one tag makes `List` selection
        // ambiguous. `InvestmentsView` filters the same way.
        let watched = model.watchlist.filter { model.isWatchOnly($0) }
        if !watched.isEmpty {
            groups.append(.titled("watchlist", "Watchlist", watched.map { security($0, model) }))
        }
        return groups
    }

    private static func security(_ commodity: Commodity, _ model: AppModel) -> SidebarRow {
        .instance(.security(SidebarSelection.securityKey(commodity)), in: model,
                  detail: commodity.fullName)
    }

    private static func reports(_ model: AppModel) -> [SidebarGroup] {
        var groups: [SidebarGroup] = [
            .untitled([.collection(.reports, "All Reports", in: model, symbol: "square.grid.2x2")]),
        ]
        // The catalogue's own four groups, which the gallery already uses — so
        // the sidebar and the gallery name the same things the same way. The
        // report names themselves stay verbatim, exactly as the gallery renders
        // them; localizing the catalogue is its own job, not this one's.
        for group in ReportKind.Group.allCases {
            let kinds = ReportKind.allCases.filter { $0.group == group }
            guard !kinds.isEmpty else { continue }
            groups.append(.titled(group.rawValue, group.title,
                                  kinds.map { .instance(.report($0), in: model, symbol: $0.icon) }))
        }
        if !model.savedReports.isEmpty {
            groups.append(.titled("saved", "Saved",
                                  model.savedReports.map { .instance(.savedReport($0.id), in: model) }))
        }
        return groups
    }

    private static func planning(_ model: AppModel) -> [SidebarGroup] {
        [.untitled([
            // The three planners, as rows. They were a segmented picker inside
            // the Planner view and nothing else could reach them — see
            // `SidebarSelection.plannerDebt`.
            .collection(.planner, "Planner", in: model, symbol: "chart.xyaxis.line",
                        children: PlanningView.Tool.allCases.map {
                            .instance($0.selection, in: model)
                        }),
            .collection(.budgets, "Budgets", in: model, symbol: "chart.bar.doc.horizontal",
                        children: model.budgets.map { .instance(.budget($0.id), in: model) }),
            .collection(.goals, "Savings Goals", in: model, symbol: "target",
                        children: model.savingsGoals.map { .instance(.goal($0.id), in: model) }),
            .collection(.scheduled, "Scheduled", in: model, symbol: "calendar.badge.clock",
                        children: model.scheduledTransactions.map {
                            .instance(.scheduledTransaction($0.id), in: model)
                        }),
        ])]
    }

    private static func business(_ model: AppModel) -> [SidebarGroup] {
        var groups: [SidebarGroup] = [
            .untitled([
                .collection(.business, "Business", in: model, symbol: "building.2"),
                .collection(.timeMileage, "Time & Mileage", in: model, symbol: "clock.badge.checkmark"),
            ]),
        ]
        // Business stays thin until invoices and payees fill it — expected
        // rather than a gap (navigation-design §6). An empty collection is
        // simply absent; nothing is disabled, which is what HIG *Tab bars*
        // warns against for areas.
        if !model.businessInvoices.isEmpty {
            groups.append(.titled("invoices", "Invoices & Bills",
                                  model.businessInvoices.map { invoice in
                                      .instance(.invoice(invoice.guid), in: model,
                                                detail: invoice.owner.displayName)
                                  }))
        }
        if !model.businessCustomers.isEmpty {
            groups.append(.titled("customers", "Customers",
                                  model.businessCustomers.map { .instance(.customer($0.guid), in: model) }))
        }
        if !model.businessVendors.isEmpty {
            groups.append(.titled("vendors", "Vendors",
                                  model.businessVendors.map { .instance(.vendor($0.guid), in: model) }))
        }
        if !model.businessJobs.isEmpty {
            groups.append(.titled("jobs", "Jobs",
                                  model.businessJobs.map { .instance(.job($0.guid), in: model) }))
        }
        if !model.businessEmployees.isEmpty {
            // An employee's name lives on their address; the username is the
            // fallback the hub already uses when it is blank.
            groups.append(.titled("employees", "Employees",
                                  model.businessEmployees.map { employee in
                                      .instance(.employee(employee.guid), in: model)
                                  }))
        }
        return groups
    }

    private static func records(_ model: AppModel) -> [SidebarGroup] {
        [.untitled([
            .collection(.rules, "Rules", in: model, symbol: "wand.and.stars",
                        children: model.ruleGroups.map { .instance(.ruleGroup($0.id), in: model) }),
            .collection(.emergencyRecords, "Emergency Records", in: model, symbol: "cross.case",
                        children: model.emergencyRecords.map {
                            .instance(.emergencyRecord($0.id), in: model)
                        }),
            // The book's own history: a collection, which is why it is a
            // destination now rather than the modal sheet it used to be.
            .collection(.auditLog, "Audit Log", in: model, symbol: "clock.arrow.circlepath"),
        ])]
    }
}


/// One account row, shared by the tree, the favourites band and the filtered
/// flat list — so all three look and read the same.
struct AccountSidebarRow: View {
    let node: AccountNode
    let label: String

    var body: some View {
        HStack {
            // GnuCash account colour, shown Finder-tag style.
            if let dot = node.color.flatMap(GnuCashColor.color(from:)) {
                Circle()
                    .fill(dot)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(label)
                .scaledFont(.body)
                .foregroundStyle(node.isHidden ? .secondary : .primary)
            Spacer()
            Text(AmountFormat.string(node.balance, code: node.currencyCode))
                .scaledFont(.body)
                .monospacedDigit()
                .foregroundStyle(node.balance < 0 ? Color.negativeAmount : Color.secondary)
        }
        .tag(SidebarSelection.account(node.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(AmountFormat.string(node.balance, code: node.currencyCode))
    }
}

/// Live state for a sidebar drag.
///
/// Shared down the tree because a drag crosses levels: the row you picked up
/// and the row you are hovering are usually in different `AccountBranch`
/// instances, and each level is its own view.
@Observable
@MainActor
final class AccountDragState {
    /// Where a drop would land, and what it would mean.
    enum Zone: Equatable { case before, onto, after }

    var dragging: GncGUID?
    var target: (id: GncGUID, zone: Zone)?

    func zone(for id: GncGUID) -> Zone? {
        target?.id == id ? target?.zone : nil
    }

    func clear() {
        dragging = nil
        target = nil
    }
}

/// One level of the account tree, recursing into its children.
///
/// A view type rather than a `@ViewBuilder` function because it is recursive,
/// and an opaque `some View` cannot be defined in terms of itself.
///
/// **Two drops, two meanings, drawn differently** (`FR-NAV-12`,
/// navigation-design §4.6). The top and bottom quarters of a row reorder —
/// setting the manual order in the account's kvp — and the middle re-parents,
/// which is a book edit. That distinction only works if it is visible *while*
/// dragging, which is why this uses a `DropDelegate`: `dropUpdated(info:)`
/// reports the pointer's position during the hover, where `.dropDestination`
/// hands over a location only once the drop has already happened.
///
/// The first attempt wired only the re-parent half, and the result was a
/// gesture that looked like sorting and quietly moved accounts to new parents.
/// A reorder now draws an insertion line and a re-parent fills the row, so the
/// two can never be confused for one another.
///
/// Offered only under manual order: dropping something "between" a sorted list
/// is a promise the sort breaks on the next redraw.
struct AccountBranch: View {
    @Bindable var model: AppModel
    let nodes: [AccountNode]
    let canReorder: Bool
    let drag: AccountDragState

    var body: some View {
        ForEach(nodes) { node in
            Group {
                if let children = node.children, !children.isEmpty {
                    DisclosureGroup {
                        AccountBranch(model: model, nodes: children,
                                      canReorder: canReorder, drag: drag)
                    } label: {
                        row(node)
                    }
                } else {
                    row(node)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ node: AccountNode) -> some View {
        if canReorder {
            AccountSidebarRow(node: node, label: node.name)
                .modifier(AccountDropFeedback(zone: drag.zone(for: node.id)))
                .onDrag {
                    drag.dragging = node.id
                    return NSItemProvider(
                        item: node.id.hexString.data(using: .utf8) as NSData?,
                        typeIdentifier: UTType.finvestLensAccountRow.identifier)
                }
                .onDrop(of: [UTType.finvestLensAccountRow],
                        delegate: AccountRowDrop(node: node, siblings: nodes,
                                                 model: model, drag: drag))
        } else {
            AccountSidebarRow(node: node, label: node.name)
        }
    }
}

/// What a drop would do, drawn.
///
/// An insertion line for a reorder, a filled row for a re-parent — the two
/// operations must never look the same, because one of them edits the book.
private struct AccountDropFeedback: ViewModifier {
    let zone: AccountDragState.Zone?

    func body(content: Content) -> some View {
        content
            .background {
                if zone == .onto {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.appAccent.opacity(0.25))
                }
            }
            .overlay(alignment: .top) { line(shown: zone == .before) }
            .overlay(alignment: .bottom) { line(shown: zone == .after) }
    }

    @ViewBuilder
    private func line(shown: Bool) -> some View {
        if shown {
            Rectangle().fill(.tint).frame(height: 2)
        }
    }
}

/// Decides which of the three things a drop means, and says so while hovering.
struct AccountRowDrop: DropDelegate {
    let node: AccountNode
    let siblings: [AccountNode]
    let model: AppModel
    let drag: AccountDragState

    /// A row is short, so the re-parent zone gets the middle half and each
    /// insertion zone a quarter. Aiming at "between" is the fiddlier of the
    /// two, and it is the harmless one.
    static func zone(atY y: CGFloat, height: CGFloat) -> AccountDragState.Zone {
        if y < height * 0.25 { return .before }
        if y > height * 0.75 { return .after }
        return .onto
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = drag.dragging else { return false }
        // Nothing may be dropped on itself, and an account may not be dropped
        // into its own subtree — `moveAccount` refuses that too, but refusing
        // it here means the feedback never promises something impossible.
        if dragged == node.id { return false }
        return !isDescendant(node.id, ofOrEqualTo: dragged)
    }

    func dropEntered(info: DropInfo) { dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // `DropInfo` has no size, so the row height is taken from the metrics
        // the sidebar draws with rather than measured per row — every account
        // row is the same height.
        drag.target = (node.id, Self.zone(atY: info.location.y, height: Self.rowHeight))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if drag.target?.id == node.id { drag.target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { drag.clear() }
        guard let dragged = drag.dragging, dragged != node.id else { return false }
        switch drag.target?.zone ?? .onto {
        case .onto:
            return model.moveAccount(dragged, under: node.id)
        case .before, .after:
            // Between siblings only. Dropping between two rows of *another*
            // parent is a re-parent wearing a reorder's clothes, so it moves
            // the account there first and then orders it.
            if !siblings.contains(where: { $0.id == dragged }) {
                let parent = model.book?.account(with: node.id)?.parent?.guid
                guard model.moveAccount(dragged, under: parent) else { return false }
            }
            // The row it was dropped against, not an index into the rows on
            // screen: hidden siblings do not appear here but do appear in the
            // level being reordered, so any integer computed from this list
            // meant something different by the time it arrived.
            model.reorderAccount(dragged, drag.target?.zone == .after
                                 ? .after(node.id) : .before(node.id))
            return true
        }
    }

    /// Whether `candidate` is `ancestor` or sits under it.
    private func isDescendant(_ candidate: GncGUID, ofOrEqualTo ancestor: GncGUID) -> Bool {
        guard let account = model.book?.account(with: candidate) else { return false }
        var walk: Account? = account
        while let current = walk {
            if current.guid == ancestor { return true }
            walk = current.parent
        }
        return false
    }

    /// One sidebar row's height. `List` rows are uniform here, and `DropInfo`
    /// carries a location but not a size.
    static let rowHeight: CGFloat = 24
}
