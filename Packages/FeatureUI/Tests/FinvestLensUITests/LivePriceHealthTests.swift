//
//  LivePriceHealthTests.swift
//  FinvestLens — FeatureUI
//
//  Phase I1 of the Investments hub against the real book: the case that broke
//  the old Prices & Securities destination (~150k prices, ~90 securities, half
//  of them no longer held) is the only case worth accepting on. A synthetic
//  fixture cannot reproduce it — docs/investments-design.md §14.
//
//  Env-gated on FL_PERF_FILE; works on a copy, so the real book is never
//  opened, locked or modified. Output is counts and ratios only: no symbol,
//  balance or account name is ever logged.
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//        swift test --package-path Packages/FeatureUI --filter LivePriceHealthTests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LivePriceHealthTests {

    @Test("Price health is self-consistent on the real book, and fast enough")
    func health() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flph-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        let book = try #require(model.book)

        let started = Date()
        let health = FinancialReports.priceHealth(book, currency: model.reportCurrency)
        let elapsed = Date().timeIntervalSince(started)

        // Counts and ratios only — never a symbol, a price or a balance.
        print("""
              price health: \(health.securities.count) securities, \
              \(health.heldCount) held, \
              coverage \(health.valueCoverage.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"), \
              \(health.currentCount) current / \(health.staleCount) stale / \(health.oldCount) old, \
              \(health.manualCount) manual, \
              \(health.securitiesWithHeldGaps) with gaps while held \
              (\(health.missingWhileHeld) trading days), \
              computed in \(String(format: "%.2fs", elapsed))
              """)

        #expect(!health.securities.isEmpty, "the reference book holds securities")
        #expect(health.heldCount > 0)

        // A ratio, by construction.
        if let coverage = health.valueCoverage {
            #expect(coverage >= 0 && coverage <= 1)
        }

        // The bands partition the held population — no security counted twice
        // or lost, which a hand-rolled band table gets wrong sooner or later.
        #expect(health.currentCount + health.staleCount + health.oldCount == health.heldCount)

        // Held is held: this report and the portfolio report must agree on the
        // population, or two surfaces will disagree in front of the user.
        let portfolio = FinancialReports.portfolio(book, currency: model.reportCurrency)
        let portfolioHeld = Set(portfolio.holdings.filter { $0.shares != 0 }.map(\.symbol))
        let healthHeld = Set(health.securities.filter(\.isHeld).map(\.commodity.mnemonic))
        #expect(portfolioHeld == healthHeld,
                "portfolio and price health disagree on \(portfolioHeld.symmetricDifference(healthHeld).count) securities")

        for security in health.securities {
            #expect(security.tradingDaysBehind >= 0)
            if security.freshness == .missing { #expect(security.lastPriceDate == nil) }
            if security.lastPriceDate != nil { #expect(security.freshness != .missing) }

            // Every gap flagged as held must really fall inside a holding
            // period — the flag is the whole basis for "fetch closed positions
            // only where their held period has gaps" (`FR-INV-25`).
            for gap in security.gaps where gap.whileHeld {
                #expect(security.holdingPeriods.contains { $0.contains(gap.start) || $0.contains(gap.end) })
            }
            if !security.gapsTruncated {
                #expect(security.missingWhileHeld
                        == security.gaps.filter(\.whileHeld).reduce(0) { $0 + $1.tradingDays })
            }
            // Provenance is recorded for every price row counted, and a day
            // cannot be priced more often than there are rows to price it.
            #expect(security.sources.values.reduce(0, +) == security.priceCount)
            #expect(security.pricedDays <= security.priceCount)
        }

        let duplicates = health.securities.reduce(0) { $0 + ($1.priceCount - $1.pricedDays) }
        print("duplicate same-day prices: \(duplicates) rows across \(health.securities.count) securities")

        // The old destination's per-edit price-row build cost ~0.09s; a health
        // pass that a header band shows on arrival has to stay in that league.
        #expect(elapsed < 5, "price health took \(String(format: "%.2fs", elapsed))")
    }
}
