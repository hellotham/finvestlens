//
//  InlineEditTests.swift
//  FinvestLens — FeatureUI
//
//  What survives of AppModel+InlineEdit: the simple-transfer gate the
//  register and bulk-edit sheet both ask, and bulk edits across a selection.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Inline register editing")
struct InlineEditTests {

    /// A book with a plain two-leg transfer, returning the ids the tests poke.
    private func makeTransferBook(_ model: AppModel, at url: URL) throws
        -> (bank: GncGUID, groceries: GncGUID, txn: GncGUID, bankSplit: GncGUID) {
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let txn = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("50"),
                                                 date: Date(timeIntervalSince1970: 1_000_000),
                                                 description: "Woolworths"))
        let book = try #require(model.book)
        let bankAccount = try #require(book.account(with: bank))
        let bankSplit = try #require(book.splits(for: bankAccount).first).guid
        return (bank, groceries, txn, bankSplit)
    }

    @Test("isSimpleTransfer is true only for two-leg same-currency transactions")
    func simpleTransferGate() throws {
        let url = tempURL()
        let model = AppModel()
        let ids = try makeTransferBook(model, at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(model.isSimpleTransfer(splitID: ids.bankSplit))

        // A three-leg transaction is not simple.
        let bank = ids.bank
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let household = try #require(model.addAccount(name: "Household", type: .expense))
        try model.addTransaction(date: Date(timeIntervalSince1970: 2_000_000), description: "Split shop",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-30")),
            SplitInput(accountID: food, value: dec("20")),
            SplitInput(accountID: household, value: dec("10"))])
        let book = try #require(model.book)
        let splitTxn = try #require(book.transactions.first { $0.transactionDescription == "Split shop" })
        let splitLeg = try #require(splitTxn.splits.first).guid
        #expect(!model.isSimpleTransfer(splitID: splitLeg))

        // A security leg (commodity != transaction currency) is not simple either.
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        try model.addTransaction(date: Date(timeIntervalSince1970: 3_000_000), description: "Buy CBA",
                                 currency: .aud, splits: [
            SplitInput(accountID: shares, value: dec("1000"), quantity: dec("10")),
            SplitInput(accountID: bank, value: dec("-1000"))])
        let buy = try #require(book.transactions.first { $0.transactionDescription == "Buy CBA" })
        let buyBankLeg = try #require(buy.splits.first { $0.account?.guid == bank }).guid
        #expect(!model.isSimpleTransfer(splitID: buyBankLeg))

        // Unknown split id.
        #expect(!model.isSimpleTransfer(splitID: .random()))
    }

    // The five tests that stood here exercised `inlineSetDate`,
    // `inlineSetDescription`, `inlineSetNotes`, `inlineSetMemo`,
    // `inlineSetAmount`, `inlineSetTransfer` and `inlineSetLegAccount`. Those
    // methods are gone (see AppModel+InlineEdit.swift): the register sheet
    // commits a whole draft through `updateTransaction`, and had done since the
    // redesign — these tests were the only callers left, which is exactly why
    // the dead API looked alive. What they were really protecting, the
    // counter-leg rebalance and the refusal to touch money on a multi-leg or
    // security transaction, is `updateTransaction`'s and is covered in
    // EditingTests, EditFidelityTests and EditableQuantityTests.

    @Test("A bulk edit applies transaction and split fields across the selection")
    func bulkFieldsApply() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))
        let dining = try #require(model.addAccount(name: "Dining", type: .expense))
        let household = try #require(model.addAccount(name: "Household", type: .expense))

        let t1 = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("10"),
                                                date: Date(timeIntervalSince1970: 0), description: "One"))
        let t2 = try #require(model.addTransfer(from: bank, to: subs, amount: dec("20"),
                                                date: Date(timeIntervalSince1970: 86_400), description: "Two"))
        // A three-leg transaction: its transfer move must be skipped, not botched.
        let t3 = try model.addTransaction(
            date: Date(timeIntervalSince1970: 172_800), description: "Three",
            currency: .aud, splits: [
                SplitInput(accountID: bank, value: dec("-30")),
                SplitInput(accountID: groceries, value: dec("20")),
                SplitInput(accountID: household, value: dec("10"))])

        let book = try #require(model.book)
        let bankAccount = try #require(book.account(with: bank))
        let bankLegs = book.splits(for: bankAccount)
        #expect(bankLegs.count == 3)
        let selection = Set(bankLegs.map(\.guid))

        var edit = AppModel.BulkTransactionEdit()
        #expect(edit.isEmpty)
        let newDate = Date(timeIntervalSince1970: 999_000)
        edit.date = newDate
        edit.description = "  Bulk Renamed "
        edit.notes = " shared note "
        edit.memo = " statement leg "
        edit.reconcile = .cleared
        edit.transferAccountID = dining
        #expect(!edit.isEmpty)

        let result = model.applyBulkEdit(edit, toSplits: selection)
        #expect(result.edited == 3)
        #expect(result.transferSkipped == 1)                       // the three-leg txn

        for id in [t1, t2, t3] {
            let txn = try #require(book.transaction(with: id))
            #expect(txn.datePosted == newDate)
            #expect(txn.transactionDescription == "Bulk Renamed")
            #expect(txn.notes == "shared note")
        }
        for leg in bankLegs {
            #expect(leg.memo == "statement leg")
            #expect(leg.reconcileState == .cleared)
        }
        // Simple transfers moved their counter legs to Dining; the split
        // transaction kept its structure.
        let txn1 = try #require(book.transaction(with: t1))
        let txn2 = try #require(book.transaction(with: t2))
        #expect(txn1.splits.first { $0.account?.guid != bank }?.account?.guid == dining)
        #expect(txn2.splits.first { $0.account?.guid != bank }?.account?.guid == dining)
        let txn3 = try #require(book.transaction(with: t3))
        #expect(txn3.splits.count == 3)
        #expect(txn3.splits.contains { $0.account?.guid == household })
        #expect(!txn3.splits.contains { $0.account?.guid == dining })
    }

    @Test("Reconciling in bulk stamps the reconcile date; blanks clear only what may be blank")
    func bulkReconcileAndBlanks() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        _ = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("10"),
                                           date: Date(timeIntervalSince1970: 0), description: "Keep Me"))
        let book = try #require(model.book)
        let bankAccount = try #require(book.account(with: bank))
        let leg = try #require(book.splits(for: bankAccount).first)
        let txn = try #require(leg.transaction)
        txn.notes = "old note"
        leg.memo = "old memo"

        var edit = AppModel.BulkTransactionEdit()
        edit.reconcile = .reconciled
        edit.description = "   "     // blank description is ignored
        edit.notes = ""              // blank notes clear
        edit.memo = ""               // blank memo clears
        let result = model.applyBulkEdit(edit, toSplits: [leg.guid])
        #expect(result.edited == 1)
        #expect(result.transferSkipped == 0)
        #expect(leg.reconcileState == .reconciled)
        #expect(leg.reconcileDate != nil)
        #expect(txn.transactionDescription == "Keep Me")
        #expect(txn.notes.isEmpty)
        #expect(leg.memo.isEmpty)
    }

    @Test("An empty edit or empty selection edits nothing")
    func bulkNoOps() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        _ = try #require(model.addTransfer(from: bank, to: groceries, amount: dec("10"),
                                           date: Date(timeIntervalSince1970: 0), description: "One"))
        let book = try #require(model.book)
        let leg = try #require(book.splits(for: book.account(with: bank)!).first)

        // Empty edit.
        let empty = model.applyBulkEdit(AppModel.BulkTransactionEdit(), toSplits: [leg.guid])
        #expect(empty == (0, 0))

        // Empty (and unknown) selection.
        var edit = AppModel.BulkTransactionEdit()
        edit.description = "New"
        #expect(model.applyBulkEdit(edit, toSplits: []) == (0, 0))
        #expect(model.applyBulkEdit(edit, toSplits: [.random()]) == (0, 0))
    }
}
