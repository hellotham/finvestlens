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
            // Counted, never named: a failed expectation prints what it
            // compared, and these are a real book's holdings and costs.
            let unexpected = pf.holdings.filter { expected[$0.id] == nil }.count
            let wrongUnits = pf.holdings.filter { holding in
                expected[holding.id].map { $0.shares != holding.shares } ?? false
            }.count
            let wrongCost = pf.holdings.filter { holding in
                expected[holding.id].map { model.reportCurrency.round($0.cost) != holding.costBasis } ?? false
            }.count
            let sameCount = pf.holdings.count == expected.count
            #expect(sameCount, "a holding appeared or vanished")
            #expect(unexpected == 0, "holdings the whole-book scan does not have")
            #expect(wrongUnits == 0, "holdings whose units differ from the whole-book scan")
            #expect(wrongCost == 0, "holdings whose cost differs from the whole-book scan")
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

    /// What the Overview pays right after an edit — the number the user
    /// feels: every memo the board reads has just been dropped (R5b; target
    /// under 100 ms). The edit is a register edit's: one transaction added
    /// to the busiest bank account, today.
    @Test("The Overview's pass after an edit")
    func postEditPass() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("fldash-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let clock = ContinuousClock()
        let model = AppModel()
        try await model.open(at: copy)
        defer { model.close() }
        let book = try #require(model.book)

        let todayCap = AppModel.endOfToday()
        let range = model.resolve(model.period)
        let asOf = min(range.to, todayCap)
        var timings: [(String, Duration)] = []
        func board(record: Bool) {
            func call(_ name: String, _ body: () -> Void) {
                let time = clock.measure(body)
                if record { timings.append((name, time)) }
            }
            call("upNextState") { _ = model.upNextState }
            call("netWorthSeries") { _ = model.netWorthSeries(months: 12, endingAt: asOf) }
            call("incomeStatement") { _ = model.incomeStatement(from: range.from, to: range.to) }
            call("categoryBreakdown") { _ = model.categoryBreakdown(from: range.from, to: range.to) }
            call("portfolio") { _ = model.portfolio(asOf: asOf) }
            call("balanceSheet") { _ = model.balanceSheet(asOf: asOf) }
            call("recentJournalHeadings") { _ = model.recentJournalHeadings }
            call("alerts") { _ = model.alerts() }
            call("billReminders") { _ = model.billReminders() }
            call("wellbeingScore") { _ = model.wellbeingScore() }
            call("aging(receivable)") { _ = model.aging(receivable: true, asOf: todayCap) }
            if let budget = model.budgets.first {
                call("budgetActuals") { _ = model.budgetActuals(budget) }
            }
        }
        board(record: false)                         // warm, as a board on screen is

        let bank = try #require(book.accounts
            .filter { $0.type == .bank && !$0.isWash }
            .max { book.splits(for: $0).count < book.splits(for: $1).count })
        let expense = try #require(book.accounts.first { $0.type == .expense && !$0.isPlaceholder })
        let edit = try clock.measure {
            _ = try model.addTransaction(date: Date(), description: "Harness", currency: bank.commodity,
                                         splits: [SplitInput(accountID: bank.guid, value: -1),
                                                  SplitInput(accountID: expense.guid, value: 1)])
        }
        let pass = clock.measure { board(record: true) }

        // The performance card's samples, which a task takes after the pass.
        var samples = Duration.zero
        if let pf = model.portfolio(asOf: asOf) {
            let start = range.from == .distantPast ? asOf.addingTimeInterval(-365 * 86_400) : range.from
            let basket = pf.holdings.filter { ($0.marketValue ?? 0) > 0 }
            samples = clock.measure {
                for step in 0...26 {
                    let date = start.addingTimeInterval(asOf.timeIntervalSince(start) * Double(step) / 26)
                    for holding in basket { _ = model.securityUnitPrice(accountID: holding.id, on: date) }
                }
            }
        }

        let width = timings.map(\.0.count).max() ?? 0
        let lines = timings.sorted { $0.1 > $1.1 }
            .map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
            .joined(separator: "\n")
        print("""

        Overview after an edit
          the edit itself (refresh) : \(edit)
          the board's pass          : \(pass)
          performance samples (task): \(samples)
        \(lines)

        """)
    }

    /// Up Next's parts, and an edit's, timed one by one after an edit — so
    /// the next change goes where the time is, not where it is guessed to be.
    @Test("Where an edit's and Up Next's time goes")
    func partsAfterAnEdit() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("fldash-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }
        let clock = ContinuousClock()
        let model = AppModel()
        try await model.open(at: copy)
        defer { model.close() }
        let book = try #require(model.book)
        let bank = try #require(book.accounts
            .filter { $0.type == .bank && !$0.isWash }
            .max { book.splits(for: $0).count < book.splits(for: $1).count })

        var parts: [(String, Duration)] = []
        func part(_ name: String, _ body: () -> Void) { parts.append((name, clock.measure(body))) }

        part("lookup index rebuild") { book.invalidateLookupIndexes(); _ = book.splits(for: bank) }
        part("balancesByAccount (one walk)") { _ = book.balancesByAccount() }
        part("book.accounts × 10") { for _ in 0..<10 { _ = book.accounts } }
        part("newest security price") { _ = book.newestPriceDate { $0.namespace != .currency } }
        part("uncategorizedCount") { _ = model.uncategorizedCount() }
        part("reconcile walk (cash accounts)") {
            var count = 0
            for account in book.accounts where account.type == .bank || account.type == .credit {
                for split in book.splits(for: account) where split.transaction != nil { count += 1 }
            }
            _ = count
        }
        part("refreshAll (.prices: tree only)") { model.refreshAll(scope: .prices) }
        part("refreshAll (.book, no register)") { model.refreshAll() }
        model.selectedAccountID = bank.guid
        part("refreshAll (.book, busiest register)") { model.refreshAll() }
        part("upNextState (cold)") { _ = model.upNextState }

        let width = parts.map(\.0.count).max() ?? 0
        print("""

        Parts after an edit
        \(parts.map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }.joined(separator: "\n"))

        """)
    }
}
