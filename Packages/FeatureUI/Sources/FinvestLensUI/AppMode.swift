//
//  AppMode.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The app's top-level areas (`FR-NAV-01`, `FR-NAV-02`).
//  Design: docs/navigation-design.md §4.1, §4.1a, §4.2.
//

import SwiftUI

/// A top-level area of the app.
///
/// Each mode owns a sidebar showing one kind of thing, its own selection, and
/// its own open tabs — so leaving a mode and coming back returns you where you
/// were rather than to a default (`FR-NAV-03`).
///
/// The membership test is deliberately narrow: **a mode is somewhere you work,
/// and it has a collection to work in**. Repair Book, Close Financial Year,
/// Import and Export are *commands*, and a sidebar full of commands is the menu
/// this design exists to remove — they stay in the menu bar. Rules are a
/// Records collection rather than a mode of their own: you almost never *go* to
/// Rules, you arrive from an import that categorised something wrongly
/// (navigation-design §4.2).
///
/// Declaration order is the order they are offered — ⌘1…⌘7, and the first five
/// are ``toolbarDefault``.
public enum AppMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, accounts, investments, reports, business, planning, records

    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .accounts: "Accounts"
        case .investments: "Investments"
        case .reports: "Reports"
        case .business: "Business"
        case .planning: "Planning"
        case .records: "Records"
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .accounts: "list.bullet.rectangle"
        case .investments: "chart.line.uptrend.xyaxis"
        case .reports: "chart.pie"
        case .business: "building.2"
        case .planning: "chart.xyaxis.line"
        case .records: "archivebox"
        }
    }

    /// ⌘1…⌘7. **Every** mode has one, including the two off the toolbar by
    /// default — an item in a menu with a shortcut is discoverable and
    /// permanent, which is precisely what an item behind a "More" menu is not
    /// (navigation-design §4.1a).
    public var shortcut: KeyEquivalent {
        // `allCases` is a compile-time constant, so the index always exists;
        // the fallback keeps this total rather than trapping.
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }

    /// Where a mode lands when it has no remembered selection.
    ///
    /// Accounts lands on All Transactions rather than a hub: Accounts is a
    /// *working* mode, and Overview already carries the reading layer for the
    /// whole app, so a second summary page here would duplicate it and delay
    /// the thing people came for (navigation-design §4.4).
    public var defaultSelection: SidebarSelection {
        switch self {
        case .overview: .dashboard
        case .accounts: .generalLedger
        case .investments: .investments
        case .reports: .reports
        case .business: .business
        case .planning: .planner
        case .records: .rules
        }
    }

    /// The mode a destination belongs to.
    ///
    /// This is both the migration map for desk state stored under the old flat
    /// ``SidebarSelection`` and what makes a menu command land in the right
    /// place — "Budget…" has to switch to Planning, not drop a Planning
    /// destination into whichever mode happened to be showing.
    public init(hosting selection: SidebarSelection) {
        switch selection {
        case .dashboard: self = .overview
        case .account, .generalLedger: self = .accounts
        case .investments, .security: self = .investments
        case .reports, .savedReport, .report: self = .reports
        // Billable time and mileage exist to be invoiced, so they belong beside
        // the invoices rather than in Records (navigation-design §4.2).
        case .business, .timeMileage, .invoice, .customer, .vendor, .job, .employee:
            self = .business
        case .budgets, .budget, .scheduled, .scheduledTransaction,
             .goals, .goal, .planner:
            self = .planning
        case .rules, .ruleGroup, .emergencyRecords, .emergencyRecord, .auditLog:
            self = .records
        }
    }

    /// The five modes on the toolbar out of the box.
    ///
    /// Planning and Records are modes in full — sidebar, tabs, state, a
    /// shortcut and a View menu item — but not everyone budgets. The HIG's own
    /// remedy for an app with "a lot of items — or … advanced functionality
    /// that not everyone needs" is toolbar customisation, not a More menu, and
    /// five keeps the default layout clear of the system's overflow menu, which
    /// *Toolbars* says to avoid by default (navigation-design §4.1a).
    public static let toolbarDefault: [AppMode] = [
        .overview, .accounts, .investments, .reports, .business,
    ]

    /// Whether this mode appears in the toolbar before the user customises it.
    public var isOnToolbarByDefault: Bool { Self.toolbarDefault.contains(self) }
}
