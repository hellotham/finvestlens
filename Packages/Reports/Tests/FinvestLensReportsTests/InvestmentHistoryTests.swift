//
//  InvestmentHistoryTests.swift
//  FinvestLens — Reports
//
//  The one walk every investment report reads: each event classified, each
//  parcel sold with its acquisition and gain, each amount in the report
//  currency or left out and named.
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

@Suite("Investment history")
struct InvestmentHistoryTests {

    private func security(_ mnemonic: String) -> Commodity {
        Commodity(namespace: .security("ASX"), mnemonic: mnemonic, fullName: mnemonic, smallestFraction: 10000)
    }

    private struct Fixture {
        let book: Book
        let stock, bank, franked, credits, interest, plain: Account
    }

    /// CBA under Broker A: buy 10 @ $10 (day 0, $5 brokerage), buy 10 @ $20
    /// (day 100), sell 15 @ $30 on day 400 — FIFO takes the whole first lot
    /// and half the second — a franked dividend with a credit on day 200 by
    /// name, a plain "Dividends ▸ CBA" dividend on day 300 by the holding's
    /// zero-unit leg, interest on day 350.
    private func fixture() -> Fixture {
        let book = Book(baseCurrency: .aud)
        let broker = Account(name: "Broker A", type: .asset, commodity: .aud)
        broker.isPlaceholder = true
        book.addAccount(broker)
        let stock = book.addAccount(Account(name: "CBA", type: .stock, commodity: security("CBA")), under: broker)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let fees = book.addAccount(Account(name: "Brokerage", type: .expense, commodity: .aud))
        let income = Account(name: "Income", type: .income, commodity: .aud)
        income.isPlaceholder = true
        _ = book.addAccount(income)
        let dividends = book.addAccount(Account(name: "Dividends", type: .income, commodity: .aud), under: income)
        let cba = book.addAccount(Account(name: "CBA", type: .income, commodity: .aud), under: dividends)
        let franked = book.addAccount(Account(name: "Franked", type: .income, commodity: .aud), under: cba)
        let credits = book.addAccount(Account(name: "Imputation Credit", type: .income, commodity: .aud), under: cba)
        let offset = book.addAccount(Account(name: "Imputation Credit Offset", type: .expense, commodity: .aud))
        let interest = book.addAccount(Account(name: "Interest", type: .income, commodity: .aud), under: income)
        let plain = book.addAccount(Account(name: "Other Dividends", type: .income, commodity: .aud), under: dividends)

        let buy1 = Transaction(currency: .aud, datePosted: day(0), description: "Buy 10")
        buy1.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        buy1.addSplit(account: fees, value: dec("5"))
        buy1.addSplit(account: bank, value: dec("-105"))
        book.addTransaction(buy1)
        let buy2 = Transaction(currency: .aud, datePosted: day(100), description: "Buy 10 more")
        buy2.addSplit(account: stock, value: dec("200"), quantity: dec("10"))
        buy2.addSplit(account: bank, value: dec("-200"))
        book.addTransaction(buy2)
        let dividend = Transaction(currency: .aud, datePosted: day(200), description: "CBA dividend")
        dividend.addSplit(account: bank, value: dec("35"))
        dividend.addSplit(account: franked, value: dec("-35"))
        dividend.addSplit(account: credits, value: dec("-15"))
        dividend.addSplit(account: offset, value: dec("15"))
        book.addTransaction(dividend)
        let linked = Transaction(currency: .aud, datePosted: day(300), description: "Special dividend")
        linked.addSplit(account: stock, value: 0, quantity: 0)        // GnuCash's link leg
        linked.addSplit(account: bank, value: dec("8"))
        linked.addSplit(account: plain, value: dec("-8"))
        book.addTransaction(linked)
        let interestPaid = Transaction(currency: .aud, datePosted: day(350), description: "Interest")
        interestPaid.addSplit(account: stock, value: 0, quantity: 0)
        interestPaid.addSplit(account: bank, value: dec("2"))
        interestPaid.addSplit(account: interest, value: dec("-2"))
        book.addTransaction(interestPaid)
        let sell = Transaction(currency: .aud, datePosted: day(400), description: "Sell 15")
        sell.addSplit(account: stock, value: dec("-450"), quantity: dec("-15"))
        sell.addSplit(account: bank, value: dec("450"))
        book.addTransaction(sell)
        book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: day(500), value: dec("25")))
        return Fixture(book: book, stock: stock, bank: bank, franked: franked, credits: credits,
                       interest: interest, plain: plain)
    }

    @Test("Every event is there, classified, in date order, with the parcels a sale took")
    func events() throws {
        let f = fixture()
        let history = FinancialReports.investmentHistory(f.book, account: f.stock, currency: .aud, to: day(600))
        #expect(history.events.map(\.kind) == [.buy, .buy, .dividendFranked, .frankingCredit, .dividendUnfranked,
                                                .interest, .sell, .sell])
        #expect(history.events.map(\.date) == [day(0), day(100), day(200), day(200), day(300), day(350), day(400), day(400)])
        // Fees are ignored by default: the first purchase cost $100, its fee recorded beside it.
        #expect(history.events[0].amount == dec("100") && history.events[0].fee == dec("5"))
        // FIFO: the first parcel (10 @ $10) sold whole for $300, gain 200; five
        // of the second (cost 100) for $150, gain 50.
        let sold = history.events.filter { $0.kind == .sell }
        #expect(sold.map(\.units) == [dec("10"), dec("5")])
        #expect(sold.map(\.acquisitionDate) == [day(0), day(100)])
        #expect(sold.map(\.costBasis) == [dec("100"), dec("100")])
        #expect(sold.map(\.realizedGain) == [dec("200"), dec("50")])
        #expect(sold.map(\.longTerm) == [true, false])
        #expect(sold.first?.description == "Sell 15")
        #expect(history.portfolio?.name == "Broker A")
    }

    @Test("The totals add up, and the unrealised gain is marked at the price on the date")
    func totals() throws {
        let f = fixture()
        let history = FinancialReports.investmentHistory(f.book, account: f.stock, currency: .aud, to: day(600))
        #expect(history.moneyIn == dec("300"))
        #expect(history.moneyOut == dec("450"))
        #expect(history.realizedGain == dec("250"))
        #expect(history.dividends == dec("45"))            // 35 franked + 8 plain + 2 interest
        #expect(history.frankingCredits == dec("15"))
        #expect(history.unitsHeld == dec("5"))
        #expect(history.remainingCostBasis == dec("100"))  // 5 @ $20
        #expect(history.marketValue == dec("125"))         // 5 @ $25
        #expect(history.unrealizedGain == dec("25"))
        #expect(history.totalReturn == dec("335"))         // 250 + 25 + 45 + 15
        #expect(abs((history.returnOnMoneyIn ?? 0) - 335.0 / 300) < 1e-12)
        #expect(history.firstAcquisition == day(0))
        #expect(!history.isClosed)
        // Cash flows: the credit is not cash; the holding's value closes the series.
        let flows = try #require(history.cashFlows(valuedAt: day(600)))
        #expect(flows.map(\.amount) == [dec("-100"), dec("-200"), dec("35"), dec("8"), dec("2"), dec("300"), dec("150"), dec("125")])
        #expect(flows.last?.date == day(600))
    }

    @Test("Fees in basis raise a purchase's cost and are kept out of the sale's proceeds")
    func feesInBasis() {
        let f = fixture()
        let history = FinancialReports.investmentHistory(f.book, account: f.stock, currency: .aud, to: day(600),
                                                         feeTreatment: .includeInBasis)
        #expect(history.events[0].amount == dec("105"))
        #expect(history.moneyIn == dec("305"))
        // The first parcel's cost basis carries the fee: gain 300 − 105.
        #expect(history.events.first { $0.kind == .sell }?.realizedGain == dec("195"))
    }

    @Test("History stops at the report date; a position sold out of is closed")
    func toDate() {
        let f = fixture()
        let early = FinancialReports.investmentHistory(f.book, account: f.stock, currency: .aud, to: day(250))
        #expect(early.events.map(\.kind) == [.buy, .buy, .dividendFranked, .frankingCredit])
        #expect(early.unitsHeld == dec("20"))
        // Valued at the price nearest the date (GnuCash's rule): day 500's $25.
        #expect(early.unrealizedGain == dec("200"))
        let sellAll = Transaction(currency: .aud, datePosted: day(450), description: "Sell the rest")
        sellAll.addSplit(account: f.stock, value: dec("-150"), quantity: dec("-5"))
        sellAll.addSplit(account: f.bank, value: dec("150"))
        f.book.addTransaction(sellAll)
        let closed = FinancialReports.investmentHistory(f.book, account: f.stock, currency: .aud, to: day(600))
        #expect(closed.isClosed && closed.unitsHeld == 0 && closed.unrealizedGain == 0)
        #expect(closed.cashFlows(valuedAt: day(600))?.last?.amount == dec("150"))
    }

    @Test("An amount with no exchange rate is left out and its currency named")
    func unconverted() {
        let book = Book(baseCurrency: .aud)
        let stock = book.addAccount(Account(name: "AAPL", type: .stock,
                                            commodity: Commodity(namespace: .security("NASDAQ"), mnemonic: "AAPL",
                                                                 fullName: "Apple", smallestFraction: 10000)))
        let usd = book.addAccount(Account(name: "USD cash", type: .bank, commodity: .usd))
        let buy = Transaction(currency: .usd, datePosted: day(0), description: "Buy")
        buy.addSplit(account: stock, value: dec("1000"), quantity: dec("10"))
        buy.addSplit(account: usd, value: dec("-1000"))
        book.addTransaction(buy)
        let history = FinancialReports.investmentHistory(book, account: stock, currency: .aud, to: day(10))
        #expect(history.tradeCurrencyCode == "USD")
        #expect(history.events.first?.converted == false)
        #expect(history.moneyIn == 0)
        #expect(history.unconvertedCurrencyCodes == ["USD"])
        // With a rate on the day, it converts.
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.5"), date: day(0))
        let converted = FinancialReports.investmentHistory(book, account: stock, currency: .aud, to: day(10))
        #expect(converted.events.first?.converted == true)
        #expect(converted.moneyIn == dec("1500"))
        #expect(converted.unconvertedCurrencyCodes.isEmpty)
    }

    @Test("Income account names classify the payment")
    func classification() {
        let book = Book(baseCurrency: .aud)
        func account(_ path: [String]) -> Account {
            var parent: Account? = nil
            for (index, name) in path.enumerated() {
                let node = Account(name: name, type: .income, commodity: .aud)
                node.isPlaceholder = index < path.count - 1
                if let parent { book.addAccount(node, under: parent) } else { book.addAccount(node) }
                parent = node
            }
            return parent!
        }
        #expect(FinancialReports.incomeKind(of: account(["Dividends", "BHP", "Franked"])) == .dividendFranked)
        #expect(FinancialReports.incomeKind(of: account(["Dividends", "BHP", "Unfranked"])) == .dividendUnfranked)
        #expect(FinancialReports.incomeKind(of: account(["Dividends", "BHP", "Imputation Credit"])) == .frankingCredit)
        #expect(FinancialReports.incomeKind(of: account(["Dividends", "VAS", "Franking Credits"])) == .frankingCredit)
        #expect(FinancialReports.incomeKind(of: account(["Distributions", "VAS"])) == .distribution)
        #expect(FinancialReports.incomeKind(of: account(["Interest", "Bonds"])) == .interest)
        #expect(FinancialReports.incomeKind(of: account(["Dividends", "CBA"])) == .dividendUnfranked)
        #expect(FinancialReports.incomeKind(of: account(["Rebates"])) == .otherIncome)
    }

    @Test("Two trades on one day keep their own descriptions, and the open parcels ride on the history")
    func sameDayTrades() throws {
        let book = Book(baseCurrency: .aud)
        let stock = book.addAccount(Account(name: "CBA", type: .stock, commodity: security("CBA")))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        for (units, value, text) in [("10", "100", "Morning buy"), ("5", "60", "Afternoon buy")] {
            let txn = Transaction(currency: .aud, datePosted: day(0), description: text)
            txn.addSplit(account: stock, value: dec(value), quantity: dec(units))
            txn.addSplit(account: bank, value: -dec(value))
            book.addTransaction(txn)
        }
        let history = FinancialReports.investmentHistory(book, account: stock, currency: .aud, to: day(10))
        #expect(Set(history.events.map(\.description)) == ["Morning buy", "Afternoon buy"])
        #expect(history.openParcels.map(\.quantity) == [10, 5])
        #expect(history.openParcels.map(\.costBasis) == [100, 60])
        #expect(history.openParcels.allSatisfy { $0.converted })
        #expect(history.remainingCostBasis == 160)
    }
}
