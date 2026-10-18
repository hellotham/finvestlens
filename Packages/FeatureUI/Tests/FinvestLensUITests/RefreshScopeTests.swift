//
//  RefreshScopeTests.swift
//  FinvestLens — FeatureUI
//
//  Performance Review 2, R7–R11: a price-only edit must not rebuild the
//  register; the provider list must be a memo the key store invalidates; the
//  iPad table's per-keystroke splice must replace exactly one block; the
//  price chart's thinning must keep every peak and both ends.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensQuotes
import FinvestLensReports
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Refresh scope — price edits leave the register alone")
struct RefreshScopeTests {

    @Test("A price-only edit moves the book revision, not the register revision")
    func priceEditKeepsRegister() throws {
        let model = AppModel()
        let undo = UndoManager()
        model.undoManager = undo
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        _ = try model.addTransaction(
            date: Date(), description: "Lunch", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -25),
                     SplitInput(accountID: food, value: 25)])
        model.selectedAccountID = bank
        #expect(model.registerRows.count == 1)
        undo.removeAllActions()

        let bookBefore = model.bookRevision
        let registerBefore = model.registerRevision
        let ratesBefore = model.rateRows.count

        let transactionsBefore = model.transactionRevision
        model.addExchangeRate(from: .usd, to: .aud, rate: 1.5, date: Date())

        #expect(model.bookRevision != bookBefore, "valuations changed — reports must recompute")
        #expect(model.registerRevision == registerBefore, "no register row changed")
        #expect(model.transactionRevision == transactionsBefore, "no transaction changed")
        #expect(model.registerRows.count == 1)
        #expect(model.rateRows.count == ratesBefore + 1, "the price editor's rows did refresh")
        #expect(model.hasUnsavedChanges)

        // Undo is price-scoped too.
        undo.undo()
        #expect(model.rateRows.count == ratesBefore)
        #expect(model.registerRevision == registerBefore)

        // A transaction edit, by contrast, rebuilds the register.
        _ = try model.addTransaction(
            date: Date(), description: "Dinner", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -40),
                     SplitInput(accountID: food, value: 40)])
        #expect(model.registerRevision != registerBefore)
        #expect(model.transactionRevision != transactionsBefore)
        #expect(model.registerRows.count == 2)
    }

    @Test("A slot-only edit leaves the register, the tree and the search, and still dirties the book")
    func kvpEditKeepsRegister() throws {
        let model = AppModel()
        let undo = UndoManager()
        model.undoManager = undo
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        _ = try model.addTransaction(
            date: Date(), description: "Lunch", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -25),
                     SplitInput(accountID: food, value: 25)])
        model.selectedAccountID = bank
        #expect(model.registerRows.count == 1)
        try model.save()
        undo.removeAllActions()

        let bookBefore = model.bookRevision
        let registerBefore = model.registerRevision
        let transactionsBefore = model.transactionRevision
        let treeBefore = model.accountTree.map(\.id)

        model.toggleFavouriteAccount(bank)

        #expect(model.favouriteAccountIDs == [bank])
        #expect(model.registerRevision == registerBefore, "no register row changed")
        #expect(model.transactionRevision == transactionsBefore, "no transaction changed")
        #expect(model.accountTree.map(\.id) == treeBefore)
        #expect(model.bookRevision != bookBefore, "slots feed reports — their memos must go")
        #expect(model.hasUnsavedChanges)

        undo.undo()
        #expect(model.favouriteAccountIDs.isEmpty)
        #expect(model.registerRevision == registerBefore)
        #expect(model.transactionRevision == transactionsBefore)
    }

    @Test("A budget edited in its slot reaches the memoised budget report")
    func kvpEditReachesReports() throws {
        let model = AppModel()
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        _ = try model.addTransaction(
            date: Date(), description: "Lunch", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -25),
                     SplitInput(accountID: food, value: 25)])
        var budget = Budget(name: "Household", lines: [BudgetLine(accountGUID: food, amount: 100)])
        model.addBudget(budget)
        #expect(model.budgetActuals(budget).first { $0.id == food }?.budgeted == 100)

        budget.lines = [BudgetLine(accountGUID: food, amount: 250)]
        model.updateBudget(budget)
        #expect(model.budgetActuals(budget).first { $0.id == food }?.budgeted == 250)
        #expect(model.budgetActuals(budget).first { $0.id == food }?.actual == 25)
    }

    @Test("Editing a price's value undoes and redoes through the change log")
    func priceValueRoundTrip() throws {
        let model = AppModel()
        let undo = UndoManager()
        model.undoManager = undo
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        _ = model.addAccount(name: "CBA", type: .stock, commodity: cba)
        model.addPrice(commodity: cba, currency: .aud, date: Date(), value: 120)
        let id = try #require(model.book?.prices.first?.guid)
        undo.removeAllActions()

        model.updatePriceValue(id, to: 121)   // a remove and an add under one guid
        #expect(model.book?.prices.count == 1)
        #expect(model.book?.latestPrice(of: cba, in: .aud)?.value == 121)
        undo.undo()
        #expect(model.book?.prices.count == 1)
        #expect(model.book?.latestPrice(of: cba, in: .aud)?.value == 120)
        undo.redo()
        #expect(model.book?.latestPrice(of: cba, in: .aud)?.value == 121)

        // An edit that changes nothing registers no undo.
        undo.removeAllActions()
        model.updatePriceValue(id, to: 121)
        #expect(!undo.canUndo)
    }

    @Test("All Transactions opens unfiltered and clears the account's rows, even via Overview")
    func generalLedgerResetsTheView() throws {
        let model = AppModel()
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        _ = try model.addTransaction(
            date: Date(), description: "Lunch", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -25),
                     SplitInput(accountID: food, value: 25)])
        model.selectedAccountID = bank
        // Leaving the account persists its arrangement under a per-account
        // key in the real defaults; cleaned up so runs do not accumulate one.
        defer { UserDefaults.standard.removeObject(forKey: AppModel.registerViewKey(bank)) }
        model.registerSortReversed = true
        model.registerIncludesSubaccounts = true
        #expect(model.registerRows.count == 1)

        model.navigate(to: .dashboard)
        #expect(model.registerRows.count == 1, "leaving for Overview keeps the rows")
        model.navigate(to: .generalLedger)
        #expect(model.registerRows.isEmpty, "All Transactions reads no account rows")
        #expect(model.registerSortReversed == false)
        #expect(model.registerIncludesSubaccounts == false)
        #expect(model.registerFilter == .showAll)
    }

    @Test("An edit's audit line lands in the book's `.audit` sidecar, beside the book")
    func auditSidecar() throws {
        let model = AppModel()
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = try #require(model.addAccount(name: "Bank", type: .bank))
        let sidecar = url.deletingPathExtension().appendingPathExtension("audit")
        defer { try? FileManager.default.removeItem(at: sidecar) }
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(model.auditLogURL == sidecar)
        let tail = model.auditLogTail()
        #expect(tail.first?.operation.contains("Account") == true)
    }

    @Test("Redo of Add Account registers the new account's commodity again")
    func redoAddAccountRegistersCommodity() throws {
        let model = AppModel()
        let undo = UndoManager()
        model.undoManager = undo
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let yen = Commodity.currency("JPY", fractionDigits: 0, name: "Yen")
        #expect(model.book?.commodities.contains(yen) == false)
        _ = try #require(model.addAccount(name: "Yen cash", type: .cash, commodity: yen))
        #expect(model.book?.commodities.contains(yen) == true)
        undo.undo()
        #expect(model.book?.commodities.contains(yen) == false, "undo unregisters what the edit registered")
        undo.redo()
        #expect(model.book?.commodities.contains(yen) == true, "redo registers it again")
        #expect(model.book?.commodities.first { $0 == yen }?.smallestFraction == 1)
    }

    @Test("A Keychain read the store refuses is not memoised as no key")
    func providersNotMemoisedOnFailure() throws {
        let store = FlakyKeyStore()
        let model = AppModel(apiKeys: store)
        let keyed = try #require(QuoteProviderKind.allCases.first { $0.requiresAPIKey })
        try store.setKey("secret", for: keyed)
        store.failing = true
        #expect(!model.availableProviders.contains(keyed), "refused read answers no key for now")
        store.failing = false
        #expect(model.availableProviders.contains(keyed), "…and the next read asks again")
        let afterDefinite = store.lookups
        #expect(model.availableProviders.contains(keyed), "memoised once definite")
        #expect(store.lookups == afterDefinite, "a definite answer is not asked for again")
    }

    @Test("lastPriceUpdate is a memo that a price edit refreshes")
    func lastPriceUpdateMemo() throws {
        let model = AppModel()
        let url = tempURL()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        _ = model.addAccount(name: "CBA", type: .stock, commodity: cba)
        #expect(model.lastPriceUpdate == nil)
        // The model restamps a price to the book's day-neutral instant, so the
        // expectation reads the stored date back rather than the one passed.
        func newest() -> Date? {
            model.book?.prices.filter { $0.commodity == cba }.map(\.date).max()
        }
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        model.addPrice(commodity: cba, currency: .aud, date: day, value: 120)
        let first = try #require(newest())
        #expect(model.lastPriceUpdate == first)
        // A currency rate is not a security price.
        model.addExchangeRate(from: .usd, to: .aud, rate: 1.5, date: day.addingTimeInterval(86_400))
        #expect(model.lastPriceUpdate == first)
        model.addPrice(commodity: cba, currency: .aud, date: day.addingTimeInterval(2 * 86_400), value: 121)
        let second = try #require(newest())
        #expect(second > first)
        #expect(model.lastPriceUpdate == second)
    }

    @Test("availableProviders is a memo the key store invalidates")
    func providersMemo() throws {
        let model = AppModel(apiKeys: InMemoryAPIKeyStore())
        let keyed = try #require(QuoteProviderKind.allCases.first { $0.requiresAPIKey })
        #expect(!model.availableProviders.contains(keyed))
        #expect(model.availableProviders.contains(.yahoo))
        let revision = model.apiKeysRevision
        try model.setAPIKey("secret", for: keyed)
        #expect(model.apiKeysRevision != revision)
        #expect(model.availableProviders.contains(keyed))
        #expect(model.apiKey(for: keyed) == "secret")
        try model.setAPIKey(nil, for: keyed)
        #expect(!model.availableProviders.contains(keyed))
        #expect(model.apiKey(for: keyed) == nil)
    }
}

/// An in-memory key store whose reads can be made to fail like a locked
/// Keychain's.
private final class FlakyKeyStore: APIKeyStoring, @unchecked Sendable {
    private let inner = InMemoryAPIKeyStore()
    var failing = false
    var lookups = 0

    func key(for kind: QuoteProviderKind) -> String? { (try? lookup(for: kind)) ?? nil }
    func setKey(_ key: String?, for kind: QuoteProviderKind) throws { try inner.setKey(key, for: kind) }
    func lookup(for kind: QuoteProviderKind) throws -> String? {
        lookups += 1
        if failing { throw QuoteError.providerError("locked") }
        return inner.key(for: kind)
    }
}

@Suite("Register table — per-keystroke block splice")
struct RegisterTableSpliceTests {

    private func row(_ id: RegisterRowID) -> RegisterTableRow {
        RegisterTableRow(id: id, selected: false, editable: false, kind: .addSplit)
    }

    @Test("Replaces exactly the transaction's block, heading to the next heading")
    func replacesBlock() {
        let a = GncGUID.random(), b = GncGUID.random(), c = GncGUID.random()
        let leg = GncGUID.random(), line = UUID()
        let rows = [row(.txn(a)), row(.notes(a)),
                    row(.txn(b)), row(.split(leg)),
                    row(.txn(c))]
        let fresh = [row(.txn(b)), row(.notes(b)), row(.tags(b)),
                     row(.split(leg)), row(.draftLine(line)), row(.addSplit)]
        let out = rows.replacingBlock(of: b, with: fresh)
        #expect(out?.map(\.id) == [.txn(a), .notes(a),
                                   .txn(b), .notes(b), .tags(b), .split(leg), .draftLine(line), .addSplit,
                                   .txn(c)])

        // A block at the end, and one that shrinks.
        let tail = rows.replacingBlock(of: c, with: [row(.txn(c)), row(.notes(c))])
        #expect(tail?.map(\.id) == [.txn(a), .notes(a), .txn(b), .split(leg), .txn(c), .notes(c)])
        let shrunk = rows.replacingBlock(of: a, with: [row(.txn(a))])
        #expect(shrunk?.map(\.id) == [.txn(a), .txn(b), .split(leg), .txn(c)])

        // No heading for the transaction: the caller must compose in full.
        #expect(rows.replacingBlock(of: GncGUID.random(), with: fresh) == nil)

        // Two headings for one transaction (two legs in the focus account):
        // one block cannot stand in for both, so the caller composes in full.
        let twice = [row(.txn(a)), row(.notes(a)), row(.txn(b)), row(.txn(a)), row(.txn(c))]
        #expect(twice.replacingBlock(of: a, with: [row(.txn(a))]) == nil)
        let apart = [row(.txn(a)), row(.txn(b)), row(.split(leg)), row(.txn(a))]
        #expect(apart.replacingBlock(of: a, with: [row(.txn(a))]) == nil)
        #expect(apart.replacingBlock(of: b, with: [row(.txn(b))])?.map(\.id)
                == [.txn(a), .txn(b), .txn(a)])
    }
}

@Suite("Price chart — thinning keeps the shape")
struct PriceChartThinningTests {

    private func rows(_ values: [Decimal]) -> [SecurityPriceRow] {
        values.enumerated().map { offset, value in
            SecurityPriceRow(id: GncGUID.random(),
                             date: Date(timeIntervalSince1970: Double(offset) * 86_400),
                             value: value, currencyCode: "AUD", source: "test")
        }
    }

    @Test("A year of daily prices is untouched")
    func shortRunUntouched() {
        let run = rows((0..<250).map { Decimal($0) })
        #expect(PriceHistoryChart.thinned(run) == run)
    }

    @Test("A long run keeps both ends, every bucket's low and high, and date order")
    func longRunThinned() {
        var values = (0..<2_000).map { Decimal(100 + $0 % 7) }
        values[1_234] = 999   // the spike
        values[777] = 1       // the trough
        let run = rows(values)
        let thin = PriceHistoryChart.thinned(run)
        #expect(thin.count <= PriceHistoryChart.maxMarksPerRun + 2)
        #expect(thin.count > PriceHistoryChart.maxMarksPerRun / 2)
        #expect(thin.first == run.first)
        #expect(thin.last == run.last)
        #expect(thin.contains { $0.value == 999 })
        #expect(thin.contains { $0.value == 1 })
        #expect(zip(thin, thin.dropFirst()).allSatisfy { $0.date < $1.date })
    }
}
