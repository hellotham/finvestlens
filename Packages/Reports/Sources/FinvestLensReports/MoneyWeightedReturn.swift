//
//  MoneyWeightedReturn.swift
//  FinvestLens — Reports
//
//  The money-weighted rate of return on a series of dated cash flows: the one
//  annual rate at which every flow, discounted back to the day of the first,
//  sums to nothing. It is what Excel prints for XIRR, and the figure a person
//  wants for a holding bought into more than once — each dollar counts from
//  the day it moved, so a top-up a month before the sale is not read as if it
//  had been working the whole time, which the simple gain ÷ cost ÷ years yield
//  (``InvestmentYield``) cannot help doing. On two flows it is the compound
//  annual growth rate GnuCash's lots report prints, (end ÷ basis)^(1 ÷ years)
//  − 1, so the two agree wherever both apply.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One movement of money on a day: negative when it left the person (a
/// purchase, brokerage), positive when it came back (a sale, a dividend — or,
/// for a position still open, what it is worth today, dated today).
public struct DatedCashFlow: Hashable, Sendable {
    public let date: Date
    public let amount: Decimal

    public init(date: Date, amount: Decimal) {
        self.date = date
        self.amount = amount
    }
}

/// Excel's XIRR, computed the way its documentation defines it (Microsoft
/// Support, "XIRR function"): the rate `r` at which
///
///     Σ Pᵢ ÷ (1 + r)^((dᵢ − d₁) ÷ 365) = 0
///
/// where "d₁ = the 0th payment date", "Pᵢ = the ith, or last, payment", and
/// "all succeeding payments are discounted based on a 365-day year". The same
/// page sets the terms this follows: "XIRR expects at least one positive cash
/// flow and one negative cash flow; otherwise, XIRR returns the #NUM! error
/// value"; the iteration runs until "the result is accurate within 0.000001
/// percent"; and "if XIRR can't find a result that works after 100 tries, the
/// #NUM! error value is returned". Doing it Excel's way, down to the day
/// count, means a figure here can be checked against a spreadsheet.
public enum MoneyWeightedReturn {

    /// Excel's year: whole calendar days over 365 — not the 365.25
    /// ``InvestmentYield`` annualises by — because XIRR is the yardstick here.
    public static let daysPerYear = 365.0

    /// "Accurate within 0.000001 percent": a rate step under this is done.
    static let rateTolerance = 1e-8

    /// Excel's "100 tries", given to each of the two searches below.
    static let maxIterations = 100

    /// A present value counts as nothing when it is under this share of the
    /// discounted flows' absolute sum: relative, so a book kept in cents and
    /// one kept in millions converge alike, and well above Double's rounding.
    static let residualTolerance = 1e-9

    /// Where the fallback looks for a rate: from losing all but a millionth
    /// of the money a year to an elevenfold gain a year.
    static let searchRange = (lower: -0.999999, upper: 10.0)

    /// The annualised rate, or `nil` when it is undefined: fewer than two
    /// flows, no sign change, a span under one day, or no convergence.
    ///
    /// Newton–Raphson starts from `guess` (Excel's default, 0.1) with the
    /// analytic slope and gets Excel's hundred tries. If a step would leave
    /// the domain (a rate at or below −100%), the slope is flat, or three
    /// steps running fail to shrink the residual — the signature of
    /// oscillation — a bracketing search takes over: it samples the present
    /// value across ``searchRange`` for a sign change, then closes in with
    /// Newton steps held inside the bracket (bisecting when a step would
    /// escape it), with a hundred tries of its own. Either search finishes
    /// when a step is under 0.000001 percent *and* the present value is
    /// nothing. A series whose only rate lies outside the bracket, or whose
    /// value never crosses zero inside it, comes back `nil`: the report shows
    /// a blank, never a guess. Like Excel's, the answer for a series whose
    /// flows change sign more than once — which can have several rates — is
    /// the one Newton reaches first from `guess`.
    public static func rate(of flows: [DatedCashFlow], guess: Double = 0.1) -> Double? {
        guard flows.count >= 2 else { return nil }
        let sorted = flows.sorted { $0.date < $1.date }
        let first = sorted[0].date
        guard wholeCalendarDays(from: first, to: sorted[sorted.count - 1].date) >= 1 else { return nil }
        let terms = sorted.map { flow in
            Term(years: Double(wholeCalendarDays(from: first, to: flow.date)) / daysPerYear,
                 amount: InvestmentYield.double(flow.amount))
        }
        guard terms.contains(where: { $0.amount > 0 }), terms.contains(where: { $0.amount < 0 }) else { return nil }
        let start = guess.isFinite && guess > -1 ? guess : 0.1
        return newton(terms, from: start) ?? bracketed(terms)
    }

    // MARK: - The arithmetic

    /// One flow as the equation sees it: years from the first date, and the
    /// amount as a Double — the iteration is floating-point work, and what it
    /// returns is a rate, not money.
    private struct Term {
        let years: Double
        let amount: Double
    }

    /// The present value at a rate, its slope there, and the absolute sum of
    /// the discounted flows the residual is read against.
    private struct Evaluation {
        let value: Double
        let slope: Double
        let scale: Double

        var isFinite: Bool { value.isFinite && slope.isFinite && scale.isFinite }
    }

    private static func evaluate(_ terms: [Term], at rate: Double) -> Evaluation {
        var value = 0.0, slope = 0.0, scale = 0.0
        for term in terms {
            let discounted = term.amount * pow(1 + rate, -term.years)
            value += discounted
            // d/dr of P (1 + r)^(−t) is −t P (1 + r)^(−t − 1).
            slope -= term.years * discounted / (1 + rate)
            scale += abs(discounted)
        }
        return Evaluation(value: value, slope: slope, scale: scale)
    }

    private static func converged(step: Double, at evaluation: Evaluation) -> Bool {
        abs(step) < rateTolerance && abs(evaluation.value) <= residualTolerance * evaluation.scale
    }

    /// Plain Newton–Raphson from `start`; `nil` when it leaves the domain,
    /// finds no slope, stops making progress, or runs out of tries.
    private static func newton(_ terms: [Term], from start: Double) -> Double? {
        var rate = start
        var current = evaluate(terms, at: rate)
        var stalled = 0
        for _ in 0..<maxIterations {
            guard current.isFinite, current.slope != 0 else { return nil }
            let step = current.value / current.slope
            let next = rate - step
            guard next.isFinite, next > -1 else { return nil }
            let after = evaluate(terms, at: next)
            guard after.isFinite else { return nil }
            if converged(step: step, at: after) { return next }
            if abs(after.value) >= abs(current.value) {
                stalled += 1
                if stalled >= 3 { return nil }
            } else {
                stalled = 0
            }
            rate = next
            current = after
        }
        return nil
    }

    /// Bracket a sign change of the present value inside ``searchRange``,
    /// then close in on it; `nil` when there is none to find.
    private static func bracketed(_ terms: [Term]) -> Double? {
        let samples = 221   // 0.05 apart across the range
        var previous: (rate: Double, value: Double)?
        for index in 0..<samples {
            let rate = searchRange.lower
                + (searchRange.upper - searchRange.lower) * Double(index) / Double(samples - 1)
            let value = evaluate(terms, at: rate).value
            guard value.isFinite else { previous = nil; continue }
            if value == 0 { return rate }
            if let previous, (previous.value < 0) != (value < 0) {
                return close(terms, lower: previous.rate, upper: rate)
            }
            previous = (rate, value)
        }
        return nil
    }

    /// Newton steps kept inside a bracket known to hold a root, bisecting
    /// whenever a step would leave it — so it cannot wander off the way the
    /// unguarded search can, yet lands on the root to full precision rather
    /// than at bisection's last halving.
    private static func close(_ terms: [Term], lower: Double, upper: Double) -> Double? {
        var lower = lower, upper = upper
        var lowerValue = evaluate(terms, at: lower).value
        var rate = (lower + upper) / 2
        var current = evaluate(terms, at: rate)
        for _ in 0..<maxIterations {
            guard current.isFinite else { return nil }
            if current.value == 0 { return rate }
            if (current.value < 0) == (lowerValue < 0) {
                lower = rate
                lowerValue = current.value
            } else {
                upper = rate
            }
            var next = current.slope == 0 ? Double.nan : rate - current.value / current.slope
            if !(next > lower && next < upper) { next = (lower + upper) / 2 }
            let after = evaluate(terms, at: next)
            let step = next - rate
            rate = next
            current = after
            if converged(step: step, at: after) { return rate }
        }
        return nil
    }
}
