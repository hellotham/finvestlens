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
        let late: ReportPeriod          // 16–30 Nov 2025: after both sales
        let utc: Calendar

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
                       both: .custom(from: date(10, 1), to: date(11, 30)),
                       late: .custom(from: date(11, 16), to: date(11, 30)),
                       utc: calendar)
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
        // No sale in October: no CGT event to report; both months, two.
        let octoberGains = try document(f, .capitalGains, period: f.october)
        #expect(octoberGains.sections.isEmpty)
        #expect(kpi(octoberGains, "Gain (loss)") == 0)
        let gains = try document(f, .capitalGains)
        #expect(kpi(gains, "Gain (loss)") == dec("130"))     // CBA 100 (FIFO) + BHP 30
        #expect(kpi(gains, "Net capital gain") == dec("130"), "both held under a year: no discount")
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

    private func day(_ f: Fixture, _ month: Int, _ day: Int) -> Date {
        f.utc.date(from: DateComponents(year: 2025, month: month, day: day, hour: 12))!
    }

    @Test("Every investment report has a portfolio section per portfolio, and the filter keeps one")
    func portfolioFilter() throws {
        let f = try fixture(); defer { f.close() }
        for kind in [ReportKind.portfolio, .investmentLots, .capitalGains, .investmentReturn,
                     .historicalCost, .multiPeriodReturn] {
            let all = try document(f, kind, includeClosed: true)
            #expect(Array(all.sections.map(\.title).prefix(3)) == ["Broker A", "Broker B", "All portfolios"],
                    Comment(rawValue: "\(kind.rawValue): \(all.sections.map(\.title))"))
            let onlyB = try document(f, kind, includeClosed: true, portfolioID: f.brokerB)
            #expect(onlyB.sections.first?.title == "Broker B", Comment(rawValue: kind.rawValue))
            #expect(onlyB.sections.contains { $0.title == "All portfolios" } == false, Comment(rawValue: kind.rawValue))
            #expect(onlyB.sections.first?.rows.first?.label.hasPrefix("BHP") == true, Comment(rawValue: kind.rawValue))
            // Typed cells under named columns, the portfolio's total beneath.
            let section = try #require(onlyB.sections.first)
            let columns = try #require(section.columns)
            #expect(section.rows.allSatisfy { $0.cells?.count == columns.count }, Comment(rawValue: kind.rawValue))
            #expect(section.cellTotals?.label == "Total", Comment(rawValue: kind.rawValue))
            #expect(section.cellTotals?.cells.count == columns.count, Comment(rawValue: kind.rawValue))
            #expect(onlyB.notes.contains { $0.contains("Broker B") }, Comment(rawValue: kind.rawValue))
        }
        // Income and Drawdown have something to say only of CBA: the
        // dividend, and the prices in the period.
        let income = try document(f, .income)
        #expect(income.sections.first?.title == "Broker A")
        #expect(kpi(income, "Cash income") == dec("7"))
        #expect(try document(f, .income, portfolioID: f.brokerA).sections.first?.title == "Broker A")
        #expect(f.model.reportDocument(for: ReportConfiguration(kind: ReportKind.income.rawValue, period: f.both,
                                                                 portfolioID: f.brokerB))?.isEmpty == true)
        let drawdown = try document(f, .drawdown)
        #expect(drawdown.sections.first?.title == "Broker A")
        #expect(drawdown.sections.first?.rows.first?.label == "CBA")
    }

    @Test("Every investment report prints dates as dates and units as units, never folded into a label")
    func typedColumns() throws {
        let f = try fixture(); defer { f.close() }
        let portfolio = try document(f, .portfolio)
        let cba = try #require(portfolio.sections.first { $0.title == "Broker A" }?.rows.first)
        #expect(cba.label == "CBA")
        #expect(cba.cells?[0] == .date(day(f, 10, 5)))          // first acquisition
        #expect(cba.cells?[1] == .units(15))
        #expect(cba.cells?[2] == .money(25))                    // the 20 Nov price
        #expect(portfolio.sections.first?.columns?.first == "Acquired")
        let lots = try document(f, .investmentLots)
        let parcels = try #require(lots.sections.first { $0.title == "Broker A" }).rows.filter { $0.depth == 1 }
        #expect(parcels.count == 2)
        #expect(parcels.first?.cells?[0] == .date(day(f, 10, 5)))
        #expect(parcels.first?.cells?[1] == .units(5))           // five of the first ten remain
        #expect(parcels.first?.label == "Parcel")
        #expect(lots.summary.contains { $0.contains("If every open parcel were sold") })
    }

    @Test("Capital Gains lists every parcel sold with acquisition and sale dates, cost base, proceeds, held and treatment")
    func capitalGainsParcels() throws {
        let f = try fixture(); defer { f.close() }
        let gains = try document(f, .capitalGains)
        #expect(gains.sections.first?.columns == ["Acquired", "Sold", "Units", "Cost base", "Proceeds", "Gain (loss)",
                                                  "Held", "Treatment", "Assessable"])
        let cba = try #require(gains.sections.first { $0.title == "Broker A" })
        let security = try #require(cba.rows.first)
        #expect(security.label == "CBA" && security.depth == 0)
        #expect(security.cells?[2] == .units(5) && security.cells?[3] == .money(50)
                && security.cells?[4] == .money(150) && security.cells?[5] == .money(100))
        let parcel = try #require(cba.rows.dropFirst().first)
        #expect(parcel.depth == 1)
        #expect(parcel.cells?[0] == .date(day(f, 10, 5)) && parcel.cells?[1] == .date(day(f, 11, 10)))
        #expect(parcel.cells?[6] == .text("36 d"))
        #expect(parcel.cells?[7] == .text("Short"))
        // The ATO's net gain, worked over the period's parcels.
        let assessment = try #require(gains.sections.first { $0.title.hasPrefix("Net capital gain") })
        #expect(assessment.total?.amount == dec("130"))
        #expect(assessment.rows.first?.label == "Capital gains" && assessment.rows.first?.amount == dec("130"))
        #expect(gains.chart != nil)
        #expect(gains.notes.contains { $0.contains("filed by the day the parcel was sold") })
    }

    @Test("Closed positions switch on and off on every investment report, each with its own meaning")
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
        // A return is history, so it includes a closed position unless asked.
        #expect(mentionsBHP(try document(f, .investmentReturn)))
        #expect(!mentionsBHP(try document(f, .investmentReturn, includeClosed: false)))
        // Capital Gains files a sale by its date: BHP's November sale is in
        // the period whichever way the switch is set …
        #expect(mentionsBHP(try document(f, .capitalGains)))
        #expect(mentionsBHP(try document(f, .capitalGains, includeClosed: false)))
        // … and a period after both sales holds no CGT event, until Closed
        // positions brings the whole history of what was sold out of by its
        // end — BHP, not the still-held CBA — marked as history and kept out
        // of the totals.
        let late = try document(f, .capitalGains, period: f.late)
        #expect(late.sections.isEmpty)
        let history = try document(f, .capitalGains, period: f.late, includeClosed: true)
        #expect(mentionsBHP(history))
        #expect(!history.sections.contains { $0.title == "Broker A" })
        #expect(kpi(history, "Gain (loss)") == 0)
        let parcel = try #require(history.sections.first?.rows.dropFirst().first)
        #expect(parcel.cells?[7].string(code: "AUD").contains("history") == true)
        // The lots report with closed parcels lists CBA's sold five under it.
        let lots = try document(f, .investmentLots, includeClosed: true)
        let cbaRows = try #require(lots.sections.first { $0.title == "Broker A" }).rows
        #expect(cbaRows.filter { $0.depth == 1 }.count == 3)        // two held lots, one sold parcel
        #expect(cbaRows.contains { $0.depth == 1 && $0.label == "Sold parcel" })
        #expect(lots.sections.first?.columns?.contains("Sold") == true)
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
        #expect(kpi(fifo, "Gain (loss)") == dec("130"))
        #expect(kpi(lifo, "Gain (loss)") == dec("80"))
        #expect(fifo.notes.contains { $0.contains(CostBasisMethod.fifo.displayName) })
        #expect(lifo.notes.contains { $0.contains(CostBasisMethod.lifo.displayName) })
    }

    @Test("Investment Return is cumulative, ordered by total return, with each security's history beneath")
    func investmentReturn() throws {
        let f = try fixture(); defer { f.close() }
        let report = try document(f, .investmentReturn)
        // Broker A (CBA: 100 realised + 125 unrealised + 7 dividend) outranks
        // Broker B (BHP: 30) in the closing table of portfolios.
        let portfolios = try #require(report.sections.first { $0.title == "All portfolios" })
        #expect(portfolios.rows.map(\.label) == ["Broker A", "Broker B"])
        #expect(portfolios.rows.first?.cells?.count == portfolios.columns?.count)
        #expect(portfolios.cellTotals?.cells.count == portfolios.columns?.count)
        // The period is bounded, so the period's contribution is a column.
        #expect(portfolios.columns?.last == "This period")
        let cba = try #require(report.sections.first { $0.title == "Broker A" }?.rows.first)
        #expect(cba.cells?[0] == .date(day(f, 10, 5)))           // acquired
        #expect(cba.cells?[1] == .money(300) && cba.cells?[2] == .money(150))   // money in, out
        #expect(cba.cells?[7] == .money(232))                    // 100 + 125 + 7
        // Everything happened inside the period, so its contribution is the whole.
        #expect(cba.cells?.last == .money(232))
        // The history: four events, dated and named.
        let history = try #require(report.sections.first { $0.title == "CBA history" })
        #expect(history.columns?.first == "Date")
        #expect(history.rows.map { $0.cells?[1] } == [.text("Buy"), .text("Buy"), .text("Income"), .text("Sell")])
        #expect(history.rows.last?.cells?[5] == .money(100))     // the sale's realised gain
        #expect(report.chart != nil)
        #expect(report.summary.contains { $0.hasPrefix("Return on money in") })
        // Over all time the same totals, and no period column.
        let lifetime = try document(f, .investmentReturn, period: .allTime)
        #expect(kpi(lifetime, "Total return") == kpi(report, "Total return"))
        #expect(lifetime.sections.first?.columns?.last == "Annualised")
    }

    @Test("Returns by Period lays financial years side by side, and the stepper sets how many")
    func multiPeriod() throws {
        let f = try fixture(); defer { f.close() }
        let three = try document(f, .multiPeriodReturn)
        #expect(three.sections.first?.columns?.count == 3 + 2)   // three FYs, total, annualised
        #expect(three.sections.first?.columns?[2] == "FY 2025–26")
        let one = try #require(f.model.reportDocument(for: ReportConfiguration(
            kind: ReportKind.multiPeriodReturn.rawValue, period: f.both, comparePeriods: 0)))
        #expect(one.sections.first?.columns?.count == 1 + 2)
        // Everything happened in FY 2025–26, so that column carries the whole return.
        let cba = try #require(one.sections.first { $0.title == "Broker A" }?.rows.first)
        #expect(cba.cells?[0] == .money(232) && cba.cells?[1] == .money(232))
    }

    @Test("Historical Cost reconciles the period's cost movement")
    func historicalCost() throws {
        let f = try fixture(); defer { f.close() }
        let report = try document(f, .historicalCost)
        let cba = try #require(report.sections.first { $0.title == "Broker A" }?.rows.first)
        // Nothing held before October; 300 bought, the $10 lot's 50 sold out at cost; 250 left, worth 375.
        #expect(cba.cells?[0] == .units(0) && cba.cells?[1] == .money(0))
        #expect(cba.cells?[2] == .money(300) && cba.cells?[3] == .money(-50))
        #expect(cba.cells?[5] == .units(15) && cba.cells?[6] == .money(250) && cba.cells?[7] == .money(375))
        #expect(kpi(report, "Closing cost") == dec("250"))     // BHP closed at zero
    }
}
