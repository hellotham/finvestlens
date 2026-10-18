//
//  LiveReportCatalogueTests.swift
//  FinvestLens — FeatureUI
//
//  The whole report catalogue against the real book: every scaffold kind must
//  produce a document (or a principled empty), under its default
//  configuration — the consistency the Jul 2026 report-polish pass promises.
//  Env-gated on FL_PERF_FILE; works on a copy.
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
struct LiveReportCatalogueTests {

    @Test("Every scaffold report kind renders a document from the real book")
    func catalogue() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flcat-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        try #require(model.book != nil)

        // Kinds that must carry real content on this book. Business aging can
        // legitimately be empty (all invoices settled), so it only has to
        // build without error.
        let mustHaveContent: Set<ReportKind> = [
            .accountSummary, .netWorth, .cashFlow, .incomeExpense, .averageBalance,
            .reconcile, .spendingInsights,
            .portfolio, .investmentLots, .capitalGains,
        ]

        var timings: [(String, Duration, Duration)] = []
        for kind in ReportKind.allCases where kind.usesScaffold {
            // The statement kinds render through the statement machinery, not
            // the scaffold builder — covered by StatementTests.
            if kind == .balanceSheet || kind == .incomeStatement
                || kind == .equityStatement || kind == .trialBalance { continue }

            let configuration = kind.defaultConfiguration(for: model)
            // Cold — each report's first build after an edit, which is what a
            // person opening it waits for (P3.3) — and warm, from the memo.
            model.refreshAll(scope: .prices)
            var document: ReportDocument?
            let cold = ContinuousClock().measure { document = model.reportDocument(for: configuration) }
            let warm = ContinuousClock().measure { _ = model.reportDocument(for: configuration) }
            timings.append((kind.rawValue, cold, warm))
            if kind == .transactions {
                // Every account by default (build 4), one section each with
                // postings in the window — so an empty window is an empty
                // report, and only that may be.
                let built = try #require(document, "transactions built no document")
                let (from, to) = model.resolve(configuration.period)
                let inWindow = model.book?.transactions
                    .filter { $0.datePosted >= from && $0.datePosted <= to }.count ?? 0
                #expect(!built.sections.isEmpty || inWindow == 0,
                        "transactions: \(inWindow) transactions in the window, no section")
                var lastYear = configuration
                lastYear.period = .previousFinancialYear
                let year = try #require(model.reportDocument(for: lastYear))
                #expect(!year.sections.isEmpty, "transactions: nothing in the previous financial year")
                let rows = year.sections.reduce(0) { $0 + $1.rows.count }
                print("📊 Transactions: \(built.sections.count) sections (\(inWindow) transactions in the default window); "
                      + "previous FY \(year.sections.count) sections, \(rows) rows")
            } else if mustHaveContent.contains(kind) {
                let built = try #require(document, "\(kind.rawValue) built no document")
                #expect(!built.isEmpty, "\(kind.rawValue) produced an empty document")
                #expect(!built.periodLabel.isEmpty)
                print("📊 \(kind.rawValue): \(built.sections.count) sections, "
                      + "\(built.kpis.count) KPIs"
                      + (built.chart != nil ? ", chart" : "")
                      + (built.summary.isEmpty ? "" : ", \(built.summary.count) summary lines"))
            } else {
                print("📊 \(kind.rawValue): \(document == nil ? "no data (ok)" : "built")")
            }
        }

        // The two interactive tools' printable documents: the price history
        // must build on this book; the forecast legitimately prints nothing
        // when no scheduled activity is upcoming.
        #expect(model.priceHistoryDocument() != nil)
        let forecast = model.defaultForecastAccountID.flatMap {
            model.forecastDocument(accountID: $0, points: model.cashFlowForecast(accountID: $0))
        }
        print("📊 Forecast: \(forecast == nil ? "no upcoming activity (ok)" : "built")")

        let width = timings.map(\.0.count).max() ?? 0
        print("""

        Report builds, cold after a price-scoped refresh (memos dropped), then warm
        \(timings.sorted { $0.1 > $1.1 }.map {
            "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  cold \($0.1)  warm \($0.2)"
        }.joined(separator: "\n"))

        """)
    }
}
