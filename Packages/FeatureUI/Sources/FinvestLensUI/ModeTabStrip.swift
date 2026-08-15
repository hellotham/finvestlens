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
                Button {
                    model.duplicateCurrentTab()
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(.callout)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .help("Open what is showing in a second tab")
                .accessibilityLabel("New tab")
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
        HStack(spacing: 4) {
            Text(model.tabTitle(for: selection))
                .scaledFont(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            // The home tab has no close button because it cannot be closed —
            // absent rather than disabled, so nothing invites a click that
            // will not work.
            if index > 0 {
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
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(index) }
        .contextMenu {
            if index > 0 {
                Button("Close Tab") { model.closeTab(index) }
            }
            Button("Close Other Tabs") { model.closeOtherTabs(keeping: index) }
                .disabled(model.openTabs.count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
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
            overviewView(id: id).name
        case .overviewCard(_, let card):
            OverviewCard(rawValue: card)?.title ?? String(localized: "Card")
        case .generalLedger: String(localized: "All Transactions")
        case .account(let id): accountName(id) ?? String(localized: "Account")
        case .reports: String(localized: "All Reports")
        case .report(let kind): kind.rawValue
        case .savedReport(let id):
            savedReports.first { $0.id == id }?.name ?? String(localized: "Report")
        case .investments: String(localized: "Portfolio")
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

    /// Closes everything in this mode except `index` — and the home tab, which
    /// is not a tab anyone opened.
    public func closeOtherTabs(keeping index: Int) {
        let keep = openTabs.indices.contains(index) ? openTabs[index] : nil
        // Descending, so each removal leaves the earlier indices where they are.
        for candidate in openTabs.indices.reversed() where candidate > 0 {
            if openTabs[candidate] != keep { closeTab(candidate) }
        }
    }
}
