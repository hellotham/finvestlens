//
//  LiveSavePerfTests.swift
//  FinvestLens — FeatureUI
//
//  A save on a **real** book supplied via FL_PERF_FILE (P10b); skipped when
//  unset. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --filter LiveSavePerfTests
//
//  Times a whole-book save against one that writes only what an edit
//  changed — the main actor's share and the write's — then checks the copy
//  the incremental one left is what a full write gives, and that the book
//  read back from it exports the same GnuCash XML, byte for byte. On a copy,
//  never the live book; prints timings and agreements, nothing of the book.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensPersistence
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LiveSavePerfTests {

    @Test("A whole-book save against one that writes only what changed")
    func saveCost() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flsave-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }
        let model = AppModel()
        try await model.open(at: copy)
        let book = try #require(model.book)
        let document = try #require(model.document)
        let clock = ContinuousClock()

        func timedSave() async throws -> (stage: Duration, write: Duration) {
            var staged: StagedSave?
            let stage = try clock.measure { staged = try document.stageSnapshot() }
            let ready = try #require(staged)
            let (fingerprint, write) = try await Task.detached {
                let clock = ContinuousClock()
                var fingerprint: Data?
                let write = try clock.measure { fingerprint = try FinvestLensDocument.commitStaged(ready) }
                return (fingerprint, write)
            }.value
            document.finishSave(fingerprint: fingerprint, staged: ready)
            return (stage, write)
        }

        // As every save was: the whole book.
        book.invalidateLookupIndexes()
        document.markDirty()
        let whole = try await timedSave()

        // One register edit, reported as the app reports it.
        let bank = try #require(book.accounts
            .filter { $0.type == .bank && !$0.isWash }
            .max { book.splits(for: $0).count < book.splits(for: $1).count })
        let expense = try #require(book.accounts.first { $0.type == .expense && !$0.isPlaceholder })
        _ = try model.addTransaction(date: Date(), description: "Harness", currency: bank.commodity,
                                     splits: [SplitInput(accountID: bank.guid, value: -1),
                                              SplitInput(accountID: expense.guid, value: 1)])
        let edited = try #require(book.transactions.first)
        _ = try model.updateTransaction(id: edited.guid, date: edited.datePosted,
                                        description: edited.transactionDescription, currency: edited.currency,
                                        splits: edited.splits.map {
                                            SplitInput(accountID: $0.account?.guid, value: $0.value,
                                                       quantity: $0.quantity, memo: $0.memo + " ")
                                        })
        model.addExchangeRate(from: .usd, to: book.baseCurrency, rate: 1.5, date: Date())
        let incremental = try await timedSave()
        let holds = try document.workingCopyHoldsBook()
        #expect(holds)

        let exported = GnuCashXMLExporter.export(book)
        model.close()
        let reopened = AppModel()
        try await reopened.open(at: copy)
        defer { reopened.close() }
        let reread = GnuCashXMLExporter.export(try #require(reopened.book))
        // Digests, not the exports: a failed `#expect` prints what it
        // compared, and this is the whole of a real book.
        let agrees = SHA256.hash(data: reread) == SHA256.hash(data: exported)
        #expect(agrees)

        print("""

        === save on the reference book ===
        whole book   : stage \(whole.stage) on the main actor, write \(whole.write)
        what changed : stage \(incremental.stage) on the main actor, write \(incremental.write)
        the copy holds the book: \(holds); read back, the GnuCash export agrees: \(agrees)

        """)
    }
}
