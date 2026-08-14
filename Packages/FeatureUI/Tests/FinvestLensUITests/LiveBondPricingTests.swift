//
//  LiveBondPricingTests.swift
//  FinvestLens — FeatureUI
//
//  Phase I4's exit criterion against the real book (docs/investments-design.md
//  §14): bonds priced from the market instead of held at par. Every bond price
//  row in the reference book was exactly 1.0, so a bond worth 72% of face was
//  valued at 100% of it — and no synthetic fixture reproduces that, because the
//  defect is in what a real book accumulated.
//
//  Runs on a **copy**: the real book is never opened, locked or modified.
//  Env-gated twice over — the book path and the live network — so CI reaches
//  neither. Output is counts and ranges only: never an ISIN, a security name or
//  a balance, because an ISIN says which bonds someone holds.
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" FL_LIVE_FIIG=1 \
//        swift test --package-path Packages/FeatureUI --filter LiveBondPricingTests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensQuotes
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]
private let liveFIIG = ProcessInfo.processInfo.environment["FL_LIVE_FIIG"] != nil

@MainActor
@Suite(.serialized)
struct LiveBondPricingTests {

    @Test("Bonds in the real book are priced from the market instead of par")
    func bondsLeavePar() async throws {
        guard let perfPath, liveFIIG else { return }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flbond-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: perfPath), to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        // The production transport: this test exists to prove the real request
        // reaches the real endpoint and lands in a real book.
        let model = AppModel(apiKeys: InMemoryAPIKeyStore(), quoteHTTP: URLSessionHTTPClient())
        defer { model.close() }
        try await model.open(at: copy)

        let candidates = model.fiigCandidates
        print("bonds with an ISIN and no provider: \(candidates.count)")
        guard !candidates.isEmpty else {
            Issue.record("no ISIN-carrying securities — the book cannot exercise this")
            return
        }

        // What the book held before: every bond at par is the defect.
        func parRelative(_ commodity: Commodity) -> [Decimal] {
            (model.book?.prices ?? [])
                .filter { $0.commodity == commodity }.map(\.value)
        }
        let before = candidates.flatMap(parRelative)
        let atPar = before.filter { $0 == 1 }.count
        print("bond price rows before: \(before.count), of which exactly 1.0: \(atPar)")

        model.routeCandidatesToFIIG()
        #expect(candidates.allSatisfy { model.quoteProvider(for: $0) == .fiig })

        let started = Date()
        await model.fetchLatestQuotes(using: .yahoo)
        print("run took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        // Priced from the market: a row that is not 1.0, dated today.
        let today = Calendar.current.startOfDay(for: Date())
        var priced = 0
        var lows: [Decimal] = [], highs: [Decimal] = []
        for commodity in candidates {
            let fresh = (model.book?.prices ?? []).filter {
                $0.commodity == commodity
                    && Calendar.current.startOfDay(for: $0.date) == today
                    && $0.source.hasPrefix("Finance::Quote:fiig")
            }
            guard let value = fresh.map(\.value).max() else { continue }
            priced += 1
            lows.append(value); highs.append(value)
        }

        print("bonds priced by FIIG: \(priced) of \(candidates.count)")
        if let low = lows.min(), let high = highs.max() {
            // **Deliberately not the figures.** FIIG publishes its whole index
            // publicly, so a bond price to five decimals is close to unique in
            // that list — printing one beside "this is the reference book"
            // would say which bond is held. The magnitude gate cannot see that;
            // it is the provenance judgement its docstring leaves to a person.
            // A band of ten is coarse enough that many bonds share it.
            func band(_ value: Decimal) -> Int {
                Int((NSDecimalNumber(decimal: value).doubleValue * 10).rounded(.down)) * 10
            }
            print("par-relative band: \(band(low))–\(band(high) + 10)% of face")
            // The ÷100 conversion, seen end to end: a percentage of par would
            // land in the tens, and a bond priced at exactly par-and-nothing-
            // else would mean the placeholder never moved.
            #expect(low > 0 && high < 3, "prices are par-relative, not percentages")
            #expect(lows.contains { $0 != 1 }, "at least one price left the 1.0 placeholder")
        }
        #expect(priced > 0, "at least one held bond should be in FIIG's index")

        // Securities FIIG does not list are *named* rather than lost — that is
        // the one failure a person can act on, by correcting the identifier.
        if case .failure(let message) = model.quoteStatus {
            print("reported failures: \(message.split(separator: ";").count)")
        }
    }
}
