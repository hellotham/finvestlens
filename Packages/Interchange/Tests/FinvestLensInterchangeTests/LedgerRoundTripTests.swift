//
//  LedgerRoundTripTests.swift
//  FinvestLens — Interchange
//
//  P10b exit criteria: Book → journal → Book is graph-equal (GUIDs, amounts
//  to the cent, states, tags, aux dates, prices), and Book → text → Book →
//  text is a fixed point.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Ledger book round-trip")
struct LedgerRoundTripTests {

    private func fixtureBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let bhp = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                            fullName: "BHP Group", smallestFraction: 10_000)
        book.registerCommodity(bhp)

        let assets = book.addAccount(Account(name: "Assets", type: .asset, commodity: .aud,
                                             isPlaceholder: true))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud,
                                           code: "101", description: "Everyday account"),
                                   under: assets)
        let brokerage = book.addAccount(Account(name: "Brokerage", type: .asset, commodity: .aud),
                                        under: assets)
        let shares = book.addAccount(Account(name: "BHP", type: .stock, commodity: bhp),
                                     under: brokerage)
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
        let equity = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))

        let opening = Transaction(currency: .aud, datePosted: day(2026, 1, 1),
                                  description: "Opening Balances")
        opening.addSplit(Split(account: bank, value: dec("1000.00"),
                               reconcileState: .reconciled,
                               reconcileDate: day(2026, 1, 31)))
        opening.addSplit(Split(account: equity, value: dec("-1000.00"),
                               reconcileState: .reconciled))
        book.addTransaction(opening)

        let shop = Transaction(currency: .aud, datePosted: day(2026, 1, 10),
                               number: "42", description: "Woolworths",
                               notes: "weekly shop")
        shop.tags = ["food", "weekly"]
        shop.statementDate = day(2026, 1, 12)
        shop.addSplit(Split(account: groceries, value: dec("85.50"),
                            memo: "fruit and veg", action: "Card"))
        shop.addSplit(Split(account: bank, value: dec("-85.50"),
                            reconcileState: .cleared))
        book.addTransaction(shop)

        let buy = Transaction(currency: .aud, datePosted: day(2026, 2, 5),
                              description: "Buy BHP")
        buy.addSplit(Split(account: shares, value: dec("421.00"),
                           quantity: dec("10"), action: "Buy"))
        buy.addSplit(Split(account: bank, value: dec("-421.00")))
        book.addTransaction(buy)

        let split = Transaction(currency: .aud, datePosted: day(2026, 3, 1),
                                description: "2:1 split")
        split.addSplit(Split(account: shares, value: 0, quantity: dec("10"), action: "Split"))
        book.addTransaction(split)

        book.addPrice(Price(commodity: bhp, currency: .aud,
                            date: day(2026, 2, 5), value: dec("42.10")))
        book.addPrice(Price(commodity: bhp, currency: .aud,
                            date: day(2026, 3, 1), value: dec("21.30")))
        return book
    }

    @Test("Book → journal → Book preserves the graph (GUIDs, amounts, states, tags)")
    func graphEquality() {
        let original = fixtureBook()
        let text = LedgerExport.text(from: original)

        let result = LedgerImport.importBook(text: text)
        #expect(!result.summary.diagnostics.contains { $0.severity == .error },
                "\(result.summary.diagnostics)")
        let imported = result.book

        // Accounts: same paths, types, commodities, GUIDs, flags.
        let originalAccounts = Dictionary(uniqueKeysWithValues:
            original.accounts.map { ($0.fullName, $0) })
        let importedAccounts = Dictionary(uniqueKeysWithValues:
            imported.accounts.map { ($0.fullName, $0) })
        #expect(Set(originalAccounts.keys) == Set(importedAccounts.keys))
        for (path, account) in originalAccounts {
            let counterpart = importedAccounts[path]
            #expect(counterpart?.guid == account.guid, Comment(rawValue: path))
            #expect(counterpart?.type == account.type, Comment(rawValue: path))
            #expect(counterpart?.commodity.mnemonic == account.commodity.mnemonic, Comment(rawValue: path))
            #expect(counterpart?.code == account.code, Comment(rawValue: path))
            #expect(counterpart?.isPlaceholder == account.isPlaceholder, Comment(rawValue: path))
        }

        // Transactions: keyed by GUID; every field that matters.
        #expect(imported.transactions.count == original.transactions.count)
        let importedTxns = Dictionary(uniqueKeysWithValues:
            imported.transactions.map { ($0.guid, $0) })
        for txn in original.transactions {
            guard let counterpart = importedTxns[txn.guid] else {
                Issue.record("missing transaction \(txn.transactionDescription)")
                continue
            }
            #expect(counterpart.datePosted == txn.datePosted)
            #expect(counterpart.transactionDescription == txn.transactionDescription)
            #expect(counterpart.number == txn.number)
            #expect(counterpart.notes == txn.notes)
            #expect(counterpart.tags == txn.tags)
            #expect(counterpart.statementDate == txn.statementDate)
            #expect(counterpart.splits.count == txn.splits.count)
            for split in txn.splits {
                let match = counterpart.splits.first {
                    $0.account?.fullName == split.account?.fullName
                        && $0.value == split.value
                }
                #expect(match != nil, Comment(rawValue: "\(txn.transactionDescription): \(split.account?.fullName ?? "?") \(split.value)"))
                #expect(match?.quantity == split.quantity)
                #expect(match?.reconcileState == split.reconcileState)
                #expect(match?.memo == split.memo)
                #expect(match?.action == split.action)
                #expect(match?.reconcileDate == split.reconcileDate)
            }
        }

        // Prices.
        #expect(imported.prices.count == original.prices.count)
        for price in original.prices {
            #expect(imported.prices.contains {
                $0.commodity.mnemonic == price.commodity.mnemonic
                    && $0.date == price.date && $0.value == price.value
            })
        }

        // Commodity identity survives (namespace + fraction via metadata).
        let importedBHP = imported.commodities.first { $0.mnemonic == "BHP" }
        #expect(importedBHP?.namespace == .security("ASX"))
        #expect(importedBHP?.smallestFraction == 10_000)
    }

    @Test("Book → text → Book → text is a fixed point")
    func textFixedPoint() {
        let original = fixtureBook()
        let once = LedgerExport.text(from: original)
        let reimported = LedgerImport.importBook(text: once).book
        let twice = LedgerExport.text(from: reimported)
        #expect(once == twice)
    }

    @Test("A foreign journal (no metadata) infers types and currency")
    func foreignJournal() {
        let result = LedgerImport.importBook(text: """
        2026/01/05 * Grocery Store
            Expenses:Food:Groceries        $65.00
            Assets:Checking

        2026/01/07 Salary
            Assets:Checking               $2,000.00
            Income:Salary
        """)
        #expect(!result.summary.diagnostics.contains { $0.severity == .error })
        let book = result.book
        #expect(book.baseCurrency.mnemonic == "$")
        let groceries = book.accounts.first { $0.fullName == "Expenses:Food:Groceries" }
        #expect(groceries?.type == .expense)
        let checking = book.accounts.first { $0.fullName == "Assets:Checking" }
        #expect(checking?.type == .asset)
        let income = book.accounts.first { $0.fullName == "Income:Salary" }
        #expect(income?.type == .income)
        // The cleared entry maps to reconciled splits.
        let shop = book.transactions.first { $0.transactionDescription == "Grocery Store" }
        #expect(shop?.splits.allSatisfy { $0.reconcileState == .reconciled } == true)
    }

    @Test("Unbalanced virtuals are skipped and counted; balanced become real splits")
    func virtualPolicy() {
        let result = LedgerImport.importBook(text: """
        2026/01/05 KFC
            Expenses:Food                 $20.00
            Assets:Cash
            [Budget:Food]                $-20.00
            [Equity:Budgets]              $20.00
            (Notes:OnTheSly)             $999.00
        """)
        #expect(result.summary.unbalancedVirtualsSkipped == 1)
        let txn = result.book.transactions[0]
        #expect(txn.splits.count == 4)
        #expect(txn.isBalanced)
        let budget = txn.splits.first { $0.account?.fullName == "Budget:Food" }
        #expect(budget?.kvp["ledger/virtual"] == .string("balanced"))

        // …and the marker restores the brackets on export.
        let reExport = LedgerExport.text(from: result.book)
        #expect(reExport.contains("[Budget:Food]"))
        #expect(!reExport.contains("(Notes:OnTheSly)"))
    }

    @Test("A multi-commodity entry without costs imports as one txn per commodity")
    func multiCommoditySplit() {
        let result = LedgerImport.importBook(text: """
        2026/01/05 Mixed
            Expenses:Fees                 $22.00
            Assets:EuroCash              -10.00 EUR
            Liabilities:Credit
        """)
        #expect(result.summary.splitTransactions == 1)
        #expect(result.summary.transactions == 2)
        for txn in result.book.transactions {
            #expect(txn.isBalanced)
        }
    }

    @Test("Import summary counts what the strict engine could not ingest")
    func summaryCounts() {
        let result = LedgerImport.importBook(text: """
        ~ Monthly
            Expenses:Rent    $500.00
            Assets

        = ^Income
            (Tithe)   -0.1

        2026/01/01 Open
            Assets:Cash    $520.00
            Equity:Opening

        2026/01/05 Adjust
            Assets:Cash             = $500.00
            Equity:Adjustments

        2026/01/06 Check
            Expenses:Food   $20.00
            Assets:Cash     $-20.00 = $480.00
        """)
        #expect(result.summary.periodicIgnored == 1)
        #expect(result.summary.automatedIgnored == 1)
        #expect(result.summary.assignmentsResolved == 1)
        #expect(result.summary.assertionsChecked == 1)
        #expect(result.summary.assertionsFailed == 0)
        #expect(result.summary.transactions == 3)
    }
}
