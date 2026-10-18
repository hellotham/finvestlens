//
//  LiveImportMatchPerfTests.swift
//  FinvestLens — FeatureUI
//
//  The import sheet's Preview against a **real** book supplied via
//  FL_PERF_FILE; skipped when unset. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --filter LiveImportMatchPerfTests
//
//  The statement is made from the book itself, on a copy that is never saved:
//  the busiest bank account's last 120 entries as the bank would send them
//  again (re-imports, to be recognised), and 60 rows a month past its end
//  with older payees' narratives and amounts a cent off (new rows, for the
//  history to suggest a category for). It prints counts, the time and a
//  fingerprint of what was matched — a hash, so two runs can be compared with
//  nothing of the book on screen.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LiveImportMatchPerfTests {

    @Test("matchStaged cost and fingerprint")
    func matchCost() async throws {
        guard let perfPath else { return }

        // Work on a copy: the harness must never touch the live book.
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flperf-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let model = AppModel()
        try await model.open(at: copy)
        defer { model.close() }
        let book = try #require(model.book)

        let bank = try #require(book.accounts
            .filter { $0.type == .bank && !$0.isWash }
            .max { book.splits(for: $0).count < book.splits(for: $1).count })
        let history = book.splits(for: bank)
            .filter { $0.transaction != nil }
            .sorted { $0.transaction!.datePosted < $1.transaction!.datePosted }
        let recent = history.suffix(120)
        let end = try #require(recent.last?.transaction?.datePosted)
        let older = history.dropLast(120).suffix(600).enumerated()
            .filter { $0.offset % 10 == 0 }.map(\.element)

        var staged = recent.map { split in
            StagedTransaction(date: split.transaction!.datePosted, amount: split.quantity,
                              payee: split.transaction!.transactionDescription, memo: split.memo)
        }
        staged += older.map { split in
            StagedTransaction(date: end.addingTimeInterval(86_400 * 30),
                              amount: split.quantity + Decimal(string: "0.01")!,
                              payee: split.transaction!.transactionDescription, memo: split.memo)
        }

        let clock = ContinuousClock()
        var results: [MatchResult] = []
        let first = clock.measure { results = model.matchStaged(staged, intoAccountID: bank.guid) }
        var again: [MatchResult] = []
        let second = clock.measure { again = model.matchStaged(staged, intoAccountID: bank.guid) }
        #expect(fingerprint(again) == fingerprint(results))

        print("""

        === matchStaged ===
        account splits        : \(history.count)
        rows                  : \(staged.count)
        duplicates            : \(results.filter(\.isDuplicate).count)
        transfers             : \(results.filter { $0.transferSplitID != nil }.count)
        with a suggestion     : \(results.filter { $0.suggestedAccountID != nil }.count)
        first / second        : \(first) / \(second)
        fingerprint           : \(fingerprint(results).prefix(16))

        """)
    }

    /// What each row was matched to, in row order, hashed.
    private func fingerprint(_ results: [MatchResult]) -> String {
        let text = results.map { result in
            [result.isDuplicate ? "dup" : "new",
             result.matchedSplitID?.description ?? "-",
             result.suggestedAccountID?.description ?? "-",
             result.transferSplitID?.description ?? "-"].joined(separator: "|")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
