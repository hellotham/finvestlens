//
//  CompactShell.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The app in the compact shell — the phone, and an iPad window narrowed by
//  multitasking (`FR-PLT-01`; PRD §8 "iOS": "compact, navigation-stack UI
//  optimized for quick transaction entry and review").
//
//  The regular shell is a split view with the modes on a row of their own
//  (navigation-design §4.1). Neither survives 440 points: seven mode buttons
//  do not fit a row, and a sidebar has nowhere to stand beside a detail pane.
//  The HIG's answer for a phone is a tab bar — *Tab bars*: "A tab bar lets
//  people navigate between top-level sections of your app … while preserving
//  the current navigation state within each section" — so the four modes most
//  used are tabs, each a `NavigationStack` whose root is what the sidebar
//  listed: the account tree, the holdings; Dashboard and Reports show their
//  board and gallery in the root itself. The destinations are the same views
//  the iPad shows beside its sidebar; only the container changes.
//
//  **Seven modes, five tabs.** *Tab bars* says "Avoid overflow tabs … The More
//  tab makes it harder for people to reach and notice content on tabs that
//  are hidden", and the same page forbids the other way out ("Don't disable
//  or hide tab bar buttons"). So nothing overflows and nothing is hidden: the
//  fifth tab is this app's own **More**, one list of everything Business,
//  Planning and Records hold, each row one tap from its destination — a level
//  shallower than a tab per mode would be, and without the second navigation
//  bar the system's overflow tab puts above a stack of its own (seen in the
//  first build of this shell, 11 Oct 2026).
//

#if os(iOS)
import SwiftUI
import FinvestLensEngine

/// The tabs of the compact shell: one per primary mode, and More.
enum CompactTab: Hashable {
    case dashboard, accounts, investments, reports, more

    static let primaryModes: [AppMode] = [.dashboard, .accounts, .investments, .reports]
    static let moreModes: [AppMode] = [.business, .planning, .records]

    init(_ mode: AppMode) {
        switch mode {
        case .dashboard: self = .dashboard
        case .accounts: self = .accounts
        case .investments: self = .investments
        case .reports: self = .reports
        case .business, .planning, .records: self = .more
        }
    }

    /// The mode a primary tab shows; `nil` for More, which shows three.
    var mode: AppMode? {
        switch self {
        case .dashboard: .dashboard
        case .accounts: .accounts
        case .investments: .investments
        case .reports: .reports
        case .more: nil
        }
    }
}

/// The tab bar and its stacks.
///
/// **Who decides what is showing.** The stacks do: each tab's `path` is the
/// list of *pages* pushed in it, and the model is kept on the page on top of
/// the tab in front (`modelFollowsShell`). When something else moves the
/// model — a board card, Show in Register, a holding's Get Info — the stacks
/// catch up (`shellFollowsModel`): the page is pushed, or the stack returns to
/// it if it is already there, and its tab comes forward. Both directions end
/// with the model on the top page, so neither can set the other off again.
///
/// A *page* is coarser than a selection (`SidebarSelection.compactPage`): the
/// Planner is one page whichever of its three tools is showing, Budgets is
/// one page whichever budget is in focus. The view reads the finer focus
/// from the model, as it does in the regular shell, and choosing it never
/// pushes a second copy of the page.
struct CompactShell: View {
    @Bindable var model: AppModel
    @State private var tab = CompactTab.dashboard
    @State private var paths: [CompactTab: [SidebarSelection]] = [:]

    var body: some View {
        TabView(selection: $tab) {
            ForEach(CompactTab.primaryModes) { mode in
                Tab(mode.title, systemImage: mode.symbol, value: CompactTab(mode)) {
                    NavigationStack(path: path(CompactTab(mode))) {
                        CompactModeRoot(model: model, mode: mode, isActive: tab == CompactTab(mode))
                            .modifier(CompactDestinations(model: model))
                    }
                    .overlay(alignment: .bottom) { StatusOverlay(model: model) }
                }
            }
            Tab("More", systemImage: "ellipsis", value: CompactTab.more) {
                NavigationStack(path: path(.more)) {
                    CompactMoreRoot(model: model, isActive: tab == .more)
                        .modifier(CompactDestinations(model: model))
                }
                .overlay(alignment: .bottom) { StatusOverlay(model: model) }
            }
        }
        .onAppear {
            model.compactNavigation = true
            shellFollowsModel()
        }
        .onDisappear { model.compactNavigation = false }
        .onChange(of: model.sidebarSelection) { shellFollowsModel() }
        .onChange(of: model.mode) { shellFollowsModel() }
        .onChange(of: tab) { tabChanged() }
        .onChange(of: paths) { modelFollowsShell() }
    }

    private func path(_ tab: CompactTab) -> Binding<[SidebarSelection]> {
        Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })
    }

    /// A tab came forward — chosen by hand, or brought by `shellFollowsModel`.
    private func tabChanged() {
        if let mode = tab.mode, !mode.pushesSelections {
            // Dashboard and Reports hold their own selection — which board
            // view, which report — so the mode simply comes forward with it.
            if model.mode != mode { model.showMode(mode) } else { model.searchQuery = "" }
        } else {
            model.searchQuery = ""
            modelFollowsShell()
        }
    }

    /// Puts the model on the page on top of the tab in front.
    private func modelFollowsShell() {
        let path = paths[tab] ?? []
        let wanted: SidebarSelection
        if let top = path.last {
            wanted = top
        } else if let mode = tab.mode, mode.pushesSelections {
            wanted = mode.defaultSelection   // the root list is the mode's home
        } else {
            return   // a board or gallery keeps its own; More's list is no page
        }
        let hosting = AppMode(hosting: wanted)
        if model.selection(in: hosting).compactPage == wanted.compactPage {
            // Already there — perhaps with a finer focus (a planner tool, one
            // budget), which is the model's to keep. Only the mode may need
            // bringing forward, as when a tab is returned to.
            if model.mode != hosting { model.mode = hosting }
            return
        }
        model.navigate(to: wanted)
        if model.selection(in: hosting).compactPage != wanted.compactPage, !path.isEmpty {
            // Refused — a group that is only a placeholder has no register.
            // The page comes back off rather than sit there empty.
            paths[tab] = Array(path.dropLast())
        }
    }

    /// Brings the stacks to where the model has gone.
    private func shellFollowsModel() {
        guard let selection = model.sidebarSelection else { return }
        let mode = model.mode
        if case .panel(let panel) = selection {
            // A panel tab — restored from a session, or left in front by the
            // regular shell before the window narrowed — is a sheet here.
            model.navigate(to: mode.defaultSelection)
            model.presentedPanel = panel
            return
        }
        let target = CompactTab(mode)
        if mode.pushesSelections {
            var path = paths[target] ?? []
            if let index = path.lastIndex(where: { $0.compactPage == selection.compactPage }) {
                path = Array(path[...index])   // on that page already, or back to it
            } else if target != .more, selection == mode.defaultSelection {
                path = []                      // home is the root list
            } else {
                path.append(selection)
            }
            if paths[target] != path { paths[target] = path }
        }
        if tab != target { tab = target }
    }
}

/// The page a selection is shown on in the compact shell — what a stack
/// pushes once. Selections that the regular shell draws with one view,
/// focused differently, share a page; every account and every security is a
/// page of its own. Exhaustive on purpose: a new kind of selection has to say
/// which page it belongs to before it compiles.
enum CompactPage: Hashable {
    case board, journal, account(GncGUID), holdings, portfolio(GncGUID), security(String)
    case reports, business, timeMileage, planner, budgets, goals, scheduled
    case rules, emergencyRecords, auditLog, panel(RootPanel)
}

extension SidebarSelection {
    var compactPage: CompactPage {
        switch self {
        case .dashboard, .overviewView, .overviewCard: .board
        case .generalLedger: .journal
        case .account(let id): .account(id)
        case .investments: .holdings
        case .portfolio(let id): .portfolio(id)
        case .security(let key): .security(key)
        case .reports, .report, .savedReport: .reports
        case .business, .invoice, .customer, .vendor, .job, .employee: .business
        case .timeMileage: .timeMileage
        case .planner, .plannerDebt, .plannerLifetime, .plannerTax: .planner
        case .budgets, .budget: .budgets
        case .goals, .goal: .goals
        case .scheduled, .scheduledTransaction: .scheduled
        case .rules, .ruleGroup: .rules
        case .emergencyRecords, .emergencyRecord: .emergencyRecords
        case .auditLog: .auditLog
        case .panel(let panel): .panel(panel)
        }
    }
}

/// What a pushed row shows: the regular shell's destination, titled — a stack
/// has no sidebar or tab strip to name it.
private struct CompactDestinations: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.navigationDestination(for: SidebarSelection.self) { selection in
            DestinationContent(model: model, selection: selection)
                .environment(\.isEmbeddedDestination, true)
                .navigationTitle(model.tabTitle(for: selection))
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension AppMode {
    /// Dashboard and Reports draw their collection in the root itself — the
    /// board, the gallery — and switch what it shows in place, so a selection
    /// there never pushes. Every other mode's root is a list and its
    /// selections are pages.
    var pushesSelections: Bool {
        switch self {
        case .dashboard, .reports: false
        case .accounts, .investments, .business, .planning, .records: true
        }
    }
}

/// Search, shared by every root: the field, and the results in place of the
/// root while a query is typed on the tab that is showing.
private struct CompactSearch: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.searchable(text: $model.searchQuery, prompt: Text("Search transactions"))
    }
}

/// The root of a primary mode's stack: the board, the report gallery, or the
/// rows the sidebar would have listed. Search results replace it while a
/// query is typed here, the way they replace the detail pane in the regular
/// shell.
struct CompactModeRoot: View {
    @Bindable var model: AppModel
    let mode: AppMode
    let isActive: Bool

    var body: some View {
        Group {
            if model.isSearching, isActive {
                SearchResultsView(model: model)
            } else {
                switch mode {
                case .dashboard: DashboardView(model: model)
                case .reports: ReportsHome(model: model)
                case .accounts: CompactAccountsList(model: model)
                case .investments, .business, .planning, .records:
                    List { CompactModeSections(model: model, mode: mode, namesMode: false) }
                        .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle(openReportTitle.map(Text.init(verbatim:)) ?? Text(mode.title))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CompactSearch(model: model))
        .toolbar {
            // An open report brings its own bar — back to the gallery,
            // favourite, export, share — and its own period control beneath.
            // The root's items on top of those left a 6.3-inch phone no room
            // for the title, so they step aside while a report is showing.
            if openReportTitle == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    if mode == .dashboard {
                        overviewViewsMenu
                    }
                    if mode.usesPeriod {
                        PeriodSelector(model: model, period: $model.period)
                    }
                    NewItemMenu(model: model)
                }
            }
        }
    }

    /// The open report's name, while the Reports root is showing one rather
    /// than the gallery — the title, since a stack has no tab strip to say.
    private var openReportTitle: String? {
        guard mode == .reports, model.mode == .reports, let selection = model.sidebarSelection else { return nil }
        switch selection {
        case .report, .savedReport: return model.tabTitle(for: selection)
        default: return nil
        }
    }

    /// The Overview views the sidebar lists on the iPad — the standard ones
    /// and any saved from the board — as a menu, since the phone's Dashboard
    /// root is the board and has no sidebar to list them.
    private var overviewViewsMenu: some View {
        Menu {
            ForEach(OverviewView.standards) { view in
                viewButton(view)
            }
            let custom = model.customOverviewViews
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { view in
                    viewButton(view)
                }
            }
        } label: {
            Label("Views", systemImage: "square.grid.2x2")
        }
        .accessibilityLabel("Overview views")
        .accessibilityValue(model.currentOverviewView.displayName)
    }

    private func viewButton(_ view: OverviewView) -> some View {
        Button {
            model.navigate(to: .overviewView(view.id))
        } label: {
            if view.id == model.currentOverviewView.id {
                Label(view.displayName, systemImage: "checkmark")
            } else {
                Text(view.displayName)
            }
        }
    }
}

/// The More tab's root: Business, Planning and Records as the sections of one
/// list, each row what the sidebar lists for that mode.
struct CompactMoreRoot: View {
    @Bindable var model: AppModel
    let isActive: Bool

    var body: some View {
        Group {
            if model.isSearching, isActive {
                SearchResultsView(model: model)
            } else {
                List {
                    ForEach(CompactTab.moreModes) { mode in
                        CompactModeSections(model: model, mode: mode, namesMode: true)
                    }
                    // App-wide, so below every mode's rows. Until 12 Oct 2026
                    // the phone could reach neither.
                    Section {
                        Button("Settings", systemImage: "gearshape") { model.showingSettings = true }
                        Button("Help", systemImage: "questionmark.circle") { model.showingHelp = true }
                    }
                    // The phone has no File menu, so until 17 Oct 2026 a book
                    // once open — and session restore opens one at every
                    // launch — could not be left: no other book, no new one,
                    // no Open from Box…, all of which are on the welcome
                    // screen this goes back to. Saved first; closing is one of
                    // the explicit saves that sends a book from Box up.
                    Section {
                        Button("Close Book", systemImage: "xmark.circle") { Task { await model.saveAndClose() } }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CompactSearch(model: model))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NewItemMenu(model: model)
            }
        }
    }
}

/// The sidebar's rows for a mode, as the sections of a list of navigation
/// links. Collections with children open as disclosure groups whose own row
/// still navigates. With `namesMode`, the mode's first section is headed by
/// the mode's own name — for a list that holds more than one mode.
struct CompactModeSections: View {
    @Bindable var model: AppModel
    let mode: AppMode
    let namesMode: Bool

    private var groups: [SidebarGroup] {
        let sort = model.sidebarSort(for: mode)
        return ModeSidebarRows.groups(for: mode, model: model).map {
            SidebarGroup(id: $0.id, key: $0.key, text: $0.text,
                         rows: model.sortedRows($0.rows, by: sort))
        }
    }

    var body: some View {
        ForEach(groups) { group in
            Section {
                rows(group)
            } header: {
                if let key = group.key {
                    Text(key)
                } else if let text = group.text {
                    Text(text)
                } else if namesMode {
                    Label(mode.title, systemImage: mode.symbol)
                }
            }
        }
    }

    private func rows(_ group: SidebarGroup) -> some View {
        ForEach(group.rows) { row in
            if let children = row.children, !children.isEmpty {
                DisclosureGroup {
                    ForEach(children) { child in link(child) }
                } label: {
                    link(row)
                }
            } else {
                link(row)
            }
        }
    }

    private func link(_ row: SidebarRow) -> some View {
        NavigationLink(value: row.id) {
            HStack {
                if let symbol = row.symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
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
        }
    }
}

/// The account tree as navigation links: All Transactions first, then the
/// favourites, then the tree with groups as disclosure rows — the same order
/// and the same hidden-accounts preference as the sidebar, without the
/// drag-to-reorder that needs a pointer. A group that is a placeholder has no
/// register to open (the model refuses it, as the sidebar does), so its row
/// only discloses.
struct CompactAccountsList: View {
    @Bindable var model: AppModel
    @AppStorage("showHiddenAccounts") private var showHidden = false

    private var tree: [AccountNode] {
        model.sidebarTree(showingHidden: showHidden, sortedBy: model.sidebarSort(for: .accounts))
    }

    var body: some View {
        List {
            Section {
                NavigationLink(value: SidebarSelection.generalLedger) {
                    Label("All Transactions", systemImage: "text.book.closed")
                        .scaledFont(.body)
                }
            }
            let favourites = model.favouriteAccountNodes
            if !favourites.isEmpty {
                Section("Favourites") {
                    ForEach(favourites) { node in
                        NavigationLink(value: SidebarSelection.account(node.id)) {
                            AccountSidebarRow(node: node, label: node.name)
                        }
                    }
                }
            }
            Section("Accounts") {
                CompactAccountBranch(nodes: tree)
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct CompactAccountBranch: View {
    let nodes: [AccountNode]

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children, !children.isEmpty {
                DisclosureGroup {
                    CompactAccountBranch(nodes: children)
                } label: {
                    if node.isPlaceholder {
                        AccountSidebarRow(node: node, label: node.name)
                    } else {
                        link(node)
                    }
                }
            } else {
                link(node)
            }
        }
    }

    private func link(_ node: AccountNode) -> some View {
        NavigationLink(value: SidebarSelection.account(node.id)) {
            AccountSidebarRow(node: node, label: node.name)
        }
    }
}
#endif
