//
//  SecurityReconciliation.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

// Phase I6 of the Investments hub (docs/investments-design.md §8.3, §8.4).
//
// The strongest argument for the hub existing at all: this is a job that needs
// the ledger **and** the market at once, so no portfolio tracker and no
// accounting package can do it alone. The provider knows what was declared, the
// book knows what was received, and the difference is a worklist that finds
// real money.
//
// Everything here is stated as a **discrepancy to look at**, never as a
// correction to apply. The planning doctrine holds: the app reports what
// happened and what is inconsistent, and the person decides.

/// What an issuer declared per unit, as this report needs it.
///
/// Deliberately **not** the quote layer's type. `Reports` sits beside `Quotes`
/// in the dependency graph, not above it — and more to the point, a
/// reconciliation has no business knowing whether a declaration came from a
/// provider, a PDF or a typed note. The caller maps whatever it has into this.
public struct DeclaredPayment: Sendable, Hashable {
    public var date: Date
    public var perUnit: Decimal

    public init(date: Date, perUnit: Decimal) {
        self.date = date
        self.perUnit = perUnit
    }
}

/// A capital change as this report needs it: a date and a multiplier.
public struct DeclaredCapitalChange: Sendable, Hashable {
    public var date: Date
    /// Shares after per share before — 2 for a two-for-one, 0.1 for a
    /// one-for-ten consolidation.
    public var ratio: Decimal

    public init(date: Date, ratio: Decimal) {
        self.date = date
        self.ratio = ratio
    }
}

/// A dividend the issuer declared set against what the book recorded
/// (`FR-INV-20`).
public struct DividendDiscrepancy: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Declared, nothing recorded — the book understates income.
        case missing
        /// Recorded, nothing declared near it — a wrong date, a wrong
        /// security, or a special dividend the provider does not list.
        case unexpected
        /// Both present, amounts apart — withholding, franking, or a DRP
        /// recorded at the wrong price.
        case amountDiffers
    }

    public var id: String { "\(kind.rawValue)|\(date.timeIntervalSince1970)" }
    public var kind: Kind
    /// The declaration's date where there is one, else the book's.
    public var date: Date
    /// Per unit, as the issuer declared it.
    public var declaredPerUnit: Decimal?
    /// The cash the book recorded for the matched transaction.
    public var recordedAmount: Decimal?
    /// Units held on the declaration date, so a per-unit rate can be compared
    /// with a cash total at all.
    public var unitsHeld: Decimal?
    /// `declaredPerUnit × unitsHeld`, when both are known.
    public var expectedAmount: Decimal?
}

/// A capital change the provider reports that the book has no transaction for
/// (`FR-INV-21`).
///
/// This one is quietly serious. Every price before an unrecorded split is
/// inconsistent with the units held, so the historical chart and every past
/// valuation are wrong — and nothing else in the app would ever notice.
public struct SplitDiscrepancy: Identifiable, Sendable, Hashable {
    public var id: Date { date }
    public var date: Date
    /// Shares after per share before — 2 for a two-for-one.
    public var ratio: Decimal
    /// Units held immediately before the date, from the book.
    public var unitsBefore: Decimal
    /// What the holding should have become.
    public var expectedUnitsAfter: Decimal
    /// What the book actually shows after the date.
    public var actualUnitsAfter: Decimal
}

/// A stored price that cannot be right (`FR-INV-28`).
///
/// Two-thirds of the reference book's prices were hand-entered, which is
/// exactly the population most likely to hold a typo — a decimal-point slip, a
/// figure entered in cents, a price in the wrong currency.
public struct PriceOutlier: Identifiable, Sendable, Hashable {
    public var id: GncGUID { priceID }
    public var priceID: GncGUID
    public var date: Date
    public var value: Decimal
    /// The median of the surrounding prices this was judged against.
    public var neighbourMedian: Decimal
    /// `value ÷ neighbourMedian` — near 10, 100 or 0.01 is a decimal slip.
    public var ratio: Double
    public var source: String
}

/// Everything I6 found for one security.
public struct SecurityReconciliation: Sendable {
    public var dividends: [DividendDiscrepancy]
    public var splits: [SplitDiscrepancy]
    public var outliers: [PriceOutlier]

    public init(dividends: [DividendDiscrepancy] = [], splits: [SplitDiscrepancy] = [],
                outliers: [PriceOutlier] = []) {
        self.dividends = dividends
        self.splits = splits
        self.outliers = outliers
    }

    public var isClean: Bool {
        dividends.isEmpty && splits.isEmpty && outliers.isEmpty
    }

    public var count: Int { dividends.count + splits.count + outliers.count }
}

public extension FinancialReports {

    /// Compares declared dividends with recorded income, and reports the four
    /// discrepancy classes (`FR-INV-20`).
    ///
    /// - Parameter declared: what the provider says the issuer paid, per unit,
    ///   oldest first.
    /// - Parameter events: the book's own movements for this security, from
    ///   ``securityDetail(_:commodity:currency:asOf:health:holdings:lots:calendar:)``.
    /// - Parameter window: how far a recorded payment may sit from a
    ///   declaration and still be the same event. Registries pay weeks after
    ///   the ex-date and the book records the day the cash landed, so a tight
    ///   window reports every dividend twice — once missing, once unexpected.
    ///   Six weeks is wide enough for an Australian payment cycle and narrow
    ///   enough not to swallow the next quarter's.
    /// - Parameter tolerance: the fraction by which a recorded amount may
    ///   differ from the expected one before it is worth a person's time. A
    ///   dividend is rarely paid to the cent of the declaration — rounding per
    ///   holding, and withholding — so a zero tolerance reports every payment.
    static func reconcileDividends(declared: [DeclaredPayment],
                                   events: [SecurityEvent],
                                   holdingPeriods: [HoldingPeriod],
                                   unitsOn: (Date) -> Decimal,
                                   window: TimeInterval = 42 * 86_400,
                                   tolerance: Double = 0.05) -> [DividendDiscrepancy] {
        let recorded = events.filter { $0.kind == .income }
        var matchedRecorded = Set<String>()
        var out: [DividendDiscrepancy] = []

        for declaration in declared {
            // Only while held. A dividend declared before you bought or after
            // you sold is not money you were owed, and reporting it as missing
            // income would fill the worklist with other people's dividends.
            guard holdingPeriods.contains(where: { $0.contains(declaration.date) }) else { continue }
            let units = unitsOn(declaration.date)
            guard units > 0 else { continue }
            let expected = declaration.perUnit * units

            // Candidates: unclaimed payments inside the window.
            let candidates = recorded.filter {
                !matchedRecorded.contains($0.id)
                    && abs($0.date.timeIntervalSince(declaration.date)) <= window
            }
            func daysApart(_ event: SecurityEvent) -> TimeInterval {
                abs(event.date.timeIntervalSince(declaration.date))
            }

            // **Amount first, then date.** Matching purely on nearness picks
            // the wrong payment whenever a special dividend lands between a
            // declaration and its own payment: a $120 special two weeks out
            // beats the $500 payment three weeks out, and then both are
            // reported wrong — one as an amount mismatch, one as unexpected.
            // A payment that equals what was declared is the match, whatever
            // else is nearer.
            let matchesAmount = candidates.filter { event in
                let scale = abs(NSDecimalNumber(decimal: expected).doubleValue)
                guard scale > 0 else { return false }
                let difference = abs(NSDecimalNumber(decimal: event.amount - expected).doubleValue)
                return difference / scale <= tolerance
            }
            let candidate = (matchesAmount.isEmpty ? candidates : matchesAmount)
                .min { daysApart($0) < daysApart($1) }

            guard let match = candidate else {
                out.append(DividendDiscrepancy(
                    kind: .missing, date: declaration.date,
                    declaredPerUnit: declaration.perUnit, recordedAmount: nil,
                    unitsHeld: units, expectedAmount: expected))
                continue
            }
            matchedRecorded.insert(match.id)

            let difference = abs(NSDecimalNumber(decimal: match.amount - expected).doubleValue)
            let scale = abs(NSDecimalNumber(decimal: expected).doubleValue)
            if scale > 0, difference / scale > tolerance {
                out.append(DividendDiscrepancy(
                    kind: .amountDiffers, date: declaration.date,
                    declaredPerUnit: declaration.perUnit, recordedAmount: match.amount,
                    unitsHeld: units, expectedAmount: expected))
            }
        }

        // Anything the book recorded that no declaration accounts for. Often a
        // special dividend the provider does not list, sometimes a date or a
        // security entered wrongly — which is why it is reported rather than
        // assumed to be either.
        for payment in recorded where !matchedRecorded.contains(payment.id) {
            // Only inside the declared series' own span: a payment from before
            // the provider's history begins is unexplained by absence of data,
            // not by absence of a dividend.
            guard let first = declared.first?.date, let last = declared.last?.date,
                  payment.date >= first.addingTimeInterval(-window),
                  payment.date <= last.addingTimeInterval(window) else { continue }
            out.append(DividendDiscrepancy(
                kind: .unexpected, date: payment.date, declaredPerUnit: nil,
                recordedAmount: payment.amount, unitsHeld: unitsOn(payment.date),
                expectedAmount: nil))
        }

        return out.sorted { $0.date > $1.date }
    }

    /// Splits the provider reports that the book's unit balance does not show
    /// (`FR-INV-21`).
    ///
    /// The test is a ratio, not an equality: a book that recorded the split
    /// *and* traded around it will not land on the arithmetic exactly, so a
    /// strict comparison would report every split as missing.
    static func reconcileSplits(declared: [DeclaredCapitalChange],
                                unitsOn: (Date) -> Decimal,
                                holdingPeriods: [HoldingPeriod],
                                tolerance: Double = 0.10) -> [SplitDiscrepancy] {
        var out: [SplitDiscrepancy] = []
        for split in declared {
            let ratio = split.ratio
            guard ratio > 0, ratio != 1 else { continue }
            guard holdingPeriods.contains(where: { $0.contains(split.date) }) else { continue }

            // A day either side, so the comparison is "before" against "after"
            // rather than two readings of the same instant.
            let before = unitsOn(split.date.addingTimeInterval(-86_400))
            let after = unitsOn(split.date.addingTimeInterval(86_400))
            guard before > 0 else { continue }

            let expected = before * ratio
            let drift = abs(NSDecimalNumber(decimal: after - expected).doubleValue)
            let scale = abs(NSDecimalNumber(decimal: expected).doubleValue)
            guard scale > 0, drift / scale > tolerance else { continue }

            out.append(SplitDiscrepancy(date: split.date, ratio: ratio, unitsBefore: before,
                                        expectedUnitsAfter: expected, actualUnitsAfter: after))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Prices that cannot be right, judged against their neighbours
    /// (`FR-INV-28`).
    ///
    /// A **median** of the surrounding window, not a mean: one bad price would
    /// drag a mean far enough to hide itself and to implicate its neighbours.
    /// The median is unmoved by a single outlier, which is the whole reason to
    /// use it here.
    ///
    /// - Parameter factor: how far from the neighbourhood a price must sit to
    ///   be reported. Four is deliberately loose — a security really can move
    ///   50% in a week, and a check that fires on real volatility is a check
    ///   people switch off. A decimal slip is a factor of ten.
    static func priceOutliers(_ prices: [SecurityPriceRow],
                              window: Int = 5,
                              factor: Double = 4) -> [PriceOutlier] {
        // Sorted by date, and enough neighbours to have a median at all.
        let ordered = prices.sorted { $0.date < $1.date }
        guard ordered.count >= 2 * window + 1 else { return [] }

        var out: [PriceOutlier] = []
        for (index, row) in ordered.enumerated() {
            let low = max(0, index - window)
            let high = min(ordered.count - 1, index + window)
            var neighbours = ordered[low...high].enumerated()
                .filter { $0.offset + low != index }
                .map(\.element.value)
            guard neighbours.count >= 2 else { continue }
            neighbours.sort()
            let median = neighbours[neighbours.count / 2]
            guard median > 0, row.value > 0 else { continue }

            let ratio = NSDecimalNumber(decimal: row.value / median).doubleValue
            guard ratio > factor || ratio < 1 / factor else { continue }
            out.append(PriceOutlier(priceID: row.id, date: row.date, value: row.value,
                                    neighbourMedian: median, ratio: ratio, source: row.source))
        }
        return out
    }
}

public extension PriceOutlier {
    /// The most likely explanation, from the ratio's shape.
    ///
    /// Named rather than left as a number because "this price is 100× its
    /// neighbours" is a fact, and "somebody typed cents where dollars were
    /// meant" is the thing a person can act on.
    enum Likely: String, Sendable {
        case decimalSlip      // 10×, 100×, 1000× or their reciprocals
        case wrongScale       // entered in cents, or in a currency far off
        case unexplained
    }

    var likelyCause: Likely {
        for power in [10.0, 100.0, 1000.0] {
            // Within 5% of a clean power of ten either way. A typo lands on the
            // power exactly; the tolerance is for a price that also moved.
            if abs(ratio - power) / power < 0.05 { return .decimalSlip }
            if abs(ratio - 1 / power) * power < 0.05 { return .decimalSlip }
        }
        return ratio > 20 || ratio < 0.05 ? .wrongScale : .unexplained
    }
}
