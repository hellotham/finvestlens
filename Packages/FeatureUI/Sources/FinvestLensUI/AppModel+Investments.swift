//
//  AppModel+Investments.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

// Phase I2 of the Investments hub (docs/investments-design.md §6): the rows and
// summaries the destination renders. The analysis itself lives in `Reports`
// (`FinancialReports.priceHealth`, I1); this file joins it to the lot engine's
// return figures, groups the result the way a person reads it, and memoises the
// join — computing health over the reference book costs ~1.1s, which is fine
// once per change and ruinous once per redraw.

/// Which band of the holdings list a security belongs in (`FR-INV-24`, `FR-INV-30`).
public enum InvestmentGroup: String, CaseIterable, Sendable {
    /// Held, and a provider can price it.
    case held
    /// Held, but no provider can — valued by hand, which is a category and not
    /// a failure.
    case manual
    /// On the watch list, not owned.
    case watching
    /// Owned once, not now. Hidden until asked for.
    case closed
}

/// One point of a holding's sparkline.
public struct SparkPoint: Identifiable, Hashable, Sendable {
    public var date: Date
    public var value: Double
    public var id: Date { date }
}

/// A contiguous run of priced days.
///
/// The sparkline is drawn as segments rather than one line so a gap reads as a
/// **break** (`FR-INV-12`). Joining across it would draw a straight line
/// through days nobody has a price for — inventing the very data whose absence
/// the chart is meant to show.
public struct SparkSegment: Identifiable, Hashable, Sendable {
    public var id: Int
    public var points: [SparkPoint]
}

/// One row of the holdings table (`FR-INV-11`).
public struct InvestmentRow: Identifiable, Sendable {
    public var id: String
    public var commodity: Commodity
    public var symbol: String
    public var name: String
    public var group: InvestmentGroup

    public var units: Decimal
    public var price: Decimal?
    public var marketValue: Decimal?
    /// Total return since holding — unrealised + realised + income ÷ money in.
    public var returnFraction: Double?
    public var allocation: Double?

    public var freshness: PriceFreshness
    public var tradingDaysBehind: Int
    public var lastPriceDate: Date?
    /// Trading days with no price inside a period this security was held.
    public var missingWhileHeld: Int
    public var spark: [SparkSegment]

    public var needsAttention: Bool {
        group == .held && (freshness == .old || freshness == .missing)
    }
}

/// A class of problem in the worklist, with the count and the fix (`FR-INV-13`).
public struct InvestmentIssue: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case unpriced       // held, never priced
        case stale          // held, more than a trading week behind
        case gaps           // holes inside a holding period
        case manualOverdue  // hand-valued and long past due
        case missingRate    // a holding's currency has no rate
    }
    public var id: String { kind.rawValue }
    public var kind: Kind
    public var count: Int
    public var symbols: [String]
}

/// FX-rate health, which is the same trust question as price health: a foreign
/// holding valued without a rate is silently wrong (`FR-INV-33`).
public struct RateHealth: Sendable {
    public var currencies: Int
    public var priced: Int
    public var missing: [String]
}

@MainActor
extension AppModel {

    // MARK: The analysis, memoised

    /// Whether a provider could price this commodity.
    ///
    /// Richer than the book's own `cmdty:get_quotes` flag, which is why
    /// `FinancialReports.priceHealth` takes this as a parameter: a ticker
    /// override set in this app is enough to make a security quotable even
    /// though GnuCash never marked it, and that mapping lives here, not in the
    /// Engine.
    public func canFetchQuotes(for commodity: Commodity) -> Bool {
        if commodity.getQuotes { return true }
        if let symbol = quoteSymbol(for: commodity), !symbol.isEmpty { return true }
        return false
    }

    /// Price health across the book (`FR-INV-09`), memoised on the book
    /// revision. Keyed on `endOfToday()` rather than `Date()`, or every redraw
    /// would be a cache miss and pay the full scan again.
    public func priceHealth() -> PortfolioPriceHealth? {
        guard let book, !securityCommodities.isEmpty || !watchlist.isEmpty else { return nil }
        let asOf = Self.endOfToday()
        return cachedReport("pxhealth:\(asOf.timeIntervalSinceReferenceDate)") {
            FinancialReports.priceHealth(book, currency: reportCurrency, asOf: asOf,
                                         quotable: { [self] in canFetchQuotes(for: $0) })
        }
    }

    /// The holdings table's rows, grouped and sorted (`FR-INV-11`).
    ///
    /// Sorted by market value descending within each group: the position that
    /// most affects whether the total is right belongs at the top, which is not
    /// what alphabetical order gives you.
    public func investmentRows(sparkDays: Int = 90) -> [InvestmentRow] {
        guard let book, let health = priceHealth() else { return [] }
        let asOf = Self.endOfToday()
        let advanced = advancedPortfolio(asOf: asOf)

        // Return and allocation come from the lot engine, per *account*; a
        // commodity can be held in more than one, so money-weight the returns
        // and sum the allocations rather than taking the first match.
        var returns: [String: (weight: Decimal, weighted: Double, allocation: Double)] = [:]
        for holding in advanced?.holdings ?? [] {
            let weight = abs(holding.marketValue ?? holding.costBasis)
            var entry = returns[holding.symbol] ?? (0, 0, 0)
            if let fraction = holding.returnFraction {
                entry.weighted += fraction * NSDecimalNumber(decimal: weight).doubleValue
                entry.weight += weight
            }
            entry.allocation += holding.allocation ?? 0
            returns[holding.symbol] = entry
        }

        let watched = Set(watchlist.map { "\($0.namespace)|\($0.mnemonic)" })
        let cutoff = Calendar.current.date(byAdding: .day, value: -sparkDays, to: Date()) ?? Date()
        let series = sparkSeries(book: book, since: cutoff)

        var rows: [InvestmentRow] = []
        for security in health.securities {
            let key = "\(security.commodity.namespace)|\(security.commodity.mnemonic)"
            let group: InvestmentGroup
            if security.isHeld {
                group = security.isQuotable ? .held : .manual
            } else if watched.contains(key) {
                group = .watching
            } else {
                group = .closed
            }
            let stats = returns[security.commodity.mnemonic]
            rows.append(InvestmentRow(
                id: key,
                commodity: security.commodity,
                symbol: security.commodity.mnemonic,
                name: security.commodity.fullName,
                group: group,
                units: security.units,
                price: book.securityUnitValue(security.commodity, in: reportCurrency, on: asOf),
                marketValue: security.marketValue,
                returnFraction: (stats?.weight ?? 0) == 0 ? nil
                    : (stats!.weighted / NSDecimalNumber(decimal: stats!.weight).doubleValue),
                allocation: stats?.allocation,
                freshness: security.freshness,
                tradingDaysBehind: security.tradingDaysBehind,
                lastPriceDate: security.lastPriceDate,
                missingWhileHeld: security.missingWhileHeld,
                spark: series[security.commodity] ?? []))
        }

        // Watch-list entries with no price and no history never reach the
        // health report (it is built from prices and movements), so add them.
        for commodity in watchlist where !rows.contains(where: { $0.commodity == commodity }) {
            rows.append(InvestmentRow(
                id: "\(commodity.namespace)|\(commodity.mnemonic)",
                commodity: commodity, symbol: commodity.mnemonic, name: commodity.fullName,
                group: .watching, units: 0, price: nil, marketValue: nil,
                returnFraction: nil, allocation: nil, freshness: .missing,
                tradingDaysBehind: 0, lastPriceDate: nil, missingWhileHeld: 0, spark: []))
        }

        return rows.sorted {
            let value = { (row: InvestmentRow) in abs(row.marketValue ?? 0) }
            if value($0) != value($1) { return value($0) > value($1) }
            return $0.symbol < $1.symbol
        }
    }

    /// Sparkline segments per commodity over the recent window (`FR-INV-12`).
    ///
    /// One pass over the price database rather than a filter per security: the
    /// reference book holds ~150k prices and this runs for every row on screen.
    private func sparkSeries(book: Book, since: Date) -> [Commodity: [SparkSegment]] {
        var byCommodity: [Commodity: [(Date, Double)]] = [:]
        for price in book.prices
        where price.commodity.namespace != .currency && price.date >= since {
            byCommodity[price.commodity, default: []]
                .append((price.date, NSDecimalNumber(decimal: price.value).doubleValue))
        }

        let calendar = Calendar.current
        var out: [Commodity: [SparkSegment]] = [:]
        for (commodity, raw) in byCommodity {
            let points = raw.sorted { $0.0 < $1.0 }
                .map { SparkPoint(date: calendar.startOfDay(for: $0.0), value: $0.1) }
            // Break the line wherever more than a week of calendar time passes
            // with no observation. A weekend is not a gap; a fortnight is.
            var segments: [SparkSegment] = []
            var current: [SparkPoint] = []
            for point in points {
                if let last = current.last,
                   point.date.timeIntervalSince(last.date) > 7 * 86_400 {
                    if current.count > 1 { segments.append(SparkSegment(id: segments.count, points: current)) }
                    current = []
                }
                current.append(point)
            }
            if current.count > 1 { segments.append(SparkSegment(id: segments.count, points: current)) }
            out[commodity] = segments
        }
        return out
    }

    // MARK: The worklist

    /// Classes of problem worth a person's time, most urgent first (`FR-INV-13`).
    ///
    /// Empty on a healthy book, and an empty worklist is the point: it is the
    /// three-second answer the old destination could never give.
    public func investmentIssues() -> [InvestmentIssue] {
        guard let health = priceHealth() else { return [] }
        var issues: [InvestmentIssue] = []

        func add(_ kind: InvestmentIssue.Kind, _ matching: (SecurityPriceHealth) -> Bool) {
            let hits = health.securities.filter { $0.isHeld && matching($0) }
            guard !hits.isEmpty else { return }
            issues.append(InvestmentIssue(kind: kind, count: hits.count,
                                          symbols: hits.map(\.commodity.mnemonic).sorted()))
        }

        add(.unpriced) { $0.freshness == .missing }
        add(.stale) { $0.freshness == .old && $0.isQuotable }
        add(.manualOverdue) { $0.freshness == .old && !$0.isQuotable }
        add(.gaps) { $0.missingWhileHeld > 0 }

        let rates = rateHealth()
        if !rates.missing.isEmpty {
            issues.append(InvestmentIssue(kind: .missingRate, count: rates.missing.count,
                                          symbols: rates.missing.sorted()))
        }
        return issues
    }

    /// Whether the book's non-base currencies have a usable rate (`FR-INV-33`).
    public func rateHealth() -> RateHealth {
        guard let book else { return RateHealth(currencies: 0, priced: 0, missing: []) }
        let base = reportCurrency
        let others = currencyCommodities.filter { $0 != base }
        let asOf = Self.endOfToday()
        var missing: [String] = []
        for currency in others where book.securityUnitValue(currency, in: base, on: asOf) == nil {
            missing.append(currency.mnemonic)
        }
        return RateHealth(currencies: others.count, priced: others.count - missing.count,
                          missing: missing)
    }

    // MARK: Closed positions (`FR-INV-24`)

    /// Whether closed positions are revealed. A book preference, because it is
    /// a property of this book's history rather than of the app.
    public var showsClosedPositions: Bool {
        get {
            if case let .int64(value)? = book?.kvp["finvestlens/showClosedPositions"] { return value != 0 }
            return false
        }
        set {
            editingBookKvp(named: "Show Closed Positions") {
                book?.kvp["finvestlens/showClosedPositions"] = .int64(newValue ? 1 : 0)
            }
        }
    }
}
