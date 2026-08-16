//
//  WholeBookRegisterTests.swift
//  FinvestLens — FeatureUI
//
//  P12/N6 — All Transactions stops being a dialect.
//
//  The oracle here is GnuCash's own source, read 15 Aug 2026 from
//  ~/Repositories/gnucash-reference:
//
//  - `split-register-layout.c:584-620` gives `GENERAL_JOURNAL` nine columns —
//    the same as a bank register — and registers every cursor, ledger and
//    journal alike. So the whole-book register is not locked to journal style.
//  - `gnc-split-reg.c:894` and `:1420` say it outright: "no anchoring split".
//    A whole-book row therefore has no single split to take a reconcile state,
//    a counterparty, or an editable amount from.
//  - `split-register-model.c:1650-1657` fills the general journal's total cell
//    from `get_trans_total_value_subaccounts`, where a single-account register
//    uses one split's amount.
//
//  Those three facts are what the summary below implements, so they are what
//  this file checks.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Whole-book register rows")
struct WholeBookRegisterTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let groceries: GncGUID
        let fees: GncGUID
        let income: GncGUID
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Everyday", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let fees = try #require(model.addAccount(name: "Fees", type: .expense))
        let income = try #require(model.addAccount(name: "Salary", type: .income))
        return Fixture(model: model, url: url, bank: bank, groceries: groceries,
                       fees: fees, income: income)
    }

    /// Two legs: the row names both ends, in the direction the money moved.
    @Test("A two-legged transaction names both accounts")
    func twoLeggedNamesBothEnds() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let id = try #require(try f.model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Woolworths", currency: .aud,
            splits: [SplitInput(accountID: f.groceries, value: 30),
                     SplitInput(accountID: f.bank, value: -30)]))

        let summary = f.model.wholeBookRowSummary(ofTransaction: id)
        #expect(summary.accounts == "Everyday → Groceries")
        #expect(summary.total == 30)
    }

    /// More than one other side, and the register's existing marker stands in —
    /// the same one a single-account row uses.
    @Test("A multi-split transaction shows the split marker")
    func multiSplitShowsMarker() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let id = try #require(try f.model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Shop", currency: .aud,
            splits: [SplitInput(accountID: f.groceries, value: 30),
                     SplitInput(accountID: f.fees, value: 2),
                     SplitInput(accountID: f.bank, value: -32)]))

        let summary = f.model.wholeBookRowSummary(ofTransaction: id)
        #expect(summary.accounts == "— Split —")
        // The transaction total, not one leg's amount — GnuCash's
        // T-Debit/T-Credit cell (split-register-model.c:1650).
        #expect(summary.total == 32)
    }

    /// Reconcile is a fact about a split. With no anchoring split there is one
    /// only while the legs agree — and a state they disagree about is not a
    /// fact, so the column stays empty rather than picking a side.
    @Test("Reconcile is the legs' agreement, or nothing")
    func reconcileIsAgreement() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let id = try #require(try f.model.addTransaction(
            date: Date(timeIntervalSince1970: 0), description: "Pay", currency: .aud,
            splits: [SplitInput(accountID: f.bank, value: 100),
                     SplitInput(accountID: f.income, value: -100)]))

        // Both legs start unreconciled and agree.
        #expect(f.model.wholeBookRowSummary(ofTransaction: id).reconcile
                == ReconcileState.notReconciled.rawValue)

        // Reconcile one side only, and they no longer agree.
        let bankSplit = try #require(
            f.model.book?.transaction(with: id)?.splits.first { $0.account?.name == "Everyday" })
        f.model.setReconcileState(splitID: bankSplit.guid, to: .reconciled)
        #expect(f.model.wholeBookRowSummary(ofTransaction: id).reconcile.isEmpty)
    }

    /// A transaction that is not in the book answers with nothing rather than
    /// trapping — the register asks per row, and rows can outlive an edit.
    @Test("An unknown transaction summarises to nothing")
    func unknownTransactionIsEmpty() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let summary = f.model.wholeBookRowSummary(ofTransaction: .random())
        #expect(summary.accounts.isEmpty)
        #expect(summary.reconcile.isEmpty)
        #expect(summary.total == 0)
    }

    // MARK: Filter and sort (P13.2)

    /// Both were gated on `!focusSet.isEmpty`, and the general ledger's focus
    /// set is empty by definition — so All Transactions ignored the Filter
    /// sheet entirely and came back oldest-first however its headers were
    /// clicked, while those headers still wrote the shared `registerSort` and
    /// silently re-sorted every single-account register instead.

    private func makeDatedBook() throws -> Fixture {
        let f = try makeFixture()
        for (day, amount, name) in [(1_000_000.0, "10", "Milk"),
                                    (9_000_000.0, "80", "Weekly shop"),
                                    (5_000_000.0, "45", "Top-up")] {
            _ = f.model.addTransfer(from: f.bank, to: f.groceries,
                                    amount: Decimal(string: amount)!,
                                    date: Date(timeIntervalSince1970: day),
                                    description: name)
        }
        return f
    }

    @Test("All Transactions honours the register's date filter")
    func wholeBookHonoursFilter() throws {
        let f = try makeDatedBook()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(f.model.journalTransactions(forAccountID: nil).count == 3)

        var filter = RegisterFilter.showAll
        filter.startDate = Date(timeIntervalSince1970: 4_000_000)
        f.model.registerFilter = filter
        let filtered = f.model.journalTransactions(forAccountID: nil)
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.datePosted >= Date(timeIntervalSince1970: 4_000_000) })
    }

    @Test("All Transactions honours the sort its own headers set")
    func wholeBookHonoursSort() throws {
        let f = try makeDatedBook()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.registerSort = .description
        #expect(f.model.journalTransactions(forAccountID: nil).map(\.transactionDescription)
                == ["Milk", "Top-up", "Weekly shop"])

        f.model.registerSortReversed = true
        #expect(f.model.journalTransactions(forAccountID: nil).map(\.transactionDescription)
                == ["Weekly shop", "Top-up", "Milk"])
    }

    /// With no anchoring split there is no leg whose value is "the" amount, and
    /// summing every leg gives zero on a balanced transaction. The debit total
    /// is what the row displays (`split-register-model.c:1650-1657`), so it is
    /// what the column sorts by.
    @Test("Sorting by amount uses the debit total the row shows")
    func wholeBookSortsByDisplayedTotal() throws {
        let f = try makeDatedBook()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.registerSort = .amount
        let sorted = f.model.journalTransactions(forAccountID: nil)
        let totals = sorted.map { f.model.wholeBookRowSummary(ofTransaction: $0.guid).total }
        #expect(totals == [10, 45, 80])
    }
}
