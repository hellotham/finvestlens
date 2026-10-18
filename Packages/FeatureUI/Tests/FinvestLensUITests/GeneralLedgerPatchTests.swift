//
//  GeneralLedgerPatchTests.swift
//  FinvestLens — FeatureUI
//
//  The general ledger's caches are patched edit by edit rather than built
//  again (P7): a changed transaction's rows come out from where its old
//  fields filed them and go in where its new ones file them. Under every sort,
//  either way round, with a filter and without, that must leave exactly what a
//  fresh build gives — the same transactions in the same order, the same rows.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

@MainActor
@Suite("General ledger patched edit by edit")
struct GeneralLedgerPatchTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let food: GncGUID
        let rent: GncGUID
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        // Several a day, so the book's order decides ties; numbers, entry
        // dates and memos that disagree with the posting order.
        for index in 0..<30 {
            _ = try model.addTransaction(
                date: day(index / 3), description: ["Shop", "cafe", "Rent", "Groceries"][index % 4] + " \(index % 5)",
                currency: .aud, splits: [
                    SplitInput(accountID: bank, value: -dec("\(index % 7 + 1).50"), memo: "m\(29 - index)"),
                    SplitInput(accountID: index % 2 == 0 ? food : rent, value: dec("\(index % 7 + 1).50"))],
                number: "\((index * 7) % 11)")
        }
        return Fixture(model: model, url: url, bank: bank, food: food, rent: rent)
    }

    /// Edits that move a transaction within the ledger, add one, take one away.
    private func edit(_ f: Fixture, step: Int) throws {
        let model = f.model
        let book = try #require(model.book)
        let target = book.transactions[(step * 7) % book.transactions.count]
        switch step % 5 {
        case 0:
            _ = try model.updateTransaction(
                id: target.guid, date: day((step * 5) % 12), description: "Moved \(step)", currency: .aud,
                splits: [SplitInput(accountID: f.bank, value: -dec("\(step + 2)")),
                         SplitInput(accountID: f.rent, value: dec("\(step + 2)"))],
                number: "\(step % 4)")
        case 1:
            _ = try model.addTransaction(date: day(step % 9), description: "Added \(step)", currency: .aud,
                                         splits: [SplitInput(accountID: f.bank, value: -1, memo: "zz"),
                                                  SplitInput(accountID: f.food, value: 1)])
        case 2:
            model.deleteTransaction(target.guid)
        case 3:
            if model.undoManager?.canUndo == true { model.undoManager?.undo() }
        default:
            _ = try model.updateTransaction(
                id: target.guid, date: target.datePosted, description: "aa \(step)", currency: .aud,
                splits: [SplitInput(accountID: f.bank, value: -dec("0.5"), memo: "a"),
                         SplitInput(accountID: f.food, value: dec("0.25")),
                         SplitInput(accountID: f.rent, value: dec("0.25"))])
        }
    }

    @Test("Under every sort, each way round, filtered or not, the patched ledger is the rebuilt one",
          arguments: RegisterSort.allCases)
    func patchedIsRebuilt(sort: RegisterSort) throws {
        // `rowsToo == false` is the app's own case: every register surface
        // asks for the order and draws its own rows, and the patch used to
        // need the rows too — so in the app it never ran.
        for rowsToo in [false, true] {
            for reversed in [false, true] {
                for filtered in [false, true] {
                    let f = try makeFixture()
                    defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
                    let undo = UndoManager()
                    undo.groupsByEvent = false
                    f.model.registerSort = sort
                    f.model.registerSortReversed = reversed
                    if filtered {
                        f.model.registerFilter = RegisterFilter(statuses: [.notReconciled], startDate: day(2), endDate: day(8))
                    }
                    if rowsToo {
                        _ = f.model.journalRows(forAccountID: nil)
                    } else {
                        _ = f.model.journalTransactions(forAccountID: nil)  // as the registers ask
                    }
                    f.model.undoManager = undo
                    for step in 0..<20 {
                        // Each edit one undo step, as a person's is; an undo is
                        // not itself inside one.
                        if step % 5 == 3 {
                            try edit(f, step: step)
                        } else {
                            undo.beginUndoGrouping()
                            try edit(f, step: step)
                            undo.endUndoGrouping()
                        }
                        #expect(f.model.generalLedgerMatchesRebuild(),
                                "sort \(sort.rawValue), reversed \(reversed), filtered \(filtered), rows \(rowsToo), step \(step)")
                        // Still kept, not merely rebuilt: the patch is what ran.
                        #expect(f.model.journalTransactionCache[nil] != nil)
                        #expect((f.model.journalRowCache[nil] != nil) == rowsToo)
                    }
                }
            }
        }
    }

    @Test("An account renamed has the ledger built again, with the new name")
    func accountRename() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        _ = f.model.journalRows(forAccountID: nil)
        f.model.updateAccount(id: f.food, name: "Groceries", code: "", description: "", notes: "",
                              isPlaceholder: false, isHidden: false)
        #expect(f.model.journalRows(forAccountID: nil).contains { $0.text == "Groceries" })
        #expect(!f.model.journalRows(forAccountID: nil).contains { $0.text == "Food" })
    }

    @Test("A sort chosen after the ledger was built is honoured, however it was set")
    func settingsChangedQuietly() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        let byDate = f.model.journalTransactions(forAccountID: nil).map(\.guid)
        // As restoring a register's saved arrangement does: the setters' own
        // refresh suspended.
        f.model.isRestoringRegisterView = true
        f.model.registerSort = .description
        f.model.isRestoringRegisterView = false
        let byDescription = f.model.journalTransactions(forAccountID: nil)
        #expect(byDescription.map(\.guid) != byDate)
        let names = byDescription.map(\.transactionDescription)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) != .orderedDescending })
    }
}
