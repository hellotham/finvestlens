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
        }
        .padding(8)
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
                ForEach(filtered(ModeSidebarRows.groups(for: model.mode, model: model))) { group in
                    section(group)
                }
            }
        }
        .contextMenu(forSelectionType: SidebarSelection.self) { selection in
            sidebarMenu(for: selection)
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
        showHidden ? model.accountTree : Self.pruningHidden(model.accountTree)
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
                OutlineGroup(visibleTree, children: \.children) { node in
                    accountRow(node, label: node.name)
                }
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

    /// Overview's board. N4 replaces this with views and their cards; until
    /// then it is the one destination the mode has.
    private static func overview(_ model: AppModel) -> [SidebarGroup] {
        [.untitled([.collection(.dashboard, "Overview", symbol: "square.grid.2x2")])]
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
                .map { security($0) }
            guard !holdings.isEmpty else { continue }
            groups.append(.named("ns-\(namespace)", namespace, holdings))
        }
        if !model.watchlist.isEmpty {
            groups.append(.titled("watchlist", "Watchlist", model.watchlist.map { security($0) }))
        }
        return groups
    }

    private static func security(_ commodity: Commodity) -> SidebarRow {
        .instance(.security(SidebarSelection.securityKey(commodity)),
                  commodity.mnemonic, detail: commodity.fullName)
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
                                  kinds.map { .instance(.report($0), $0.rawValue, symbol: $0.icon) }))
        }
        if !model.savedReports.isEmpty {
            groups.append(.titled("saved", "Saved",
                                  model.savedReports.map { .instance(.savedReport($0.id), $0.name) }))
        }
        return groups
    }

    private static func planning(_ model: AppModel) -> [SidebarGroup] {
        [.untitled([
            .collection(.planner, "Planner", symbol: "chart.xyaxis.line"),
            .collection(.budgets, "Budgets", symbol: "chart.bar.doc.horizontal",
                        children: model.budgets.map { .instance(.budget($0.id), $0.name) }),
            .collection(.goals, "Savings Goals", symbol: "target",
                        children: model.savingsGoals.map { .instance(.goal($0.id), $0.name) }),
            .collection(.scheduled, "Scheduled", symbol: "calendar.badge.clock",
                        children: model.scheduledTransactions.map {
                            .instance(.scheduledTransaction($0.id), $0.name)
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
                                      .instance(.invoice(invoice.guid),
                                                invoice.id.isEmpty ? invoice.owner.displayName : invoice.id,
                                                detail: invoice.owner.displayName)
                                  }))
        }
        if !model.businessCustomers.isEmpty {
            groups.append(.titled("customers", "Customers",
                                  model.businessCustomers.map { .instance(.customer($0.guid), $0.name) }))
        }
        if !model.businessVendors.isEmpty {
            groups.append(.titled("vendors", "Vendors",
                                  model.businessVendors.map { .instance(.vendor($0.guid), $0.name) }))
        }
        if !model.businessJobs.isEmpty {
            groups.append(.titled("jobs", "Jobs",
                                  model.businessJobs.map { .instance(.job($0.guid), $0.name) }))
        }
        if !model.businessEmployees.isEmpty {
            // An employee's name lives on their address; the username is the
            // fallback the hub already uses when it is blank.
            groups.append(.titled("employees", "Employees",
                                  model.businessEmployees.map { employee in
                                      .instance(.employee(employee.guid),
                                                employee.address.name.isEmpty
                                                    ? employee.username : employee.address.name)
                                  }))
        }
        return groups
    }

    private static func records(_ model: AppModel) -> [SidebarGroup] {
        [.untitled([
            .collection(.rules, "Rules", symbol: "wand.and.stars",
                        children: model.ruleGroups.map { .instance(.ruleGroup($0.id), $0.name) }),
            .collection(.emergencyRecords, "Emergency Records", symbol: "cross.case",
                        children: model.emergencyRecords.map {
                            .instance(.emergencyRecord($0.id), $0.title)
                        }),
            // The book's own history: a collection, which is why it is a
            // destination now rather than the modal sheet it used to be.
            .collection(.auditLog, "Audit Log", symbol: "clock.arrow.circlepath"),
        ])]
    }
}
