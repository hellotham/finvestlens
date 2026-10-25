//
//  InvestmentReportsTests.swift
//  FinvestLens — Reports
//
//  The investment reports built on the shared history: total return is
//  cumulative to the report date whatever the period's start; a CGT event
//  is filed by its disposal date and carries its acquisition date however
//  early; the twelve-month rule, the period's contribution, the sold
//  parcels, the income classes, the cost movement, the periods side by
//  side, the drawdown, and the price history's income and benchmarks.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

@Suite("Investment reports on the shared history")
struct InvestmentReportsTests {

    private func security(_ mnemonic: String) -> Commodity {
        Commodity(namespace: .security("ASX"), mnemonic: mnemonic, fullName: mnemonic, smallestFraction: 10000)
    }

    private struct Fixture {
        let book: Book
        let brokerA, brokerB, cba, bhp, bank, cbaIncome, cbaCredits: Account
    }

    /// Broker A ▸ CBA: 10 @ $10 on 2024-01-10, 10 @ $20 on 2024-06-01, a
    /// $35 franked dividend with a $15 credit on 2025-03-01, 5 sold @ $30 on
    /// 2025-09-15 (FIFO: the first lot, held 20 months), priced $25 on
    /// 2026-06-30. Broker B ▸ BHP: 10 @ $20 on 2024-02-01, all sold @ $18
    /// on 2024-11-20 (a loss, held under a year).
    private func fixture() -> Fixture {
        let book = Book(baseCurrency: .aud)
        let brokerA = Account(name: "Broker A", type: .asset, commodity: .aud); brokerA.isPlaceholder = true
        let brokerB = Account(name: "Broker B", type: .asset, commodity: .aud); brokerB.isPlaceholder = true
        book.addAccount(brokerA); book.addAccount(brokerB)
        let cba = book.addAccount(Account(name: "CBA", type: .stock, commodity: security("CBA")), under: brokerA)
        let bhp = book.addAccount(Account(name: "BHP", type: .stock, commodity: security("BHP")), under: brokerB)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = Account(name: "Income", type: .income, commodity: .aud); income.isPlaceholder = true
        book.addAccount(income)
        let dividends = book.addAccount(Account(name: "Dividends", type: .income, commodity: .aud), under: income)
        let cbaDividends = book.addAccount(Account(name: "CBA", type: .income, commodity: .aud), under: dividends)
        let franked = book.addAccount(Account(name: "Franked", type: .income, commodity: .aud), under: cbaDividends)
        let credits = book.addAccount(Account(name: "Imputation Credit", type: .income, commodity: .aud), under: cbaDividends)
        let offset = book.addAccount(Account(name: "Imputation Credit Offset", type: .expense, commodity: .aud))

        func trade(_ account: Account, _ on: Date, units: String, value: String) {
            let txn = Transaction(currency: .aud, datePosted: on, description: "Trade")
            txn.addSplit(account: account, value: dec(value), quantity: dec(units))
            txn.addSplit(account: bank, value: -dec(value))
            book.addTransaction(txn)
        }
        trade(cba, date(2024, 1, 10), units: "10", value: "100")
        trade(cba, date(2024, 6, 1), units: "10", value: "200")
        let dividend = Transaction(currency: .aud, datePosted: date(2025, 3, 1), description: "CBA dividend")
        dividend.addSplit(account: bank, value: dec("35"))
        dividend.addSplit(account: franked, value: dec("-35"))
        dividend.addSplit(account: credits, value: dec("-15"))
        dividend.addSplit(account: offset, value: dec("15"))
        book.addTransaction(dividend)
        trade(cba, date(2025, 9, 15), units: "-5", value: "-150")
        book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: date(2024, 1, 10), value: dec("10")))
        book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: date(2025, 6, 30), value: dec("22")))
        book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: date(2026, 6, 30), value: dec("25")))
        trade(bhp, date(2024, 2, 1), units: "10", value: "200")
        trade(bhp, date(2024, 11, 20), units: "-10", value: "-180")
        return Fixture(book: book, brokerA: brokerA, brokerB: brokerB, cba: cba, bhp: bhp, bank: bank,
                       cbaIncome: franked, cbaCredits: credits)
    }

    // MARK: Investment Return

    @Test("Total return is cumulative to the report date, whatever the period's start")
    func cumulative() throws {
        let f = fixture()
        let to = date(2026, 6, 30)
        let allTime = FinancialReports.investmentReturn(f.book, currency: .aud, to: to)
        let fy = FinancialReports.investmentReturn(f.book, currency: .aud, from: date(2025, 7, 1), to: to)
        let cba = try #require(allTime.lines.first { $0.symbol == "CBA" })
        // 15 held: 5 @ $10 + 10 @ $20 = $250 cost, worth 15 × $25 = $375.
        #expect(cba.moneyIn == dec("300") && cba.moneyOut == dec("150"))
        #expect(cba.realizedGain == dec("100"))          // 5 @ $30 against 5 @ $10
        #expect(cba.unrealizedGain == dec("125"))
        #expect(cba.dividends == dec("35") && cba.frankingCredits == dec("15"))
        #expect(cba.totalReturn == dec("275"))
        #expect(cba.history.events.count == 5)           // 2 buys, dividend, credit, 1 parcel sold
        #expect(cba.firstAcquisition == date(2024, 1, 10))
        // The same totals under a financial-year period — only the period's
        // contribution differs.
        let cbaFY = try #require(fy.lines.first { $0.symbol == "CBA" })
        #expect(cbaFY.totalReturn == cba.totalReturn)
        #expect(cba.periodReturn == nil)
        // FY 2025–26: the sale's 100 realised, plus the move in unrealised:
        // at 30 Jun 2025, 20 held @ $22 over cost 300 = 140; at 30 Jun 2026,
        // 125 → −15. Contribution 85.
        #expect(cbaFY.periodReturn == dec("85"))
        #expect(fy.totalPeriodReturn == dec("85") + (fy.lines.first { $0.symbol == "BHP" }?.periodReturn ?? 0))
        // BHP is closed: its total is its loss, and it is out when closed
        // positions are off.
        let bhp = try #require(allTime.lines.first { $0.symbol == "BHP" })
        #expect(bhp.isClosed && bhp.totalReturn == dec("-20"))
        let open = FinancialReports.investmentReturn(f.book, currency: .aud, to: to, includeClosed: false)
        #expect(open.lines.map(\.symbol) == ["CBA"])
        // Money-weighted rate: present for CBA (two and a half years), absent
        // for BHP (under a year).
        #expect(cba.annualisedReturn != nil && cba.annualisedReturn! > 0)
        #expect(bhp.annualisedReturn == nil)
        #expect(allTime.annualisedReturn != nil)
    }

    // MARK: Capital Gains

    @Test("A CGT event is filed by its disposal date and carries its acquisition date however early")
    func capitalGainsParcels() throws {
        let f = fixture()
        let fy = FinancialReports.capitalGains(f.book, currency: .aud, from: date(2025, 7, 1), to: date(2026, 6, 30),
                                               calendar: utc)
        #expect(fy.periodLines.count == 1)
        let parcel = try #require(fy.periodLines.first)
        #expect(parcel.symbol == "CBA")
        #expect(parcel.acquisitionDate == date(2024, 1, 10))     // before the period, still shown
        #expect(parcel.disposalDate == date(2025, 9, 15))
        #expect(parcel.quantity == dec("5"))
        #expect(parcel.costBasis == dec("50") && parcel.proceeds == dec("150") && parcel.gain == dec("100"))
        #expect(parcel.longTerm == true)
        #expect(parcel.components.map(\.treatment) == [.discount])
        #expect(parcel.annualisedReturn != nil)
        // The ATO steps over the year: 100 eligible, no losses, 50% off.
        #expect(fy.net.grossGains == dec("100"))
        #expect(fy.net.discountApplied == dec("50") && fy.net.netCapitalGain == dec("50"))
        // Closed positions on: BHP, sold out of in FY 2024–25, is listed as
        // history — outside the period, and outside the year's net.
        let withClosed = FinancialReports.capitalGains(f.book, currency: .aud, from: date(2025, 7, 1),
                                                       to: date(2026, 6, 30), includeClosed: true, calendar: utc)
        #expect(withClosed.lines.map(\.symbol) == ["BHP", "CBA"])
        let bhp = try #require(withClosed.lines.first { $0.symbol == "BHP" })
        #expect(!bhp.inPeriod && bhp.positionClosed && bhp.gain == dec("-20") && bhp.longTerm == false)
        #expect(withClosed.net.grossGains == dec("100"))
        // The year the loss fell in: short-term loss, no discount; net is a loss carried forward.
        let earlier = FinancialReports.capitalGains(f.book, currency: .aud, from: date(2024, 7, 1), to: date(2025, 6, 30),
                                                    calendar: utc)
        #expect(earlier.periodLines.count == 1 && earlier.shortTermGain == dec("-20"))
        #expect(earlier.net.netCapitalGain == 0 && earlier.net.lossCarriedForward == dec("20"))
    }

    @Test("A parcel straddling 1 July 2027 is split at its value just before the reform")
    func capitalGainsReform() throws {
        let f = fixture()
        // Price CBA at $40 just before the reform and sell the rest in FY 2027–28 at $50.
        f.book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: date(2027, 6, 30), value: dec("40")))
        let sell = Transaction(currency: .aud, datePosted: date(2028, 3, 1), description: "Sell the rest")
        sell.addSplit(account: f.cba, value: dec("-750"), quantity: dec("-15"))
        sell.addSplit(account: f.bank, value: dec("750"))
        f.book.addTransaction(sell)
        // CPI 100 in the quarter the reform starts (the post-reform slice's
        // base), 110 by the quarter of the sale.
        let stepUp = date(2027, 10, 1)
        let cpi: @Sendable (Date) -> Double? = { d in d >= stepUp ? 110 : 100 }
        let report = FinancialReports.capitalGains(f.book, currency: .aud, from: date(2027, 7, 1), to: date(2028, 6, 30),
                                                   cpi: cpi, calendar: utc)
        // FIFO: 5 @ $10 (lot 1) and 10 @ $20 (lot 2), both acquired before the reform.
        #expect(report.periodLines.count == 2)
        let lot1 = try #require(report.periodLines.first { $0.acquisitionDate == date(2024, 1, 10) })
        // Value before the reform: 5 × $40 = 200; pre part 200 − 50 = 150
        // (discount); post part: proceeds 250 − 200 indexed by 110/100 = 220 → 30.
        #expect(lot1.components.map(\.treatment) == [.discount, .indexation])
        #expect(lot1.components[0].gain == dec("150") && lot1.components[0].discountEligible)
        #expect(lot1.components[1].gain == dec("30") && lot1.components[1].indexed)
        #expect(report.transitionalValueMissingSymbols.isEmpty && report.unindexedCount == 0)
    }

    // MARK: Lots

    @Test("Lots carry the twelve-month test and, when asked, the sold parcels")
    func lots() throws {
        let f = fixture()
        let open = FinancialReports.investmentLots(f.book, currency: .aud, asOf: date(2026, 6, 30), calendar: utc)
        #expect(open.count == 2)
        #expect(open.allSatisfy { $0.longTerm == true && !$0.isClosed })
        #expect(open.first?.annualisedReturn != nil)
        let all = FinancialReports.investmentLots(f.book, currency: .aud, asOf: date(2026, 6, 30),
                                                  includeClosed: true, calendar: utc)
        #expect(all.filter(\.isClosed).count == 2)                 // CBA's 5 sold, BHP's 10 sold
        let bhp = try #require(all.first { $0.symbol == "BHP" })
        #expect(bhp.isClosed && bhp.proceeds == dec("180") && bhp.realizedGain == dec("-20") && bhp.longTerm == false)
    }

    // MARK: Income

    @Test("The Income report classifies each payment and totals the year")
    func income() throws {
        let f = fixture()
        let report = FinancialReports.incomeReport(f.book, currency: .aud, from: date(2024, 7, 1), to: date(2025, 6, 30))
        let cba = try #require(report.lines.first)
        #expect(report.lines.count == 1 && cba.symbol == "CBA")
        #expect(cba.franked == dec("35") && cba.frankingCredits == dec("15") && cba.unfranked == 0)
        #expect(cba.cash == dec("35") && cba.grossedUp == dec("50"))
        #expect(cba.payments.count == 2)
        #expect(report.totalGrossedUp == dec("50"))
        let empty = FinancialReports.incomeReport(f.book, currency: .aud, from: date(2025, 7, 1), to: date(2026, 6, 30))
        #expect(empty.lines.isEmpty)
    }

    // MARK: Historical cost

    @Test("The cost movement over a year reconciles")
    func historicalCost() throws {
        let f = fixture()
        let report = FinancialReports.historicalCost(f.book, currency: .aud, from: date(2025, 7, 1), to: date(2026, 6, 30))
        let cba = try #require(report.lines.first { $0.symbol == "CBA" })
        #expect(cba.openingUnits == dec("20") && cba.openingCost == dec("300"))
        #expect(cba.purchases == 0 && cba.costOfSales == dec("50"))
        #expect(cba.closingUnits == dec("15") && cba.closingCost == dec("250") && cba.closingValue == dec("375"))
        #expect(cba.reconciles)
        // BHP had nothing at either end and nothing in between: not a line.
        #expect(report.lines.map(\.symbol) == ["CBA"])
    }

    // MARK: Multi-period

    @Test("Returns by period are the periods' contributions, with the total beside them")
    func multiPeriod() throws {
        let f = fixture()
        let periods = [(from: date(2024, 7, 1), to: date(2025, 6, 30)), (from: date(2025, 7, 1), to: date(2026, 6, 30))]
        let report = FinancialReports.multiPeriodReturns(f.book, currency: .aud, periods: periods)
        let cba = try #require(report.lines.first { $0.symbol == "CBA" })
        #expect(cba.periodReturns.count == 2)
        #expect(cba.periodReturns[1] == dec("85"))
        #expect(cba.totalReturn == dec("275"))
        #expect(report.periodTotals.count == 2)
    }

    // MARK: Drawdown

    @Test("Drawdown reads each held security's worst fall against its return")
    func drawdown() throws {
        let f = fixture()
        for (day, value) in [(date(2025, 9, 1), "30"), (date(2025, 12, 1), "24"), (date(2026, 3, 1), "27")] {
            f.book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: day, value: dec(value)))
        }
        let report = FinancialReports.drawdownRisk(f.book, currency: .aud, from: date(2025, 7, 1), to: date(2026, 6, 30),
                                                   calendar: utc)
        let cba = try #require(report.lines.first { $0.symbol == "CBA" })
        // Peak 30 → trough 24: −20%; the range ran 30 → 25.
        #expect(abs((cba.drawdown?.fraction ?? 0) + 0.2) < 1e-9)
        #expect(cba.romad != nil)
        #expect(report.lines.map(\.symbol) == ["CBA"])               // BHP is closed
    }

    // MARK: Price history

    @Test("Price history adds the income per unit, overlays the trades and rebases a benchmark")
    func priceHistory() throws {
        let f = fixture()
        for (day, value) in [(date(2025, 1, 1), "20"), (date(2025, 4, 1), "21"), (date(2025, 9, 1), "30")] {
            f.book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: day, value: dec(value)))
        }
        let index = Commodity(namespace: .security("ASX"), mnemonic: "XJO", fullName: "S&P/ASX 200", smallestFraction: 100)
        f.book.addPrice(Price(commodity: index, currency: .aud, date: date(2025, 1, 1), value: dec("8000")))
        f.book.addPrice(Price(commodity: index, currency: .aud, date: date(2025, 9, 1), value: dec("8800")))
        // A price is stored at GnuCash's day-neutral 10:59Z of its local day,
        // so a range starts at the start of its first day, as the app's do.
        let from = utc.startOfDay(for: date(2025, 1, 1))
        let report = FinancialReports.priceHistory(f.book, commodity: security("CBA"), account: f.cba, currency: .aud,
                                                   from: from, to: date(2025, 12, 31),
                                                   benchmark: .commodity(index), calendar: utc)
        #expect(report.series.map(\.value) == [dec("20"), dec("21"), dec("22"), dec("30")])
        // The $35 dividend on 1 Mar 2025 over 20 units held: $1.75 a unit,
        // added to every later price.
        #expect(report.priceWithIncome.map(\.value) == [dec("20"), dec("22.75"), dec("23.75"), dec("31.75")])
        #expect(report.trades.count == 1 && report.trades.first?.kind == .sell)
        #expect(report.income.count == 1)
        #expect(report.unitsHeld == dec("15") && report.averageCost == dec("250") / dec("15"))
        #expect(report.rebasedPrice.first?.value == 100 && report.rebasedPrice.last?.value == 150)
        #expect(report.benchmarkLabel == "XJO")
        #expect(report.benchmarkRebased.last?.value == 110)
        #expect(abs((report.benchmarkChangeFraction ?? 0) - 0.1) < 1e-9)
        #expect(report.summary?.high.value == dec("30"))
        // A cash-rate benchmark compounds from the range start.
        let cash = FinancialReports.priceHistory(f.book, commodity: security("CBA"), account: nil, currency: .aud,
                                                 from: from, to: date(2025, 12, 31),
                                                 benchmark: .cashRate(0.05), calendar: utc)
        #expect(cash.benchmarkRebased.first?.value == 100)
        #expect((cash.benchmarkRebased.last?.value ?? 0) > 103)
        #expect(cash.trades.isEmpty && cash.priceWithIncome == cash.series)
    }
}
