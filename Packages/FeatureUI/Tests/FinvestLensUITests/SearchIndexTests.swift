//
//  SearchIndexTests.swift
//  FinvestLens — FeatureUI
//
//  The search bar scans a folded index rather than walking the book, narrows
//  a lengthened query among the last one's matches, and shows its results as
//  the general ledger narrowed to them — GnuCash's search ledger. Each of
//  those is a shortcut, and each must find exactly what the walk found.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Search index")
struct SearchIndexTests {

    private func makeModel() throws -> (AppModel, URL, [String: GncGUID]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        var ids: [String: GncGUID] = [:]
        for (name, type) in [("Everyday Account", AccountType.bank), ("Groceries", .expense),
                             ("Café Visits", .expense), ("Salary", .income)] {
            ids[name] = try #require(model.addAccount(name: name, type: type))
        }
        let rows: [(String, String, String, String, String)] = [
            // description, number, memo, account, amount
            ("Woolworths groceries", "", "weekly shop", "Groceries", "84.20"),
            ("GROCERY OUTLET", "1042", "", "Groceries", "12.00"),
            ("Morning coffee", "", "flat white", "Café Visits", "5.50"),
            // Decomposed é, as an import can leave it.
            ("Cafe\u{301} Luna", "", "", "Café Visits", "7.00"),
            ("Payroll ACME", "", "October", "Salary", "-3000"),
            ("Transfer", "", "groceries kitty", "Groceries", "40"),
            // Matches "gro" and not "grocer": what tells narrowing from a
            // lengthening apart from narrowing from a shortening.
            ("Grow bags", "", "", "Café Visits", "9.00"),
        ]
        for (index, row) in rows.enumerated() {
            let other = try #require(ids[row.3])
            let everyday = try #require(ids["Everyday Account"])
            let amount = dec(row.4)
            _ = try model.addTransaction(
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                description: row.0, currency: .aud,
                splits: [SplitInput(accountID: other, value: amount, memo: row.2),
                         SplitInput(accountID: everyday, value: -amount)])
            if !row.1.isEmpty, let txn = model.book?.transactions.last {
                model.editing([txn.guid], named: "Number") { txn.number = row.1 }
            }
        }
        return (model, url, ids)
    }

    /// The walk the index replaced: each field lowercased and searched, every
    /// token required, negations and keys through the matcher as before.
    private func walked(_ query: String, in model: AppModel) -> Set<GncGUID> {
        let words = query.split(separator: " ").map { String($0).lowercased() }
        return Set((model.book?.transactions ?? []).filter { txn in
            words.allSatisfy { word in
                var fields = [txn.transactionDescription, txn.number]
                for split in txn.splits {
                    fields.append(split.memo)
                    if let name = split.account?.name { fields.append(name) }
                }
                return fields.contains { $0.lowercased().contains(word) }
            }
        }.map(\.guid))
    }

    private func found(_ query: String, in model: AppModel) -> Set<GncGUID> {
        model.searchQuery = query
        model.runSearch()
        return Set(model.searchResults.map(\.id))
    }

    @Test("Plain words find what walking the book found — case, accents and several words alike",
          arguments: ["groc", "GROC", "grocer", "café", "cafe\u{301}", "cafe", "white flat",
                      "acme october", "1042", "everyday", "zzz", "o", "groceries kitty"])
    func plainWords(_ query: String) throws {
        let (model, url, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(found(query, in: model) == walked(query, in: model))
    }

    @Test("Negations and keys still test what is left after the words")
    func keysAndNegations() throws {
        let (model, url, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let groceries = found("groc", in: model)
        let notOutlet = found("groc -outlet", in: model)
        #expect(notOutlet == groceries.subtracting(found("outlet", in: model)))
        #expect(found("memo:weekly", in: model).count == 1)
        // An unknown key is free text, colon and all.
        #expect(found("date:2026", in: model).isEmpty)
    }

    @Test("A lengthened query narrows the last one's matches, and finds what a fresh one would")
    func narrowing() throws {
        let (model, url, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        for query in ["g", "gr", "gro", "groc", "groce", "grocer"] {
            #expect(found(query, in: model) == walked(query, in: model), "\(query)")
        }
        // Shorter again: not a narrowing, so the whole book is searched.
        let shorter = found("gro", in: model)
        #expect(shorter == walked("gro", in: model))
        #expect(shorter.count > walked("grocer", in: model).count, "the fixture tells the two apart")
        // A word added: still a narrowing of every old word.
        #expect(found("gro weekly", in: model) == walked("gro weekly", in: model))
    }

    @Test("An edit between keystrokes is searched for — the index and the narrowing follow the book")
    func editBetweenKeystrokes() throws {
        let (model, url, ids) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = found("gro", in: model)
        let everyday = try #require(ids["Everyday Account"])
        let groceries = try #require(ids["Groceries"])
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 1_700_900_000),
                                     description: "Grocer on the corner", currency: .aud,
                                     splits: [SplitInput(accountID: groceries, value: 3),
                                              SplitInput(accountID: everyday, value: -3)])
        let after = found("groc", in: model)
        #expect(after == walked("groc", in: model))
        #expect(model.book?.transactions.last.map { after.contains($0.guid) } == true)
    }

    @Test("The search ledger is the matches in the general ledger's own order — under no account's sort or filter")
    func searchLedger() throws {
        let (model, url, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.searchQuery = "groc"
        model.runSearch()
        let matched = Set(model.searchResults.map(\.id))
        let ledger = model.searchLedgerTransactions().map(\.guid)
        // All Transactions' default order, narrowed.
        #expect(ledger == model.journalTransactions(forAccountID: nil).map(\.guid).filter(matched.contains))
        // An account register's sort and filter, left in force underneath
        // when a search starts, neither reorder nor hide its results.
        model.registerSort = .amount
        model.registerSortReversed = true
        model.registerFilter = RegisterFilter(statuses: [.reconciled], startDate: nil, endDate: nil)
        model.searchQuery = ""
        model.runSearch()
        model.searchQuery = "groc"
        model.runSearch()
        #expect(model.searchLedgerTransactions().map(\.guid) == ledger)
        #expect(model.searchLedgerSummary().count == matched.count)
        #expect(model.searchMatchCount == matched.count)
    }

    @Test("A word and its negation are complements, whatever the text's script")
    func negationComplements() throws {
        let (model, url, ids) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let everyday = try #require(ids["Everyday Account"])
        let cafe = try #require(ids["Café Visits"])
        for description in ["Thanks 👍🏽 lunch", "ร้านค้า", "Plain"] {
            _ = try model.addTransaction(date: Date(timeIntervalSince1970: 1_701_000_000), description: description,
                                         currency: .aud, splits: [SplitInput(accountID: cafe, value: 1),
                                                                  SplitInput(accountID: everyday, value: -1)])
        }
        let all = Set(model.book?.transactions.map(\.guid) ?? [])
        for word in ["👍", "ร้านค", "plain", "o"] {
            let with = found(word, in: model), without = found("-\(word)", in: model)
            #expect(with.isDisjoint(with: without), "\(word)")
            #expect(with.union(without) == all, "\(word)")
        }
    }

    @Test("Results are rows only when asked, newest first, and follow an edit to a result")
    func rowsWhenAsked() throws {
        let (model, url, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.searchQuery = "groc"
        model.runSearch()
        #expect(model.searchResultsCache == nil, "a keystroke makes no rows")
        let rows = model.searchResults
        #expect(rows.map(\.date) == rows.map(\.date).sorted(by: >))
        #expect(model.searchMatchCount == rows.count)
        // Renamed in place: the same transactions match, the row must not be stale.
        let first = try #require(model.book?.transaction(with: rows[0].id))
        model.editing([first.guid], named: "Rename") { first.transactionDescription = "Grocer renamed" }
        #expect(model.searchResults.first { $0.id == first.guid }?.description == "Grocer renamed")
    }
}
