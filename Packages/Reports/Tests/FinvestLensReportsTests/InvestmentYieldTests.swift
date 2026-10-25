//
//  InvestmentYieldTests.swift
//  FinvestLens — Reports
//
//  The one yield the investment reports print, and the portfolio filter they
//  share: a gain as a simple annual rate on what the parcels cost, over the
//  cost-weighted time they were held.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@Suite("Investment yield")
struct InvestmentYieldTests {

    @Test("Years are whole calendar days over 365.25, never negative")
    func years() {
        #expect(InvestmentYield.years(from: day(0), to: day(730)) == 730 / 365.25)
        #expect(InvestmentYield.years(from: day(10), to: day(0)) == 0)
    }

    @Test("Holding time is weighted by cost")
    func weighted() throws {
        // $300 held two years and $100 held one: (600 + 100) / 400 = 1.75.
        let years = try #require(InvestmentYield.weightedYears([
            HeldParcel(cost: 300, years: 2), HeldParcel(cost: 100, years: 1)]))
        #expect(abs(years - 1.75) < 1e-12)
        #expect(InvestmentYield.weightedYears([]) == nil)
        #expect(InvestmentYield.weightedYears([HeldParcel(cost: 0, years: 3)]) == nil)
    }

    @Test("The rate is gain over cost over years; nothing paid or no time gives none")
    func annualised() throws {
        // $20 on $100 over two years: 10% a year.
        let rate = try #require(InvestmentYield.annualised(gain: 20, cost: 100, years: 2))
        #expect(abs(rate - 0.10) < 1e-12)
        #expect(InvestmentYield.annualised(gain: 20, cost: 0, years: 2) == nil)
        #expect(InvestmentYield.annualised(gain: 20, cost: 100, years: 0) == nil)
        #expect(InvestmentYield.annualised(gain: 20, cost: 100, years: nil) == nil)
        // A loss is a negative rate, and a short position's cost is read by size.
        #expect(InvestmentYield.annualised(gain: -10, cost: -100, years: 1) == -0.1)
    }

    @Test("Holdings combine by their gains, costs and cost-weighted years")
    func combined() throws {
        // $10 on $100 over one year and $30 on $100 over two: $40 on $200 over 1.5 years.
        let rate = try #require(InvestmentYield.combined([(10, 100, 1.0), (30, 100, 2.0)]))
        #expect(abs(rate - 40.0 / 200 / 1.5) < 1e-12)
    }
}

/// The four reports over one book with two portfolios: the filter and the
/// grouping they share.
@Suite("Investment reports by portfolio")
struct InvestmentPortfolioFilterTests {

    private func security(_ mnemonic: String) -> Commodity {
        Commodity(namespace: .security("ASX"), mnemonic: mnemonic, fullName: mnemonic, smallestFraction: 10000)
    }

    private struct Fixture {
        let book: Book
        let brokerA, brokerB, cba, bhp, bank: Account
    }

    /// Broker A holds CBA: buy 10 @ $10 on day 0, sell 4 @ $15 on day 365,
    /// marked $12. Broker B holds BHP: buy 10 @ $20 on day 0, sold out at
    /// $25 on day 730 — a closed position.
    private func fixture() -> Fixture {
        let book = Book(baseCurrency: .aud)
        let brokerA = Account(name: "Broker A", type: .asset, commodity: .aud)
        brokerA.isPlaceholder = true
        let brokerB = Account(name: "Broker B", type: .asset, commodity: .aud)
        brokerB.isPlaceholder = true
        book.addAccount(brokerA); book.addAccount(brokerB)
        let cba = book.addAccount(Account(name: "CBA", type: .stock, commodity: security("CBA")), under: brokerA)
        let bhp = book.addAccount(Account(name: "BHP", type: .stock, commodity: security("BHP")), under: brokerB)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))

        func trade(_ account: Account, _ date: Date, units: String, value: String) {
            let txn = Transaction(currency: .aud, datePosted: date, description: "Trade")
            txn.addSplit(account: account, value: dec(value), quantity: dec(units))
            txn.addSplit(account: bank, value: -dec(value))
            book.addTransaction(txn)
        }
        trade(cba, day(0), units: "10", value: "100")
        trade(cba, day(365), units: "-4", value: "-60")
        book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: day(700), value: dec("12")))
        trade(bhp, day(0), units: "10", value: "200")
        trade(bhp, day(730), units: "-10", value: "-250")
        return Fixture(book: book, brokerA: brokerA, brokerB: brokerB, cba: cba, bhp: bhp, bank: bank)
    }

    @Test("Each line names its portfolio, and the filter keeps one portfolio's accounts")
    func portfolioFilter() throws {
        let f = fixture()
        let all = FinancialReports.advancedPortfolio(f.book, currency: .aud, asOf: day(800))
        #expect(all.holdings.map(\.symbol).sorted() == ["BHP", "CBA"])
        #expect(all.holdings.first { $0.symbol == "CBA" }?.portfolio == PortfolioRef(id: f.brokerA.guid, name: "Broker A"))

        let onlyA = FinancialReports.advancedPortfolio(f.book, currency: .aud, asOf: day(800),
                                                       portfolioID: f.brokerA.guid)
        #expect(onlyA.holdings.map(\.symbol) == ["CBA"])

        let gainsB = FinancialReports.capitalGains(f.book, currency: .aud, to: day(800), portfolioID: f.brokerB.guid)
        #expect(gainsB.lines.map(\.symbol) == ["BHP"])
        #expect(gainsB.lines.first?.portfolio?.name == "Broker B")

        let lotsA = FinancialReports.investmentLots(f.book, currency: .aud, asOf: day(800), portfolioID: f.brokerA.guid)
        #expect(lotsA.map(\.symbol) == ["CBA"])
        #expect(lotsA.first?.accountID == f.cba.guid)

        let returnB = FinancialReports.investmentReturn(f.book, currency: .aud, to: day(800),
                                                        portfolioID: f.brokerB.guid)
        #expect(returnB.lines.map(\.symbol) == ["BHP"])
    }

    @Test("Capital Gains leaves out a position sold out of when closed positions are off")
    func capitalGainsClosed() {
        let f = fixture()
        let with = FinancialReports.capitalGains(f.book, currency: .aud, to: day(800))
        #expect(with.lines.map(\.symbol).sorted() == ["BHP", "CBA"])
        #expect(with.lines.first { $0.symbol == "BHP" }?.positionClosed == true)
        #expect(with.lines.first { $0.symbol == "CBA" }?.positionClosed == false)
        let without = FinancialReports.capitalGains(f.book, currency: .aud, to: day(800), includeClosed: false)
        #expect(without.lines.map(\.symbol) == ["CBA"])
    }

    @Test("Investment Lots lists sold parcels, with proceeds and realised gain, only when asked")
    func lotsClosed() throws {
        let f = fixture()
        let open = FinancialReports.investmentLots(f.book, currency: .aud, asOf: day(800))
        #expect(open.count == 1)                       // CBA's 6 remaining
        #expect(open.first?.isClosed == false)
        let all = FinancialReports.investmentLots(f.book, currency: .aud, asOf: day(800), includeClosed: true)
        #expect(all.count == 3)                        // + CBA's 4 sold, BHP's 10 sold
        let bhp = try #require(all.first { $0.symbol == "BHP" })
        #expect(bhp.isClosed)
        #expect(bhp.proceeds == dec("250"))
        #expect(bhp.realizedGain == dec("50"))
        #expect(bhp.value == dec("250") && bhp.gain == dec("50"))
        // $50 on $200 over two years: 12.5% a year.
        #expect(abs((bhp.yieldPerAnnum ?? 0) - 50.0 / 200 / (730 / 365.25)) < 1e-9)
    }

    @Test("A disposal's yield is its gain on its cost over its holding time")
    func capitalGainYield() throws {
        let f = fixture()
        let report = FinancialReports.capitalGains(f.book, currency: .aud, to: day(800))
        let cba = try #require(report.lines.first { $0.symbol == "CBA" })
        // 4 sold for 60, cost 40: gain 20 on 40 over one year = 50% a year.
        #expect(cba.gain == dec("20"))
        #expect(abs((cba.yieldPerAnnum ?? 0) - 20.0 / 40 / (365 / 365.25)) < 1e-9)
    }

    @Test("A holding's yield is its total gain on money in over the cost-weighted years held")
    func portfolioYield() throws {
        let f = fixture()
        let report = FinancialReports.advancedPortfolio(f.book, currency: .aud, asOf: day(730))
        let cba = try #require(report.holdings.first { $0.symbol == "CBA" })
        // Held: 6 @ $10 = $60 for 730 days; sold: 4 @ $10 = $40 for 365 days.
        // Weighted years = (60 × 2 + 40 × 1) / 100 = 1.6. Gain: unrealised 12
        // + realised 20 = 32 on 100 → 32% over 1.6 years = 20% a year.
        let years = try #require(cba.heldYears)
        #expect(abs(years - (60 * 730 + 40 * 365) / 100.0 / 365.25) < 1e-9)
        #expect(cba.totalGain == dec("32"))
        #expect(abs((cba.yieldPerAnnum ?? 0) - 0.32 / years) < 1e-9)
    }

    @Test("Investment Return over a period counts that period's disposals, income and price move")
    func periodReturn() throws {
        let f = fixture()
        // Mark CBA at its purchase price on day 0 — as a book does, recording
        // a price on each trade — at $11 on day 100, and $12 on day 700 (the
        // fixture's). A date is valued at the price *nearest* it, GnuCash's
        // way, so without the day-0 price day 59 would read $11 too.
        f.book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: day(0), value: dec("10")))
        f.book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: day(100), value: dec("11")))
        // A dividend inside the window and one before it.
        let income = f.book.addAccount(Account(name: "CBA", type: .income, commodity: .aud))
        for (date, amount) in [(day(20), "5"), (day(500), "7")] {
            let txn = Transaction(currency: .aud, datePosted: date, description: "Dividend")
            txn.addSplit(account: f.bank, value: dec(amount))
            txn.addSplit(account: income, value: -dec(amount))
            f.book.addTransaction(txn)
        }
        // Days 200–800: the sale on day 365 (gain 20), the $7 dividend, and the
        // unrealised move on what is held: at day 199, 10 held @ $11 vs cost 100
        // = 10; at day 800, 6 held @ $12 vs cost 60 = 12 → +2.
        let report = FinancialReports.investmentReturn(f.book, currency: .aud, from: day(200), to: day(800))
        let cba = try #require(report.lines.first { $0.symbol == "CBA" })
        #expect(cba.realizedGain == dec("20"))
        #expect(cba.dividends == dec("7"))
        #expect(cba.unrealizedGain == dec("2"))
        #expect(cba.totalReturn == dec("29"))
        // Money in: what is held at the end (60) plus what was sold in the period (40).
        #expect(cba.moneyIn == dec("100"))
        // BHP: bought before, sold in the window → in, as a closed position.
        let bhp = try #require(report.lines.first { $0.symbol == "BHP" })
        #expect(bhp.isClosed && bhp.realizedGain == dec("50"))
        // Years inside the window: held parcel 600 days, sold parcel 165 days
        // (day 200 → 365), weighted by cost 60 and 40.
        let years = try #require(cba.heldYears)
        #expect(abs(years - (60 * 600 + 40 * 165) / 100.0 / 365.25) < 1e-9)

        // A window before anything happened to CBA but its purchase: no sale,
        // no income, just the price move from $10 at its start to $11 → 10.
        // (Its start, day 39, is nearer the day-0 price than the day-100 one.)
        let early = FinancialReports.investmentReturn(f.book, currency: .aud, from: day(40), to: day(150))
        let earlyCBA = try #require(early.lines.first { $0.symbol == "CBA" })
        #expect(earlyCBA.realizedGain == 0 && earlyCBA.dividends == 0)
        #expect(earlyCBA.unrealizedGain == dec("10"))
        // All time is the lifetime figure: both dividends, the sale, the mark.
        let lifetime = FinancialReports.investmentReturn(f.book, currency: .aud, to: day(800))
        let lifeCBA = try #require(lifetime.lines.first { $0.symbol == "CBA" })
        #expect(lifeCBA.dividends == dec("12") && lifeCBA.realizedGain == dec("20") && lifeCBA.unrealizedGain == dec("12"))
    }
}
