//
//  LiveWholeBookPerfTests.swift
//  FinvestLens — FeatureUI
//
//  Measures what "All Transactions" costs on a real book, because the
//  navigation design proposes making it the Accounts mode's landing tab and
//  that is only defensible with a number (docs/navigation-design.md §4.4).
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --package-path Packages/FeatureUI \
//          --filter LiveWholeBookPerfTests
//
//  Skipped when FL_PERF_FILE is unset, so CI stays deterministic.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LiveWholeBookPerfTests {

    @Test("Whole-book journal build cost")
    func wholeBookCost() async throws {
        guard let perfPath else { return }

        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flwb-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let clock = ContinuousClock()
        let model = AppModel()
        try await model.open(at: copy)
        defer { model.close() }
        let book = try #require(model.book)

        // `journalTransactions` is memoised on `derivedRevision`, so a repeated
        // call measures a dictionary lookup and reports nanoseconds. Every
        // measurement below invalidates first, so it is the **cold** build —
        // which is what landing on this tab actually pays.
        var wholeBook = Duration.zero
        var rows = 0
        for _ in 0..<3 {
            model.refreshAll()
            wholeBook = clock.measure {
                rows = model.journalTransactions(forAccountID: nil).count
            }
        }
        // And the warm cost, for contrast — what scrolling and re-rendering pay.
        let warm = clock.measure { _ = model.journalTransactions(forAccountID: nil) }

        // The same call scoped to the busiest single account, as a yardstick:
        // that is what opening a normal register already costs today.
        let busiest = book.accounts.max { book.splits(for: $0).count < book.splits(for: $1).count }!
        var single = Duration.zero
        for _ in 0..<3 {
            model.refreshAll()
            single = clock.measure { _ = model.journalTransactions(forAccountID: busiest.guid) }
        }

        // What the register then does with the journal on entry: a summary
        // for every row (the Mac sheet and the iPad table both), and, in the
        // Transaction Journal style, every leg of every transaction.
        let journal = model.journalTransactions(forAccountID: nil)
        let summaries = clock.measure {
            for txn in journal { _ = model.wholeBookRowSummary(ofTransaction: txn.guid) }
        }
        var legCount = 0
        let legs = clock.measure {
            for txn in journal { legCount += model.legRows(ofTransaction: txn.guid).count }
        }

        // Not the file's name: the reference book is a real household's.
        print("""

        === All Transactions cost on the reference book ===
        transactions in book : \(book.transactions.count)
        splits in book       : \(book.transactions.reduce(0) { $0 + $1.splits.count })
        whole-book rows      : \(rows)
        whole-book build     : \(wholeBook)   (cold — cache invalidated first)
        whole-book warm      : \(warm)   (memoised hit)
        busiest account      : \(book.splits(for: busiest).count) splits, cold build \(single)
        row summaries        : \(summaries)   (one per row, as the register builds them)
        leg rows             : \(legs)   (\(legCount) legs — the Journal style's)

        """)
    }
}
