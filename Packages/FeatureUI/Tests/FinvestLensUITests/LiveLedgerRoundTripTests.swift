//
//  LiveLedgerRoundTripTests.swift
//  FinvestLens — FeatureUI
//
//  P10b acceptance on the real reference book (env-gated, like the other
//  live harnesses):
//
//      FL_PERF_FILE="$PWD/Ashley Bears.finvestlens" \
//      swift test --package-path Packages/FeatureUI --filter LiveLedger
//
//  Exports the book to a Ledger journal, re-imports it, and checks the graph
//  survives: account/transaction/split counts, every account's balance to
//  the cent, and export→import→export text stability. Set FL_LEDGER_OUT to
//  also write the journal out, so the real `ledger` binary can read it.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensPersistence
import FinvestLensInterchange
@testable import FinvestLensUI

private let bookPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]
private let journalOut = ProcessInfo.processInfo.environment["FL_LEDGER_OUT"]

@Suite(.serialized)
struct LiveLedgerRoundTripTests {

    @Test("The real book survives a Ledger journal round-trip")
    func realBookRoundTrip() throws {
        guard let bookPath else { return }
        let store = try SQLiteDocumentStore(readOnlyPath: bookPath)
        let book = try store.read()

        let start = Date()
        let text = LedgerExport.text(from: book)
        let exportSeconds = Date().timeIntervalSince(start)
        if let journalOut {
            try text.write(toFile: journalOut, atomically: true, encoding: .utf8)
        }

        let importStart = Date()
        let result = LedgerImport.importBook(text: text)
        let importSeconds = Date().timeIntervalSince(importStart)
        let errors = result.summary.diagnostics.filter { $0.severity == .error }
        print("""
        ledger round-trip: \(book.transactions.count) txns, \(book.accounts.count) accounts, \
        \(book.prices.count) prices → \(text.count) chars in \(String(format: "%.2f", exportSeconds))s; \
        re-imported in \(String(format: "%.2f", importSeconds))s with \(errors.count) errors
        """)
        for diagnostic in errors.prefix(5) { print("  \(diagnostic)") }
        #expect(errors.isEmpty)

        let imported = result.book
        #expect(imported.accounts.count == book.accounts.count)
        #expect(imported.transactions.count == book.transactions.count)
        #expect(imported.prices.count == book.prices.count)
        #expect(imported.transactions.reduce(0) { $0 + $1.splits.count }
                == book.transactions.reduce(0) { $0 + $1.splits.count })

        // Every account's native balance, to the cent.
        let originalBalances = book.balancesByAccount()
        let importedBalances = imported.balancesByAccount()
        var byPath: [String: Decimal] = [:]
        for account in book.accounts {
            byPath[account.fullName] = originalBalances[ObjectIdentifier(account)] ?? 0
        }
        var mismatches: [String] = []
        for account in imported.accounts {
            let expected = byPath[account.fullName] ?? 0
            let actual = importedBalances[ObjectIdentifier(account)] ?? 0
            if account.commodity.round(expected) != account.commodity.round(actual) {
                mismatches.append("\(account.fullName): \(expected) vs \(actual)")
            }
        }
        #expect(mismatches.isEmpty, Comment(rawValue: mismatches.prefix(5).joined(separator: "; ")))

        // Text stability.
        #expect(LedgerExport.text(from: imported) == text)
    }
}
