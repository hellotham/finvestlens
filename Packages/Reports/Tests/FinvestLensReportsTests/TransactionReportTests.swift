//
//  TransactionReportTests.swift
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
private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

@Suite("Transaction report")
struct TransactionReportTests {

    private func book() -> (Book, Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        func tx(_ d: Int, _ desc: String, _ to: Account, _ amount: Decimal) {
            let t = Transaction(currency: .aud, datePosted: day(d), description: desc)
            t.addSplit(account: bank, value: amount)
            t.addSplit(account: to, value: -amount)
            book.addTransaction(t)
        }
        tx(0, "Opening pay", income, dec("1000"))     // before period
        tx(10, "Groceries", food, dec("-50"))
        tx(20, "Pay", income, dec("500"))
        return (book, bank)
    }

    @Test("Running balance seeded by opening, postings in period, totals")
    func report() {
        let (book, bank) = book()
        let report = FinancialReports.transactionReport(book, accountID: bank.guid,
                                                        from: day(5), to: day(30))!
        #expect(report.opening == dec("1000"))
        #expect(report.rows.count == 2)
        #expect(report.rows[0].balance == dec("950"))    // 1000 − 50
        #expect(report.rows[0].transfer == "Food")
        #expect(report.rows[1].balance == dec("1450"))   // 950 + 500
        #expect(report.total == dec("450"))
        #expect(report.closing == dec("1450"))
    }

    @Test("Same-day postings run in the register's order, whatever order they were entered in")
    func sameDayInRegisterOrder() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        // Cheque 2 entered before cheque 1, both on day 3.
        for (num, amount) in [("2", dec("-100")), ("1", dec("1000"))] {
            let t = Transaction(currency: .aud, datePosted: day(3), description: "Cheque \(num)")
            t.number = num
            t.addSplit(account: bank, value: amount)
            t.addSplit(account: rent, value: -amount)
            book.addTransaction(t)
        }
        let report = FinancialReports.transactionReport(book, accountID: bank.guid,
                                                        from: day(0), to: day(10))!
        #expect(report.rows.map(\.description) == ["Cheque 1", "Cheque 2"])
        #expect(report.rows.map(\.balance) == [dec("1000"), dec("900")])
    }

    @Test("A chosen account with nothing in the period still has its opening and closing")
    func quietAccount() {
        let (book, bank) = book()
        let report = FinancialReports.transactionReport(book, accountID: bank.guid,
                                                        from: day(40), to: day(50))!
        #expect(report.rows.isEmpty)
        #expect(report.opening == dec("1450"))
        #expect(report.closing == dec("1450"))
        // Chosen alone, the many-account report keeps it, for those figures…
        let alone = FinancialReports.transactionReport(book, accountIDs: [bank.guid],
                                                       from: day(40), to: day(50))
        #expect(alone.groups.map(\.id) == [bank.guid])
        #expect(alone.groups.first?.opening == dec("1450"))
        #expect(alone.groups.first?.closing == dec("1450"))
        // …and among every account, a quiet one is left out.
        #expect(FinancialReports.transactionReport(book, accountIDs: nil,
                                                   from: day(40), to: day(50)).groups.isEmpty)
    }

    @Test("A chosen parent brings every subaccount, every level; nothing chosen is every account")
    func scopes() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let expenses = book.addAccount(Account(name: "Expenses", type: .expense, commodity: .aud))
        let home = book.addAccount(Account(name: "Home", type: .expense, commodity: .aud), under: expenses)
        let power = book.addAccount(Account(name: "Power", type: .expense, commodity: .aud), under: home)
        for (account, amount) in [(home, dec("10")), (power, dec("20"))] {
            let t = Transaction(currency: .aud, datePosted: day(2), description: "Bill")
            t.addSplit(account: account, value: amount)
            t.addSplit(account: bank, value: -amount)
            book.addTransaction(t)
        }
        let chosen = FinancialReports.transactionReport(book, accountIDs: [expenses.guid], from: day(0), to: day(9))
        #expect(chosen.groups.map(\.accountName) == ["Expenses:Home", "Expenses:Home:Power"])
        let all = FinancialReports.transactionReport(book, accountIDs: nil, from: day(0), to: day(9))
        #expect(all.groups.map(\.accountName) == ["Bank", "Expenses:Home", "Expenses:Home:Power"])
        #expect(all.postingCount == 4)
    }
}
