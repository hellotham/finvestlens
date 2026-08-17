//
//  BudgetReportTests.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Budget vs actual")
struct BudgetReportTests {

    @Test("Compares budgeted amounts to actual spending")
    func budgetActuals() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
        let dining = book.addAccount(Account(name: "Dining", type: .expense, commodity: .aud))

        // Spend $450 groceries and $120 dining in January.
        let shop = Transaction(currency: .aud, datePosted: day(2026, 1, 10), description: "Shop")
        shop.addSplit(account: groceries, value: dec("450"))
        shop.addSplit(account: bank, value: dec("-450"))
        book.addTransaction(shop)
        let meal = Transaction(currency: .aud, datePosted: day(2026, 1, 20), description: "Dinner")
        meal.addSplit(account: dining, value: dec("120"))
        meal.addSplit(account: bank, value: dec("-120"))
        book.addTransaction(meal)

        var budget = Budget(name: "Monthly")
        budget.setAmount(dec("400"), for: groceries.guid)   // over by 50
        budget.setAmount(dec("200"), for: dining.guid)      // under by 80

        let actuals = FinancialReports.budgetActuals(book, budget: budget,
                                                     from: day(2026, 1, 1), to: day(2026, 1, 31),
                                                     currency: .aud)
        let g = actuals.first { $0.accountName == "Groceries" }!
        #expect(g.budgeted == dec("400"))
        #expect(g.actual == dec("450"))
        #expect(g.remaining == dec("-50"))
        #expect(g.isOverBudget)

        let d = actuals.first { $0.accountName == "Dining" }!
        #expect(d.actual == dec("120"))
        #expect(d.remaining == dec("80"))
        #expect(!d.isOverBudget)
    }

    @Test("Budget round-trips through Codable")
    func codable() throws {
        var budget = Budget(name: "B")
        budget.setAmount(dec("100"), for: .random())
        let data = try JSONEncoder().encode(budget)
        let decoded = try JSONDecoder().decode(Budget.self, from: data)
        #expect(decoded == budget)
    }
}

@Suite("Budget rollover window")
struct BudgetRolloverWindowTests {

    private func local(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test("March's prior period is the whole of February, not 29 Jan – 28 Feb")
    func priorPeriodIsACalendarMonth() {
        // The window used to be stepped back by its own duration in *seconds*.
        // March is 31 days, February 28, so "the previous period" began on
        // 29 January and dragged three days of January spending into
        // February's unspent remainder.
        let cal = Calendar.current
        let from = local(2026, 3, 1)
        let through = cal.date(byAdding: DateComponents(month: 1, second: -1), to: from)!
        let priorFrom = FinancialReports.periodStart(before: from, coveringThrough: through,
                                                     calendar: cal)
        #expect(priorFrom == local(2026, 2, 1))
    }

    @Test("A quarter steps back a quarter, and a day count steps back that many days")
    func otherPeriodLengths() {
        let cal = Calendar.current
        let q = local(2026, 4, 1)
        let qEnd = cal.date(byAdding: DateComponents(month: 3, second: -1), to: q)!
        #expect(FinancialReports.periodStart(before: q, coveringThrough: qEnd, calendar: cal)
                == local(2026, 1, 1))

        // Ten days, 5–14 March inclusive: the ten before it are 23 Feb – 4 Mar.
        let d = local(2026, 3, 5)
        let dEnd = cal.date(byAdding: DateComponents(day: 10, second: -1), to: d)!
        #expect(FinancialReports.periodStart(before: d, coveringThrough: dEnd, calendar: cal)
                == local(2026, 2, 23))
    }

    @Test("A leap February is a month, not 29 days of the next one")
    func leapYear() {
        let cal = Calendar.current
        let from = local(2024, 3, 1)
        let through = cal.date(byAdding: DateComponents(month: 1, second: -1), to: from)!
        #expect(FinancialReports.periodStart(before: from, coveringThrough: through, calendar: cal)
                == local(2024, 2, 1))
    }
}

@Suite("Rollover window is timezone-independent")
struct BudgetRolloverTimezoneTests {

    /// The budget surfaces build their windows in UTC, so the span must be
    /// measured in UTC too. Measured in the reader's calendar, a New York
    /// reader's March prior-period began 25 January — a week of January
    /// spending folded into February's unspent remainder, and a different
    /// answer in every timezone.
    @Test("A UTC-built month measures as one month whatever the reader's zone")
    func utcWindowMeasuredInUTC() {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let from = utcCal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let to = utcCal.date(byAdding: DateComponents(month: 1, second: -1), to: from)!
        let expected = utcCal.date(from: DateComponents(year: 2026, month: 2, day: 1))!

        #expect(FinancialReports.periodStart(before: from, coveringThrough: to,
                                             calendar: utcCal) == expected)
        // At least one real reader zone diverges — which is the whole point
        // of pinning the calendar rather than taking the reader's.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(FinancialReports.periodStart(before: from, coveringThrough: to,
                                             calendar: ny) != expected)
    }
}
