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

    /// The mode's name as text, for a sentence that has to contain it — the
    /// board's "Open Accounts" button. Spelled out rather than derived from
    /// ``title``: a `LocalizedStringKey` cannot be interpolated into another
    /// string, and `String(localized:)` resolves against `Bundle.main`, where
    /// the app's single catalog lives.
    public var name: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .accounts: String(localized: "Accounts")
        case .investments: String(localized: "Investments")
        case .reports: String(localized: "Reports")
        case .business: String(localized: "Business")
        case .planning: String(localized: "Planning")
        case .records: String(localized: "Records")
        }
    }

    /// Whether the window's period selector governs anything in this mode.
    ///
    /// `FR-NAV-11` asks for one period control rather than a private one per
    /// screen, and two modes read it: the Overview board scopes its tiles by it
    /// (`DashboardView`), and Reports seeds every new report's configuration
    /// from it (`ReportKind.defaultConfiguration(for:)`), which is what makes a
    /// report agree with the board you were just looking at.
    ///
    /// The other five do not, and the control was shown in all seven — so in
    /// Accounts, Business, Planning and Records it was a live picker that
    /// changed the number beside it and nothing on screen. Each has its own
    /// reason to be excluded rather than wired:
    ///
    /// - **Accounts** — a register already has a date range, in the Filter
    ///   sheet, which is per-register and persists. A second date scope in the
    ///   toolbar would silently fight it.
    /// - **Investments** — holdings are valued as of today by definition, and
    ///   the chart window is its own persisted book preference
    ///   (`AppModel.sparkRange`) with ranges an accounting period has no names
    ///   for, like five years.
    /// - **Business** — invoices and aging are as-of, not for-a-period.
    /// - **Planning** — forward-looking, with each planner's own horizon.
    /// - **Records** — a document list, not a ledger view.
    public var usesPeriod: Bool {
        switch self {
        case .overview, .reports: return true
        case .accounts, .investments, .business, .planning, .records: return false
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
        // The Mix view, which *is* the board — not `.dashboard`, which no
        // Overview sidebar row carries. With `.dashboard` as the home, the
        // sidebar highlighted nothing at launch and clicking "Mix" opened a
        // second tab showing the identical board.
        case .overview: .overviewView("mix")
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
        // Overview's views and cards stay in Overview. Selecting one changes
        // what you see; it never changes where you are (navigation-design §4.3).
        case .dashboard, .overviewView, .overviewCard: self = .overview
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

    /// What this mode's sidebar can create.
    ///
    /// A sidebar that lists a collection has to be able to add to it — that is
    /// what a collection sidebar is for, and every one of these already had a
    /// creation path buried in its detail view. The `+` in the sidebar header
    /// is the same command, where the list is.
    public var creations: [SidebarCreation] {
        switch self {
        case .overview: [.overviewView]
        case .accounts: [.account]
        case .investments: [.security, .watchedSecurity]
        case .reports: []          // the catalogue is fixed; saved reports come from a report
        case .business: [.customer, .vendor, .invoice, .job, .employee]
        case .planning: [.budget, .goal, .scheduled]
        case .records: [.ruleGroup, .emergencyRecord]
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


/// Something a mode's sidebar can add to its collection (`FR-NAV-04`).
///
/// A request rather than a call: most of these open a sheet that belongs to the
/// detail view, which the sidebar cannot reach. The same shape as
/// `bankImportRequested` and the other cross-surface requests on `AppModel`.
public enum SidebarCreation: String, Identifiable, Hashable, Sendable {
    case account, security, budget, goal, scheduled, ruleGroup, emergencyRecord
    case customer, vendor, invoice, job, employee, watchedSecurity, overviewView

    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .account: "New Account…"
        case .security: "New Security…"
        case .budget: "New Budget"
        case .goal: "New Goal…"
        case .scheduled: "New Scheduled Transaction…"
        case .ruleGroup: "New Rule Group"
        case .emergencyRecord: "New Record…"
        case .customer: "New Customer…"
        case .vendor: "New Vendor…"
        case .invoice: "New Invoice…"
        case .job: "New Job…"
        case .employee: "New Employee…"
        case .watchedSecurity: "Watch a Security…"
        case .overviewView: "Save This View…"
        }
    }

    /// Where the sidebar goes before asking, so the new thing appears in a list
    /// the user is already looking at.
    var destination: SidebarSelection? {
        switch self {
        case .budget: .budgets
        case .goal: .goals
        case .scheduled: .scheduled
        case .ruleGroup: .rules
        case .emergencyRecord: .emergencyRecords
        case .customer, .vendor, .invoice, .job, .employee: .business
        case .watchedSecurity: .investments
        case .security: .investments
        case .account, .overviewView: nil
        }
    }
}
