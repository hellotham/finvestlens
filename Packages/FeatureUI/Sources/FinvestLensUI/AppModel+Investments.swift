//
//  AppModel+Investments.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes
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
    /// What the units still held cost in total — a figure of the same kind as
    /// ``marketValue``, so the two can be read against each other. A per-unit
    /// average cannot: "I can't compare average price with current value."
    public var purchaseAmount: Decimal?
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
        group == .held && freshness.needsAttention
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
        case bondProvider   // carries an ISIN and no provider that reads one
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
        // Proof beats declaration, and `get_quotes` is a stale declaration:
        // it records what **GnuCash** could fetch, from the much smaller set of
        // providers Finance::Quote supported. A false there means "GnuCash
        // could not", never "nothing can". So the flag is read only as a
        // positive signal and its absence proves nothing — the fetch already
        // works that way (`pricableSecurities` is every security, flag
        // unconsulted), which is how a security stayed current while this test
        // filed it under "Valued by hand".
        //
        // What does count is evidence: a provider-sourced price in the book
        // means some provider served this security. Hand-valued is then the
        // residue — everything no provider has ever priced.
        return providerPricedCommodities.contains(commodity)
    }

    // MARK: Securities that have stopped trading (`FR-INV-37`)

    /// Whether a security has stopped trading, so its last price is final.
    ///
    /// Nothing infers this. A thinly-traded note that has not printed for a
    /// month and a redeemed one look identical from the price data, and
    /// guessing wrong either nags forever about a security nobody can price or
    /// silently stops chasing one that is merely quiet. It is recorded.
    public func isDelisted(_ commodity: Commodity) -> Bool {
        delistedSecurities.contains(securityKey(commodity))
    }

    /// Marks a security as no longer trading, or returns it to the fold.
    public func setDelisted(_ commodity: Commodity, _ delisted: Bool) {
        let key = securityKey(commodity)
        guard delisted != delistedSecurities.contains(key) else { return }
        if delisted {
            delistedSecurities.append(key)
        } else {
            delistedSecurities.removeAll { $0 == key }
        }
        commitKvpCollections(named: delisted ? "Mark as No Longer Trading" : "Mark as Trading")
    }

    private func securityKey(_ commodity: Commodity) -> String {
        "\(commodity.namespace)|\(commodity.mnemonic)"
    }

    // MARK: Securities no provider prices (`FR-INV-40`)

    /// Whether this security is valued by hand because **no provider publishes
    /// a price for it** — a retail super or managed-fund unit, a private
    /// holding.
    ///
    /// Distinct from ``isDelisted(_:)``, which says a security has stopped
    /// trading and its last price is final. These are still trading; their
    /// price simply arrives on a statement rather than a feed. Conflating the
    /// two would freeze a live holding's valuation and lie in the reports.
    public func isUnquoted(_ commodity: Commodity) -> Bool {
        unquotedSecurities.contains(securityKey(commodity))
    }

    /// Records that nothing will ever quote this security, or takes it back.
    public func setUnquoted(_ commodity: Commodity, _ unquoted: Bool) {
        let key = securityKey(commodity)
        guard unquoted != unquotedSecurities.contains(key) else { return }
        if unquoted {
            unquotedSecurities.append(key)
        } else {
            unquotedSecurities.removeAll { $0 == key }
        }
        commitKvpCollections(named: unquoted ? "Mark as Valued by Hand" : "Mark as Quoted")
    }

    /// The securities a fetch should actually ask a provider about: everything
    /// pricable, less the ones that have stopped trading. Asking after those
    /// spends a request to be told nothing, every run, forever.
    public var fetchableSecurities: [Commodity] {
        // Neither the ones whose price is final nor the ones nothing publishes:
        // both spend a request to be told nothing, every run, forever.
        pricableSecurities.filter { !isDelisted($0) && !isUnquoted($0) }
    }

    /// Commodities the book holds at least one **provider-sourced** price for.
    ///
    /// `Price.source` records who supplied each row: `Finance::Quote…` for a
    /// provider, `user:…` for anything typed, imported or entered through a
    /// dialog. Memoised on the book revision — asking per security would rescan
    /// the whole price database once per row on screen.
    private var providerPricedCommodities: Set<Commodity> {
        cachedReport("providerPriced") { [self] in
            var found: Set<Commodity> = []
            for price in book?.prices ?? []
            where price.source.hasPrefix("Finance::Quote") {
                found.insert(price.commodity)
            }
            return found
        } ?? []
    }

    /// Price health across the book (`FR-INV-09`), memoised on the book
    /// revision. Keyed on `endOfToday()` rather than `Date()`, or every redraw
    /// would be a cache miss and pay the full scan again.
    public func priceHealth() -> PortfolioPriceHealth? {
        guard let book, !securityCommodities.isEmpty || !watchlist.isEmpty else { return nil }
        let asOf = Self.endOfToday()
        return cachedReport("pxhealth:\(asOf.timeIntervalSinceReferenceDate)") {
            FinancialReports.priceHealth(book, currency: reportCurrency, asOf: asOf,
                                         quotable: { [self] in canFetchQuotes(for: $0) },
                                         ceased: { [self] in isDelisted($0) })
        }
    }

    /// The holdings table's rows, grouped and sorted (`FR-INV-11`).
    ///
    /// Sorted by market value descending within each group: the position that
    /// most affects whether the total is right belongs at the top, which is not
    /// what alphabetical order gives you.
    public func investmentRows(range: SparkRange? = nil) -> [InvestmentRow] {
        guard let book, let health = priceHealth() else { return [] }
        let window = range.map { chosen -> ClosedRange<Date> in
            let end = Self.endOfToday()
            return (Calendar.current.date(byAdding: .day, value: -chosen.days, to: end) ?? end)...end
        } ?? sparkWindow
        let asOf = Self.endOfToday()
        let advanced = advancedPortfolio(asOf: asOf)

        // Return and allocation come from the lot engine, per *account*; a
        // commodity can be held in more than one, so money-weight the returns
        // and sum the allocations rather than taking the first match.
        //
        // Cost comes along for the ride, and for the same reason: a security
        // held through two brokers arrives as two holdings, and what was paid
        // for it is the sum of both. `shares` rides along only to tell a live
        // holding from one that has been sold out of — a closed position has a
        // cost basis of zero, which is not a purchase amount of zero.
        var returns: [String: (weight: Decimal, weighted: Double, allocation: Double,
                               cost: Decimal, shares: Decimal)] = [:]
        for holding in advanced?.holdings ?? [] {
            let weight = abs(holding.marketValue ?? holding.costBasis)
            var entry = returns[holding.symbol] ?? (0, 0, 0, 0, 0)
            if let fraction = holding.returnFraction {
                entry.weighted += fraction * NSDecimalNumber(decimal: weight).doubleValue
                entry.weight += weight
            }
            entry.allocation += holding.allocation ?? 0
            entry.cost += holding.costBasis
            entry.shares += holding.shares
            returns[holding.symbol] = entry
        }

        let watched = Set(watchlist.map { "\($0.namespace)|\($0.mnemonic)" })
        let series = sparkSeries(book: book, window: window)

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
                purchaseAmount: (stats?.shares ?? 0) == 0 ? nil : stats!.cost,
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
                group: .watching, units: 0, price: nil, purchaseAmount: nil, marketValue: nil,
                returnFraction: nil, allocation: nil, freshness: .missing,
                tradingDaysBehind: 0, lastPriceDate: nil, missingWhileHeld: 0, spark: []))
        }

        return rows.sorted {
            let value = { (row: InvestmentRow) in abs(row.marketValue ?? 0) }
            if value($0) != value($1) { return value($0) > value($1) }
            return $0.symbol < $1.symbol
        }
    }

    /// Sparkline segments per commodity over `window` (`FR-INV-12`).
    ///
    /// One pass over the price database rather than a filter per security: the
    /// reference book holds ~150k prices and this runs for every row on screen.
    private func sparkSeries(book: Book, window: ClosedRange<Date>) -> [Commodity: [SparkSegment]] {
        var byCommodity: [Commodity: [(Date, Double)]] = [:]
        for price in book.prices
        where price.commodity.namespace != .currency && window.contains(price.date) {
            byCommodity[price.commodity, default: []]
                .append((price.date, NSDecimalNumber(decimal: price.value).doubleValue))
        }

        // Break the line where an absence is actually visible. A week is the
        // floor — a weekend is not a gap, a fortnight is — but a week drawn
        // across five years is a third of a pixel, so the threshold also has to
        // scale with the window or a 5Y line shatters into confetti.
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let breakAfter = max(7 * 86_400, span * 0.02)

        let calendar = Calendar.current
        var out: [Commodity: [SparkSegment]] = [:]
        for (commodity, raw) in byCommodity {
            let points = raw.sorted { $0.0 < $1.0 }
                .map { SparkPoint(date: calendar.startOfDay(for: $0.0), value: $0.1) }
            var segments: [SparkSegment] = []
            var current: [SparkPoint] = []
            for point in points {
                if let last = current.last,
                   point.date.timeIntervalSince(last.date) > breakAfter {
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

        // `@MainActor` on the predicate is load-bearing: without it the closure
        // is task-isolated while `filter`'s closure is main-actor-isolated, and
        // Swift 6 rejects passing one into the other. Debug builds let it pass;
        // the release build does not, so this only appeared when `finlab` was
        // built with `-c release`.
        // **One security, one row.** A holding claimed by an earlier kind is
        // not offered again by a later one.
        //
        // Reported 16 Aug 2026, and correct: the reference book showed three
        // rows where the answer is one bond. `FR0014014MD4` appeared twice —
        // once as a hand-valued holding out of date, once as a bond FIIG could
        // price — which are not two problems but a problem and its fix.
        var claimed: Set<Commodity> = []
        func add(_ kind: InvestmentIssue.Kind, _ matching: @MainActor (SecurityPriceHealth) -> Bool) {
            let hits = health.securities.filter {
                $0.isHeld && !claimed.contains($0.commodity) && matching($0)
            }
            guard !hits.isEmpty else { return }
            claimed.formUnion(hits.map(\.commodity))
            issues.append(InvestmentIssue(kind: kind, count: hits.count,
                                          symbols: hits.map(\.commodity.mnemonic).sorted()))
        }

        // The one-click fix comes first, so a bond FIIG can price is offered
        // FIIG rather than scolded for being out of date. Same reasoning as
        // above: name the remedy, not the symptom.
        let heldSet = Set(health.securities.filter(\.isHeld).map(\.commodity))
        let wantingSet = Set(health.securities
            .filter { $0.freshness == .missing || $0.freshness == .old }
            .map(\.commodity))
        let bondCandidates = fiigCandidates.filter { heldSet.contains($0) && wantingSet.contains($0) }
        if !bondCandidates.isEmpty {
            claimed.formUnion(bondCandidates)
            issues.append(InvestmentIssue(kind: .bondProvider, count: bondCandidates.count,
                                          symbols: bondCandidates.map(\.mnemonic).sorted()))
        }

        add(.unpriced) { $0.freshness == .missing }
        add(.stale) { $0.freshness == .old && $0.isQuotable }
        // Hand-valued holdings are judged against **their own cadence**
        // (`FR-INV-30`), not the trading calendar: a super fund posting a unit
        // price quarterly is not stale on a Tuesday because the ASX traded, and
        // telling the user off for that is how a worklist stops being read.
        add(.manualOverdue) { [self] in
            !$0.isQuotable && isValuationOverdue($0.commodity)
        }
        // **Gaps are not a worklist item.** A hole in a series while a security
        // was held is a fact about history, not a thing to do today — and the
        // confidence band above already states it in the same words ("14 with
        // gaps while held"), so the row was the same sentence twice. Fourteen
        // of them sat between the user and the one bond that did need a
        // decision.

        let rates = rateHealth()
        if !rates.missing.isEmpty {
            issues.append(InvestmentIssue(kind: .missingRate, count: rates.missing.count,
                                          symbols: rates.missing.sorted()))
        }

        return issues
    }

    /// Points every ISIN-carrying holding at FIIG, in one edit (`FR-INV-31`).
    ///
    /// The worklist's fix. Reversible from any security's own page, and it
    /// changes nothing but which service is asked — no price moves until the
    /// next fetch, which is what makes it safe to offer as one click.
    public func routeCandidatesToFIIG() {
        let candidates = fiigCandidates
        guard !candidates.isEmpty else { return }
        for commodity in candidates {
            quoteProviders["\(commodity.namespace)|\(commodity.mnemonic)"] =
                QuoteProviderKind.fiig.rawValue
        }
        commitKvpCollections(named: "Use FIIG for Bonds")
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

    // MARK: The sparkline window (`FR-INV-12`)

    /// The period every holding's sparkline covers.
    ///
    /// Named on screen and adjustable, because an unlabelled line is unreadable:
    /// a shape means nothing until you know whether it spans a month or a
    /// decade, and the answer changes which shapes are worth worrying about.
    public enum SparkRange: String, CaseIterable, Sendable, Identifiable {
        case month, quarter, halfYear, year, fiveYears
        public var id: String { rawValue }

        /// Days back from today.
        public var days: Int {
            switch self {
            case .month: return 30
            case .quarter: return 91
            case .halfYear: return 183
            case .year: return 365
            case .fiveYears: return 1826
            }
        }

        /// The written-out name, used everywhere a person reads it: the picker,
        /// the column legend and VoiceOver. There is deliberately no "3M" form —
        /// an abbreviation is what made the axis unreadable in the first place,
        /// and VoiceOver would say "three em".
        public var label: String {
            switch self {
            case .month: String(localized: "1 month")
            case .quarter: String(localized: "3 months")
            case .halfYear: String(localized: "6 months")
            case .year: String(localized: "1 year")
            case .fiveYears: String(localized: "5 years")
            }
        }
    }

    /// The chosen sparkline period. A book preference: it belongs to how this
    /// book's holdings behave, not to the app.
    public var sparkRange: SparkRange {
        get {
            if case let .string(raw)? = book?.kvp["finvestlens/sparkRange"],
               let range = SparkRange(rawValue: raw) { return range }
            return .quarter
        }
        set {
            editingBookKvp(named: "Change Sparkline Period") {
                book?.kvp["finvestlens/sparkRange"] = .string(newValue.rawValue)
            }
        }
    }

    /// The window every sparkline is drawn against — **one axis for the whole
    /// table**, not one per row.
    ///
    /// Scaling each row to its own first and last price made the column
    /// unreadable and, worse, dishonest: five days of data stretched the full
    /// width, and a holding a month stale still drew to the right-hand edge as
    /// though it were current. Sharing the axis means a horizontal position is
    /// the same date on every row, and a line that stops short is a line whose
    /// data stops short — which is the point.
    /// Anchored to `endOfToday()` rather than `Date()` for the same reason the
    /// report cache is: a live clock makes every redraw a different window, so
    /// nothing downstream can ever compare equal.
    public var sparkWindow: ClosedRange<Date> {
        let end = Self.endOfToday()
        let start = Calendar.current.date(byAdding: .day, value: -sparkRange.days, to: end) ?? end
        return start...end
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
