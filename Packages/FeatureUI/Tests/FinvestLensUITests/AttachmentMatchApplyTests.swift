//
//  AttachmentMatchApplyTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Match Attachments' Apply used to link each file and categorise each
//  transaction as edits of their own — up to two refreshes of the whole book
//  and two undo steps per match (Performance Review P5.1). It is one edit now,
//  and these tests hold it to that.
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Applying matched attachments", .serialized)
struct AttachmentMatchApplyTests {

    @Test("A batch of matches is one edit: one refresh, one step to undo")
    func oneEdit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        let undo = UndoManager()
        model.undoManager = undo
        try model.newDocument(at: url)
        defer { model.close() }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        func purchase(_ text: String) throws -> GncGUID {
            try model.addTransaction(date: Date(), description: text, currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -50),
                                              SplitInput(accountID: shopping, value: 50)])
        }
        let ids = try ["CARD 1", "CARD 2", "CARD 3"].map(purchase)
        undo.removeAllActions()

        let folder = FileManager.default.temporaryDirectory
        var matches = ids.enumerated().map { index, id in
            var match = AppModel.AttachmentMatch(url: folder.appendingPathComponent("receipt-\(index).pdf"))
            match.transactionID = id
            return match
        }
        matches[0].suggestion = AppModel.AttachmentCategorySuggestion(
            accountID: groceries, accountName: "Groceries", friendlyDescription: "Grocer",
            currencyCode: "AUD", lines: nil)

        let revision = model.transactionRevision
        let applied = model.applyAttachmentMatches(matches)

        #expect(applied.linked == 3)
        #expect(applied.categorised == 1)
        #expect(model.transactionRevision == revision + 1, "one refresh for the whole batch")
        #expect(undo.undoActionName == String(localized: "Apply Matches"))
        #expect(ids.allSatisfy { model.documentLink(for: $0) != nil })
        let categorised = try #require(model.book?.transaction(with: ids[0]))
        #expect(categorised.transactionDescription == "Grocer")
        #expect(categorised.splits.contains { $0.account?.guid == groceries })

        undo.undo()
        #expect(ids.allSatisfy { model.documentLink(for: $0) == nil }, "the links go back with one undo")
        let restored = try #require(model.book?.transaction(with: ids[0]))
        #expect(restored.transactionDescription == "CARD 1")
        #expect(restored.splits.contains { $0.account?.guid == shopping })
        #expect(!restored.splits.contains { $0.account?.guid == groceries })
    }

    @Test("Two documents for one transaction: the second sees the first's change")
    func sameTransactionTwice() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let id = try model.addTransaction(date: Date(), description: "CARD", currency: .aud,
                                          splits: [SplitInput(accountID: bank, value: -50),
                                                   SplitInput(accountID: shopping, value: 50)])
        let folder = FileManager.default.temporaryDirectory
        func match(_ name: String, _ suggestion: AppModel.AttachmentCategorySuggestion) -> AppModel.AttachmentMatch {
            var match = AppModel.AttachmentMatch(url: folder.appendingPathComponent(name))
            match.transactionID = id
            match.suggestion = suggestion
            return match
        }
        func lines(_ first: GncGUID, _ second: GncGUID) -> [AppModel.AttachmentCategorySuggestion.SplitLine] {
            [.init(accountID: first, accountName: "", memo: "Food", value: 30),
             .init(accountID: second, accountName: "", memo: "Bags", value: 20)]
        }
        let split = AppModel.AttachmentCategorySuggestion(accountID: groceries, accountName: "Groceries",
                                                         friendlyDescription: nil, currencyCode: "AUD",
                                                         lines: lines(groceries, shopping))
        let repoint = AppModel.AttachmentCategorySuggestion(accountID: groceries, accountName: "Groceries",
                                                           friendlyDescription: nil, currencyCode: "AUD", lines: nil)

        // The first document splits the purchase leg in two. The transaction
        // the second finds is no longer two legs, so its re-pointing has no
        // leg to take and is refused. A plan made before the first applied
        // would have re-pointed the leg the split had removed, and counted it.
        let applied = model.applyAttachmentMatches([match("a.pdf", split), match("b.pdf", repoint)])
        #expect(applied.linked == 2)
        #expect(applied.categorised == 1, "the second saw the split and declined")
        let txn = try #require(model.book?.transaction(with: id))
        #expect(txn.isBalanced)
        #expect(txn.splits.count == 3)
        #expect(txn.documentLink?.hasSuffix("b.pdf") == true, "the last document's link stands")

        // Splitting twice: the second split has no single leg to replace, and
        // a stale one would have added fifty dollars of legs to a balanced
        // transaction.
        let again = model.applyAttachmentMatches([match("c.pdf", split)])
        #expect(again.categorised == 0)
        #expect(try #require(model.book?.transaction(with: id)).isBalanced)
    }
}
