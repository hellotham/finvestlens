//
//  InvestmentYieldTests.swift
//  FinvestLens — Reports
//
//  The simple annual rate the report documents still pool parcels by, and the
//  portfolio filter and rate the investment reports share: an annualised
//  return is the money-weighted rate of a holding's dated flows (XIRR), and
//  nothing under a year is annualised.
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

    @Test("A span annualises from 365 whole days — the day a parcel turns one")
    func annualisable() {
        #expect(InvestmentYield.isAnnualisable(from: day(0), to: day(365)))
        #expect(!InvestmentYield.isAnnualisable(from: day(0), to: day(364)))
        #expect(!InvestmentYield.isAnnualisable(from: day(365), to: day(0)))
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

    @Test("Capital Gains files a sale by its disposal date; closed positions add the history of what is sold out")
    func capitalGainsClosed() {
        let f = fixture()
        // Every sale in the period, whether or not the position is closed.
        let all = FinancialReports.capitalGains(f.book, currency: .aud, to: day(800))
        #expect(all.lines.map(\.symbol).sorted() == ["BHP", "CBA"])
        #expect(all.lines.first { $0.symbol == "BHP" }?.positionClosed == true)
        #expect(all.lines.first { $0.symbol == "CBA" }?.positionClosed == false)
        #expect(all.lines.allSatisfy { $0.inPeriod })
        // A period after both sales holds no CGT event …
        let late = FinancialReports.capitalGains(f.book, currency: .aud, from: day(740), to: day(800))
        #expect(late.lines.isEmpty)
        // … but with closed positions on, BHP — sold out of by the period's
        // end — brings its whole history, marked as outside the period; CBA,
        // still held, does not.
        let closed = FinancialReports.capitalGains(f.book, currency: .aud, from: day(740), to: day(800),
                                                   includeClosed: true)
        #expect(closed.lines.map(\.symbol) == ["BHP"])
        #expect(closed.lines.first?.inPeriod == false)
        #expect(closed.periodLines.isEmpty)
        #expect(closed.totalGain == 0 && closed.net.netCapitalGain == 0, "history parcels never enter the period's totals")
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
        #expect(bhp.longTerm == true)
        // $200 to $250 over two years: the compound rate is √1.25 − 1.
        #expect(abs((bhp.annualisedReturn ?? 0) - (pow(1.25, 0.5) - 1)) < 1e-6)
    }

    @Test("A disposal's annualised return is the compound rate from its cost to its proceeds")
    func capitalGainRate() throws {
        let f = fixture()
        let report = FinancialReports.capitalGains(f.book, currency: .aud, to: day(800))
        let cba = try #require(report.lines.first { $0.symbol == "CBA" })
        // 4 sold for 60, cost 40, on the first anniversary: 50% a year.
        #expect(cba.gain == dec("20"))
        #expect(cba.acquisitionDate == day(0) && cba.disposalDate == day(365))
        #expect(cba.quantity == 4 && cba.costBasis == dec("40") && cba.proceeds == dec("60"))
        #expect(abs((cba.annualisedReturn ?? 0) - 0.5) < 1e-6)
    }

    @Test("A holding's annualised return is the money-weighted rate of its flows and its value")
    func portfolioRate() throws {
        let f = fixture()
        let report = FinancialReports.advancedPortfolio(f.book, currency: .aud, asOf: day(730))
        let cba = try #require(report.holdings.first { $0.symbol == "CBA" })
        #expect(cba.firstAcquisition == day(0))
        let years = try #require(cba.heldYears)
        #expect(abs(years - 730 / 365.25) < 1e-9)
        #expect(cba.totalGain == dec("32"))
        // −100 on day 0, +60 on day 365 and 6 × $12 = 72 on day 730:
        // 100 = 60/(1+r) + 72/(1+r)², so 1/(1+r) = 5/6 and r is 20%.
        #expect(abs((cba.annualisedReturn ?? 0) - 0.2) < 1e-6)
    }

    @Test("Investment Return is cumulative to the period's end, with the period's own contribution beside it")
    func periodReturn() throws {
        let f = fixture()
        // Mark CBA at its purchase price on day 0 — as a book does, recording
        // a price on each trade — at $11 on day 100, and $12 on day 700 (the
        // fixture's). A date is valued at the price *nearest* it, GnuCash's
        // way, so without the day-0 price day 39 would read $11 too.
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
        // Days 200–800. The line is the whole holding to day 800: the sale on
        // day 365 (gain 20), both dividends (12), and 6 held @ $12 against
        // their cost of 60 (12) — 44 on the 100 put in. The period's
        // contribution is that total less the total the day before the period
        // began: at day 199, 10 held @ $11 (10) plus the $5 dividend, 15 — so 29.
        let report = FinancialReports.investmentReturn(f.book, currency: .aud, from: day(200), to: day(800))
        let cba = try #require(report.lines.first { $0.symbol == "CBA" })
        #expect(cba.realizedGain == dec("20"))
        #expect(cba.dividends == dec("12"))
        #expect(cba.unrealizedGain == dec("12"))
        #expect(cba.totalReturn == dec("44"))
        #expect(cba.moneyIn == dec("100") && cba.moneyOut == dec("60"))
        #expect(cba.periodReturn == dec("29"))
        #expect(cba.firstAcquisition == day(0))
        let heldYears = try #require(cba.heldYears)
        #expect(abs(heldYears - 800 / 365.25) < 1e-9)
        #expect(cba.history.events.map(\.kind) == [.buy, .otherIncome, .sell, .otherIncome])
        // Moving the period's start changes nothing in the total.
        let later = FinancialReports.investmentReturn(f.book, currency: .aud, from: day(400), to: day(800))
        #expect(later.lines.first { $0.symbol == "CBA" }?.totalReturn == dec("44"))
        // BHP: sold out inside the window, a closed position with no price
        // list — its total is its realised gain, and with no opening mark its
        // period contribution is unknown rather than guessed.
        let bhp = try #require(report.lines.first { $0.symbol == "BHP" })
        #expect(bhp.isClosed && bhp.realizedGain == dec("50") && bhp.totalReturn == dec("50"))
        #expect(bhp.periodReturn == nil)
        #expect(report.totalPeriodReturn == dec("29"))

        // Days 40–150: the total to day 150 is the $5 dividend and 10 @ $11
        // against 100 (15); at day 39 the mark was $10 (nearer the day-0
        // price than the day-100 one), so the period's contribution is the
        // price move alone, 10.
        let early = FinancialReports.investmentReturn(f.book, currency: .aud, from: day(40), to: day(150))
        let earlyCBA = try #require(early.lines.first { $0.symbol == "CBA" })
        #expect(earlyCBA.realizedGain == 0 && earlyCBA.dividends == dec("5"))
        #expect(earlyCBA.unrealizedGain == dec("10"))
        #expect(earlyCBA.periodReturn == dec("10"))
        // All time is the lifetime figure, with no period figure beside it.
        let lifetime = FinancialReports.investmentReturn(f.book, currency: .aud, to: day(800))
        let lifeCBA = try #require(lifetime.lines.first { $0.symbol == "CBA" })
        #expect(lifeCBA.dividends == dec("12") && lifeCBA.realizedGain == dec("20") && lifeCBA.unrealizedGain == dec("12"))
        #expect(lifeCBA.periodReturn == nil && lifetime.totalPeriodReturn == nil)
    }
}
