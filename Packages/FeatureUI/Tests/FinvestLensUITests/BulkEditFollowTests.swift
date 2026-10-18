//
//  BulkEditFollowTests.swift
//  FinvestLens — FeatureUI
//
//  An edit of many transactions at once — a reconcile, or voiding or
//  deleting a search's results — rebuilds the lookup indexes once instead of
//  re-filing each transaction, which rescans its accounts' legs every time
//  (seconds for two thousand legs in a busy account). What follows must still
//  be exactly right: the indexes, the account tree's balances, and the next
//  save writing only what changed. And a book just opened has nothing unsaved,
//  so its first save is incremental too — it used to rewrite every transaction.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Edits of many transactions, and the first save after opening")
struct BulkEditFollowTests {

    private func makeModel(transactions count: Int) throws -> (AppModel, URL, [GncGUID]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        var ids: [GncGUID] = []
        for index in 0..<count {
            ids.append(try model.addTransaction(
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600),
                description: "Shop \(index)", currency: .aud,
                splits: [SplitInput(accountID: bank, value: -Decimal(index + 1)),
                         SplitInput(accountID: food, value: Decimal(index + 1))]))
        }
        try model.save()
        return (model, url, ids)
    }

    @Test("Voiding and deleting more than a re-file's worth, and undoing it, leave every index, balance and save right")
    func bulkEdits() throws {
        let (model, url, ids) = try makeModel(transactions: 150)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let book = try #require(model.book)
        let document = try #require(model.document)
        #expect(ids.count > AppModel.refileLimit)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        func followed(_ step: String) throws {
            _ = book.transaction(with: ids[0])          // the indexes, built again
            #expect(book.lookupIndexesMatchRebuild(), "\(step): indexes")
            #expect(model.treeNativesMatchWalk(), "\(step): account balances")
            try model.save()
            #expect(try document.workingCopyHoldsBook(), "\(step): the saved copy")
        }

        undo.beginUndoGrouping()
        model.voidTransactions(Array(ids.prefix(100)))
        undo.endUndoGrouping()
        try followed("void")

        undo.beginUndoGrouping()
        model.deleteTransactions(Array(ids.suffix(80)))
        undo.endUndoGrouping()
        #expect(book.transactions.count == 70)
        try followed("delete")

        undo.undo()
        #expect(book.transactions.count == 150)
        try followed("undo")
    }

    @Test("A book just opened has nothing unsaved")
    func openedIsSaved() async throws {
        let (model, url, _) = try makeModel(transactions: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        model.close()
        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close() }
        let book = try #require(reopened.book)
        #expect(book.takeUnsaved().transactions == [])
    }
}
