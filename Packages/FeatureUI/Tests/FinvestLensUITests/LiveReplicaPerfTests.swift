//
//  LiveReplicaPerfTests.swift
//  FinvestLens — FeatureUI
//
//  What `Book.replica()` costs on a **real** book supplied via FL_PERF_FILE,
//  and what it buys: the three whole-book exports built on a replica off the
//  main actor, against the same exports built on the book. Skipped when unset.
//  Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --filter LiveReplicaPerfTests
//
//  Prints timings, counts and whether the bytes agree — nothing of the book.
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
struct LiveReplicaPerfTests {

    @Test("Replica cost, and the exports built on one")
    func replicaCost() async throws {
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
        let clock = ContinuousClock()

        var replicaTimes: [Duration] = []
        for _ in 0..<3 { replicaTimes.append(clock.measure { _ = book.replica() }) }

        var xml = Data()
        let xmlOnBook = clock.measure { xml = GnuCashXMLExporter.export(book) }
        var ledger = ""
        let ledgerOnBook = clock.measure { ledger = LedgerExport.text(from: book) }
        var csv = ""
        let csvOnBook = clock.measure { csv = CSVExporter.transactions(book) }

        let replica = book.replica()
        let (xmlCopy, xmlOffMain) = await Task.detached {
            let clock = ContinuousClock()
            var data = Data()
            let time = clock.measure { data = GnuCashXMLExporter.export(replica.book) }
            return (data, time)
        }.value
        let other = book.replica()
        let ledgerCopy = await Task.detached { LedgerExport.text(from: other.book) }.value
        let third = book.replica()
        let csvCopy = await Task.detached { CSVExporter.transactions(third.book) }.value

        // Digests, not the exports: a failed `#expect` prints both operands,
        // and these are the whole of a real book's journal.
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let xmlAgrees = digest(xmlCopy) == digest(xml)
        let ledgerAgrees = digest(Data(ledgerCopy.utf8)) == digest(Data(ledger.utf8))
        let csvAgrees = digest(Data(csvCopy.utf8)) == digest(Data(csv.utf8))
        #expect(xmlAgrees)
        #expect(ledgerAgrees)
        #expect(csvAgrees)

        print("""

        === replica ===
        transactions / prices : \(book.transactions.count) / \(book.prices.count)
        replica (main actor)  : \(replicaTimes.map(\.description).joined(separator: ", "))
        XML on the book       : \(xmlOnBook)
        XML on a replica      : \(xmlOffMain) (off the main actor)
        Ledger on the book    : \(ledgerOnBook)
        CSV on the book       : \(csvOnBook)
        exports agree         : XML \(xmlAgrees), Ledger \(ledgerAgrees), CSV \(csvAgrees)

        """)
    }
}
