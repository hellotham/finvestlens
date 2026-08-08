//
//  RegisterEditModelTests.swift
//  FinvestLens — FeatureUI
//
//  The register's editing model, pinned where it can drift:
//
//  * **⇥ order** is derived from the same switches that decide what is drawn —
//    a folded column must never be a tab stop, an opened-out draft must
//    continue onto its split lines, and an FX leg must expose its quantity
//    cell. GnuCash moves its cursor programmatically (`gnc_table_move_tab`);
//    with one real field in our register, tabbing is entirely this logic.
//  * **The two-leg mirror**: editing one amount of a plain two-split
//    transaction rebalances the other (GnuCash's recalculation), and stays
//    out of the way for FX/security legs and explicit-currency transactions.
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
struct RegisterEditModelTests {

    private struct Fixture {
        let model: AppModel
        let bank: GncGUID
        let cash: GncGUID
        let txn: GncGUID
        let accounts: [AccountNode]
        let currency: String
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let cash = try #require(model.addAccount(name: "Cash", type: .cash))
        let currency = model.transactionCurrency(for: [bank, cash])
        let txn = try model.addTransaction(
            date: Date(timeIntervalSince1970: 86_400),
            description: "Groceries",
            currency: currency,
            splits: [SplitInput(accountID: bank, value: -25),
                     SplitInput(accountID: cash, value: 25)])
        model.selectedAccountID = bank
        return Fixture(model: model, bank: bank, cash: cash, txn: txn,
                       accounts: model.postableAccounts,
                       currency: currency.mnemonic)
    }

    private func draft(_ fixture: Fixture, expanded: Bool) throws -> TransactionDraft {
        try #require(TransactionDraft(model: fixture.model,
                                      transactionID: fixture.txn,
                                      expanded: expanded))
    }

    // MARK: ⇥ order

    @Test("In place, a wide register tabs date → description → transfer → amount → notes → tags")
    func inPlaceOrderWide() throws {
        let fixture = try makeFixture()
        let draft = try draft(fixture, expanded: false)
        let order = draft.fieldOrder(
            metrics: RegisterMetrics(width: 900), expandedOnScreen: false,
            showsSecondLine: true, showsBalanceColumn: true,
            focusAccountID: fixture.bank, accounts: fixture.accounts,
            currencyCode: fixture.currency)
        #expect(order == [.date, .description, .transfer, .amount, .notes, .tags])
    }

    @Test("Folded columns are not tab stops")
    func foldedColumnsSkipped() throws {
        let fixture = try makeFixture()
        let draft = try draft(fixture, expanded: false)
        // 360pt: date, side and balance columns are all folded away.
        let order = draft.fieldOrder(
            metrics: RegisterMetrics(width: 360), expandedOnScreen: false,
            showsSecondLine: false, showsBalanceColumn: false,
            focusAccountID: fixture.bank, accounts: fixture.accounts,
            currencyCode: fixture.currency)
        #expect(order == [.description, .amount])
    }

    @Test("Opened out, the order continues onto every split line")
    func expandedOrderCoversSplits() throws {
        let fixture = try makeFixture()
        let draft = try draft(fixture, expanded: true)
        let order = draft.fieldOrder(
            metrics: RegisterMetrics(width: 900), expandedOnScreen: true,
            showsSecondLine: false, showsBalanceColumn: true,
            focusAccountID: fixture.bank, accounts: fixture.accounts,
            currencyCode: fixture.currency)
        let ids = draft.lines.map(\.id)
        #expect(order == [.date, .description, .transfer, .amount, .notes, .tags,
                          .splitAction(ids[0]), .splitMemo(ids[0]),
                          .splitAccount(ids[0]), .splitAmount(ids[0]),
                          .splitAction(ids[1]), .splitMemo(ids[1]),
                          .splitAccount(ids[1]), .splitAmount(ids[1])])
    }

    @Test("⇥ wraps forward and ⇧⇥ wraps backward within the transaction")
    func traversalWraps() throws {
        let fixture = try makeFixture()
        let draft = try draft(fixture, expanded: false)
        let order = draft.fieldOrder(
            metrics: RegisterMetrics(width: 900), expandedOnScreen: false,
            showsSecondLine: false, showsBalanceColumn: true,
            focusAccountID: fixture.bank, accounts: fixture.accounts,
            currencyCode: fixture.currency)
        #expect(draft.nextField(after: order.last, backwards: false, in: order) == order.first)
        #expect(draft.nextField(after: order.first, backwards: true, in: order) == order.last)
        #expect(draft.nextField(after: nil, backwards: false, in: order) == order.first)
    }

    // MARK: The two-leg mirror

    @Test("Editing one amount of a plain two-leg transaction mirrors the other")
    func twoLegMirror() throws {
        let fixture = try makeFixture()
        var draft = try draft(fixture, expanded: false)
        draft.setAmountText("-40", at: 0)
        #expect(draft.lines[0].amount == -40)
        #expect(draft.lines[1].amount == 40)
        #expect(draft.imbalance == 0)
        #expect(draft.isBalanced)
    }

    @Test("The mirror stays out of an FX leg's way")
    func mirrorSkipsForeignLegs() throws {
        let fixture = try makeFixture()
        var draft = try draft(fixture, expanded: false)
        draft.lines[1].quantityText = "12.5"   // the counterleg carries its own commodity amount
        draft.setAmountText("-40", at: 0)
        #expect(draft.lines[0].amount == -40)
        #expect(draft.lines[1].amount == 25)   // untouched
    }

    @Test("Three or more legs are never auto-rebalanced")
    func mirrorSkipsMultiSplit() throws {
        let fixture = try makeFixture()
        var draft = try draft(fixture, expanded: true)
        draft.lines.append(EditableSplit(accountID: fixture.cash, amountText: "5"))
        draft.setAmountText("-40", at: 0)
        #expect(draft.lines[1].amount == 25)
        #expect(draft.imbalance == -10)
        #expect(!draft.isBalanced)
    }
}

@MainActor
@Suite(.serialized)
struct RegisterTapMapTests {

    private var metrics: RegisterMetrics { RegisterMetrics(width: 1000) }

    private func target(_ x: CGFloat, _ y: CGFloat = 10,
                        draft: TransactionDraft? = nil,
                        expanded: Bool = false, secondLine: Bool = false,
                        height: CGFloat = 24,
                        accounts: [AccountNode] = [],
                        currency: String = "AUD") -> RegisterRowTap {
        RegisterTapMap.target(point: CGPoint(x: x, y: y),
                              rowSize: CGSize(width: 1000, height: height),
                              metrics: metrics, draft: draft,
                              isExpanded: expanded, showsSecondLine: secondLine,
                              showsAccountColumn: false, showsBalanceColumn: true,
                              focusAccountID: nil, accounts: accounts,
                              currencyCode: currency, restSplitCount: 0)
    }

    @Test("The main line maps every column to its cell")
    func mainLineColumns() {
        // metrics(1000): date 90, handle 22, transfer 160, reconcile 24,
        // amount 100, balance 110 → description = 984 - 506 = 478.
        #expect(target(50) == .cursor(.date))
        #expect(target(105) == .expandToggle)                   // handle: raw 98…120
        #expect(target(300) == .cursor(.description))
        #expect(target(600) == .cursor(.transfer))              // 590+…750
        #expect(target(760) == .cycleReconcile)                 // 750…774
        #expect(target(800) == .cursor(.amount))                // 774…874
        #expect(target(950) == .none)                           // balance
    }

    @Test("A second-line tap splits between notes and tags")
    func notesLine() {
        // Two bands: main 1.0 + notes 0.82 of height 44.
        #expect(target(300, 40, secondLine: true, height: 44) == .cursor(.notes))
        #expect(target(900, 40, secondLine: true, height: 44) == .cursor(.tags))
        // The top band still maps the main line.
        #expect(target(300, 8, secondLine: true, height: 44) == .cursor(.description))
    }

    @Test("Expanded rows band into split lines with per-line identities")
    func splitBands() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let cash = try #require(model.addAccount(name: "Cash", type: .cash))
        let currency = model.transactionCurrency(for: [bank, cash])
        let txn = try model.addTransaction(
            date: .now, description: "Split test", currency: currency,
            splits: [SplitInput(accountID: bank, value: -30),
                     SplitInput(accountID: cash, value: 30)])
        var draft = try #require(TransactionDraft(model: model, transactionID: txn,
                                                  expanded: true))
        draft.isExpanded = true
        let ids = draft.lines.map(\.id)
        // Bands (weights): main 1.0, notes 0.82, labels 0.82, split0 1.0,
        // split1 1.0, addSplit 0.9 → total 5.54; height 120 → unit ≈ 21.66.
        // split0 spans y ≈ 57.2…78.9; split1 ≈ 78.9…100.6.
        #expect(target(300, 70, draft: draft, expanded: true, height: 120)
                == .cursor(.splitMemo(ids[0])))
        #expect(target(300, 90, draft: draft, expanded: true, height: 120)
                == .cursor(.splitMemo(ids[1])))
        #expect(target(600, 90, draft: draft, expanded: true, height: 120)
                == .cursor(.splitAccount(ids[1])))
        #expect(target(800, 70, draft: draft, expanded: true, height: 120)
                == .cursor(.splitAmount(ids[0])))
        // Two legs only: the reconcile column offers no removal.
        #expect(target(760, 70, draft: draft, expanded: true, height: 120) == .none)
        // The bottom band appends a split.
        #expect(target(300, 115, draft: draft, expanded: true, height: 120) == .appendSplit)
    }
}
