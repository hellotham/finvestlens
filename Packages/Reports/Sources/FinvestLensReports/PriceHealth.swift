//
//  PriceHealth.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

// Phase I1 of the Investments hub (docs/investments-design.md §8): the models
// that answer "can I trust today's valuation". No UI depends on this file yet.
//
// Three ideas earn their place here, and each replaces something the old
// Prices & Securities destination got wrong:
//
//  1. Freshness is judged against the exchange's **observed trading days**, not
//     elapsed calendar days — otherwise every ASX holding reads as stale every
//     Monday morning (`FR-INV-10`).
//  2. A missing price is only a defect **inside a period the security was
//     held**; outside one it is irrelevant, and conflating the two is what made
//     the old page unable to say anything useful (`FR-INV-26`).
//  3. Coverage is **weighted by market value**, because a count cannot tell
//     "everything is fine" from "one holding is most of the book and a month
//     stale" (`FR-INV-09`).

// MARK: - Trading calendar

/// The days an exchange is *observed* to trade, inferred from the book's own
/// price history (`FR-INV-10`).
///
/// Deriving the calendar from the data rather than shipping holiday tables is
/// deliberate: it is self-maintaining, needs no per-country upkeep, and is
/// automatically right about weekends, public holidays and half-days for every
/// exchange the book actually holds. The cost is that it only knows about days
/// some security was priced on — which is exactly the definition that matters
/// here, since a day nothing was priced on is a day nothing can be stale
/// against.
///
/// An exchange with too little history of its own (a handful of manually
/// valued bonds, say) falls back to the **whole book's** observed days, and
/// only to bare weekdays when the book itself has nothing to go on. Falling
/// back to weekdays directly would have been wrong in the one case this model
/// exists to get right: with weekdays, a Friday close read as stale every
/// Monday, which is the exact false alarm the old destination produced.
public struct TradingCalendar: Sendable {

    /// Ascending, de-duplicated start-of-day dates per exchange.
    private let daysByExchange: [String: [Date]]
    /// Every observed day across all exchanges — the fallback for a sparse one.
    private let allDays: [Date]
    private let calendar: Calendar
    /// Below this many observed days a calendar is not credible.
    static let minimumObservations = 20

    /// Builds the calendar from every security price in `book`.
    ///
    /// Currency prices are excluded: an FX rate can be recorded on any day, so
    /// including them would invent trading days no equity market had.
    public init(book: Book, calendar: Calendar = .current) {
        var seen: [String: Set<Date>] = [:]
        var union: Set<Date> = []
        for price in book.prices where price.commodity.namespace != .currency {
            let day = calendar.startOfDay(for: price.date)
            seen[Self.exchange(of: price.commodity), default: []].insert(day)
            union.insert(day)
        }
        self.init(daysByExchange: seen, allDays: union, calendar: calendar)
    }

    /// Built from days already bucketed by the caller.
    ///
    /// Bucketing a timestamp into a civil day is the most expensive operation
    /// in this file — 0.36s over the reference book's ~150k prices — and
    /// ``priceHealth(_:currency:asOf:quotable:gapLimit:calendar:)`` needs the
    /// same buckets for its own per-security day sets. Doing it once and
    /// sharing the result halves the cost; the public initialiser above stays
    /// for callers that only want a calendar.
    init(daysByExchange: [String: Set<Date>], allDays: Set<Date>, calendar: Calendar) {
        self.calendar = calendar
        self.daysByExchange = daysByExchange.mapValues { $0.sorted() }
        self.allDays = allDays.sorted()
    }

    /// The exchange key for a commodity — the namespace's name.
    public static func exchange(of commodity: Commodity) -> String {
        switch commodity.namespace {
        case .currency: return "CURRENCY"
        case .security(let name), .other(let name): return name
        }
    }

    /// Whether this exchange has enough observations of its own to be believed.
    public func isInferred(for exchange: String) -> Bool {
        (daysByExchange[exchange]?.count ?? 0) >= Self.minimumObservations
    }

    /// The best available day series for an exchange: its own if credible, the
    /// book-wide union next, and `nil` when neither has enough to say.
    private func series(for exchange: String) -> [Date]? {
        if isInferred(for: exchange) { return daysByExchange[exchange] }
        if allDays.count >= Self.minimumObservations { return allDays }
        return nil
    }

    /// The most recent observed trading day on or before `asOf`.
    ///
    /// This is the reference point for "current": a security priced on this day
    /// is as fresh as the exchange allows, whatever the wall-clock date. On a
    /// Monday when nothing has been fetched yet, the latest observed day is
    /// still Friday — so Friday's close is *current*, not a day behind, which
    /// is the behaviour the whole model exists to produce.
    public func latestTradingDay(for exchange: String, onOrBefore asOf: Date) -> Date? {
        let cap = calendar.startOfDay(for: asOf)
        guard let days = series(for: exchange) else {
            return Self.previousWeekday(onOrBefore: cap, calendar: calendar)
        }
        // Rightmost day ≤ cap.
        var low = 0, high = days.count - 1, found: Date?
        while low <= high {
            let mid = (low + high) / 2
            if days[mid] <= cap { found = days[mid]; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// Observed trading days in `from...to`, inclusive.
    public func tradingDays(for exchange: String, from: Date, to: Date) -> [Date] {
        let start = calendar.startOfDay(for: from), end = calendar.startOfDay(for: to)
        guard start <= end else { return [] }
        guard let days = series(for: exchange) else {
            return Self.weekdays(from: start, to: end, calendar: calendar)
        }
        return days.filter { $0 >= start && $0 <= end }
    }

    /// How many observed trading days separate `date` from the exchange's most
    /// recent one — the honest unit for "how far behind is this price".
    ///
    /// Measured against ``latestTradingDay(for:onOrBefore:)`` rather than
    /// against `asOf` itself. Counting to `asOf` would charge a security for
    /// days the market never opened, and for today before anyone has fetched.
    public func tradingDaysBehind(_ date: Date, for exchange: String, asOf: Date) -> Int {
        let after = calendar.startOfDay(for: date)
        guard let latest = latestTradingDay(for: exchange, onOrBefore: asOf),
              latest > after else { return 0 }
        return tradingDays(for: exchange, from: after, to: latest).filter { $0 > after }.count
    }

    // MARK: Weekday fallback

    private static func previousWeekday(onOrBefore date: Date, calendar: Calendar) -> Date? {
        var day = date
        for _ in 0..<10 {
            if !calendar.isDateInWeekend(day) { return day }
            guard let earlier = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = earlier
        }
        return nil
    }

    private static func weekdays(from: Date, to: Date, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var day = from
        while day <= to {
            if !calendar.isDateInWeekend(day) { out.append(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }
}

// MARK: - Holding periods

/// A stretch during which a security was actually owned.
///
/// Gaps, freshness and "return since holding" all need this, and none of them
/// can be answered from the price database alone — which is the whole reason
/// this analysis belongs in an accounting app rather than a price tracker.
public struct HoldingPeriod: Hashable, Sendable {
    public var start: Date
    /// `nil` while the security is still held.
    public var end: Date?

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && (end.map { date <= $0 } ?? true)
    }
}

// MARK: - Findings

/// How current a security's price is (`FR-INV-09`).
public enum PriceFreshness: String, Sendable, CaseIterable, Codable {
    /// Priced on the exchange's most recent observed trading day.
    case current
    /// One to five trading days behind.
    case stale
    /// More than five trading days behind.
    case old
    /// No price at all.
    case missing

    /// The count of trading days at which each band begins.
    static func band(daysBehind: Int) -> PriceFreshness {
        switch daysBehind {
        case 0: return .current
        case 1...5: return .stale
        default: return .old
        }
    }
}

/// A run of consecutive trading days with no price (`FR-INV-26`).
public struct PriceGap: Hashable, Sendable {
    public var start: Date
    public var end: Date
    /// Observed trading days with no price in this run.
    public var tradingDays: Int
    /// Whether the run falls inside a period the security was held — the only
    /// case in which the gap corrupts a historical valuation.
    public var whileHeld: Bool
}

/// Everything the hub needs to know about one security's prices.
public struct SecurityPriceHealth: Identifiable, Sendable {
    public var id: String { "\(commodity.namespace)|\(commodity.mnemonic)" }
    public var commodity: Commodity
    /// Units held as at the report date; zero for a closed or watched position.
    public var units: Decimal
    public var isHeld: Bool { units != 0 }
    /// Market value in the report currency, when a price exists.
    public var marketValue: Decimal?
    public var lastPriceDate: Date?
    public var freshness: PriceFreshness
    /// Observed trading days between the last price and the report date.
    public var tradingDaysBehind: Int
    /// Price **rows** stored for this security — what the detail page lists.
    public var priceCount: Int
    /// Distinct days carrying a price — what freshness and gaps are computed
    /// from, since a day is priced or it is not however many rows say so.
    ///
    /// `priceCount - pricedDays` is the count of **duplicate same-day prices**,
    /// which is a data-quality signal in its own right: the auto-refresh used
    /// to append an identical close on every book open over a closed weekend
    /// ([AppModel+Quotes.swift](../../../FeatureUI/Sources/FinvestLensUI/AppModel+Quotes.swift)),
    /// and older imports can double up the same day from two sources.
    public var pricedDays: Int
    /// Whether a provider can price this security at all; manual valuations are
    /// a category, not a failure (`FR-INV-30`).
    public var isQuotable: Bool
    public var holdingPeriods: [HoldingPeriod]
    public var gaps: [PriceGap]
    /// Missing trading days inside a holding period, across all gaps.
    public var missingWhileHeld: Int
    /// True when ``gaps`` was capped; ``missingWhileHeld`` is still exact.
    public var gapsTruncated: Bool
    /// Price count by `Price.source` — provenance the book records and the old
    /// UI never showed (`FR-INV-27`).
    public var sources: [String: Int]

    /// Whether this security should be shown by default: held, or watched with
    /// no history to speak of. Closed positions hide behind a reveal (`FR-INV-24`).
    public var isDormant: Bool { !isHeld }
}

/// Book-wide price health (`FR-INV-09`).
public struct PortfolioPriceHealth: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var securities: [SecurityPriceHealth]

    /// Fraction of **held market value** priced on the latest trading day.
    ///
    /// `nil` when nothing held can be valued at all — which is a different
    /// statement from 0%, and the UI must not conflate them.
    public var valueCoverage: Double?
    /// Held market value that could not be valued at all (no price ever).
    public var unvaluedCount: Int

    public var heldCount: Int
    public var currentCount: Int
    public var staleCount: Int
    public var oldCount: Int
    /// Held securities with gaps inside a holding period.
    public var securitiesWithHeldGaps: Int
    /// Total missing trading days inside holding periods, across held securities.
    public var missingWhileHeld: Int
    /// Held securities that no provider can price.
    public var manualCount: Int

    /// Securities a person should act on: held, and either unpriceable today or
    /// more than a trading week behind. The worklist in the overview (`FR-INV-13`).
    public var needsAttention: [SecurityPriceHealth] {
        securities.filter { $0.isHeld && ($0.freshness == .old || $0.freshness == .missing) }
    }
}

// MARK: - Computation

public extension FinancialReports {

    /// Price health for every security the book knows about (`FR-INV-09`).
    ///
    /// - Parameter quotable: whether a provider can price a commodity. Defaults
    ///   to the book's own `cmdty:get_quotes` flag; `FeatureUI` passes a richer
    ///   test that also knows about ticker overrides and ISIN routing to FIIG,
    ///   which live outside the Engine.
    /// - Parameter gapLimit: the most gaps retained per security. Counts stay
    ///   exact when this truncates; a UI cannot render thousands of gaps and a
    ///   report that tries is a report nobody runs twice.
    /// - Parameter calendar: which calendar buckets a timestamp into a day.
    ///   Explicit rather than always `.current` because every date this report
    ///   returns is a start-of-day in *this* calendar, so a caller comparing
    ///   those dates to its own must be able to agree on the zone — and a test
    ///   or a CI machine in another one must still get the same answer.
    static func priceHealth(_ book: Book, currency: Commodity, asOf: Date = Date(),
                            quotable: (Commodity) -> Bool = { $0.getQuotes },
                            gapLimit: Int = 100,
                            calendar: Calendar = .current) -> PortfolioPriceHealth {
        let today = calendar.startOfDay(for: asOf)

        // **One** bucketing pass over the price database, feeding both the
        // trading calendar and the per-security day sets. Turning a timestamp
        // into a civil day is the dominant cost here, and building the calendar
        // separately did it a second time over every price in the book.
        var priceDays: [Commodity: Set<Date>] = [:]
        var rowCounts: [Commodity: Int] = [:]
        var sources: [Commodity: [String: Int]] = [:]
        var daysByExchange: [String: Set<Date>] = [:]
        var allDays: Set<Date> = []
        for price in book.prices where price.commodity.namespace != .currency {
            let day = calendar.startOfDay(for: price.date)
            // The calendar describes when the market traded, so it takes every
            // observation; the per-security sets answer "as at `asOf`".
            daysByExchange[TradingCalendar.exchange(of: price.commodity), default: []].insert(day)
            allDays.insert(day)
            guard price.date <= asOf else { continue }
            priceDays[price.commodity, default: []].insert(day)
            rowCounts[price.commodity, default: 0] += 1
            sources[price.commodity, default: [:]][price.source, default: 0] += 1
        }
        let tradingCalendar = TradingCalendar(daysByExchange: daysByExchange, allDays: allDays,
                                              calendar: calendar)

        // Quantity movements per commodity, which become holding periods. Driven
        // from each security account's own splits rather than by walking every
        // transaction in the book — the same change that took the advanced
        // portfolio report from 4.76s to 0.14s on the reference book.
        //
        // Book order is preserved explicitly. Walking accounts instead of
        // transactions groups a commodity's movements by account, and two
        // accounts can move the same commodity on the same day; `sorted(by:)`
        // is not stable, so without a tie-break the running balance could open
        // and close a holding period in a different order than before. One
        // cheap pass over transactions gives the tie-break the old nested scan
        // got for free.
        var order: [ObjectIdentifier: Int] = [:]
        for (index, transaction) in book.transactions.enumerated() {
            order[ObjectIdentifier(transaction)] = index
        }
        var movements: [Commodity: [(rank: Int, date: Date, quantity: Decimal)]] = [:]
        // Same filter as `portfolio(_:currency:asOf:)`, deliberately: the two
        // must agree on what "held" means, and a live harness cross-checks them
        // against the real book.
        for account in book.accounts where account.type.isSecurityType && !account.isPlaceholder {
            for split in book.splits(for: account) {
                guard split.reconcileState != .voided, split.quantity != 0,
                      let transaction = split.transaction, transaction.datePosted <= asOf
                else { continue }
                movements[account.commodity, default: []].append(
                    (order[ObjectIdentifier(transaction)] ?? 0,
                     calendar.startOfDay(for: transaction.datePosted), split.quantity))
            }
        }
        let ordered = movements.mapValues { entries in
            entries.sorted { ($0.date, $0.rank) < ($1.date, $1.rank) }
                .map { (date: $0.date, quantity: $0.quantity) }
        }

        var results: [SecurityPriceHealth] = []
        for commodity in Set(priceDays.keys).union(ordered.keys) {
            let exchange = TradingCalendar.exchange(of: commodity)
            let days = priceDays[commodity] ?? []
            let last = days.max()
            let periods = holdingPeriods(from: ordered[commodity] ?? [], asOf: today)
            let units = (ordered[commodity] ?? []).reduce(Decimal(0)) { $0 + $1.quantity }

            let behind = last.map {
                tradingCalendar.tradingDaysBehind($0, for: exchange, asOf: today)
            } ?? 0
            let freshness: PriceFreshness = last == nil ? .missing : .band(daysBehind: behind)

            let found = gaps(for: commodity, pricedDays: days, periods: periods,
                             calendar: tradingCalendar, exchange: exchange, asOf: today)
            let heldMissing = found.filter(\.whileHeld).reduce(0) { $0 + $1.tradingDays }

            let price = book.securityUnitValue(commodity, in: currency, on: asOf)
            results.append(SecurityPriceHealth(
                commodity: commodity,
                units: units,
                marketValue: price.map { currency.round(units * $0) },
                lastPriceDate: last,
                freshness: freshness,
                tradingDaysBehind: behind,
                priceCount: rowCounts[commodity] ?? 0,
                pricedDays: days.count,
                isQuotable: quotable(commodity),
                holdingPeriods: periods,
                gaps: Array(found.prefix(gapLimit)),
                missingWhileHeld: heldMissing,
                gapsTruncated: found.count > gapLimit,
                sources: sources[commodity] ?? [:]))
        }
        results.sort { $0.commodity.mnemonic < $1.commodity.mnemonic }

        // Value-weighted coverage over held positions only: a dormant holding
        // cannot drag the number down, and a large stale one cannot hide behind
        // a crowd of small healthy ones.
        let held = results.filter(\.isHeld)
        let valued = held.compactMap { security -> (Decimal, Bool)? in
            guard let value = security.marketValue else { return nil }
            return (abs(value), security.freshness == .current)
        }
        let total = valued.reduce(Decimal(0)) { $0 + $1.0 }
        let fresh = valued.filter(\.1).reduce(Decimal(0)) { $0 + $1.0 }
        let coverage: Double? = total == 0 ? nil
            : NSDecimalNumber(decimal: fresh).doubleValue / NSDecimalNumber(decimal: total).doubleValue

        return PortfolioPriceHealth(
            asOf: asOf,
            currencyCode: currency.mnemonic,
            securities: results,
            valueCoverage: coverage,
            unvaluedCount: held.filter { $0.marketValue == nil }.count,
            heldCount: held.count,
            currentCount: held.filter { $0.freshness == .current }.count,
            staleCount: held.filter { $0.freshness == .stale }.count,
            oldCount: held.filter { $0.freshness == .old || $0.freshness == .missing }.count,
            securitiesWithHeldGaps: held.filter { $0.missingWhileHeld > 0 }.count,
            missingWhileHeld: held.reduce(0) { $0 + $1.missingWhileHeld },
            manualCount: held.filter { !$0.isQuotable }.count)
    }

    /// Periods during which the running unit balance was non-zero.
    ///
    /// Internal to the computation but exposed for testing and for the detail
    /// page's held-period shading.
    static func holdingPeriods(from movements: [(date: Date, quantity: Decimal)],
                               asOf: Date) -> [HoldingPeriod] {
        guard !movements.isEmpty else { return [] }
        var periods: [HoldingPeriod] = []
        var balance = Decimal(0)
        var openedAt: Date?
        for movement in movements.sorted(by: { $0.date < $1.date }) {
            let before = balance
            balance += movement.quantity
            if before == 0 && balance != 0 {
                openedAt = movement.date
            } else if before != 0 && balance == 0, let start = openedAt {
                periods.append(HoldingPeriod(start: start, end: movement.date))
                openedAt = nil
            }
        }
        if let start = openedAt { periods.append(HoldingPeriod(start: start, end: nil)) }
        return periods
    }

    /// Runs of observed trading days with no price, flagged by whether they
    /// fall inside a holding period (`FR-INV-26`).
    ///
    /// Scanning starts at the first price rather than the first holding: a
    /// security bought before its history was ever fetched should report the
    /// backfill as one honest gap, not as a hole for every day since purchase
    /// — but only once there is a series to have a hole in.
    private static func gaps(for commodity: Commodity, pricedDays: Set<Date>,
                             periods: [HoldingPeriod], calendar: TradingCalendar,
                             exchange: String, asOf: Date) -> [PriceGap] {
        guard let first = pricedDays.min() else { return [] }
        let candidates = calendar.tradingDays(for: exchange, from: first, to: asOf)
        guard !candidates.isEmpty else { return [] }

        var runs: [PriceGap] = []
        var runStart: Date?
        var runEnd: Date?
        var runDays = 0
        var runHeld = false

        func close() {
            if let start = runStart, let end = runEnd {
                runs.append(PriceGap(start: start, end: end, tradingDays: runDays, whileHeld: runHeld))
            }
            runStart = nil; runEnd = nil; runDays = 0; runHeld = false
        }

        for day in candidates {
            if pricedDays.contains(day) { close(); continue }
            let held = periods.contains { $0.contains(day) }
            if runStart == nil { runStart = day; runHeld = held }
            // A run that touches a holding period at any point is a run that
            // corrupted a valuation, so the flag latches rather than tracking
            // only the final day.
            runHeld = runHeld || held
            runEnd = day
            runDays += 1
        }
        close()
        return runs
    }
}
