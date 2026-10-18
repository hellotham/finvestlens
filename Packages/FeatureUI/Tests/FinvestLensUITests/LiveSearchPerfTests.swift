//
//  LiveSearchPerfTests.swift
//  FinvestLens — FeatureUI
//
//  The search bar on a **real** book supplied via FL_PERF_FILE; skipped when
//  unset. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --filter LiveSearchPerfTests
//
//  What one keystroke costs, letter by letter, as a person types a word:
//  matching the query against the book, and making the result rows. On a
//  copy, never the live book; prints timings and counts, nothing of the book
//  — the queries are common English letters, not words from it.
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
struct LiveSearchPerfTests {

    @Test("What each keystroke of a search costs")
    func keystrokes() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flsearch-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let model = AppModel()
        try await model.open(at: copy)
        defer { model.close() }
        let clock = ContinuousClock()

        var lines: [String] = []
        // The first keystroke after a change builds the folded index; the rest
        // scan it, and a lengthened query only the last one's matches. The
        // results are drawn as the general ledger narrowed to them, so that
        // cut is timed too — rows of summaries are made only when asked.
        for query in ["s", "st", "sta", "e", "er", "a", "an", "and"] {
            model.searchQuery = query
            let elapsed = clock.measure { model.runSearch() }
            let ledger = clock.measure { _ = model.searchLedgerTransactions() }
            lines.append("  \(query.padding(toLength: 5, withPad: " ", startingAt: 0)) \(model.searchMatchCount) matches  search \(elapsed)  ledger \(ledger)")
        }
        let rows = clock.measure { _ = model.searchResults }
        lines.append("  rows of the last results, when asked: \(rows)")
        let book = try #require(model.book)
        let index = clock.measure {
            model.searchTextIndex = nil
            _ = model.searchIndex(for: book)
        }
        lines.append("  the index itself, built again: \(index)")
        print("""

        === search keystrokes on the reference book ===
        \(lines.joined(separator: "\n"))

        """)
    }
}
