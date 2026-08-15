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

    /// A collection, or one of a mode's own destinations.
    static func collection(_ id: SidebarSelection, _ key: LocalizedStringKey,
                           symbol: String, detail: String? = nil,
                           children: [SidebarRow]? = nil) -> SidebarRow {
        SidebarRow(id: id, key: key, text: nil, symbol: symbol,
                   detail: detail, children: children)
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

    /// The plain-text name, for filtering and for VoiceOver on instance rows.
    /// Collections match on nothing here — their label is a catalog key that
    /// SwiftUI resolves at render time, so filtering against the English source
    /// would be wrong in seven of the eight languages.
    var searchText: String { text ?? "" }
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
            // Every mode, not just Accounts: name order means something over a
            // list of budgets or customers too, and a control that appears in
            // one sidebar and not the others is the inconsistency this phase
            // exists to remove.
            sortMenu
        }
        .padding(8)
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
        case .overview: "Filter views"
        case .accounts: "Filter accounts"
        case .investments: "Filter securities"
        case .reports: "Filter reports"
        case .business: "Filter business records"
        case .planning: "Filter plans"
        case .records: "Filter records"
        }
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        List(selection: $model.sidebarSelection) {
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

    /// Filters a mode's rows, keeping a collection whose *children* match so the
    /// match stays reachable.
    private func filtered(_ groups: [SidebarGroup]) -> [SidebarGroup] {
        guard !trimmedFilter.isEmpty else { return groups }
        let needle = trimmedFilter.lowercased()
        func matches(_ row: SidebarRow) -> SidebarRow? {
            let kept = (row.children ?? []).filter {
                $0.searchText.lowercased().contains(needle)
            }
            if !kept.isEmpty {
                var copy = row
                copy.children = kept
                return copy
            }
            return row.searchText.lowercased().contains(needle) ? row : nil
        }
        return groups.compactMap { group in
            let kept = group.rows.compactMap(matches)
            guard !kept.isEmpty else { return nil }
            return SidebarGroup(id: group.id, key: group.key, text: group.text, rows: kept)
        }
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
        if trimmedFilter.isEmpty {
            Section {
                Label("All Transactions", systemImage: "text.book.closed")
                    .tag(SidebarSelection.generalLedger)
            }
            // Pinned accounts, flat, in the order they were favourited — the
            // shortcut past three disclosure triangles for the handful of
            // registers someone lives in. Same row (and context menu) as the
            // tree, so selecting one is selecting the account.
            let favourites = model.favouriteAccountNodes
            if !favourites.isEmpty {
                Section("Favourites") {
                    ForEach(favourites) { node in
                        accountRow(node, label: node.name)
                    }
                }
            }
        }
        Section("Accounts") {
            if trimmedFilter.isEmpty {
                AccountBranch(model: model, nodes: visibleTree,
                              canReorder: accountSort.allowsDragging)
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
            Divider()
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
        switch mode {
        case .overview: overview(model)
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
                return .collection(.overviewView(view.id), key,
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
            .untitled([.collection(.investments, "Portfolio", symbol: "chart.pie")]),
        ]
        // Securities by type, using the grouping the book already carries:
        // GnuCash's commodity namespace (ASX, NASDAQ, FUND…). The exchange is
        // data, so its name is shown verbatim rather than looked up.
        let byNamespace = Dictionary(grouping: model.securityCommodities) { "\($0.namespace)" }
        for namespace in byNamespace.keys.sorted() {
            let holdings = (byNamespace[namespace] ?? [])
                .sorted { $0.mnemonic < $1.mnemonic }
                .map { security($0, model) }
            guard !holdings.isEmpty else { continue }
            groups.append(.named("ns-\(namespace)", namespace, holdings))
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
            .untitled([.collection(.reports, "All Reports", symbol: "square.grid.2x2")]),
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
            .collection(.planner, "Planner", symbol: "chart.xyaxis.line"),
            .collection(.budgets, "Budgets", symbol: "chart.bar.doc.horizontal",
                        children: model.budgets.map { .instance(.budget($0.id), in: model) }),
            .collection(.goals, "Savings Goals", symbol: "target",
                        children: model.savingsGoals.map { .instance(.goal($0.id), in: model) }),
            .collection(.scheduled, "Scheduled", symbol: "calendar.badge.clock",
                        children: model.scheduledTransactions.map {
                            .instance(.scheduledTransaction($0.id), in: model)
                        }),
        ])]
    }

    private static func business(_ model: AppModel) -> [SidebarGroup] {
        var groups: [SidebarGroup] = [
            .untitled([
                .collection(.business, "Business", symbol: "building.2"),
                .collection(.timeMileage, "Time & Mileage", symbol: "clock.badge.checkmark"),
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
            .collection(.rules, "Rules", symbol: "wand.and.stars",
                        children: model.ruleGroups.map { .instance(.ruleGroup($0.id), in: model) }),
            .collection(.emergencyRecords, "Emergency Records", symbol: "cross.case",
                        children: model.emergencyRecords.map {
                            .instance(.emergencyRecord($0.id), in: model)
                        }),
            // The book's own history: a collection, which is why it is a
            // destination now rather than the modal sheet it used to be.
            .collection(.auditLog, "Audit Log", symbol: "clock.arrow.circlepath"),
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
                .foregroundStyle(node.balance < 0 ? .red : .secondary)
        }
        .tag(SidebarSelection.account(node.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(AmountFormat.string(node.balance, code: node.currencyCode))
    }
}

/// One level of the account tree, recursing into its children.
///
/// A view type rather than a `@ViewBuilder` function because it is recursive,
/// and an opaque `some View` cannot be defined in terms of itself.
///
/// It exists at all because `OutlineGroup` has no move affordance: the
/// between-siblings reorder `FR-NAV-12` asks for had no drop target, so the only
/// drag that existed re-parented — a book edit from a gesture that looked like
/// sorting. `.onMove` is the system's own reorder, and it draws the insertion
/// line, which is exactly the "insertion line versus highlighted row" feedback
/// §4.6 asks for without this code drawing either.
///
/// Offered only under manual order: dropping something "between" a sorted list
/// is a promise the sort breaks on the next redraw.
struct AccountBranch: View {
    @Bindable var model: AppModel
    let nodes: [AccountNode]
    let canReorder: Bool

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children, !children.isEmpty {
                DisclosureGroup {
                    AccountBranch(model: model, nodes: children, canReorder: canReorder)
                } label: {
                    AccountSidebarRow(node: node, label: node.name)
                }
            } else {
                AccountSidebarRow(node: node, label: node.name)
            }
        }
        .onMove(perform: moveHandler)
    }

    /// Typed explicitly: a ternary inline in `.onMove` gave the type-checker
    /// nothing to anchor the optional to.
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard canReorder else { return nil }
        return { offsets, destination in move(from: offsets, to: destination) }
    }

    /// `.onMove` reports the destination *before* the removal, which is one
    /// more than the final index when moving down.
    private func move(from offsets: IndexSet, to destination: Int) {
        guard let source = offsets.first, nodes.indices.contains(source) else { return }
        model.reorderAccount(nodes[source].id, to: destination > source ? destination - 1 : destination)
    }
}
