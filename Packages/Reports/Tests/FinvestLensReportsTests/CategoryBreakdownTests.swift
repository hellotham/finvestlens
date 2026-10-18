//
//  CategoryBreakdownTests.swift
//  FinvestLens — Reports
//
//  The pie and the bars are bound to the income statement: slices sum to its
//  totals, months sum to the slices. Three views of a period that cannot tell
//  three stories — that binding is what these tests pin.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

@Suite("Category breakdown")
struct CategoryBreakdownTests {

    /// A UTC calendar, so "which month is this posting in" does not depend on
    /// where the test machine happens to be.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    /// Two months of living: salary in, groceries under a Food parent, rent
    /// flat — so there is a subtree to roll and months to cut.
    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let food = Account(name: "Food", type: .expense, commodity: .aud)
        food.isPlaceholder = true
        _ = book.addAccount(food)
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense,
                                                commodity: .aud), under: food)
        let dining = book.addAccount(Account(name: "Dining", type: .expense,
                                             commodity: .aud), under: food)
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))

        func post(_ from: Account, _ to: Account, _ amount: Decimal, day n: Int) {
            let txn = Transaction(currency: .aud, datePosted: day(n), description: "t")
            txn.addSplit(account: to, value: amount)
            txn.addSplit(account: from, value: -amount)
            book.addTransaction(txn)
        }
        // January 1970 (days 0–30) and February (31–58).
        post(salary, bank, 5000, day: 5)
        post(bank, groceries, 400, day: 6)
        post(bank, dining, 100, day: 7)
        post(bank, rent, 2000, day: 8)
        post(salary, bank, 5000, day: 36)
        post(bank, groceries, 450, day: 37)
        post(bank, rent, 2000, day: 38)
        return book
    }

    /// The binding: slices sum to the income statement's totals.
    @Test("Slices sum to the income statement")
    func slicesMatchStatement() {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        let statement = FinancialReports.incomeStatement(book, from: day(0), to: day(60),
                                                         currency: .aud)
        #expect(breakdown.totalExpenses == statement.totalExpenses)
        #expect(breakdown.totalIncome == statement.totalIncome)
        #expect(breakdown.expenseSlices.reduce(Decimal(0)) { $0 + $1.amount }
                == breakdown.totalExpenses)
        #expect(breakdown.incomeSlices.reduce(Decimal(0)) { $0 + $1.amount }
                == breakdown.totalIncome)
    }

    /// One slice per *top-level* category: the Food subtree is one slice, not a
    /// slice per grocery run.
    @Test("A subtree is one slice, rolled")
    func subtreesRoll() throws {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        #expect(breakdown.expenseSlices.map(\.name) == ["Rent", "Food"])   // largest first
        #expect(try #require(breakdown.expenseSlices.first { $0.name == "Food" }).amount == 950)
        #expect(try #require(breakdown.expenseSlices.first { $0.name == "Rent" }).amount == 4000)
    }

    /// …and the months sum to the slices.
    @Test("Months sum to the period")
    func monthsSumToPeriod() {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        #expect(breakdown.months.count == 2)
        #expect(breakdown.months.reduce(Decimal(0)) { $0 + $1.income } == breakdown.totalIncome)
        #expect(breakdown.months.reduce(Decimal(0)) { $0 + $1.expenses }
                == breakdown.totalExpenses)
    }

    @Test("Each month carries its own money")
    func monthCut() throws {
        let book = makeBook()
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        let january = try #require(breakdown.months.first)
        let february = try #require(breakdown.months.last)
        #expect(january.income == 5000)
        #expect(january.expenses == 2500)     // 400 + 100 + 2000
        #expect(february.income == 5000)
        #expect(february.expenses == 2450)    // 450 + 2000
    }

    @Test("The period bounds are real")
    func periodBounds() {
        let book = makeBook()
        let januaryOnly = FinancialReports.categoryBreakdown(book, from: day(0), to: day(30),
                                                             currency: .aud, calendar: utc)
        #expect(januaryOnly.totalExpenses == 2500)
        #expect(januaryOnly.months.count == 1)
    }

    @Test("A category quiet in the period is not a slice")
    func quietCategoriesVanish() {
        let book = makeBook()
        _ = book.addAccount(Account(name: "Holidays", type: .expense, commodity: .aud))
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(60),
                                                           currency: .aud, calendar: utc)
        #expect(!breakdown.expenseSlices.contains { $0.name == "Holidays" })
    }

    @Test("The totals alone are the breakdown's totals, for any window")
    func totalsAreTheBreakdowns() {
        let book = makeBook()
        // A USD expense, valued through a rate, and a closing entry, which
        // both paths leave out.
        let usd = book.addAccount(Account(name: "Travel", type: .expense, commodity: .usd))
        let bank = book.accounts.first { $0.name == "Bank" }!
        book.addPrice(Price(commodity: .usd, currency: .aud, date: day(1), value: Decimal(string: "1.5")!))
        let trip = Transaction(currency: .aud, datePosted: day(40), description: "Trip")
        trip.addSplit(Split(account: usd, value: 150, quantity: 100))
        trip.addSplit(account: bank, value: -150)
        book.addTransaction(trip)
        let close = Transaction(currency: .aud, datePosted: day(58), description: "Close")
        close.kvp["book_closing"] = .int64(1)
        close.addSplit(account: book.accounts.first { $0.name == "Salary" }!, value: 10_000)
        close.addSplit(account: bank, value: -10_000)
        book.addTransaction(close)

        for (from, to) in [(day(0), day(58)), (day(0), day(30)), (day(31), day(58)), (day(6), day(7))] {
            let full = FinancialReports.categoryBreakdown(book, from: from, to: to, currency: .aud)
            let totals = FinancialReports.categoryTotals(book, from: from, to: to, currency: .aud)
            #expect(totals.income == full.totalIncome)
            #expect(totals.expenses == full.totalExpenses)
        }
    }

    @Test("Several windows' totals in one walk are each window's own")
    func windowedTotals() {
        let book = makeBook()
        let windows = [(day(0), day(58)), (day(0), day(30)), (day(31), day(58)), (day(6), day(7))]
        let together = FinancialReports.categoryTotals(book, windows: windows.map { (from: $0.0, to: $0.1) },
                                                       currency: .aud)
        for ((from, to), totals) in zip(windows, together) {
            let alone = FinancialReports.categoryTotals(book, from: from, to: to, currency: .aud)
            #expect(totals.income == alone.income && totals.expenses == alone.expenses)
        }
    }

    @Test("Lifetime buckets from balances already walked are the ones it walks for")
    func bucketsFromGivenBalances() {
        let book = makeBook()
        let asOf = day(45)
        let walked = FinancialReports.lifetimeBuckets(book, currency: .aud, asOf: asOf) { _ in false }
        let given = FinancialReports.lifetimeBuckets(
            book, currency: .aud, asOf: asOf,
            balances: book.balancesByAccount(from: nil, to: asOf)) { _ in false }
        #expect(given == walked)
    }

    @Test("Each category's accounts are everything under its top level, so they sum to its slice — mixed types included")
    func accountsSumToSlices() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = book.addAccount(Account(name: "Income", type: .income, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud), under: income)
        // An expense account under an income one, as GnuCash allows.
        let withheld = book.addAccount(Account(name: "Withheld", type: .expense, commodity: .aud), under: salary)
        let expenses = book.addAccount(Account(name: "Expenses", type: .expense, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud), under: expenses)
        func post(_ a: Account, _ b: Account, _ amount: Decimal) {
            let t = Transaction(currency: .aud, datePosted: day(5), description: "Move")
            t.addSplit(account: a, value: amount)
            t.addSplit(account: b, value: -amount)
            book.addTransaction(t)
        }
        post(bank, salary, 5000)
        post(withheld, bank, 1000)
        post(food, bank, 300)
        let breakdown = FinancialReports.categoryBreakdown(book, from: day(0), to: day(30),
                                                           currency: .aud, calendar: utc)
        func sum(_ lines: [ReportLine]) -> Decimal { lines.reduce(0) { $0 + $1.amount } }
        #expect(sum(breakdown.expenseAccounts) == sum(breakdown.expenseSlices))
        #expect(sum(breakdown.incomeAccounts) == sum(breakdown.incomeSlices))
        #expect(breakdown.expenseAccounts.map(\.name) == ["Food"])
        #expect(Set(breakdown.incomeAccounts.map(\.name)) == ["Salary", "Withheld"])
    }
}
