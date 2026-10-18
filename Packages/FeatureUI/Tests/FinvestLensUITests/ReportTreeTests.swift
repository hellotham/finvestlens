//
//  ReportTreeTests.swift
//  FinvestLens — FeatureUI
//
//  Reports drawn as the account tree, every level (build 4: "Income and
//  expense report needs to break down into sub categories (recursively)",
//  "All reports should display max indentation depth"), and the Transaction
//  Report over many accounts with their subaccounts ("needs to show
//  transactions belong to all accounts … filter by subaccount (recursively)").
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Reports as the account tree")
struct ReportTreeTests {

    /// Expenses (a placeholder) ▸ Groceries ▸ Supermarket / Market, and
    /// Expenses ▸ Dining; Groceries carries postings of its own too.
    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank, expenses, groceries, supermarket, market, dining: GncGUID
        let from, to: Date
    }

    private func fixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let expenses = try #require(model.addAccount(name: "Expenses", type: .expense))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense, parentID: expenses))
        let supermarket = try #require(model.addAccount(name: "Supermarket", type: .expense, parentID: groceries))
        let market = try #require(model.addAccount(name: "Market", type: .expense, parentID: groceries))
        let dining = try #require(model.addAccount(name: "Dining", type: .expense, parentID: expenses))
        let placeholder = try #require(model.book?.account(with: expenses))
        model.editing(accounts: [expenses], named: "Placeholder") { placeholder.isPlaceholder = true }

        let (from, to) = model.resolve(.currentFinancialYear)
        let inside = Calendar.current.date(byAdding: .day, value: 20, to: from)!
        func spend(_ account: GncGUID, _ amount: String, on date: Date) throws {
            try model.addTransaction(date: date, description: "Spend", currency: .aud, splits: [
                SplitInput(accountID: account, value: dec(amount)),
                SplitInput(accountID: bank, value: -dec(amount))])
        }
        try spend(supermarket, "50", on: inside)
        try spend(market, "20", on: inside)
        try spend(groceries, "10", on: inside)
        try spend(dining, "30", on: inside)
        // Before the period: an opening balance, and nothing in the period's figures.
        try spend(dining, "5", on: Calendar.current.date(byAdding: .day, value: -10, to: from)!)
        return Fixture(model: model, url: url, bank: bank, expenses: expenses, groceries: groceries,
                       supermarket: supermarket, market: market, dining: dining, from: from, to: to)
    }

    @Test("Income & Expense breaks each category down, every level, largest first; the top row is its slice")
    func incomeExpenseBreakdown() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let configuration = ReportKind.incomeExpense.defaultConfiguration(for: f.model)
        var period = configuration
        period.period = .currentFinancialYear
        let document = try #require(f.model.reportDocument(for: period))
        let spending = try #require(document.sections.first { $0.title == "Spending by category" })
        let rows = spending.rows.map { "\(String(repeating: " ", count: $0.depth))\($0.label) \($0.amount ?? 0)" }
        #expect(rows == [
            "Expenses 110",
            " Groceries 80",
            "  Groceries (direct) 10",
            "  Supermarket 50",
            "  Market 20",
            " Dining 30",
        ])
        let breakdown = try #require(f.model.categoryBreakdown(from: f.from, to: f.to))
        #expect(spending.rows.first?.amount == breakdown.expenseSlices.first?.amount)
        #expect(spending.total?.amount == breakdown.totalExpenses)
    }

    @Test("The income statement is the same tree, by name, and its tops sum to the section")
    func incomeStatementTree() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        var configuration = ReportKind.incomeStatement.defaultConfiguration(for: f.model)
        configuration.period = .currentFinancialYear
        let document = try #require(f.model.reportDocument(for: configuration))
        let expenses = try #require(document.sections.first { $0.title == "Expenses" })
        #expect(expenses.rows.map(\.label) == ["Expenses", "Dining", "Groceries", "Groceries (direct)", "Market", "Supermarket"])
        #expect(expenses.rows.map(\.depth) == [0, 1, 1, 2, 2, 2])
        let tops = expenses.rows.filter { $0.depth == 0 }.compactMap(\.amount).reduce(0, +)
        #expect(tops == expenses.total?.amount)
    }

    @Test("Each node is rounded once, from the exact amounts beneath it")
    func roundedOncePerNode() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let lines = [f.supermarket, f.market].map { id in
            ReportLine(id: id, name: "", fullName: "", amount: dec("0.335"))
        } + [ReportLine(id: f.groceries, name: "", fullName: "", amount: dec("0.33"))]
        let rows = f.model.accountTreeRows([lines], round: { Commodity.aud.round($0) })
        let groceries = try #require(rows.first { $0.label == "Groceries" })
        // 0.335 + 0.335 + 0.33 = 1.00 exactly; the children print 0.34 and 0.34.
        #expect(groceries.amounts == [dec("1")])
        #expect(rows.first { $0.label == "Supermarket" }?.amounts == [dec("0.34")])
    }

    @Test("Side by side, a column with nothing beneath a row stays blank, and lines that are not accounts are kept")
    func columnsAndLooseLines() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let current = [ReportLine(id: f.market, name: "Market", fullName: "Expenses:Groceries:Market", amount: 4),
                       ReportLine(id: .random(), name: "Unrealised FX", fullName: "Trading", amount: 2)]
        let prior = [ReportLine(id: f.dining, name: "Dining", fullName: "Expenses:Dining", amount: 9)]
        let rows = f.model.accountTreeRows([current, prior])
        #expect(rows.first { $0.label == "Expenses" }?.amounts == [dec("4"), dec("9")])
        #expect(rows.first { $0.label == "Groceries" }?.amounts == [dec("4"), nil])
        #expect(rows.first { $0.label == "Dining" }?.amounts == [nil, dec("9")])
        // By its own name, not GnuCash's "Trading".
        #expect(rows.last?.label == "Unrealised FX")
        #expect(rows.last?.amounts == [dec("2"), nil])
    }

    @Test("The transaction report covers every account by default, grouped by account in name order")
    func transactionsAllAccounts() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let report = try #require(f.model.transactionReport(accountIDs: nil, from: f.from, to: f.to))
        #expect(report.groups.map(\.accountName) == [
            "Bank", "Expenses:Dining", "Expenses:Groceries",
            "Expenses:Groceries:Market", "Expenses:Groceries:Supermarket"])
        let dining = try #require(report.groups.first { $0.id == f.dining })
        #expect(dining.opening == dec("5"))
        #expect(dining.total == dec("30"))
        #expect(dining.closing == dec("35"))
        #expect(report.postingCount == 8)

        var configuration = ReportKind.transactions.defaultConfiguration(for: f.model)
        configuration.period = .currentFinancialYear
        let document = try #require(f.model.reportDocument(for: configuration))
        #expect(document.title == "Transactions — All Accounts")
        #expect(document.sections.count == 5)
        #expect(document.kpis.isEmpty)
    }

    @Test("Choosing a parent — a placeholder too — reports it and every subaccount beneath, every level")
    func transactionsSubtree() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let report = try #require(f.model.transactionReport(accountIDs: [f.expenses], from: f.from, to: f.to))
        #expect(Set(report.groups.map(\.id)) == [f.dining, f.groceries, f.market, f.supermarket])
        let groceries = try #require(f.model.transactionReport(accountIDs: [f.groceries], from: f.from, to: f.to))
        #expect(Set(groceries.groups.map(\.id)) == [f.groceries, f.market, f.supermarket])
        // One account: its own opening, change and closing as the headline —
        // even over a period with nothing in it.
        let one = try #require(f.model.transactionsDocument(accountIDs: [f.dining], from: f.from, to: f.to))
        #expect(one.kpis.map(\.amount) == [dec("5"), dec("30"), dec("35")])
        let later = Calendar.current.date(byAdding: .year, value: 2, to: f.to)!
        let quiet = try #require(f.model.transactionsDocument(accountIDs: [f.dining], from: later, to: later))
        #expect(quiet.kpis.map(\.amount) == [dec("35"), dec("0"), dec("35")])
        // A parent chosen shows no subaccount's figures as its own.
        let parent = try #require(f.model.transactionsDocument(accountIDs: [f.groceries], from: f.from, to: f.to))
        #expect(parent.kpis.isEmpty)
        // Sections are told apart by account, not by name.
        #expect(Set(parent.sections.map(\.id)).count == parent.sections.count)
    }

    @Test("The Account Summary opens on every level, and its stepper reaches the deepest")
    func accountSummaryEveryLevel() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let configuration = ReportKind.accountSummary.defaultConfiguration(for: f.model)
        #expect(configuration.depth == nil)
        #expect(f.model.accountTreeDepth == 3)
        let document = try #require(f.model.reportDocument(for: configuration))
        let expenses = try #require(document.sections.first { $0.title == "Expenses" })
        #expect(expenses.rows.contains { $0.label == "Supermarket" && $0.depth == 2 })
        // A parent is its subtree's total, with its own money as "(direct)";
        // the placeholder at the top carries everything.
        #expect(expenses.rows.first { $0.label == "Groceries" }?.amount == dec("80"))
        #expect(expenses.rows.first { $0.label == "Groceries (direct)" }?.amount == dec("10"))
        #expect(expenses.rows.first { $0.label == "Expenses" }?.amount == dec("115"))
    }

    @Test("Two accounts with one full name are two sections, not one drawn twice")
    func duplicateFullNames() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        // "Expenses:Dining" twice: a top-level account named with a colon.
        let impostor = try #require(f.model.addAccount(name: "Expenses:Dining", type: .expense))
        _ = try f.model.addTransaction(date: Calendar.current.date(byAdding: .day, value: 21, to: f.from)!,
                                       description: "Spend", currency: .aud,
                                       splits: [SplitInput(accountID: impostor, value: 7),
                                                SplitInput(accountID: f.bank, value: -7)])
        let document = try #require(f.model.transactionsDocument(accountIDs: nil, from: f.from, to: f.to))
        #expect(document.sections.filter { $0.title == "Expenses:Dining" }.count == 2)
        #expect(Set(document.sections.map(\.id)).count == document.sections.count)
    }

    @Test("Cash Flow lists where the money came from largest first, at every level")
    func cashFlowLargestFirst() throws {
        let f = try fixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let salary = try #require(f.model.addAccount(name: "Salary", type: .income))
        let refunds = try #require(f.model.addAccount(name: "Refunds", type: .income))
        for (account, amount) in [(salary, dec("3000")), (refunds, dec("5"))] {
            _ = try f.model.addTransaction(date: Calendar.current.date(byAdding: .day, value: 22, to: f.from)!,
                                           description: "In", currency: .aud,
                                           splits: [SplitInput(accountID: f.bank, value: amount),
                                                    SplitInput(accountID: account, value: -amount)])
        }
        var configuration = ReportKind.cashFlow.defaultConfiguration(for: f.model)
        configuration.period = .currentFinancialYear
        configuration.accountIDs = [f.bank]
        let document = try #require(f.model.reportDocument(for: configuration))
        let moneyIn = try #require(document.sections.first { $0.title == "Money in, from" })
        #expect(moneyIn.rows.map(\.label) == ["Salary", "Refunds"])
    }

    /// Every security account is in the Transactions report now, and its
    /// postings are units: GnuCash prints a non-ISO commodity as the number,
    /// no decimals forced, then its symbol (`gnc_commodity_print_info`).
    @Test("A security's units print as units, every recorded place, not as money")
    func securityUnits() {
        let units = AmountFormat.string(dec("1234.5678"), code: "XYZ")
        #expect(units.hasSuffix(" XYZ"))
        #expect(units.filter(\.isNumber) == "12345678")
        #expect(AmountFormat.string(120, code: "XYZ").filter(\.isNumber) == "120")
        #expect(AmountFormat.isCurrency("AUD") && AmountFormat.isCurrency("aud"))
        #expect(!AmountFormat.isCurrency("XYZ"))
        // Money is as it was.
        #expect(AmountFormat.string(dec("12.5"), code: "AUD") == dec("12.5").formatted(.currency(code: "AUD")))
    }
}
