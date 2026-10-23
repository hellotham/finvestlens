//
//  ImportMatchOffMainTests.swift
//  FinvestLens — FeatureUI
//
//  Preview's matcher runs on a replica of the book, off the main actor
//  (P6b). It must find exactly what it finds on the book itself: the same
//  duplicates, the same transfers to complete, the same suggestions — rules
//  and heuristics included, which run after it on the model.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensRules
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Import matching off the main actor")
struct ImportMatchOffMainTests {

    @Test("Duplicates, transfers and suggestions are the ones the book itself gives")
    func sameAsOnTheBook() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let card = try #require(model.addAccount(name: "Card", type: .credit))
        let imbalance = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let subs = try #require(model.addAccount(name: "Subscriptions", type: .expense))
        model.addRule(Rule(name: "Netflix",
                           triggers: [RuleTrigger(field: .description, op: .contains, value: "netflix")],
                           actions: [.setAccount(subs)]))

        let day = Date(timeIntervalSince1970: 1_700_000_000)
        // Already in the book: a purchase this statement repeats, and the
        // card's side of a payment whose bank side is still parked.
        let purchase = try model.addTransaction(date: day, description: "WOOLWORTHS 1234 SYDNEY",
                                                currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-80")),
            SplitInput(accountID: groceries, value: dec("80"))])
        let payment = try model.addTransaction(date: day, description: "PAYMENT RECEIVED ACCT THANK YOU",
                                               currency: .aud, splits: [
            SplitInput(accountID: card, value: dec("50")),
            SplitInput(accountID: imbalance, value: dec("-50"))])
        _ = try model.addTransaction(date: day.addingTimeInterval(-86_400 * 30),
                                     description: "WOOLWORTHS 1234 SYDNEY", currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-61.20")),
            SplitInput(accountID: groceries, value: dec("61.20"))])

        let staged = [
            StagedTransaction(date: day, amount: dec("-80"), payee: "WOOLWORTHS 1234 SYDNEY"),
            StagedTransaction(date: day, amount: dec("-50"), payee: "PAYMENT TO CARD ACCT"),
            StagedTransaction(date: day.addingTimeInterval(86_400), amount: dec("-42.10"),
                              payee: "WOOLWORTHS 1234 SYDNEY"),
            StagedTransaction(date: day.addingTimeInterval(86_400), amount: dec("-19.99"), payee: "NETFLIX.COM"),
            StagedTransaction(date: day.addingTimeInterval(86_400), amount: dec("-5"), payee: "UNKNOWN PLACE"),
        ]

        let onBook = model.matchStaged(staged, intoAccountID: bank)
        let offMain = await model.matchStagedOffMain(staged, intoAccountID: bank)

        func facts(_ results: [MatchResult]) -> [String] {
            results.map {
                "\($0.staged.id)|\($0.isDuplicate)|\($0.matchedSplitID?.description ?? "-")|" +
                "\($0.suggestedAccountID?.description ?? "-")|\($0.transferSplitID?.description ?? "-")"
            }
        }
        #expect(facts(offMain) == facts(onBook))

        // And they are the right ones.
        let book = try #require(model.book)
        let bankLeg = book.transaction(with: purchase)?.splits.first { $0.account?.guid == bank }
        let parked = book.transaction(with: payment)?.splits.first { $0.account?.guid == imbalance }
        #expect(offMain[0].isDuplicate && offMain[0].matchedSplitID == bankLeg?.guid)
        #expect(offMain[1].transferSplitID == parked?.guid && offMain[1].suggestedAccountID == card)
        #expect(offMain[2].suggestedAccountID == groceries)
        #expect(offMain[3].suggestedAccountID == subs)
    }

    @Test("A book closed while the matcher runs gives nothing to show")
    func closedMeanwhile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let rows = [StagedTransaction(date: Date(), amount: dec("-1"), payee: "X")]

        let gate = ReplicaGate()
        model.replicaWorkWillStart = { await gate.arrive() }
        let pending = Task { await model.matchStagedOffMain(rows, intoAccountID: bank) }
        // It has its replica and has not matched, so the close lands while it
        // matches — not before it starts, which never reached the check, nor
        // after it finished, which one `Task.yield()` could not rule out.
        await gate.waitForArrivals(1)
        model.close()
        await gate.open()
        #expect(await pending.value.isEmpty)
    }
}
