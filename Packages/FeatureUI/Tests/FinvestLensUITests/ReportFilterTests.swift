//
//  ReportFilterTests.swift
//  FinvestLens — FeatureUI
//
//  Every control on a report's parameter bar, driven through the production
//  path — `reportDocument(for:)` → model → engine — and shown to change the
//  document. Reported on build 8: "The filtering of average balance by
//  account does not seem to work. Please check all reports to sure filtering
//  works." A control that changes its own label and not the report is what
//  this suite exists to catch.
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
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Report filters reach the engine")
struct ReportFilterTests {

    /// A small book with every shape the filters distinguish: two bank
    /// accounts under one parent, two portfolios with a security each — one
    /// still held after a part-sale across two lots, one sold out of — a
    /// dividend, and a sale dated after the first month.
    @MainActor
    private struct Fixture {
        let model: AppModel
        let url: URL
        let currentAssets, everyday, savings, salary, groceries: GncGUID
        let brokerA, brokerB, cba, bhp: GncGUID
        let october: ReportPeriod       // 1–31 Oct 2025: the purchases, no sale
        let both: ReportPeriod          // 1 Oct – 30 Nov 2025: everything

        func close() { model.close(); try? FileManager.default.removeItem(at: url) }
    }

    private func fixture() throws -> Fixture {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: 12))!
        }
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)

        let currentAssets = try #require(model.addAccount(name: "Current Assets", type: .asset))
        let everyday = try #require(model.addAccount(name: "Everyday", type: .bank, parentID: currentAssets))
        let savings = try #require(model.addAccount(name: "Savings", type: .bank, parentID: currentAssets))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let dividends = try #require(model.addAccount(name: "CBA", type: .income))
        let cbaCommodity = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                     fullName: "Commonwealth Bank", smallestFraction: 10000)
        let bhpCommodity = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                                     fullName: "BHP", smallestFraction: 10000)
        let brokerA = try #require(model.addAccount(name: "Broker A", type: .asset))
        let brokerB = try #require(model.addAccount(name: "Broker B", type: .asset))
        let cba = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cbaCommodity, parentID: brokerA))
        let bhp = try #require(model.addAccount(name: "BHP", type: .stock, commodity: bhpCommodity, parentID: brokerB))

        model.addTransfer(from: salary, to: everyday, amount: dec("1000"), date: date(10, 3), description: "Pay")
        model.addTransfer(from: salary, to: savings, amount: dec("500"), date: date(10, 10), description: "Pay")
        model.addTransfer(from: everyday, to: groceries, amount: dec("200"), date: date(10, 20), description: "Shop")
        func trade(_ security: GncGUID, _ on: Date, units: String, value: String) throws {
            try model.addTransaction(date: on, description: "Trade", currency: .aud, splits: [
                SplitInput(accountID: security, value: dec(value), quantity: dec(units)),
                SplitInput(accountID: everyday, value: -dec(value))])
        }
        // CBA: two lots at $10 and $20, five sold at $30 in November.
        try trade(cba, date(10, 5), units: "10", value: "100")
        try trade(cba, date(10, 6), units: "10", value: "200")
        try trade(cba, date(11, 10), units: "-5", value: "-150")
        model.addPrice(commodity: cbaCommodity, currency: .aud, date: date(10, 5), value: dec("10"))
        model.addPrice(commodity: cbaCommodity, currency: .aud, date: date(11, 20), value: dec("25"))
        // BHP: bought at $5, sold out at $8 — a closed position.
        try trade(bhp, date(10, 7), units: "10", value: "50")
        try trade(bhp, date(11, 15), units: "-10", value: "-80")
        model.addPrice(commodity: bhpCommodity, currency: .aud, date: date(10, 7), value: dec("5"))
        // A dividend, under an income account named for the security.
        model.addTransfer(from: dividends, to: everyday, amount: dec("7"), date: date(11, 1), description: "Dividend")

        return Fixture(model: model, url: url,
                       currentAssets: currentAssets, everyday: everyday, savings: savings,
                       salary: salary, groceries: groceries,
                       brokerA: brokerA, brokerB: brokerB, cba: cba, bhp: bhp,
                       october: .custom(from: date(10, 1), to: date(10, 31)),
                       both: .custom(from: date(10, 1), to: date(11, 30)))
    }

    private func document(_ f: Fixture, _ kind: ReportKind, period: ReportPeriod? = nil,
                          accountIDs: Set<GncGUID>? = nil, depth: Int? = nil,
                          step: AverageBalanceStep? = nil, includeClosed: Bool? = nil,
                          portfolioID: GncGUID? = nil) throws -> ReportDocument {
        let configuration = ReportConfiguration(
            kind: kind.rawValue, period: period ?? f.both, accountIDs: accountIDs, depth: depth,
            step: step, includeClosed: includeClosed, portfolioID: portfolioID)
        return try #require(f.model.reportDocument(for: configuration), "\(kind.rawValue) built no document")
    }

    private func kpi(_ document: ReportDocument, _ label: String) -> Decimal? {
        document.kpis.first { $0.label == label }?.amount
    }

    // MARK: Account scope

    @Test("Average Balance narrows to the accounts chosen; none chosen is the bank and cash accounts")
    func averageBalanceScope() throws {
        let f = try fixture(); defer { f.close() }
        let everyday = try document(f, .averageBalance, accountIDs: [f.everyday])
        let savings = try document(f, .averageBalance, accountIDs: [f.savings])
        let all = try document(f, .averageBalance)
        // Everyday took the pay, the sale proceeds and the dividend; Savings
        // one pay. Each account on its own, and both together, differ.
        #expect(kpi(everyday, "Total in") == dec("1237"))
        #expect(kpi(savings, "Total in") == dec("500"))
        #expect(kpi(all, "Total in") == dec("1737"))
        #expect(kpi(everyday, "Average balance") != kpi(savings, "Average balance"))
        // The note names the accounts in scope.
        #expect(everyday.notes.contains { $0.contains("Everyday") && !$0.contains("Savings") })
    }

    @Test("A chosen parent stands for its subaccounts, and an empty choice is the default")
    func scopeExpands() throws {
        let f = try fixture(); defer { f.close() }
        let parent = try document(f, .averageBalance, accountIDs: [f.currentAssets])
        let explicit = try document(f, .averageBalance, accountIDs: [f.everyday, f.savings])
        let empty = try document(f, .averageBalance, accountIDs: [])
        let unset = try document(f, .averageBalance)
        for document in [parent, explicit, empty] {
            #expect(kpi(document, "Total in") == kpi(unset, "Total in"))
            #expect(kpi(document, "Average balance") == kpi(unset, "Average balance"))
        }
        // Cash Flow reads its scope the same way.
        let flowParent = try document(f, .cashFlow, accountIDs: [f.currentAssets])
        let flowSavings = try document(f, .cashFlow, accountIDs: [f.savings])
        let flowUnset = try document(f, .cashFlow)
        #expect(kpi(flowParent, "Money in") == kpi(flowUnset, "Money in"))
        #expect(kpi(flowSavings, "Money in") == dec("500"))
        #expect(kpi(flowSavings, "Money in") != kpi(flowUnset, "Money in"))
    }

    @Test("Transactions covers every account until some are chosen")
    func transactionsScope() throws {
        let f = try fixture(); defer { f.close() }
        let all = try document(f, .transactions)
        #expect(all.title == "Transactions — All Accounts")
        #expect(all.sections.count > 2)
        let savings = try document(f, .transactions, accountIDs: [f.savings])
        // One section, titled by the account's full name.
        #expect(savings.sections.count == 1)
        #expect(savings.sections.first?.title.hasSuffix("Savings") == true)
        #expect(savings.sections.first?.rows.count == 1)
    }

    @Test("Reconciliation reads the one account chosen")
    func reconcileAccount() throws {
        let f = try fixture(); defer { f.close() }
        let everyday = try document(f, .reconcile, accountIDs: [f.everyday])
        let savings = try document(f, .reconcile, accountIDs: [f.savings])
        #expect(everyday.kpis.map(\.amount) != savings.kpis.map(\.amount))
    }

    // MARK: Period, step, depth

    @Test("The period bounds what a report sees")
    func period() throws {
        let f = try fixture(); defer { f.close() }
        let octoberPostings = try document(f, .transactions, period: f.october, accountIDs: [f.everyday])
        let allPostings = try document(f, .transactions, accountIDs: [f.everyday])
        #expect((octoberPostings.sections.first?.rows.count ?? 0) < (allPostings.sections.first?.rows.count ?? 0))
        // No sale in October: no realised gain to report; both months, two.
        let octoberGains = try document(f, .capitalGains, period: f.october)
        #expect(octoberGains.sections.isEmpty)
        #expect(kpi(octoberGains, "Total realised") == 0)
        let gains = try document(f, .capitalGains)
        #expect(kpi(gains, "Total realised") == dec("130"))     // CBA 100 (FIFO) + BHP 30
        #expect(gains.periodLabel == f.model.label(for: f.both))
        // Investment Return is a period report too. October has the
        // purchases, no sale and no dividend; its capital gain is the
        // unrealised move alone — 20 CBA at the price nearest 31 Oct, which
        // is the 20 Nov $25 (GnuCash's nearest-in-time rule), over their
        // $300 cost: 200; BHP sits at its $5 purchase price. Both months
        // add the sale, the dividend and the November mark.
        let octoberReturn = try document(f, .investmentReturn, period: f.october)
        #expect(kpi(octoberReturn, "Dividends") == 0)
        #expect(kpi(octoberReturn, "Capital gain") == dec("200"))
        let fullReturn = try document(f, .investmentReturn)
        #expect(kpi(fullReturn, "Dividends") == dec("7"))
        #expect(kpi(fullReturn, "Capital gain") == dec("130") + dec("125"))   // + 15 held @ $25 over cost 250
        #expect(fullReturn.periodLabel == f.model.label(for: f.both))
    }

    @Test("Average Balance's interval changes the rows")
    func step() throws {
        let f = try fixture(); defer { f.close() }
        let monthly = try document(f, .averageBalance, step: .month)
        let weekly = try document(f, .averageBalance, step: .week)
        #expect(monthly.sections.first?.rows.count == 2)
        #expect((weekly.sections.first?.rows.count ?? 0) > 2)
    }

    @Test("Account Summary's depth cuts the tree")
    func depth() throws {
        let f = try fixture(); defer { f.close() }
        let whole = try document(f, .accountSummary)
        let top = try document(f, .accountSummary, depth: 1)
        let rows = { (document: ReportDocument) in document.sections.reduce(0) { $0 + $1.rows.count } }
        #expect(rows(top) < rows(whole))
    }

    // MARK: The investment reports' shared controls

    @Test("Every investment report has a portfolio section per portfolio, and the filter keeps one")
    func portfolioFilter() throws {
        let f = try fixture(); defer { f.close() }
        for kind in [ReportKind.portfolio, .investmentLots, .capitalGains, .investmentReturn] {
            let all = try document(f, kind, includeClosed: true)
            #expect(all.sections.map(\.title) == ["Broker A", "Broker B", "All portfolios"],
                    Comment(rawValue: "\(kind.rawValue): \(all.sections.map(\.title))"))
            let onlyB = try document(f, kind, includeClosed: true, portfolioID: f.brokerB)
            #expect(onlyB.sections.map(\.title) == ["Broker B"], Comment(rawValue: kind.rawValue))
            #expect(onlyB.sections.first?.rows.first?.label.hasPrefix("BHP") == true, Comment(rawValue: kind.rawValue))
            // The portfolio's own total under its rows, the yield last.
            let section = try #require(onlyB.sections.first)
            #expect(section.columns?.last == "Yield p.a.", Comment(rawValue: kind.rawValue))
            #expect(section.columnFormats?.last == .percent, Comment(rawValue: kind.rawValue))
            #expect(section.columnTotals?.label == "Total", Comment(rawValue: kind.rawValue))
            #expect(onlyB.notes.contains { $0.contains("Broker B") }, Comment(rawValue: kind.rawValue))
        }
    }

    @Test("Closed positions switch on and off on every investment report, each with its own default")
    func closedPositions() throws {
        let f = try fixture(); defer { f.close() }
        func mentionsBHP(_ document: ReportDocument) -> Bool {
            document.sections.contains { $0.title == "Broker B" }
        }
        // Valuations leave a sold-out position out unless asked.
        #expect(!mentionsBHP(try document(f, .portfolio)))
        #expect(mentionsBHP(try document(f, .portfolio, includeClosed: true)))
        #expect(!mentionsBHP(try document(f, .investmentLots)))
        #expect(mentionsBHP(try document(f, .investmentLots, includeClosed: true)))
        // A gain and a return are history, so they include it unless asked.
        #expect(mentionsBHP(try document(f, .capitalGains)))
        #expect(!mentionsBHP(try document(f, .capitalGains, includeClosed: false)))
        #expect(kpi(try document(f, .capitalGains, includeClosed: false), "Total realised") == dec("100"))
        #expect(mentionsBHP(try document(f, .investmentReturn)))
        #expect(!mentionsBHP(try document(f, .investmentReturn, includeClosed: false)))
        // The lots report with closed parcels lists CBA's sold five under it.
        let lots = try document(f, .investmentLots, includeClosed: true)
        let cbaRows = try #require(lots.sections.first { $0.title == "Broker A" }).rows
        #expect(cbaRows.filter { $0.depth == 1 }.count == 3)        // two held lots, one sold parcel
        #expect(cbaRows.contains { $0.depth == 1 && $0.label.hasPrefix("sold") })
        #expect(kpi(lots, "Realised") == dec("130"))
    }

    @Test("Method and fees change the figures, so the screen recomputes on them")
    func method() throws {
        let f = try fixture(); defer { f.close() }
        f.model.costBasisMethod = .fifo
        let fifo = try document(f, .capitalGains)
        f.model.costBasisMethod = .lifo
        let lifo = try document(f, .capitalGains)
        // FIFO sells the $10 lot (gain 100 on CBA); LIFO the $20 lot (gain 50).
        #expect(kpi(fifo, "Total realised") == dec("130"))
        #expect(kpi(lifo, "Total realised") == dec("80"))
        #expect(fifo.notes.contains { $0.contains(CostBasisMethod.fifo.displayName) })
        #expect(lifo.notes.contains { $0.contains(CostBasisMethod.lifo.displayName) })
    }

    @Test("Securities and portfolios are in order of gain, largest first, with a yield on every row")
    func ordering() throws {
        let f = try fixture(); defer { f.close() }
        let report = try document(f, .investmentReturn)
        // Broker A (CBA: 100 realised + 125 unrealised + 7 dividend) outranks
        // Broker B (BHP: 30) in the closing table of portfolios.
        let portfolios = try #require(report.sections.first { $0.title == "All portfolios" })
        #expect(portfolios.rows.map(\.label) == ["Broker A", "Broker B"])
        #expect(portfolios.rows.first?.amounts?.last.flatMap { $0 } != nil)
        #expect(portfolios.columnTotals?.amounts.count == portfolios.columns?.count)
        // Capital Gains puts each disposal under its security, in date order.
        let gains = try document(f, .capitalGains)
        let cba = try #require(gains.sections.first { $0.title == "Broker A" })
        #expect(cba.rows.first?.label == "CBA  5 sh sold")
        #expect(cba.rows.dropFirst().allSatisfy { $0.depth == 1 && $0.label.hasPrefix("sold") })
        #expect(cba.rows.first?.amounts?.prefix(3).map { $0 } == [dec("150"), dec("50"), dec("100")])
    }
}
