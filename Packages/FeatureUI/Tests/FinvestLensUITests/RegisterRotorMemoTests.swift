//
//  RegisterRotorMemoTests.swift
//  FinvestLens — FeatureUI
//
//  The "Unreconciled" VoiceOver rotor used to filter every register row inside
//  the view body. A rotor's `ForEach` is rebuilt on every body pass — every
//  click, every keystroke, every selection change — so on a register with
//  140,000 rows that was a full scan per interaction, on a screen showing
//  thirty of them. The filtering is now memoised on the book revision, the way
//  every other derivation in `AppModel` is, and the way GnuCash derives once
//  into memory and invalidates on edit.
//
//  These tests pin the two halves of that contract: the same revision returns
//  the identical array (so no work and no new array for SwiftUI to diff), and
//  an edit invalidates it.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite(.serialized)
struct RegisterRotorMemoTests {

    private struct Fixture {
        let model: AppModel
        let bank: GncGUID
        let cash: GncGUID
    }

    private func makeFixture(transactions: Int) throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let cash = try #require(model.addAccount(name: "Cash", type: .cash))
        let currency = model.transactionCurrency(for: [bank, cash])
        for index in 0..<transactions {
            _ = try model.addTransaction(
                date: Date(timeIntervalSince1970: TimeInterval(index) * 86_400),
                description: "Posting \(index)",
                currency: currency,
                splits: [SplitInput(accountID: bank, value: 10),
                         SplitInput(accountID: cash, value: -10)])
        }
        model.selectedAccountID = bank
        return Fixture(model: model, bank: bank, cash: cash)
    }

    @Test("Every unreconciled row is offered to the rotor")
    func listsUnreconciledRows() throws {
        let fixture = try makeFixture(transactions: 5)
        // Nothing has been reconciled, so every row qualifies.
        #expect(fixture.model.unreconciledRegisterRows.count == fixture.model.registerRows.count)
        #expect(fixture.model.registerRows.count == 5)
    }

    @Test("Asking twice on one revision does no work and returns the same array")
    func memoisesWithinARevision() throws {
        let fixture = try makeFixture(transactions: 5)
        let first = fixture.model.unreconciledRegisterRows
        let second = fixture.model.unreconciledRegisterRows
        // Identity, not just equality: handing SwiftUI a fresh array every body
        // pass is what the memo exists to prevent.
        #expect(first.withUnsafeBufferPointer { $0.baseAddress }
                == second.withUnsafeBufferPointer { $0.baseAddress })
    }

    @Test("Reconciling a row drops it from the rotor on the next revision")
    func invalidatesOnEdit() throws {
        let fixture = try makeFixture(transactions: 3)
        #expect(fixture.model.unreconciledRegisterRows.count == 3)

        let target = try #require(fixture.model.registerRows.first)
        fixture.model.setReconcileState(splitID: target.id, to: .reconciled)

        // A stale memo would still say three.
        #expect(fixture.model.unreconciledRegisterRows.count == 2)
        #expect(!fixture.model.unreconciledRegisterRows.contains { $0.id == target.id })
    }
}
