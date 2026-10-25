//
//  InvestmentYield.swift
//  FinvestLens — Reports
//
//  What the four investment reports share, so that they agree: the portfolio
//  a security account belongs to, the security accounts a report covers, and
//  the one yield they all print — a gain as a simple annual rate on the money
//  that earned it, gain ÷ cost ÷ years held — so a parcel held eighteen months
//  and one held a week can be read against each other, and against a term
//  deposit's rate. Asked for on build 8: "an equivalent yield per annum based
//  on original purchase price."
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The account above a security account — a broker, a super fund, a pool —
/// which the Investments hub calls its portfolio. A portfolio is a shape in
/// the tree, not a type in the book (`AppModel.portfolioAccounts`).
public struct PortfolioRef: Hashable, Sendable {
    public let id: GncGUID
    public let name: String

    public init(id: GncGUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A parcel of a security as a yield sees it: what it cost, and how long it
/// was held inside the window a report looks at.
public struct HeldParcel: Hashable, Sendable {
    public var cost: Decimal
    public var years: Double

    public init(cost: Decimal, years: Double) {
        self.cost = cost
        self.years = years
    }
}

/// The yield every investment report prints, computed one way.
public enum InvestmentYield {

    /// A calendar year, the Gregorian mean — what the finance world
    /// annualises by.
    public static let daysPerYear = 365.25

    /// Years between two dates, by whole calendar days; never negative.
    public static func years(from start: Date, to end: Date) -> Double {
        Double(max(0, wholeCalendarDays(from: start, to: end))) / daysPerYear
    }

    /// The parcels' holding time weighted by what each cost — so a large
    /// parcel held two years and a small one held a month read as about two
    /// years, not a year each. `nil` when nothing was paid.
    public static func weightedYears(_ parcels: [HeldParcel]) -> Double? {
        let cost = parcels.reduce(0.0) { $0 + double($1.cost.magnitude) }
        guard cost > 0 else { return nil }
        let weighted = parcels.reduce(0.0) { $0 + double($1.cost.magnitude) * $1.years }
        return weighted / cost
    }

    /// `gain` as a simple annual rate on `cost` over `years`: the rate a
    /// deposit of the purchase price would have had to pay to match it. `nil`
    /// when nothing was paid or no time has passed — a parcel bought today has
    /// no rate, not an infinite one.
    public static func annualised(gain: Decimal, cost: Decimal, years: Double?) -> Double? {
        guard let years, years > 0, cost != 0 else { return nil }
        return double(gain) / double(cost.magnitude) / years
    }

    /// The rate for a set of holdings read together — a portfolio, or the
    /// whole report: their gains over their costs, over the cost-weighted
    /// time they were held. An item with no holding time (nothing paid, or
    /// an uncovered short with no purchase to date it from) has no part in
    /// the rate: neither its gain nor its cost, so the two stay matched.
    public static func combined(_ items: [(gain: Decimal, cost: Decimal, years: Double?)]) -> Double? {
        let dated = items.compactMap { item in
            item.years.map { (gain: item.gain, cost: item.cost, years: $0) }
        }
        let gain = dated.reduce(Decimal(0)) { $0 + $1.gain }
        let cost = dated.reduce(Decimal(0)) { $0 + $1.cost }
        let parcels = dated.map { HeldParcel(cost: $0.cost, years: $0.years) }
        return annualised(gain: gain, cost: cost, years: weightedYears(parcels))
    }

    static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
}

extension FinancialReports {

    /// The security accounts a report covers: every one in the book, or
    /// those directly under the portfolio `portfolioID` names.
    static func securityAccounts(_ book: Book, inPortfolio portfolioID: GncGUID?) -> [Account] {
        book.accounts.filter { account in
            account.type.isSecurityType && !account.isPlaceholder
                && (portfolioID == nil || account.parent?.guid == portfolioID)
        }
    }

    /// The portfolio `account` sits in — its parent — or `nil` for a security
    /// account kept at the top of the tree.
    static func portfolio(of account: Account) -> PortfolioRef? {
        guard let parent = account.parent, !parent.isRoot else { return nil }
        return PortfolioRef(id: parent.guid, name: parent.name)
    }

    /// Whether any parcel in `basis` has no date of its own — a pooled
    /// (average-cost) lot, or an uncovered short — and so is held from the
    /// first purchase (``firstAcquisition(of:in:)``), which only then needs
    /// looking up.
    static func pooledLots(_ basis: CostBasisResult) -> Bool {
        basis.openLots.contains { $0.acquisitionDate == nil }
            || basis.realizedGains.contains { $0.acquisitionDate == nil }
    }

    /// When `account`'s first parcel was bought: the date a pooled
    /// (average-cost) lot is held from, since it has no date of its own.
    static func firstAcquisition(of account: Account, in book: Book) -> Date? {
        book.splits(for: account).lazy
            .filter { $0.quantity > 0 && $0.reconcileState != .voided }
            .compactMap { $0.transaction?.datePosted }
            .min()
    }
}
