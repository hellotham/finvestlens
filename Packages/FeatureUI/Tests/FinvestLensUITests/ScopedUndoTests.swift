//
//  ScopedUndoTests.swift
//  FinvestLens — FeatureUI
//
//  The business operations, Post Scheduled Transactions, Close Financial Year
//  and Repair Book used to undo through a snapshot of the whole book — a
//  GnuCash export before the edit, an import on undo (P9c, P9d). Each now
//  captures only what it changes. Undo and redo must still put back exactly
//  what was there — and for the business layer, the very objects: an
//  invoice's posting and a lot's members point at particular transactions
//  and splits, and pointing at copies would orphan them.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
    return Calendar(identifier: .gregorian).date(from: c)!
}

@MainActor
@Suite("Scoped undo")
struct ScopedUndoTests {

    @MainActor
    private struct Fixture {
        let model: AppModel
        let undo: UndoManager
        let url: URL
        var book: Book { model.book! }
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        // Attached once a test's setup is done: with grouping
        // by event off, each step is grouped by hand, as a user's action is.
        let undo = UndoManager()
        undo.groupsByEvent = false
        return Fixture(model: model, undo: undo, url: url)
    }

    /// One undoable step, grouped the way a user's action is.
    private func step(_ f: Fixture, _ body: () -> Void) {
        f.undo.beginUndoGrouping()
        body()
        f.undo.endUndoGrouping()
    }

    /// Every reference the business layer holds lands on an object the book
    /// itself holds — the identity the undo has to keep.
    private func linked(_ book: Book) -> Bool {
        let transactions = Set(book.transactions.map(ObjectIdentifier.init))
        let splits = Set(book.transactions.flatMap(\.splits).map(ObjectIdentifier.init))
        let lots = Set(book.lots.map(ObjectIdentifier.init))
        for invoice in book.invoices where invoice.isPosted {
            guard let posting = invoice.postedTransaction, transactions.contains(ObjectIdentifier(posting)),
                  let lot = invoice.postedLot, lots.contains(ObjectIdentifier(lot)) else { return false }
        }
        for lot in book.lots where !lot.splits.allSatisfy({ splits.contains(ObjectIdentifier($0)) }) {
            return false
        }
        return book.transactions.allSatisfy { txn in txn.splits.allSatisfy { $0.transaction === txn } }
    }

    @Test("Each business operation undoes and redoes, keeping every posting and lot linked")
    func businessOperations() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let model = f.model
        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let gst = try #require(model.addAccount(name: "GST", type: .liability))
        f.model.undoManager = f.undo

        var customer: GncGUID?
        step(f) { customer = model.addCustomer(id: "C1", name: "Acme") }
        var term: GncGUID?
        step(f) { term = model.addBillTerm(name: "Net 30", dueDays: 30) }
        var table: GncGUID?
        step(f) { table = model.addTaxTable(name: "GST", accountID: gst, percentage: dec("10")) }
        var invoice: GncGUID?
        step(f) {
            invoice = model.createInvoice(id: "INV-1", kind: .invoice, ownerType: .customer,
                                          ownerID: customer!, lines: [
                .init(accountID: sales, price: dec("100"), taxable: true, taxTableID: table)])
        }
        step(f) { #expect(model.postInvoice(invoice!, to: ar, postDate: date(2026, 3, 1))) }
        step(f) { #expect(model.processPayment(ownerType: .customer, ownerID: customer!,
                                              amount: dec("60"), fromAccountID: bank,
                                              on: date(2026, 3, 10))) }
        #expect(model.outstanding(invoice!) == dec("50"))
        #expect(f.book.transactions.count == 2)
        #expect(linked(f.book))

        // Back through the payment, the posting, the invoice, the table, the
        // term and the customer.
        f.undo.undo()
        #expect(model.outstanding(invoice!) == dec("110"))
        #expect(f.book.transactions.count == 1)
        #expect(f.book.invoices.first?.postedLot?.splits.count == 1)
        #expect(linked(f.book))
        f.undo.undo()
        #expect(f.book.invoices.first?.isPosted == false)
        #expect(f.book.transactions.isEmpty && f.book.lots.isEmpty)
        f.undo.undo()
        #expect(f.book.invoices.isEmpty)
        f.undo.undo()
        #expect(f.book.taxTables.isEmpty)
        f.undo.undo()
        #expect(f.book.billTerms.isEmpty)
        f.undo.undo()
        #expect(f.book.customers.isEmpty)
        _ = term

        // And forward again: the same objects, still linked.
        for _ in 0..<6 { f.undo.redo() }
        #expect(f.book.customers.map(\.guid) == [customer!])
        #expect(model.outstanding(invoice!) == dec("50"))
        #expect(f.book.transactions.count == 2)
        #expect(linked(f.book))
        model.selectedAccountID = ar
        #expect(model.registerRows.count == 2)
    }

    @Test("Unposting undoes back to the very transaction that was posted")
    func unpostUndo() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let model = f.model
        let ar = try #require(model.addAccount(name: "A/R", type: .receivable))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))
        let invoice = try #require(model.createInvoice(
            id: "INV-1", kind: .invoice, ownerType: .customer, ownerID: customer,
            lines: [.init(accountID: sales, price: dec("100"))]))
        #expect(model.postInvoice(invoice, to: ar))
        let posting = try #require(f.book.invoice(with: invoice)?.postedTransaction)
        f.model.undoManager = f.undo

        step(f) { model.unpostInvoice(invoice) }
        #expect(f.book.transactions.isEmpty)
        f.undo.undo()
        #expect(f.book.transactions.count == 1)
        #expect(f.book.transactions.first === posting)
        #expect(f.book.transaction(with: posting.guid) === posting)
        #expect(f.book.invoice(with: invoice)?.postedTransaction === posting)
        #expect(model.outstanding(invoice) == dec("100"))
        #expect(linked(f.book))
        f.undo.redo()
        #expect(f.book.transactions.isEmpty)
        #expect(f.book.invoice(with: invoice)?.isPosted == false)
    }

    @Test("Posting scheduled transactions undoes the postings and the schedules' progress together")
    func postScheduledUndo() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let model = f.model
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        model.addScheduledTransaction(ScheduledTransaction(
            name: "Rent", currency: .aud, description: "Monthly rent",
            recurrence: Recurrence(period: .monthly, startDate: date(2020, 1, 1)),
            splits: [ScheduledSplit(accountGUID: rent, value: 500),
                     ScheduledSplit(accountGUID: bank, value: -500)]))
        f.model.undoManager = f.undo

        var created = 0
        step(f) { created = model.postDueScheduled(through: date(2020, 3, 15)) }
        #expect(created == 3)
        let posted = f.book.transactions
        #expect(model.pendingScheduled(through: date(2020, 3, 15)).isEmpty)

        f.undo.undo()
        #expect(f.book.transactions.isEmpty)
        #expect(model.pendingScheduled(through: date(2020, 3, 15)).count == 3)
        #expect(model.scheduledTransactions.first?.lastPosted == nil)

        f.undo.redo()
        #expect(f.book.transactions.count == 3)
        #expect(zip(f.book.transactions, posted).allSatisfy { $0 === $1 })
        #expect(model.pendingScheduled(through: date(2020, 3, 15)).isEmpty)
    }

    @Test("Closing a year undoes to before the closing entries, and redoes them")
    func closeYearUndo() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let model = f.model
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let equity = try #require(model.addAccount(name: "Retained Earnings", type: .equity))
        _ = try model.addTransaction(date: date(2025, 3, 1), description: "Pay", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("1000")), SplitInput(accountID: salary, value: dec("-1000"))])
        f.model.undoManager = f.undo

        var closed: Int?
        step(f) { closed = model.closeBook(asOf: date(2025, 6, 30), equityID: equity) }
        #expect(closed == 1)
        #expect(f.book.transactions.count == 2)
        let salaryAccount = try #require(f.book.account(with: salary))
        #expect(f.book.balance(of: salaryAccount).amount == 0)

        f.undo.undo()
        #expect(f.book.transactions.count == 1)
        #expect(f.book.balance(of: salaryAccount).amount == dec("-1000"))
        f.undo.redo()
        #expect(f.book.transactions.count == 2)
        #expect(f.book.balance(of: salaryAccount).amount == 0)
    }

    @Test("Repair Book undoes every repair it made, and the accounts it made for them")
    func repairUndo() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let model = f.model
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let book = f.book
        let bankAccount = try #require(book.account(with: bank))
        let foodAccount = try #require(book.account(with: food))

        // An empty one, one with a leg in no account, one that does not balance.
        let empty = Transaction(currency: .aud, datePosted: date(2025, 1, 1), description: "Empty")
        empty.addSplit(account: bankAccount, value: 0)
        let orphaned = Transaction(currency: .aud, datePosted: date(2025, 1, 2), description: "Orphaned")
        orphaned.addSplit(account: bankAccount, value: dec("-20"))
        orphaned.addSplit(Split(value: dec("20")))
        let unbalanced = Transaction(currency: .aud, datePosted: date(2025, 1, 3), description: "Short")
        unbalanced.addSplit(account: bankAccount, value: dec("-30"))
        unbalanced.addSplit(account: foodAccount, value: dec("25"))
        model.editing([empty.guid, orphaned.guid, unbalanced.guid], named: "Set Up") {
            for txn in [empty, orphaned, unbalanced] { book.addTransaction(txn) }
        }
        let accountsBefore = Set(book.accounts.map(\.guid))
        f.model.undoManager = f.undo

        step(f) { model.applyCleanup() }
        #expect(book.transaction(with: empty.guid) == nil)
        #expect(book.transaction(with: orphaned.guid)?.splits.allSatisfy { $0.account != nil } == true)
        #expect(book.transaction(with: unbalanced.guid)?.isBalanced == true)
        #expect(Set(book.accounts.map(\.guid)).count == accountsBefore.count + 2)   // Orphan-, Imbalance-

        f.undo.undo()
        #expect(book.transaction(with: empty.guid) != nil)
        #expect(book.transaction(with: orphaned.guid)?.splits.contains { $0.account == nil } == true)
        #expect(book.transaction(with: unbalanced.guid)?.isBalanced == false)
        #expect(book.transaction(with: unbalanced.guid)?.splits.count == 2)
        #expect(Set(book.accounts.map(\.guid)) == accountsBefore)

        f.undo.redo()
        #expect(book.transaction(with: empty.guid) == nil)
        #expect(book.transaction(with: unbalanced.guid)?.isBalanced == true)
        #expect(book.transactions.allSatisfy { $0.isBalanced })
    }
}
