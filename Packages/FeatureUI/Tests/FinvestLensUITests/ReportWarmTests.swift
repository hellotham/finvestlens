//
//  ReportWarmTests.swift
//  FinvestLens — FeatureUI
//
//  Slow reports are built on a replica off the main actor before a view asks
//  for them (P3.3). What lands in the memo must be what the main actor would
//  have built, must not land at all if the book moved meanwhile, and a report
//  measured fast is not sent off the main actor — taking the replica would
//  cost more than building it.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Reports built off the main actor")
struct ReportWarmTests {

    private func makeModel() throws -> (AppModel, URL, Set<GncGUID>) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        for index in 0..<40 {
            _ = try model.addTransaction(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400 * 2),
                                         description: "Shop \(index)", currency: .aud, splits: [
                SplitInput(accountID: bank, value: -dec("\(index + 1).25")),
                SplitInput(accountID: food, value: dec("\(index + 1).25"))])
        }
        return (model, url, [bank])
    }

    private var range: (Date, Date) {
        (Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_000 + 86_400 * 90))
    }

    @Test("Built off the main actor, it is the report the main actor builds, and the memo has it")
    func sameReport() async throws {
        let (model, url, scope) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let (from, to) = range
        let request = model.averageBalanceRequest(accountIDs: scope, from: from, to: to, step: .week)

        await model.warm(request)
        let warmed: AverageBalanceReport? = model.peekReport(request.key)
        let built = try #require(warmed, "the memo holds the report built off the main actor")
        #expect(model.reportBuildTimes[request.kind] != nil)

        model.refreshAll(scope: .prices)          // drop the memo; build it here
        let onMain = try #require(model.averageBalance(accountIDs: scope, from: from, to: to, step: .week))
        #expect(built.intervals == onMain.intervals)
        #expect(built.accountNames == onMain.accountNames)
    }

    @Test("An edit made while it builds keeps that build out of the memo; the one built after it goes in")
    func editMeanwhile() async throws {
        let (model, url, scope) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let (from, to) = range
        let bank = try #require(scope.first)
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        let request = model.averageBalanceRequest(accountIDs: scope, from: from, to: to, step: .month)

        let revision = model.bookRevision
        let warming = Task { await model.warm(request) }
        // Let it take its replica and set off; the edit lands while it builds
        // (its continuation needs the main actor, which this holds). The edit
        // moves the very balances the report averages.
        await Task.yield()
        #expect(model.bookRevision == revision)
        _ = try model.addTransaction(date: from.addingTimeInterval(86_400 * 10), description: "Meanwhile",
                                     currency: .aud, splits: [SplitInput(accountID: bank, value: -500),
                                                              SplitInput(accountID: rent, value: 500)])
        await warming.value
        // Built again after the edit, so what the memo holds is the book as it
        // now stands — not the build the edit overtook.
        let warmed: AverageBalanceReport? = model.peekReport(request.key)
        let kept = try #require(warmed)
        model.refreshAll(scope: .prices)          // drop the memo; build it here
        let fresh = try #require(model.averageBalance(accountIDs: scope, from: from, to: to, step: .month))
        #expect(kept.intervals == fresh.intervals)
    }

    @Test("A report measured fast is built where it is asked, not on a replica")
    func fastStaysHere() async throws {
        let (model, url, scope) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let (from, to) = range
        let request = model.averageBalanceRequest(accountIDs: scope, from: from, to: to, step: .day)
        model.reportBuildTimes[request.kind] = ReportBuildTime(took: .milliseconds(1), work: request.work)

        await model.warm(request)
        let warmed: AverageBalanceReport? = model.peekReport(request.key)
        #expect(warmed == nil, "nothing was sent off the main actor")
        #expect(model.averageBalance(accountIDs: scope, from: from, to: to, step: .day) != nil)
    }

    @Test("A quick build over a quiet account does not keep a busy account's report on the main actor")
    func quietDoesNotVouchForBusy() async throws {
        let (model, url, scope) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let (from, to) = range
        let bank = try #require(scope.first)
        let quiet = try #require(model.addAccount(name: "Quiet", type: .bank))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        _ = try model.addTransaction(date: from.addingTimeInterval(86_400), description: "Once",
                                     currency: .aud, splits: [SplitInput(accountID: quiet, value: -5),
                                                              SplitInput(accountID: rent, value: 5)])
        let small = model.transactionsReportRequest(accountIDs: [quiet], from: from, to: to)
        let busy = model.transactionsReportRequest(accountIDs: [bank], from: from, to: to)
        #expect(small.work == 1)
        #expect(busy.work == 40)
        // 10 ms over one posting is a rate: forty of them is 400 ms, past the
        // threshold — so the busy account's report is built on a replica.
        model.reportBuildTimes[small.kind] = ReportBuildTime(took: .milliseconds(10), work: small.work)

        await model.warm(small)
        let smallWarmed: AccountsTransactionReport? = model.peekReport(small.key)
        #expect(smallWarmed == nil, "the quiet account's own report is fast: built where it is asked")
        await model.warm(busy)
        let busyWarmed: AccountsTransactionReport? = model.peekReport(busy.key)
        #expect(busyWarmed != nil, "the busy account's report was built off the main actor")
    }

    @Test("A quick month does not keep All Time's average balance on the main actor")
    func monthDoesNotVouchForAllTime() async throws {
        let (model, url, scope) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let (from, _) = range
        let month = model.averageBalanceRequest(accountIDs: scope, from: from,
                                                to: from.addingTimeInterval(86_400 * 30), step: .week)
        // The same forty postings, over ten years of days walked one by one.
        let allTime = model.averageBalanceRequest(accountIDs: scope, from: .distantPast,
                                                  to: from.addingTimeInterval(86_400 * 3_650), step: .month)
        #expect(month.work == 40 + 31)
        #expect(allTime.work == 40 + 3_651)
        model.reportBuildTimes[month.kind] = ReportBuildTime(took: .milliseconds(10), work: month.work)

        await model.warm(allTime)
        let warmed: AverageBalanceReport? = model.peekReport(allTime.key)
        #expect(warmed != nil, "All Time was built off the main actor")
    }

    @Test("Build times describe one book: closing it forgets them")
    func closeForgetsBuildTimes() async throws {
        let (model, url, scope) = try makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        let (from, to) = range
        let request = model.averageBalanceRequest(accountIDs: scope, from: from, to: to, step: .week)
        await model.warm(request)
        #expect(model.reportBuildTimes[request.kind] != nil)
        model.close()
        #expect(model.reportBuildTimes.isEmpty)
    }

    @Test("What the warm step builds is what the document reads — nothing is built again on the main actor")
    func warmIsWhatTheDocumentReads() async throws {
        let (model, url, scope) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        for kind in [ReportKind.averageBalance, .transactions, .reconcile] {
            var configuration = kind.defaultConfiguration(for: model)
            configuration.accountIDs = scope
            model.reportBuildTimes = [:]
            await model.warmReports(for: configuration)
            // Each build records its time under its kind; the warm step's
            // were off the main actor. Marked, so a build in place shows.
            let warmed = Array(model.reportBuildTimes.keys)
            #expect(!warmed.isEmpty, "\(kind.rawValue): the warm step built nothing")
            let marked = ReportBuildTime(took: .seconds(-1), work: nil)
            for key in warmed { model.reportBuildTimes[key] = marked }
            _ = try #require(model.reportDocument(for: configuration))
            for key in warmed {
                // The warm step and the document resolve their account,
                // period and step each in their own code: if they drift, the
                // warm builds a report nobody reads and this one is built here.
                #expect(model.reportBuildTimes[key] == marked,
                        "\(kind.rawValue): \(key) was built again on the main actor")
            }
        }
    }

    @Test("The Reports view's warm step leaves a document that is the one built in place")
    func documentFromWarmMemo() async throws {
        let (model, url, scope) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        var configuration = ReportKind.averageBalance.defaultConfiguration(for: model)
        configuration.accountIDs = scope
        await model.warmReports(for: configuration)
        let fromWarm = try #require(model.reportDocument(for: configuration))
        model.refreshAll(scope: .prices)
        let inPlace = try #require(model.reportDocument(for: configuration))
        #expect(fromWarm.kpis.map(\.amount) == inPlace.kpis.map(\.amount))
        #expect(fromWarm.sections.map(\.rows.count) == inPlace.sections.map(\.rows.count))
    }
}
