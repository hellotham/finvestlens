//
//  LiveDashboardPerfTests.swift
//  FinvestLens — FeatureUI
//
//  Where the Dashboard's first paint goes, measured rather than guessed.
//  Reported 16 Aug 2026: "dashboard mode takes too long to load - performance
//  issue." The board calls a dozen report functions and every one of them is
//  supposed to be memoised on `derivedRevision`; this harness times each call
//  cold and then warm, so a slow one and an *unmemoised* one are told apart by
//  a number instead of by reading the code and forming an opinion.
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --filter LiveDashboardPerfTests
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
struct LiveDashboardPerfTests {

    @Test("Where the Dashboard's first paint goes")
    func dashboardCost() async throws {
        guard let perfPath else { return }

        // Work on a copy: the harness must never touch the live book.
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("fldash-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let clock = ContinuousClock()
        let model = AppModel()
        _ = try await clock.measure { try await model.open(at: copy) }
        defer { model.close() }

        // The board's own parameters, spelled the way `DashboardView` spells
        // them — a different period would measure a different question.
        let todayCap = AppModel.endOfToday()
        let range = model.resolve(model.period)
        let asOf = min(range.to, todayCap)

        // **Identity, before speed.** `FinancialReports.portfolio` stopped
        // walking every transaction per security account and started using the
        // `splits(for:)` index. That is a money report, so the rewrite has to
        // produce the same figures on a real book, not merely pass fixtures.
        // The old shape is recomputed here and compared holding by holding.
        if let pf = model.portfolio(asOf: asOf), let book = model.book {
            var expected: [GncGUID: (shares: Decimal, cost: Decimal)] = [:]
            for account in book.accounts
            where account.type.isSecurityType && !account.isPlaceholder {
                var shares = Decimal(0), cost = Decimal(0)
                for transaction in book.transactions where transaction.datePosted <= asOf {
                    for split in transaction.splits
                    where split.account === account && split.reconcileState != .voided {
                        shares += split.quantity
                        cost += split.value
                    }
                }
                if shares != 0 || cost != 0 { expected[account.guid] = (shares, cost) }
            }
            #expect(pf.holdings.count == expected.count, "a holding appeared or vanished")
            for holding in pf.holdings {
                let want = try #require(expected[holding.id], "unexpected holding \(holding.symbol)")
                #expect(holding.shares == want.shares, "\(holding.symbol) units")
                #expect(holding.costBasis == model.reportCurrency.round(want.cost),
                        "\(holding.symbol) cost")
            }
            print("identity: \(pf.holdings.count) holdings match the whole-book scan")
        }

        var report: [(String, Duration, Duration)] = []
        func time(_ name: String, _ body: () -> Void) {
            let cold = clock.measure(body)
            let warm = clock.measure(body)
            report.append((name, cold, warm))
        }

        time("incomeStatement") { _ = model.incomeStatement(from: range.from, to: range.to) }
        time("categoryBreakdown") { _ = model.categoryBreakdown(from: range.from, to: range.to) }
        time("portfolio") { _ = model.portfolio(asOf: asOf) }
        time("balanceSheet") { _ = model.balanceSheet(asOf: asOf) }
        time("netWorthSeries") { _ = model.netWorthSeries(months: 12, endingAt: asOf) }
        time("alerts") { _ = model.alerts() }
        time("billReminders") { _ = model.billReminders() }
        time("wellbeingScore") { _ = model.wellbeingScore() }
        time("aging(receivable)") { _ = model.aging(receivable: true, asOf: todayCap) }
        time("upNextState") { _ = model.upNextState }
        time("accountTree") { _ = model.accountTree }
        if let budget = model.budgets.first {
            time("budgetActuals") { _ = model.budgetActuals(budget) }
        }

        // The performance card's sampling loop, which the timings above do not
        // reach: it is `async`, so it is off the first-paint path — but it is
        // also `@MainActor`, so every sample it takes is main-thread work while
        // the board is trying to draw.
        if let pf = model.portfolio(asOf: asOf) {
            let end = asOf
            let start = range.from == .distantPast
                ? end.addingTimeInterval(-365 * 86_400) : range.from
            let basket = pf.holdings.filter { ($0.marketValue ?? 0) > 0 }
            let samples = 26
            let loop = clock.measure {
                for step in 0...samples {
                    let fraction = Double(step) / Double(samples)
                    let date = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
                    for h in basket { _ = model.securityUnitPrice(accountID: h.id, on: date) }
                }
            }
            let one = clock.measure {
                _ = model.securityUnitPrice(accountID: basket.first!.id, on: start)
            }
            report.append(("computePerformance loop", loop, one))
            print("basket \(basket.count) holdings × \(samples + 1) samples "
                  + "= \(basket.count * (samples + 1)) price lookups")
        }

        let width = report.map(\.0.count).max() ?? 0
        let lines = report
            .sorted { $0.1 > $1.1 }
            .map { name, cold, warm in
                "  \(name.padding(toLength: width, withPad: " ", startingAt: 0))"
                + "  cold \(cold)  warm \(warm)"
            }
            .joined(separator: "\n")
        print("""

        Dashboard call costs (sorted by cold time)
        \(lines)

        """)
    }
}
