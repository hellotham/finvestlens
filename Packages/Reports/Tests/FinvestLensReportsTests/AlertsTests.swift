//
//  AlertsTests.swift
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
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }

@Suite("Alerts engine")
struct AlertsTests {

    @Test("Overdue bill produces a critical alert")
    func billAlert() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: day(2026, 1, 1)),
            splits: [ScheduledSplit(accountGUID: rent.guid, value: dec("800")),
                     ScheduledSplit(accountGUID: bank.guid, value: dec("-800"))])

        let alerts = FinancialReports.alerts(book, scheduled: [sx], currency: .aud, asOf: day(2026, 2, 5))
        let overdue = alerts.first { $0.kind == .billDue }
        #expect(overdue?.severity == .critical)
        #expect(overdue?.title.contains("Rent") == true)
    }

    @Test("Over-budget spending produces a warning")
    func budgetAlert() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let t = Transaction(currency: .aud, datePosted: day(2026, 2, 10), description: "Groceries")
        t.addSplit(account: food, value: dec("500")); t.addSplit(account: bank, value: dec("-500"))
        book.addTransaction(t)
        var budget = Budget(name: "Monthly"); budget.setAmount(dec("300"), for: food.guid)

        let alerts = FinancialReports.alerts(book, budgets: [budget], currency: .aud, asOf: day(2026, 2, 20))
        #expect(alerts.contains { $0.kind == .overBudget && $0.severity == .warning })
    }

    @Test("Price target hit produces an info alert")
    func priceAlert() {
        let book = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA", fullName: "CBA", smallestFraction: 10000)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("110")))
        let target = PriceTarget(commodity: cba, target: dec("100"), direction: .atOrAbove)

        let alerts = FinancialReports.alerts(book, currency: .aud, asOf: day(2026, 2, 2), priceTargets: [target])
        #expect(alerts.contains { $0.kind == .priceTarget })
        // Below-target direction not hit.
        let below = PriceTarget(commodity: cba, target: dec("100"), direction: .atOrBelow)
        let none = FinancialReports.alerts(book, currency: .aud, asOf: day(2026, 2, 2), priceTargets: [below])
        #expect(none.contains { $0.kind == .priceTarget } == false)
    }

    @Test("Projected negative balance is critical")
    func lowBalanceAlert() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        // Small opening balance.
        let open = Transaction(currency: .aud, datePosted: day(2026, 1, 1), description: "Open")
        open.addSplit(account: bank, value: dec("100"))
        open.addSplit(account: book.rootAccount, value: dec("-100"))
        book.addTransaction(open)
        // Big monthly rent will drive it negative.
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: day(2026, 2, 1)),
            splits: [ScheduledSplit(accountGUID: rent.guid, value: dec("800")),
                     ScheduledSplit(accountGUID: bank.guid, value: dec("-800"))])

        let alerts = FinancialReports.alerts(book, scheduled: [sx], currency: .aud,
                                             asOf: day(2026, 1, 15), forecastAccountID: bank.guid)
        let low = alerts.first { $0.kind == .lowBalance }
        #expect(low?.severity == .critical)
    }
}

@Suite("Alerts engine (review pins)")
struct AlertsReviewPinTests {

    @Test("Income above its budget is favourable, not an over-budget warning")
    func incomeAbovePlanIsNotOverBudget() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let t = Transaction(currency: .aud, datePosted: day(2026, 2, 10), description: "Pay")
        t.addSplit(account: bank, value: dec("8500")); t.addSplit(account: salary, value: dec("-8500"))
        book.addTransaction(t)
        var budget = Budget(name: "Monthly"); budget.setAmount(dec("8000"), for: salary.guid)

        let alerts = FinancialReports.alerts(book, budgets: [budget], currency: .aud, asOf: day(2026, 2, 20))
        #expect(!alerts.contains { $0.kind == .overBudget })
    }

    @Test("Unusual spend: double the trailing average raises an info alert")
    func unusualSpend() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let dining = book.addAccount(Account(name: "Dining", type: .expense, commodity: .aud))
        // Six months at ~$200/month, then $850 in the current month.
        for month in 1...6 {
            let t = Transaction(currency: .aud, datePosted: day(2025, 6 + month, 10), description: "Dinner")
            t.addSplit(account: dining, value: dec("200")); t.addSplit(account: bank, value: dec("-200"))
            book.addTransaction(t)
        }
        let spike = Transaction(currency: .aud, datePosted: day(2026, 1, 12), description: "Banquet")
        spike.addSplit(account: dining, value: dec("850")); spike.addSplit(account: bank, value: dec("-850"))
        book.addTransaction(spike)

        let alerts = FinancialReports.alerts(book, currency: .aud, asOf: day(2026, 1, 20))
        let unusual = alerts.first { $0.kind == .unusualSpend }
        #expect(unusual != nil)
        #expect(unusual?.title.contains("Dining") == true)

        // A normal month raises nothing.
        let quiet = FinancialReports.alerts(book, currency: .aud, asOf: day(2025, 12, 20))
        #expect(!quiet.contains { $0.kind == .unusualSpend })
    }
}
