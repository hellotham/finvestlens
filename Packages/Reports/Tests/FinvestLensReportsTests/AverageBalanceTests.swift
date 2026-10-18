//
//  AverageBalanceTests.swift
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

@Suite("Average balance")
struct AverageBalanceTests {

    /// A UTC calendar keeps day boundaries deterministic across machines.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: "\(iso)T00:00:00Z")!
    }

    private func book() -> (Book, Account) {
        let book = Book(baseCurrency: .aud)
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        book.addAccount(bank)
        func post(_ iso: String, _ amount: String) {
            let txn = Transaction(currency: .aud, datePosted: date(iso), description: iso)
            txn.addSplit(account: bank, value: dec(amount), quantity: dec(amount))
            txn.addSplit(account: book.rootAccount, value: dec("-\(amount)"))
            book.addTransaction(txn)
        }
        // Mirrors the reference book's October Torrens shape: +100 on the 3rd,
        // +100 on the 17th, so daily balances are 0 (days 1–2), 100 (3–16),
        // 200 (17–31) → mean over 31 days.
        post("2025-10-03", "100")
        post("2025-10-17", "100")
        return (book, bank)
    }

    @Test("Monthly average is the mean of daily balances")
    func monthlyAverage() {
        let (book, _) = book()
        let report = FinancialReports.averageBalance(
            book, accounts: book.accounts.filter { $0.type == .bank },
            currency: .aud, from: date("2025-10-01"), to: date("2025-10-31"),
            step: .month, calendar: utc)

        #expect(report.intervals.count == 1)
        let october = report.intervals[0]
        // 0×2 + 100×14 + 200×15 = 4400 over 31 days.
        #expect(october.dayCount == 31)
        let expected = dec("4400") / dec("31")
        #expect(abs(october.average - expected) < dec("0.0000001"))
        #expect(october.maximum == dec("200"))
        #expect(october.minimum == dec("0"))
        #expect(october.gain == dec("200"))
        #expect(october.loss == dec("0"))
        #expect(october.profit == dec("200"))
    }

    @Test("A balance carried in from before the range seeds it without a flow")
    func priorBalance() {
        let (book, _) = book()   // +200 total, all before November
        let report = FinancialReports.averageBalance(
            book, accounts: book.accounts.filter { $0.type == .bank },
            currency: .aud, from: date("2025-11-01"), to: date("2025-11-30"),
            step: .month, calendar: utc)

        let november = report.intervals[0]
        // Flat at 200 the whole month; no postings, so no gain/loss.
        #expect(november.average == dec("200"))
        #expect(november.maximum == dec("200"))
        #expect(november.minimum == dec("200"))
        #expect(november.gain == dec("0"))
        #expect(november.loss == dec("0"))
        #expect(november.profit == dec("0"))
    }

    @Test("Weekly step splits the range into seven-day intervals")
    func weeklyStep() {
        let (book, _) = book()
        let report = FinancialReports.averageBalance(
            book, accounts: book.accounts.filter { $0.type == .bank },
            currency: .aud, from: date("2025-10-01"), to: date("2025-10-28"),
            step: .week, calendar: utc)

        // Four whole weeks: Oct 1–7, 8–14, 15–21, 22–28.
        #expect(report.intervals.count == 4)
        #expect(report.intervals.allSatisfy { $0.dayCount == 7 })
        // Week 1 (Oct 1–7): 0 on 1–2, 100 on 3–7 → 500/7.
        #expect(abs(report.intervals[0].average - dec("500") / dec("7")) < dec("0.0000001"))
        // Week 4 (Oct 22–28): flat at 200.
        #expect(report.intervals[3].average == dec("200"))
    }

    @Test("An outflow registers as loss and lowers the minimum")
    func outflow() {
        let book = Book(baseCurrency: .aud)
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        book.addAccount(bank)
        func post(_ iso: String, _ amount: String) {
            let txn = Transaction(currency: .aud, datePosted: date(iso), description: iso)
            txn.addSplit(account: bank, value: dec(amount), quantity: dec(amount))
            txn.addSplit(account: book.rootAccount, value: dec("-\(amount)"))
            book.addTransaction(txn)
        }
        post("2025-10-05", "300")
        post("2025-10-20", "-100")

        let report = FinancialReports.averageBalance(
            book, accounts: [bank], currency: .aud,
            from: date("2025-10-01"), to: date("2025-10-31"), step: .month, calendar: utc)
        let october = report.intervals[0]
        #expect(october.maximum == dec("300"))
        #expect(october.minimum == dec("0"))
        #expect(october.gain == dec("300"))
        #expect(october.loss == dec("100"))
        #expect(october.profit == dec("200"))
    }
}

/// The report as it was before it read each account's own legs (17 Oct 2026),
/// kept as the oracle the faster one must match interval for interval.
private func referenceAverageBalance(_ book: Book, accounts: [Account], currency: Commodity,
                                     from: Date, to: Date, step: AverageBalanceStep,
                                     calendar: Calendar) -> [AverageBalanceInterval] {
    let fromDay = calendar.startOfDay(for: from)
    let toDay = calendar.startOfDay(for: to)
    func value(_ native: Decimal, _ commodity: Commodity, on day: Date) -> Decimal {
        if native == 0 { return 0 }
        if commodity == currency { return native }
        return book.convert(native, from: commodity, to: currency, on: day) ?? 0
    }
    struct AccountState {
        let account: Account
        var running: Decimal
        var events: [(day: Date, delta: Decimal)]
        var cursor: Int = 0
    }
    var states: [AccountState] = accounts.map { account in
        var prior = Decimal(0)
        var events: [(Date, Decimal)] = []
        for transaction in book.transactions {
            let day = calendar.startOfDay(for: transaction.datePosted)
            for split in transaction.splits
            where split.account === account && split.reconcileState != .voided {
                if day < fromDay { prior += split.quantity }
                else if day <= toDay { events.append((day, split.quantity)) }
            }
        }
        events.sort { $0.0 < $1.0 }
        return AccountState(account: account, running: prior, events: events)
    }
    guard fromDay <= toDay, !states.isEmpty else { return [] }
    var boundaries: [Date] = []
    var boundary = fromDay
    while boundary <= toDay {
        boundaries.append(boundary)
        boundary = calendar.date(byAdding: step.components, to: boundary)!
    }
    var intervals: [AverageBalanceInterval] = []
    var boundaryIndex = 0
    var dailyBalances: [Decimal] = []
    var flows: [Decimal] = []
    func closeInterval(start: Date, endExclusive: Date) {
        let end = calendar.date(byAdding: .day, value: -1, to: endExclusive)!
        let count = dailyBalances.count
        let average = count > 0 ? dailyBalances.reduce(0, +) / Decimal(count) : 0
        let gain = flows.filter { $0 > 0 }.reduce(0, +)
        let loss = flows.filter { $0 < 0 }.reduce(0, +)
        intervals.append(AverageBalanceInterval(
            start: start, end: end, average: average,
            maximum: currency.round(dailyBalances.max() ?? 0),
            minimum: currency.round(dailyBalances.min() ?? 0),
            gain: currency.round(gain), loss: currency.round(-loss),
            profit: currency.round(gain + loss)))
        dailyBalances = []
        flows = []
    }
    var day = fromDay
    while day <= toDay {
        while boundaryIndex + 1 < boundaries.count, day >= boundaries[boundaryIndex + 1] {
            closeInterval(start: boundaries[boundaryIndex], endExclusive: boundaries[boundaryIndex + 1])
            boundaryIndex += 1
        }
        for index in states.indices {
            while states[index].cursor < states[index].events.count,
                  states[index].events[states[index].cursor].day == day {
                let delta = states[index].events[states[index].cursor].delta
                states[index].running += delta
                flows.append(value(delta, states[index].account.commodity, on: day))
                states[index].cursor += 1
            }
        }
        var balance = Decimal(0)
        for state in states { balance += value(state.running, state.account.commodity, on: day) }
        dailyBalances.append(balance)
        day = calendar.date(byAdding: .day, value: 1, to: day)!
    }
    closeInterval(start: boundaries[boundaryIndex],
                  endExclusive: calendar.date(byAdding: .day, value: 1, to: toDay)!)
    return intervals
}

@Suite("Average balance matches its reference")
struct AverageBalanceReferenceTests {

    @Test("Several accounts, two currencies, voided legs, a prior balance: every interval as before",
          arguments: AverageBalanceStep.allCases)
    func matchesReference(step: AverageBalanceStep) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let usd = book.addAccount(Account(name: "USD", type: .bank, commodity: .usd))
        let cash = book.addAccount(Account(name: "Cash", type: .cash, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        book.addPrice(Price(commodity: .usd, currency: .aud, date: base, value: Decimal(string: "1.5")!))
        book.addPrice(Price(commodity: .usd, currency: .aud, date: base.addingTimeInterval(86_400 * 40),
                            value: Decimal(string: "1.6")!))
        for index in 0..<90 {
            let posted = base.addingTimeInterval(Double(index) * 86_400 * 1.3 - 86_400 * 20)
            let txn = Transaction(currency: .aud, datePosted: posted)
            let amount = Decimal(index % 9 + 1) * (index % 3 == 0 ? -1 : 1)
            let account = [bank, usd, cash][index % 3]
            txn.addSplit(Split(account: account, value: amount, quantity: account === usd ? amount / 2 : amount,
                               reconcileState: index % 11 == 0 ? .voided : .notReconciled))
            txn.addSplit(account: food, value: -amount)
            book.addTransaction(txn)
        }
        let from = base, to = base.addingTimeInterval(86_400 * 75)
        let report = FinancialReports.averageBalance(book, accounts: [bank, usd, cash], currency: .aud,
                                                     from: from, to: to, step: step, calendar: calendar)
        let reference = referenceAverageBalance(book, accounts: [bank, usd, cash], currency: .aud,
                                                from: from, to: to, step: step, calendar: calendar)
        #expect(report.intervals == reference)
        #expect(!report.intervals.isEmpty)
    }

    @Test("All Time starts at the book's first entry, not in the year 1")
    func allTimeStartsWithTheBook() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let t = Transaction(currency: .aud, datePosted: first, description: "Pay")
        t.addSplit(account: bank, value: 100)
        t.addSplit(account: salary, value: -100)
        book.addTransaction(t)
        let report = FinancialReports.averageBalance(book, accounts: [bank], currency: .aud,
                                                     from: .distantPast,
                                                     to: first.addingTimeInterval(86_400 * 60),
                                                     step: .month)
        #expect(report.intervals.count <= 3)
        #expect((report.intervals.first?.start ?? .distantPast) >= Calendar.current.startOfDay(for: first))
    }
}
