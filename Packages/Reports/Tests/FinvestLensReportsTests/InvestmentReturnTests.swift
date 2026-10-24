//
//  InvestmentReturnTests.swift
//  FinvestLens — Reports
//
//  Total return is capital gain plus dividends plus franking credits, and
//  the rule that makes it trustworthy is that every dividend is counted
//  once — whichever of the book's two ways of recording it was used.
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

@Suite("Investment return")
struct InvestmentReturnTests {

    private func security(_ mnemonic: String) -> Commodity {
        Commodity(namespace: .security("ASX"), mnemonic: mnemonic, fullName: mnemonic, smallestFraction: 10000)
    }

    private struct Fixture {
        let book: Book
        let stock, bank, franked, unfranked, credits, offset, plainDividends: Account
    }

    /// CBA: buy 10 @ $10, sell 4 @ $15 (realised 20), marked at $12 (6 held,
    /// unrealised 12); dividend accounts shaped as the book records them.
    private func fixture() -> Fixture {
        let book = Book(baseCurrency: .aud)
        let stock = book.addAccount(Account(name: "CBA", type: .stock, commodity: security("CBA")))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let income = Account(name: "Income", type: .income, commodity: .aud)
        income.isPlaceholder = true
        _ = book.addAccount(income)
        let dividends = book.addAccount(Account(name: "Dividends", type: .income, commodity: .aud), under: income)
        let cba = book.addAccount(Account(name: "CBA", type: .income, commodity: .aud), under: dividends)
        let franked = book.addAccount(Account(name: "Franked", type: .income, commodity: .aud), under: cba)
        let unfranked = book.addAccount(Account(name: "Unfranked", type: .income, commodity: .aud), under: cba)
        let credits = book.addAccount(Account(name: "Imputation Credit", type: .income, commodity: .aud), under: cba)
        let offset = book.addAccount(Account(name: "Imputation Credit Offset", type: .expense, commodity: .aud))

        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: stock, value: dec("100"), quantity: dec("10"))
        buy.addSplit(account: bank, value: dec("-100"))
        book.addTransaction(buy)
        let sell = Transaction(currency: .aud, datePosted: day(400), description: "Sell")
        sell.addSplit(account: stock, value: dec("-60"), quantity: dec("-4"))
        sell.addSplit(account: bank, value: dec("60"))
        book.addTransaction(sell)
        book.addPrice(Price(commodity: security("CBA"), currency: .aud, date: day(410), value: dec("12")))
        return Fixture(book: book, stock: stock, bank: bank, franked: franked, unfranked: unfranked,
                       credits: credits, offset: offset, plainDividends: dividends)
    }

    private func line(_ report: InvestmentReturnReport, _ symbol: String) -> InvestmentReturnLine? {
        report.lines.first { $0.symbol == symbol }
    }

    @Test("Capital gain is realised plus unrealised, from the lot engine")
    func capitalGain() throws {
        let f = fixture()
        let report = FinancialReports.investmentReturn(f.book, currency: .aud, asOf: day(420))
        let cba = try #require(line(report, "CBA"))
        #expect(cba.realizedGain == dec("20"))
        #expect(cba.unrealizedGain == dec("12"))
        #expect(cba.capitalGain == dec("32"))
        #expect(cba.moneyIn == dec("100"))
        #expect(cba.dividends == 0 && cba.frankingCredits == 0)
        #expect(cba.totalReturn == dec("32"))
        #expect(abs((cba.returnFraction ?? 0) - 0.32) < 1e-9)
    }

    /// Three dividends, each recorded a different way, each counted once:
    /// by name with no stock leg; GnuCash's zero-unit link leg with a plain
    /// income account; and both at once.
    @Test("Dividends and franking credits are found by the stock leg or by name, and counted once")
    func incomeBothWays() throws {
        let f = fixture()
        // By name only — the book's own shape, never touching the holding.
        let byName = Transaction(currency: .aud, datePosted: day(100), description: "CBA dividend")
        byName.addSplit(account: f.bank, value: dec("35"))
        byName.addSplit(account: f.franked, value: dec("-35"))
        byName.addSplit(account: f.credits, value: dec("-15"))
        byName.addSplit(account: f.offset, value: dec("15"))
        f.book.addTransaction(byName)
        // GnuCash's way: a zero-unit leg on the holding, a plain income account.
        let byLeg = Transaction(currency: .aud, datePosted: day(200), description: "Dividend")
        byLeg.addSplit(account: f.stock, value: dec("0"), quantity: dec("0"))
        byLeg.addSplit(account: f.plainDividends, value: dec("-10"))
        byLeg.addSplit(account: f.bank, value: dec("10"))
        f.book.addTransaction(byLeg)
        // Both: the leg and the named accounts — one transaction, one count.
        let both = Transaction(currency: .aud, datePosted: day(300), description: "CBA dividend")
        both.addSplit(account: f.stock, value: dec("0"), quantity: dec("0"))
        both.addSplit(account: f.bank, value: dec("7"))
        both.addSplit(account: f.unfranked, value: dec("-7"))
        both.addSplit(account: f.credits, value: dec("-3"))
        both.addSplit(account: f.offset, value: dec("3"))
        f.book.addTransaction(both)

        let report = FinancialReports.investmentReturn(f.book, currency: .aud, asOf: day(420))
        let cba = try #require(line(report, "CBA"))
        #expect(cba.dividends == dec("52"))          // 35 + 10 + 7
        #expect(cba.frankingCredits == dec("18"))    // 15 + 3
        #expect(cba.totalReturn == dec("102"))       // 32 + 52 + 18
        #expect(abs((cba.returnFraction ?? 0) - 1.02) < 1e-9)
        #expect(report.totalDividends == dec("52"))
        #expect(report.totalFranking == dec("18"))
        #expect(report.totalReturn == dec("102"))
        #expect(abs((report.totalReturnFraction ?? 0) - 1.02) < 1e-9)
    }

    @Test("A closed position's gain and dividends count only when closed positions are included")
    func closedPositions() throws {
        let f = fixture()
        let xyz = f.book.addAccount(Account(name: "XYZ", type: .stock, commodity: security("XYZ")))
        let xyzDividends = f.book.addAccount(Account(name: "XYZ", type: .income, commodity: .aud),
                                             under: f.plainDividends)
        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: xyz, value: dec("100"), quantity: dec("5"))
        buy.addSplit(account: f.bank, value: dec("-100"))
        f.book.addTransaction(buy)
        let dividend = Transaction(currency: .aud, datePosted: day(20), description: "XYZ dividend")
        dividend.addSplit(account: f.bank, value: dec("5"))
        dividend.addSplit(account: xyzDividends, value: dec("-5"))
        f.book.addTransaction(dividend)
        let sell = Transaction(currency: .aud, datePosted: day(50), description: "Sell all")
        sell.addSplit(account: xyz, value: dec("-125"), quantity: dec("-5"))
        sell.addSplit(account: f.bank, value: dec("125"))
        f.book.addTransaction(sell)

        let with = FinancialReports.investmentReturn(f.book, currency: .aud, asOf: day(420), includeClosed: true)
        let closed = try #require(line(with, "XYZ"))
        #expect(closed.isClosed && closed.units == 0)
        #expect(closed.realizedGain == dec("25") && closed.unrealizedGain == 0)
        #expect(closed.dividends == dec("5"))
        #expect(closed.totalReturn == dec("30"))
        #expect(with.totalReturn == dec("62"))      // CBA 32 + XYZ 30
        #expect(with.lines.map(\.symbol) == ["CBA", "XYZ"], "largest return first")

        let without = FinancialReports.investmentReturn(f.book, currency: .aud, asOf: day(420), includeClosed: false)
        #expect(line(without, "XYZ") == nil)
        #expect(without.totalReturn == dec("32"))
        #expect(without.totalMoneyIn == dec("100"))
    }

    @Test("A held security with no price has no unrealised figure, and the report names it")
    func unpriced() throws {
        let f = fixture()
        let nab = f.book.addAccount(Account(name: "NAB", type: .stock, commodity: security("NAB")))
        let buy = Transaction(currency: .aud, datePosted: day(0), description: "Buy")
        buy.addSplit(account: nab, value: dec("50"), quantity: dec("2"))
        buy.addSplit(account: f.bank, value: dec("-50"))
        f.book.addTransaction(buy)

        let report = FinancialReports.investmentReturn(f.book, currency: .aud, asOf: day(420))
        let line = try #require(line(report, "NAB"))
        #expect(line.unrealizedGain == nil)
        #expect(line.capitalGain == 0)
        #expect(report.unpricedSymbols == ["NAB"])
        #expect(report.totalMoneyIn == dec("150"))
    }

    @Test("Income in a currency with no rate on the day is left out, and the report says which")
    func unconverted() throws {
        let f = fixture()
        let usd = Commodity.currency("USD")
        let foreign = Transaction(currency: usd, datePosted: day(150), description: "CBA ADR dividend")
        foreign.addSplit(account: f.bank, value: dec("20"))
        foreign.addSplit(account: f.franked, value: dec("-20"))
        f.book.addTransaction(foreign)

        let report = FinancialReports.investmentReturn(f.book, currency: .aud, asOf: day(420))
        let cba = try #require(line(report, "CBA"))
        #expect(cba.dividends == 0)
        #expect(report.unconvertedCurrencyCodes == ["USD"])
    }
}
