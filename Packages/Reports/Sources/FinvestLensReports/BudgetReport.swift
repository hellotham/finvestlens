//
//  BudgetReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Budgeted vs actual for one account over a period.
public struct BudgetActual: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var accountName: String
    public var budgeted: Decimal
    /// Rollover carried in from the prior period (0 unless the line rolls over).
    public var carryover: Decimal
    public var actual: Decimal
    /// Budgeted + carryover − actual (positive = under budget).
    public var remaining: Decimal
    /// Fraction of the effective budget spent (0…), or `nil` when nothing is
    /// budgeted.
    public var fractionUsed: Double?
    /// Budget after carryover.
    public var effectiveBudget: Decimal { budgeted + carryover }
    public var isOverBudget: Bool { remaining < 0 }
}

/// A zero-based summary: is every budgeted dollar of income assigned to an
/// expense/saving? (`FR-PLAN-04`).
public struct BudgetSummary: Sendable {
    public var incomeBudget: Decimal
    public var expenseBudget: Decimal
    /// Income budget minus expense budget (0 = fully allocated / zero-based).
    public var unallocated: Decimal
}

public extension FinancialReports {

    /// Budget-vs-actual for each budgeted account over `from`…`to`
    /// (`FR-BUD-02`). Actuals use the same sign-adjusted period balance as the
    /// income statement (so expense spending is positive). For rollover lines,
    /// the unspent remainder of the immediately-preceding period of equal length
    /// is carried into the effective budget.
    /// - Parameter period: when given, budgeted amounts use that period's value
    ///   (GnuCash's per-period budget); `nil` uses each line's flat amount.
    static func budgetActuals(_ book: Book, budget: Budget, from: Date, to: Date,
                              currency: Commodity, period: Int? = nil) -> [BudgetActual] {
        // The prior period must end strictly *before* `from`: displayBalance is
        // inclusive at both ends, so sharing the `from` instant would count a
        // posting dated exactly at `from` in both the prior and current windows.
        let priorTo = from.addingTimeInterval(-1)
        // …and it must be the preceding *calendar* period, not the preceding
        // N seconds. Months are 28–31 days long, so stepping back by the
        // current window's duration lands mid-month: the prior period for
        // March ran 29 January – 28 February, pulling three days of January
        // spending into February's unspent remainder and carrying the wrong
        // figure forward. Measuring the window in calendar components and
        // subtracting those handles months, quarters, years and plain day
        // counts alike. `Calendar.current` is the reports' convention
        // throughout (deferred.md ▸ local-time date bucketing).
        // Measured in the calendar the window was **built** in, which for the
        // budget surfaces is UTC (`AppModel.budgetActuals` pins it explicitly).
        // Measuring a UTC-built window with `Calendar.current` folds the
        // reader's offset into the span: for a New York reader, March 2026
        // measured as "1 month 3 hours" and the prior period began 25 January —
        // a week of January spending inside February's remainder, and a
        // different answer in every timezone. deferred.md's local-time
        // convention governs which day a *posting* falls in, not how long a
        // window already expressed in UTC is.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let priorFrom = Self.periodStart(before: from, coveringThrough: to, calendar: cal)

        return budget.lines.compactMap { line -> BudgetActual? in
            guard let account = book.account(with: line.accountGUID) else { return nil }
            // Closing entries excluded, as everywhere else that totals a
            // period: they zero every budgeted income and expense account, so
            // a closed year's Budget vs Actual otherwise read $0 on every line
            // beside an Income Statement that reads correctly.
            let actual = currency.round(displayBalance(of: account, in: book, from: from, to: to,
                                                       excludingClosing: true))
            let budgeted = currency.round(period.map { line.amount(inPeriod: $0) } ?? line.amount)

            var carryover = Decimal(0)
            if line.rollover {
                let priorActual = currency.round(displayBalance(of: account, in: book,
                                                                from: priorFrom, to: priorTo,
                                                                excludingClosing: true))
                carryover = currency.round(budgeted - priorActual)
            }
            let effective = budgeted + carryover
            let fraction: Double? = effective == 0 ? nil
                : NSDecimalNumber(decimal: actual).doubleValue / NSDecimalNumber(decimal: effective).doubleValue
            return BudgetActual(
                id: account.guid,
                accountName: account.name,
                budgeted: budgeted,
                carryover: carryover,
                actual: actual,
                remaining: currency.round(effective - actual),
                fractionUsed: fraction
            )
        }
        .sorted { $0.accountName < $1.accountName }
    }

    /// The start of the calendar period immediately preceding `from`, given a
    /// current window of `from`…`through` (both inclusive).
    ///
    /// The window is measured in calendar components rather than seconds, so a
    /// month steps back a month whatever its length, a quarter a quarter, and
    /// an arbitrary run of days that many days.
    ///
    /// Public because every "compare against the period before" surface needs
    /// the same answer — ``AppModel/spendingInsights(period:)`` kept its own
    /// seconds-based copy and so drew March against 29 January – 28 February.
    public static func periodStart(before from: Date, coveringThrough through: Date,
                                   calendar cal: Calendar = .current) -> Date {
        // Measure to the *exclusive* end so a whole month reads as exactly one
        // month rather than "30 days, 23 hours, 59 minutes and 59 seconds".
        // Measured *backwards*, so the calendar hands back the negated span
        // itself rather than six components negated by hand — and there is no
        // seconds-arithmetic fallback left to regress into.
        let exclusiveEnd = through.addingTimeInterval(1)
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                      from: exclusiveEnd, to: from)
        return cal.date(byAdding: back, to: from) ?? from
    }

    /// Zero-based summary of a budget: total income budget vs total expense
    /// budget, and what's left to allocate (`FR-PLAN-04`).
    static func budgetSummary(_ book: Book, budget: Budget, currency: Commodity) -> BudgetSummary {
        var income = Decimal(0)
        var expense = Decimal(0)
        for line in budget.lines {
            guard let type = book.account(with: line.accountGUID)?.type else { continue }
            if type == .income { income += line.amount }
            else if type == .expense { expense += line.amount }
        }
        return BudgetSummary(incomeBudget: currency.round(income),
                             expenseBudget: currency.round(expense),
                             unallocated: currency.round(income - expense))
    }
}
