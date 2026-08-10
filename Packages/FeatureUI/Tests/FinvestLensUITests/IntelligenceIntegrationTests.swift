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

    @Test("A receipt from a trip matches on what the card was actually charged")
    func foreignAmountMatching() throws {
        // The card posts in the book's currency, so the receipt in your hand
        // (NZD 72.11) shares no number with the transaction (AUD −64.51). The
        // issuer wrote the original into the narrative, which is the number the
        // receipt does share — no exchange rate, no tolerance, nothing tagged.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let card = try #require(model.addAccount(name: "Card", type: .credit))
        let food = try #require(model.addAccount(name: "Dining", type: .expense))
        let trip = try #require(day("2026-01-22"))
        let abroad = try model.addTransaction(
            date: trip, description: "THE SQUARE RESTAURANT     CHRISTCHURCH  72.11  NZD 2.18 AUD",
            currency: .aud,
            splits: [SplitInput(accountID: card, value: -64.51), SplitInput(accountID: food, value: 64.51)])

        let receiptDate = try #require(day("2026-01-20"))
        let seventyTwoEleven = try #require(Decimal(string: "72.11"))
        #expect(model.findTransactionByForeignAmount(
            seventyTwoEleven, near: receiptDate, spending: true)?.guid == abroad)

        // The posted amount still matches the ordinary way, so nothing regresses.
        #expect(model.foreignAmountIndex()[seventyTwoEleven]?.count == 1)

        // The conversion fee is in the book's own currency and must never be
        // read as a foreign amount, or every domestic fee becomes a purchase
        // abroad.
        let fee = try #require(Decimal(string: "2.18"))
        #expect(model.findTransactionByForeignAmount(fee, near: receiptDate, spending: true) == nil)

        // Same rules as a domestic match: outside the window, no answer…
        let farOff = try #require(day("2026-03-01"))
        #expect(model.findTransactionByForeignAmount(
            seventyTwoEleven, near: farOff, spending: true) == nil)
        // …wrong direction, no answer…
        #expect(model.findTransactionByForeignAmount(
            seventyTwoEleven, near: receiptDate, spending: false) == nil)
        // …and a transaction that already carries a document is not re-claimed.
        model.setDocumentLink("square.png", for: abroad)
        #expect(model.findTransactionByForeignAmount(
            seventyTwoEleven, near: receiptDate, spending: true) == nil)
    }

    @Test("A domestic narrative contributes nothing to the foreign index")
    func domesticNarrativesAreNotIndexed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let card = try #require(model.addAccount(name: "Card", type: .credit))
        let food = try #require(model.addAccount(name: "Dining", type: .expense))
        _ = try model.addTransaction(
            date: Date(), description: "SUPERMARKET 5773                CHATSWOOD", currency: .aud,
            splits: [SplitInput(accountID: card, value: -28.90), SplitInput(accountID: food, value: 28.90)])
        #expect(model.foreignAmountIndex().isEmpty)
    }

    @Test("A cash receipt is entered against the account it is told, and only that")
    func recordCashPurchase() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.configuredDocumentFolder = folder

        let hers = try #require(model.addAccount(name: "Her Cash", type: .cash))
        _ = try #require(model.addAccount(name: "His Cash", type: .cash))
        let bought = try #require(day("2026-02-22"))

        // The receipt is linked where it lies, so the test writes it into the
        // document folder and hands over the URL. The stored link is still the
        // bare name, because the file is under that folder.
        let receipt = folder.appendingPathComponent("2026-02-22 BBQ.png")
        try Data("receipt".utf8).write(to: receipt)
        let entered = try await model.recordCashPurchase(
            receipt: receipt, date: bought,
            vendor: "BBQ King", amount: 99.35, cashAccountID: hers)

        let book = try #require(model.book)
        let txn = try #require(book.transaction(with: entered.id))
        #expect(txn.isBalanced)
        #expect(txn.transactionDescription == "BBQ King")
        #expect(txn.tags.contains("cash"))
        #expect(txn.documentLink == "2026-02-22 BBQ.png")

        // The money came out of the account named, and no other.
        let herAccount = try #require(book.account(with: hers))
        #expect(book.balance(of: herAccount).amount == Decimal(string: "-99.35"))

        // The counter-leg is parked in the wash account, which is what lets the
        // ordinary categoriser finish the job rather than a second one here.
        #expect(txn.splits.contains { $0.account?.isWash == true })
        #expect(model.uncategorizedItems().count == 1)
    }

    @Test("A cash purchase is posted on the day the receipt says, in UTC")
    func cashPurchasePostsOnTheRightDay() async throws {
        // Caught on a real run: four receipts were entered a day early. A date
        // built from a filename is midnight *local*, which in Sydney is 13:00
        // UTC the day before — and the book stores a posting day as midnight
        // UTC (GnuCashDate writes `00:00:00 +0000`). Stored raw it renders a
        // day early anywhere reading UTC, and exports to GnuCash wrong.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.configuredDocumentFolder = folder

        let cash = try #require(model.addAccount(name: "Cash", type: .cash))
        let ninth = try #require(day("2026-01-09"))       // midnight, local
        let receipt = folder.appendingPathComponent("2026-01-09 Tofu.png")
        try Data("x".utf8).write(to: receipt)
        let entered = try await model.recordCashPurchase(
            receipt: receipt, date: ninth,
            vendor: "Artisan Tofu", amount: 25.60, cashAccountID: cash)

        let book = try #require(model.book)
        let txn = try #require(book.transaction(with: entered.id))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let stored = utc.dateComponents([.year, .month, .day, .hour], from: txn.datePosted)
        #expect(stored.year == 2026)
        #expect(stored.month == 1)
        #expect(stored.day == 9, "posted on the day the receipt names, read in UTC")
        #expect(stored.hour == 0, "a posting day carries no time of day")
    }

    @Test("The posting-day repair moves only rows whose UTC and local days disagree")
    func repairIsNarrowAndIdempotent() async throws {
        // The first version of this repair asked "is the time midnight UTC?"
        // and selected 759 transactions on a real book instead of the 4 that
        // were wrong — GnuCash stores plenty of dates at 10:59 UTC, which is
        // the same calendar day here and perfectly fine. Rewriting those would
        // have dirtied hundreds of untouched rows to fix something that was
        // not wrong with them.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.configuredDocumentFolder = folder

        let card = try #require(model.addAccount(name: "Card", type: .credit))
        let shop = try #require(model.addAccount(name: "Shop", type: .expense))

        /// A transaction posted at an exact instant, carrying a document.
        func linked(_ iso: String, _ name: String) throws -> GncGUID {
            let formatter = ISO8601DateFormatter()
            let id = try model.addTransaction(
                date: try #require(formatter.date(from: iso)), description: name, currency: .aud,
                splits: [SplitInput(accountID: card, value: -10), SplitInput(accountID: shop, value: 10)])
            model.setDocumentLink("\(name).png", for: id)
            return id
        }
        // The zone is stated, not inherited. This repair is unreproducible at
        // UTC — a UTC day and a local day never disagree there — so a test that
        // assumed the runner sat at +11 passed in Sydney and failed on CI,
        // which is what kept the pipeline red for five commits.
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = try #require(TimeZone(identifier: "Australia/Sydney"))

        // GnuCash's own shape: a stray time, but the same day either way.
        let fine = try linked("2026-01-20T10:59:00Z", "Fine")
        // The defect: 13:00 UTC on the 8th is midnight on the 9th in Sydney.
        let broken = try linked("2026-01-08T13:00:00Z", "Broken")

        let moved = model.repostLinkedTransactionDays(apply: true, in: sydney)
        #expect(moved.count == 1, "only the row whose days disagree should move")
        #expect(moved.first?.id == broken)

        let book = try #require(model.book)
        // The untouched one keeps its exact instant, not just its day.
        let untouched = try #require(book.transaction(with: fine))
        #expect(untouched.datePosted == ISO8601DateFormatter().date(from: "2026-01-20T10:59:00Z"))

        // And running again finds nothing.
        #expect(model.repostLinkedTransactionDays(apply: true, in: sydney).isEmpty)
    }

    @Test("A cash purchase with no vendor still gets a usable description")
    func cashPurchaseFallsBackToTheFileName() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.configuredDocumentFolder = folder

        let cash = try #require(model.addAccount(name: "Cash", type: .cash))
        let receipt = folder.appendingPathComponent("2026-01-09 H Hung.png")
        try Data("x".utf8).write(to: receipt)
        let entered = try await model.recordCashPurchase(
            receipt: receipt, date: Date(),
            vendor: nil, amount: 25.60, cashAccountID: cash)
        let book = try #require(model.book)
        let txn = try #require(book.transaction(with: entered.id))
        #expect(txn.transactionDescription == "2026-01-09 H Hung")
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
