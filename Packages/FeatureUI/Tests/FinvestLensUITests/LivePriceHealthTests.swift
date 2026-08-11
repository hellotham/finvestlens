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

        // Where the missing days actually are, by exchange rather than by name:
        // knowing they sit in one namespace is what tells you whether a provider
        // can fix them at all.
        var byExchange: [String: Int] = [:]
        for security in health.securities where security.missingWhileHeld > 0 {
            byExchange[TradingCalendar.exchange(of: security.commodity), default: 0]
                += security.missingWhileHeld
        }
        print("missing days while held, by exchange: "
              + byExchange.sorted { $0.value > $1.value }
                  .map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        // Per-security detail goes to a file when asked, never to the log: this
        // harness prints counts only, and a security's name is the book's.
        if let path = ProcessInfo.processInfo.environment["FL_GAP_REPORT"] {
            let lines = health.securities
                .filter { $0.missingWhileHeld > 0 }
                .sorted { $0.missingWhileHeld > $1.missingWhileHeld }
                .map { "\($0.commodity.mnemonic)\t\($0.missingWhileHeld)\t\($0.isHeld ? "held" : "closed")"
                       + "\t\($0.priceCount) rows\t\($0.sources.keys.sorted().joined(separator: "+"))" }
            try? (["symbol\tmissing\tposition\trows\tsources"] + lines)
                .joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("gap detail written to FL_GAP_REPORT (\(lines.count) securities)")
        }

        // The old destination's per-edit price-row build cost ~0.09s; a health
        // pass that a header band shows on arrival has to stay in that league.
        #expect(elapsed < 5, "price health took \(String(format: "%.2fs", elapsed))")
    }

    @Test("The indexed lot events are identical to the scanning form, event for event")
    func lotEventsMatchTheScan() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("fllots-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        let book = try #require(model.book)

        /// The pre-index algorithm, verbatim: walk every transaction in the
        /// book, per account. Cost basis is verified against GnuCash, so the
        /// replacement has to be provably identical rather than merely green —
        /// a reordering here moves realised gains without failing loudly.
        func scanned(_ account: Account) -> [LotEvent] {
            var events: [LotEvent] = []
            for transaction in book.transactions {
                var brokerage = Decimal(0)
                var securitySplits = 0
                for split in transaction.splits where split.reconcileState != .voided {
                    if let type = split.account?.type {
                        if type == .expense { brokerage += split.value }
                        else if type.isSecurityType && split.quantity != 0 { securitySplits += 1 }
                    }
                }
                let feePerSecurity = securitySplits > 0 ? brokerage / Decimal(securitySplits) : 0
                for split in transaction.splits
                where split.account === account && split.reconcileState != .voided
                    && (split.quantity != 0 || split.action == "ReturnOfCapital") {
                    let isTrade = split.quantity != 0 && split.action != "Split"
                    events.append(LotEvent(date: transaction.datePosted,
                                           quantity: split.quantity, value: split.value,
                                           isSplit: split.action == "Split",
                                           isReturnOfCapital: split.action == "ReturnOfCapital",
                                           fee: isTrade ? feePerSecurity : 0))
                }
            }
            return events
        }

        var accounts = 0, compared = 0
        for account in book.accounts where account.type.isSecurityType && !account.isPlaceholder {
            let indexed = book.lotEvents(for: account)
            let reference = scanned(account)
            accounts += 1
            compared += reference.count
            #expect(indexed.count == reference.count,
                    "\(account.commodity.mnemonic): \(indexed.count) events against \(reference.count)")
            for (lhs, rhs) in zip(indexed, reference) {
                #expect(lhs.date == rhs.date && lhs.quantity == rhs.quantity
                        && lhs.value == rhs.value && lhs.fee == rhs.fee
                        && lhs.isSplit == rhs.isSplit && lhs.isReturnOfCapital == rhs.isReturnOfCapital,
                        "\(account.commodity.mnemonic): an event differs from the scanning form")
            }
        }
        print("lot events: \(compared) compared across \(accounts) security accounts, all identical")
        #expect(accounts > 0)
        #expect(compared > 0)
    }

    @Test("Building the holdings table repeatedly costs almost nothing after the first")
    func rowsAreMemoised() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flrows-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        let book = try #require(model.book)

        // A SwiftUI body pass reads the rows many times over — once per group in
        // the table, again per section header, again for the empty check. If
        // each of those rebuilds the series from ~150k prices the destination
        // takes seconds to draw, which is exactly what it did.
        // Where the first build's time actually goes, measured rather than
        // guessed: each of these memoises on `derivedRevision`, so timing them
        // in order attributes the cost to the right component.
        // Inside price health: the per-price day bucketing is the suspect, so
        // time it alone rather than infer it.
        let calendar = Calendar.current
        let prices = book.prices
        let tDay = Date()
        var sink = 0
        for price in prices { sink &+= calendar.startOfDay(for: price.date).hashValue }
        let dayCost = Date().timeIntervalSince(tDay)
        print("startOfDay over \(prices.count) prices: \(String(format: "%.2fs", dayCost)) (sink \(sink == 0 ? 0 : 1))")

        let t0 = Date()
        _ = model.priceHealth()
        let healthCost = Date().timeIntervalSince(t0)

        let t1 = Date()
        _ = model.advancedPortfolio(asOf: AppModel.endOfToday())
        let portfolioCost = Date().timeIntervalSince(t1)

        let t2 = Date()
        _ = model.investmentRows()
        let remainder = Date().timeIntervalSince(t2)
        print("""
              first-build breakdown: priceHealth \(String(format: "%.2fs", healthCost)), \
              advancedPortfolio \(String(format: "%.2fs", portfolioCost)), \
              rows assembly + sparklines \(String(format: "%.2fs", remainder))
              """)

        // The number a person feels: everything the destination must compute
        // before it can draw, from a book just opened. The three phases above
        // are that total, since each was measured cold in turn.
        let coldTotal = healthCost + portfolioCost + remainder
        let rows = model.investmentRows()

        let repeated = Date()
        for _ in 0..<20 { _ = model.investmentRows() }
        let warm = Date().timeIntervalSince(repeated) / 20

        print("""
              investmentRows: \(rows.count) rows, \
              cold total \(String(format: "%.2fs", coldTotal)), \
              repeat \(String(format: "%.4fs", warm))
              """)

        #expect(!rows.isEmpty)
        // Was 5.99s before the split index, the lot-event rewrite and sharing
        // one day-bucketing pass. The budget is deliberately well under that
        // rather than at it, so a regression is caught while it is still small.
        #expect(coldTotal < 2.0, "first paint needs \(String(format: "%.2fs", coldTotal))")
        // Redrawing must be free: a SwiftUI body pass reads the rows many times
        // over, once per group and again per section header.
        #expect(warm < 0.2, "a repeat build costs \(String(format: "%.3fs", warm))")

        // Changing the period must invalidate: the window is part of the answer.
        //
        // The starting range is *set*, not assumed. It is a book preference, so
        // the reference book carries whatever was last chosen in the app — this
        // asserted against the default and failed the moment someone picked a
        // different period on screen, which is the preference working correctly.
        model.sparkRange = .quarter
        let quarterPoints = model.investmentRows().reduce(0) { $0 + $1.spark.flatMap(\.points).count }
        model.sparkRange = .year
        let yearPoints = model.investmentRows().reduce(0) { $0 + $1.spark.flatMap(\.points).count }
        print("spark points: quarter \(quarterPoints), year \(yearPoints)")
        let yearRows = model.investmentRows()
        #expect(yearRows.count == rows.count)
        #expect(yearPoints > quarterPoints,
                "a longer window must produce more points, not a stale cache hit")
    }
}
