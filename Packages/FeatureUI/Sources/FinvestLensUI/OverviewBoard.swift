//
//  OverviewBoard.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Overview as a board of *views* (`FR-NAV-07` … `FR-NAV-10`).
//  Design: docs/navigation-design.md §4.3.
//
//  Overview is the app's front page: it opens there, and it reports across
//  every mode rather than about accounts. Its sidebar lists **views**, with
//  their cards nested underneath — section then instances, the same two-level
//  shape as every other mode — which means the sidebar doubles as the card
//  index and no separate "which cards are on this view?" affordance is needed.
//

import SwiftUI
import FinvestLensEngine

/// One card on the board.
///
/// Promoted out of `DashboardView` in P12/N4: the sidebar lists cards, so the
/// type can no longer be private to the view that draws them.
enum OverviewCard: String, Hashable, CaseIterable {
    case upNext
    case netWorth, income, expenses, cashflow, savingsRate, allocation, performance
    case spendingTrend, topMovers, goals, recentActivity, composition
    case alerts, bills, accounts, wellbeing
    /// The three modes that contributed nothing to the board (`FR-NAV-07`:
    /// "Every mode must be able to contribute at least one card, and the
    /// default board carries one from each"). Business was the one the
    /// requirement named outright; Reports and Records had no view at all, so
    /// their absence did not even show as an empty board.
    case receivables, reportsShortcut, recordsShortcut

    var minColumns: Int {
        switch self {
        case .upNext, .netWorth, .income, .expenses, .cashflow, .savingsRate, .alerts, .wellbeing: 1
        case .reportsShortcut, .recordsShortcut: 1
        case .allocation, .performance, .spendingTrend, .topMovers, .goals, .recentActivity, .bills: 2
        case .receivables: 2
        case .composition, .accounts: 3
        }
    }

    /// How many board rows the tile spans: charts and lists that need
    /// real space take two, glance figures take one.
    var units: Int {
        switch self {
        case .income, .expenses, .allocation, .performance,
             .accounts, .goals, .recentActivity: 2
        default: 1
        }
    }

    /// Resolved through the catalog rather than returned verbatim. These names
    /// reach `Text` as a `String` in three places now — the board's headings,
    /// the Cards menu and the Overview sidebar — and a `String` picks `Text`'s
    /// verbatim initializer, so every one of them was English-only.
    var title: String {
        switch self {
        case .upNext: String(localized: "Up Next")
        case .netWorth: String(localized: "Net Worth")
        case .income: String(localized: "Income")
        case .expenses: String(localized: "Expenses")
        case .cashflow: String(localized: "Cashflow")
        case .savingsRate: String(localized: "Savings Rate")
        case .allocation: String(localized: "Allocation")
        case .performance: String(localized: "Performance")
        case .spendingTrend: String(localized: "Spending Trend")
        case .topMovers: String(localized: "Top Movers")
        case .goals: String(localized: "Savings Goals")
        case .recentActivity: String(localized: "Recent Activity")
        case .composition: String(localized: "Net Worth Composition")
        case .alerts: String(localized: "Alerts")
        case .bills: String(localized: "Upcoming Bills")
        case .accounts: String(localized: "Accounts")
        case .wellbeing: String(localized: "Wellbeing")
        case .receivables: String(localized: "Receivables")
        case .reportsShortcut: String(localized: "Reports")
        case .recordsShortcut: String(localized: "Records")
        }
    }
}

extension OverviewCard {
    /// The mode this card reports on, or `nil` where it reports across all of
    /// them. Two jobs: it builds the standard views, and it is what a card's
    /// **"Open …"** button uses — the explicit door out of Overview.
    var mode: AppMode? {
        switch self {
        case .netWorth, .income, .expenses, .cashflow, .savingsRate,
             .accounts, .recentActivity, .composition, .spendingTrend:
            .accounts
        case .allocation, .performance, .topMovers:
            .investments
        case .goals, .bills, .wellbeing:
            .planning
        case .receivables:
            .business
        case .reportsShortcut:
            .reports
        case .recordsShortcut:
            .records
        case .upNext, .alerts:
            nil
        }
    }
}

/// A named selection of cards.
///
/// A view says *which* cards are eligible and in what priority; the board's
/// packing algorithm already decides placement from the window size, so a view
/// never needs to describe a layout. **A favourite is just a saved custom
/// view** — there is no separate concept (navigation-design §4.3).
struct OverviewView: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let cards: [String]
    /// Standard views are ours and are named from the catalog; custom ones are
    /// the user's and are shown verbatim.
    let isStandard: Bool

    var overviewCards: [OverviewCard] { cards.compactMap(OverviewCard.init(rawValue:)) }

    /// The catalog key for a standard view. Spelled out rather than built from
    /// `name`, so `-emit-localized-strings` can see it.
    var title: LocalizedStringKey? {
        guard isStandard else { return nil }
        switch id {
        case "overview": return "Overview"
        case "accounts": return "Accounts"
        case "investments": return "Investments"
        case "business": return "Business"
        case "planning": return "Planning"
        case "reports": return "Reports"
        case "records": return "Records"
        default: return nil
        }
    }

    /// The mode a view reports on — what its "Open …" button opens. `nil` for
    /// Mix, which reports across all of them and so has no single door.
    var mode: AppMode? {
        guard isStandard else { return nil }
        return AppMode(rawValue: id)
    }

    /// A standard view's *displayed* name, resolved through the catalog.
    ///
    /// `name` holds the English source so the id/name pair stays readable in
    /// storage; everything that shows it to a person goes through here. It went
    /// straight to `.navigationTitle` and to the tab strip before, so the window
    /// title read "Accounts" in eight languages while the sidebar row beside it
    /// read the translation.
    var displayName: String {
        guard isStandard else { return name }
        switch id {
        case "overview": return String(localized: "Overview")
        case "accounts": return String(localized: "Accounts")
        case "investments": return String(localized: "Investments")
        case "business": return String(localized: "Business")
        case "planning": return String(localized: "Planning")
        case "reports": return String(localized: "Reports")
        case "records": return String(localized: "Records")
        default: return name
        }
    }

    static func standard(_ id: String, _ name: String, _ cards: [OverviewCard]) -> OverviewView {
        OverviewView(id: id, name: name, cards: cards.map(\.rawValue), isStandard: true)
    }

    /// Every card, in board priority — the **Overview** view, and the fallback
    /// for a stored view whose id no longer exists.
    ///
    /// Renamed 16 Aug 2026: the mode is *Dashboard* and its every-card view is
    /// *Overview*, which reads better than a mode called Overview holding a
    /// view called Mix. The stored id stays `"overview"` so no desk state migrates —
    /// only what a reader sees changed.
    static let everything = standard("overview", "Overview", OverviewCard.allCases)

    /// Views named after modes. §4.3 is explicit that choosing one does **not**
    /// switch mode: the sidebar would then be doing navigation *and* data, the
    /// exact conflation this redesign deletes from the account sidebar. The
    /// door out is the board's "Open …" button, and clicking *through* a card.
    static let standards: [OverviewView] = [
        everything,
        standard("accounts", "Accounts",
                 OverviewCard.allCases.filter { $0.mode == .accounts }),
        standard("investments", "Investments",
                 OverviewCard.allCases.filter { $0.mode == .investments }),
        standard("planning", "Planning",
                 OverviewCard.allCases.filter { $0.mode == .planning }),
        // Business held an empty view for a while — "so the gap is visible
        // rather than silently absent". `FR-NAV-07` calls the receivables card
        // a **Must**, so the gap is closed rather than displayed.
        standard("business", "Business",
                 OverviewCard.allCases.filter { $0.mode == .business }),
        standard("reports", "Reports",
                 OverviewCard.allCases.filter { $0.mode == .reports }),
        standard("records", "Records",
                 OverviewCard.allCases.filter { $0.mode == .records }),
    ]
}

@MainActor
extension AppModel {

    /// Standard views, then the user's own.
    var overviewViews: [OverviewView] { OverviewView.standards + customOverviewViews }

    /// Custom views. Desk state — a view is a way of looking, not an accounting
    /// fact — and per book, because which cards matter depends on the book.
    var customOverviewViews: [OverviewView] {
        get {
            // Decoded once per book, not once per read. `currentOverviewView`
            // reaches this nine times in one `DashboardView` body pass, one of
            // them inside the `GeometryReader` — so a window resize was reading
            // UserDefaults and running JSONDecoder on every frame.
            guard let key = customViewsKey else { return [] }
            if customViewsKeyCached == key { return customViewsCache }
            let decoded = UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([OverviewView].self, from: $0) } ?? []
            customViewsCache = decoded
            customViewsKeyCached = key
            return decoded
        }
        set {
            guard let key = customViewsKey else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            customViewsCache = newValue
            customViewsKeyCached = key
        }
    }

    private var customViewsKey: String? {
        documentURL.map { "overview.views:\($0.standardizedFileURL.path)" }
    }

    func overviewView(id: String) -> OverviewView {
        overviewViews.first { $0.id == id } ?? .everything
    }

    /// Saves the cards currently on the board as a view of the user's own.
    func saveOverviewView(named name: String, cards: [OverviewCard]) {
        var views = customOverviewViews
        // A UUID, not the view count. The count is reused after a delete, so
        // saving three views and deleting the first minted a duplicate id —
        // two sidebar rows with one tag, and one delete removing both. It also
        // keeps the id free of the "/" that separates view from card in the
        // stored `overviewCard:` form.
        let id = "custom-\(UUID().uuidString)"
        views.append(OverviewView(id: id, name: name,
                                  cards: cards.map(\.rawValue), isStandard: false))
        customOverviewViews = views
        navigate(to: .overviewView(id))
    }

    func deleteOverviewView(id: String) {
        customOverviewViews = customOverviewViews.filter { $0.id != id }
        if sidebarSelection == .overviewView(id) { navigate(to: .dashboard) }
    }

    /// The view the board is showing.
    var currentOverviewView: OverviewView {
        switch sidebarSelection {
        case .overviewView(let id): overviewView(id: id)
        // The card carries the view it was picked from, so closing it returns
        // to the board it came from rather than to whichever view happens to
        // list it first.
        case .overviewCard(let view, _): overviewView(id: view)
        default: .everything
        }
    }

    /// The card shown full-window, if one is (`FR-NAV-08`).
    var zoomedOverviewCard: OverviewCard? {
        guard case .overviewCard(_, let card) = sidebarSelection else { return nil }
        return OverviewCard(rawValue: card)
    }
}
