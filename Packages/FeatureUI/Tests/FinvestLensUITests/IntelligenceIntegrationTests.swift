//
//  IntelligenceIntegrationTests.swift
//  FinvestLens — FeatureUI
//
//  Deterministic halves of the Apple Intelligence features: uncategorised
//  detection and re-assignment, dividend booking with franking credits,
//  duplicate-match reconciliation, budget-suggestion application, and the
//  spending statistics fed to the budget advisor. (Model calls themselves
//  are exercised manually — they are nondeterministic and need the
//  on-device model.)
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensIntelligence
@testable import FinvestLensUI

/// A `yyyy-MM-dd` day, for tests that care which day something is on.
private func day(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: text)
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Intelligence integration")
struct IntelligenceIntegrationTests {

    @Test("Uncategorised items are found in Imbalance accounts and re-assignable")
    func uncategorized() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))

        _ = try model.addTransaction(date: Date(), description: "WOOLWORTHS", currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -50),
                                              SplitInput(accountID: imbalance, value: 50)])

        let items = model.uncategorizedItems()
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.transactionDescription == "WOOLWORTHS")
        #expect(item.amount == 50)

        #expect(model.applyCategorization(plans: [], assignments: [item.splitID: groceries]) == 1)
        #expect(model.uncategorizedItems().isEmpty)
        let book = try #require(model.book)
        let account = try #require(book.account(with: groceries))
        #expect(book.splits(for: account).count == 1)
    }

    @Test("Dividend with franking credits books five balanced splits and creates accounts")
    func dividendWithCredits() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let details = DividendStatementDetails(
            securityName: "Vanguard Australian Shares", ticker: "VAS",
            paymentDate: Date(),
            frankedAmount: 70, unfrankedAmount: 30, frankingCredits: 30, netPayment: 100
        )
        let id = try model.recordDividend(details, cashAccountID: bank)

        let book = try #require(model.book)
        let transaction = try #require(book.transaction(with: id))
        #expect(transaction.splits.count == 5)
        #expect(transaction.isBalanced)
        #expect(transaction.tags.contains("dividend"))

        // The cash leg carries exactly the net payment.
        let bankAccount = try #require(book.account(with: bank))
        #expect(book.balance(of: bankAccount).amount == 100)

        // Standard accounts were created on demand.
        for path in ["Income:Dividends:Franked Dividends",
                     "Income:Dividends:Unfranked Dividends",
                     "Income:Dividends:Franking Credits",
                     "Assets:Franking Credits Receivable"] {
            #expect(book.accounts.contains { $0.fullName == path }, "missing \(path)")
        }
    }

    @Test("Dividend without gross-up books only cash and income components")
    func dividendWithoutCredits() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let details = DividendStatementDetails(
            securityName: "Test Co", ticker: "TST",
            frankedAmount: 70, unfrankedAmount: 30, frankingCredits: 30, netPayment: 100
        )
        let id = try model.recordDividend(details, cashAccountID: bank,
                                          recordFrankingCredits: false)
        let book = try #require(model.book)
        let transaction = try #require(book.transaction(with: id))
        #expect(transaction.splits.count == 3)
        #expect(transaction.isBalanced)
        #expect(!book.accounts.contains { $0.fullName == "Assets:Franking Credits Receivable" })
    }

    @Test("Matched duplicates get their register split marked cleared")
    func reconcileDuplicates() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let date = Date()
        _ = try model.addTransaction(date: date, description: "WOOLWORTHS", currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -45.20),
                                              SplitInput(accountID: groceries, value: 45.20)])

        // The same transaction arrives on a statement.
        let staged = [StagedTransaction(date: date, amount: -45.20, payee: "WOOLWORTHS")]
        let results = model.matchStaged(staged, intoAccountID: bank)
        #expect(results.count == 1)
        #expect(results[0].isDuplicate)
        #expect(results[0].matchedSplitID != nil)

        #expect(model.reconcileMatchedDuplicates(results) == 1)
        let book = try #require(model.book)
        let split = try #require(book.split(with: results[0].matchedSplitID!))
        #expect(split.reconcileState == .cleared)

        // Idempotent: a second pass changes nothing.
        #expect(model.reconcileMatchedDuplicates(results) == 0)
    }

    @Test("An already-linked transaction is only blamed when it is near the document")
    func linkedCandidateStaysNearTheDocument() throws {
        // Found on a real 46,578-transaction book: the "…but that transaction
        // already has an attachment" note searched a year either side on the
        // reasoning that the amount narrowed it enough. Everyday spending is
        // full of common round totals, so it always found *something* — a café
        // receipt from January was reported as matching a supermarket purchase in
        // March. The note has to clear the same date bar as a real match.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let card = try #require(model.addAccount(name: "Card", type: .credit))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        let january = try #require(day("2026-01-20"))
        let march = try #require(day("2026-03-13"))

        // One $18.00 purchase, months away from the document, already linked.
        let far = try model.addTransaction(
            date: march, description: "SUPERMARKET", currency: .aud,
            splits: [SplitInput(accountID: card, value: -18), SplitInput(accountID: shopping, value: 18)])
        model.setDocumentLink("other.png", for: far)

        // Nothing within the window of a 20 January receipt for $18.00.
        #expect(model.linkedCandidate(amount: 18, spending: true, near: january) == nil)
        // With no readable document date there is nothing better to go on, so
        // the loose search still answers.
        #expect(model.linkedCandidate(amount: 18, spending: true, near: nil) != nil)

        // A second $18.00 purchase, this time three days from the receipt, is
        // exactly what the note is for.
        let threeDaysLater = try #require(day("2026-01-23"))
        let near = try model.addTransaction(
            date: threeDaysLater, description: "CAFE", currency: .aud,
            splits: [SplitInput(accountID: card, value: -18), SplitInput(accountID: shopping, value: 18)])
        model.setDocumentLink("receipt.png", for: near)
        #expect(model.linkedCandidate(amount: 18, spending: true, near: january)?.guid == near)
    }

    @Test("Budget suggestions create or update the monthly budget")
    func applyBudgetSuggestion() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let dining = try #require(model.addAccount(name: "Dining", type: .expense))

        #expect(model.budgets.isEmpty)
        model.applyBudgetSuggestion([
            BudgetSuggestionLine(categoryID: groceries, fullName: "Groceries",
                                 monthlyAmount: 600, rationale: "matches average"),
        ])
        #expect(model.budgets.count == 1)
        #expect(model.budgets.first?.amount(for: groceries) == 600)

        // A second application updates the same budget.
        model.applyBudgetSuggestion([
            BudgetSuggestionLine(categoryID: groceries, fullName: "Groceries",
                                 monthlyAmount: 550, rationale: "trimmed"),
            BudgetSuggestionLine(categoryID: dining, fullName: "Dining",
                                 monthlyAmount: 200, rationale: "new"),
        ])
        #expect(model.budgets.count == 1)
        #expect(model.budgets.first?.amount(for: groceries) == 550)
        #expect(model.budgets.first?.amount(for: dining) == 200)
    }

    @Test("Spending history and income average reflect prior months")
    func spendingHistory() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: Date())!

        _ = try model.addTransaction(date: lastMonth, description: "Shop", currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -300),
                                              SplitInput(accountID: groceries, value: 300)])
        _ = try model.addTransaction(date: lastMonth, description: "Pay", currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: 6000),
                                              SplitInput(accountID: salary, value: -6000)])

        let history = model.spendingHistory(months: 6)
        let line = try #require(history.first { $0.categoryID == groceries })
        #expect(line.monthlyAverage == 50)          // 300 over 6 months
        #expect(line.monthlyMaximum == 300)
        #expect(line.monthlyMinimum == 0)
        #expect(model.monthlyIncomeAverage(months: 6) == 1000)  // 6000 over 6 months
    }
}
