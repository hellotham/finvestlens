//
//  ModeTabStrip.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Several open items within one mode (`FR-NAV-05`, `FR-NAV-06`).
//  Design: docs/navigation-design.md §4.5.
//
//  A **tabbed interface**, in the manner of a code editor — not macOS window
//  tabs. A window tab carries a whole window, so each would bring its own
//  sidebar and toolbar: three open registers would mean three copies of the
//  565-account tree, and switching tabs would switch modes. In-window tabs keep
//  one sidebar serving many open items, which is the requirement.
//

import SwiftUI
import FinvestLensEngine

/// The strip across the top of the detail pane.
struct ModeTabStrip: View {
    @Bindable var model: AppModel
    @Environment(\.appFontScale) private var appFontScale

    var body: some View {
        // Only ever a handful of tabs, so the strip is a plain `HStack` in a
        // scroll view rather than a lazy one — and it must stay that way: this
        // is the strip the attribute-graph risk in plan.md §13d names, and it
        // is safe precisely because the *content* of the inactive tabs is never
        // built, only their titles.
        ScrollView(.horizontal) {
            HStack(spacing: 1) {
                ForEach(Array(model.openTabs.enumerated()), id: \.offset) { index, selection in
                    tab(index: index, selection: selection)
                }
                // A rule before it, and a symbol that is about *tabs*.
                //
                // A bare `plus` was ambiguous and, worse, it was the sidebar's
                // symbol for "add an item to this collection" sitting a few
                // pixels away — so in Accounts it read as "new account".
                // Reported 16 Aug 2026: "a + button can mean anything, and I
                // would have thought 'add item to collection'." The stacked
                // rectangles say which kind of new thing this makes, and the
                // divider says it is not one of the tabs.
                Divider().frame(height: 14).padding(.horizontal, 4)
                // A menu, because a bare press had nothing honest to open.
                //
                // `openNewTab()` appended `mode.defaultSelection` — which *is*
                // the home tab, derived as tab 0 and never stored — so ⌘T made
                // a duplicate of it that `restoreNavigation` then filtered out
                // on reopen: a tab you could make but not keep. There is no
                // "blank tab" in this app to open instead; every tab shows one
                // of the mode's destinations. So the button offers them.
                Menu {
                    let candidates = model.unopenedTabDestinations
                    if candidates.isEmpty {
                        Text("Everything in this mode is already open")
                    } else {
                        ForEach(Array(candidates.prefix(AppModel.unopenedTabLimit)
                                          .enumerated()), id: \.offset) { _, selection in
                            Button(model.tabTitle(for: selection)) {
                                model.navigate(to: selection, inNewTab: true)
                            }
                        }
                        // Never a silent truncation: a menu that stops at
                        // twelve without saying so reads as "that is all there
                        // is", which in a 565-account book is badly wrong.
                        if candidates.count > AppModel.unopenedTabLimit {
                            Divider()
                            Text("More in the sidebar — double-click to open in a tab")
                        }
                    }
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .scaledFont(.callout)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 6)
                .help("New Tab (⌘T) — open another of this mode's items")
                .accessibilityLabel("New Tab")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .frame(height: 30 * appFontScale)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open tabs")
    }

    @ViewBuilder
    private func tab(index: Int, selection: SidebarSelection) -> some View {
        let isActive = index == model.activeTabIndex
        // A `Button`, not an `HStack` with `.onTapGesture`. A tap gesture is
        // activatable by VoiceOver but reachable by nothing else — no Tab stop,
        // no keyboard at all — so switching tabs would have been mouse-only.
        // ⌃⇥ and ⌃⇧⇥ cycle them from the View menu for the same reason.
        HStack(spacing: 4) {
            Button {
                model.selectTab(index)
            } label: {
                Text(model.tabTitle(for: selection))
                    .scaledFont(.callout)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            // Home and the standing tabs have no close button because they
            // cannot be closed — absent rather than disabled, so nothing
            // invites a click that will not work.
            if model.isClosableTab(index) {
                Button {
                    model.closeTab(index)
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(model.tabTitle(for: selection))")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            // The active tab is filled; the others are outlined rather than
            // invisible. With the strip now always on screen, a lone unfilled
            // title would have read as a heading — the outline is what says
            // "this is a tab, and there can be more of them".
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
                .strokeBorder(isActive ? AnyShapeStyle(.clear)
                                       : AnyShapeStyle(.separator), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if model.isClosableTab(index) {
                Button("Close Tab") { model.closeTab(index) }
            }
            Button("Close Other Tabs") { model.closeOtherTabs(keeping: index) }
                .disabled(model.openTabs.count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(model.tabTitle(for: selection))
    }
}

@MainActor
extension AppModel {

    /// What a tab calls itself.
    ///
    /// Returns a `String` rather than a `LocalizedStringKey` because most tabs
    /// are named by the *book* — an account, a budget, a security — and only
    /// the collection destinations have names of ours. `String(localized:)`
    /// resolves those against `Bundle.main`, which is where the app's single
    /// catalog lives, so both kinds arrive at `Text` already resolved and
    /// neither is looked up twice.
    func tabTitle(for selection: SidebarSelection) -> String {
        switch selection {
        case .dashboard: String(localized: "Overview")
        case .overviewView(let id):
            // A standard view's name is ours; a custom one is the user's, and
            // `name` already holds the right text for both.
            overviewView(id: id).displayName
        case .overviewCard(_, let card):
            OverviewCard(rawValue: card)?.title ?? String(localized: "Card")
        case .generalLedger: String(localized: "All Transactions")
        case .account(let id): accountName(id) ?? String(localized: "Account")
        case .reports: String(localized: "All Reports")
        case .report(let kind): kind.rawValue
        case .savedReport(let id):
            savedReports.first { $0.id == id }?.name ?? String(localized: "Report")
        case .investments: String(localized: "All Holdings")
        case .portfolio(let id): portfolioLabel(id)
        case .panel(let panel): panel.title
        case .security(let key):
            securityCommodity(forKey: key)?.mnemonic ?? String(localized: "Security")
        case .business: String(localized: "Business")
        case .timeMileage: String(localized: "Time & Mileage")
        case .invoice(let id):
            businessInvoices.first { $0.guid == id }.map { $0.id.isEmpty ? $0.owner.displayName : $0.id }
                ?? String(localized: "Invoice")
        case .customer(let id):
            businessCustomers.first { $0.guid == id }?.name ?? String(localized: "Customer")
        case .vendor(let id):
            businessVendors.first { $0.guid == id }?.name ?? String(localized: "Vendor")
        case .job(let id):
            businessJobs.first { $0.guid == id }?.name ?? String(localized: "Job")
        case .employee(let id):
            businessEmployees.first { $0.guid == id }
                .map { $0.address.name.isEmpty ? $0.username : $0.address.name }
                ?? String(localized: "Employee")
        case .planner: String(localized: "Planner")
        case .budgets: String(localized: "Budgets")
        case .budget(let id): budgets.first { $0.id == id }?.name ?? String(localized: "Budget")
        case .goals: String(localized: "Savings Goals")
        case .goal(let id): savingsGoals.first { $0.id == id }?.name ?? String(localized: "Goal")
        case .scheduled: String(localized: "Scheduled")
        case .scheduledTransaction(let id):
            scheduledTransactions.first { $0.id == id }?.name ?? String(localized: "Scheduled")
        case .rules: String(localized: "Rules")
        case .ruleGroup(let id):
            ruleGroups.first { $0.id == id }?.name ?? String(localized: "Rules")
        case .emergencyRecords: String(localized: "Emergency Records")
        case .emergencyRecord(let id):
            emergencyRecords.first { $0.id == id }?.title ?? String(localized: "Record")
        case .auditLog: String(localized: "Audit Log")
        }
    }

    /// A portfolio's tab name, qualified only when a bare name would be
    /// ambiguous.
    ///
    /// The reference book holds `Assets:Chris Tham:Investments` **and**
    /// `Assets:Lyn Cheah:Investments`. Two tabs both reading "Investments" name
    /// nothing, so where a name repeats it takes its parent's:
    /// "Chris Tham · Investments". Where it does not, the bare name is what a
    /// person calls it and the qualifier would be noise on all fifteen.
    func portfolioLabel(_ id: GncGUID) -> String {
        let all = portfolioAccounts
        guard let node = all.first(where: { $0.id == id }) else {
            return String(localized: "Portfolio")
        }
        guard all.filter({ $0.name == node.name }).count > 1 else { return node.name }
        // `fullName` is the colon path; the segment above this one is what
        // tells the two apart.
        let parts = node.fullName.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return node.name }
        return "\(parts[parts.count - 2]) · \(node.name)"
    }

    /// Moves to the next tab, wrapping — ⌃⇥, the shortcut macOS uses for this
    /// everywhere. `offset` of -1 is ⌃⇧⇥.
    public func cycleTab(by offset: Int) {
        let count = openTabs.count
        guard count > 1 else { return }
        selectTab(((activeTabIndex + offset) % count + count) % count)
    }

    /// Closes everything in this mode except `index` — and the home tab, which
    /// is not a tab anyone opened.
    public func closeOtherTabs(keeping index: Int) {
        let keep = openTabs.indices.contains(index) ? openTabs[index] : nil
        // Descending, so each removal leaves the earlier indices where they are.
        for candidate in openTabs.indices.reversed() where isClosableTab(candidate) {
            if openTabs[candidate] != keep { closeTab(candidate) }
        }
    }
}
