//
//  SecurityDetailTests.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

private let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme Ltd", smallestFraction: 10000)
private let other = Commodity(namespace: .security("ASX"), mnemonic: "OTHR",
                              fullName: "Other Ltd", smallestFraction: 10000)

@discardableResult
private func buy(_ book: Book, _ commodity: Commodity, units: String, cost: String,
                 on date: Date, account: Account? = nil) -> Account {
    let bank = book.accounts.first { $0.type == .bank }
        ?? book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
    let stock = account ?? book.addAccount(
        Account(name: commodity.mnemonic, type: .stock, commodity: commodity))
    let txn = Transaction(currency: .aud, datePosted: date, description: "Buy")
    txn.addSplit(Split(account: stock, value: dec(cost), quantity: dec(units)))
    txn.addSplit(account: bank, value: -dec(cost))
    book.addTransaction(txn)
    return stock
}

private func sell(_ book: Book, from stock: Account, units: String, proceeds: String, on date: Date) {
    let bank = book.accounts.first { $0.type == .bank }!
    let txn = Transaction(currency: .aud, datePosted: date, description: "Sell")
    txn.addSplit(Split(account: stock, value: -dec(proceeds), quantity: -dec(units)))
    txn.addSplit(account: bank, value: dec(proceeds))
    book.addTransaction(txn)
}

/// A dividend: cash into the bank, an income credit, and a zero-quantity split
/// on the security account so the transaction is attributed to the holding the
/// way GnuCash's advanced portfolio attributes it.
private func dividend(_ book: Book, on stock: Account, amount: String, date: Date) {
    let bank = book.accounts.first { $0.type == .bank }!
    let income = book.accounts.first { $0.type == .income }
        ?? book.addAccount(Account(name: "Dividends", type: .income, commodity: .aud))
    let txn = Transaction(currency: .aud, datePosted: date, description: "Dividend")
    txn.addSplit(Split(account: stock, value: 0, quantity: 0))
    txn.addSplit(account: income, value: -dec(amount))
    txn.addSplit(account: bank, value: dec(amount))
    book.addTransaction(txn)
}

private func detail(_ book: Book, _ commodity: Commodity, asOf: Date) -> SecurityDetail {
    let portfolio = FinancialReports.advancedPortfolio(book, currency: .aud, asOf: asOf)
    return FinancialReports.securityDetail(
        book, commodity: commodity, currency: .aud, asOf: asOf,
        holdings: portfolio.holdings,
        lots: FinancialReports.investmentLots(book, currency: .aud, asOf: asOf),
        calendar: utc)
}

@Suite("Security detail")
struct SecurityDetailTests {

    // MARK: What the page is about — one security, not the book

    @Test("Only this security's prices, events and lots are collected")
    func scopedToOneSecurity() {
        let book = Book(baseCurrency: .aud)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        buy(book, other, units: "5", cost: "500", on: day(2026, 1, 6))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 6, 1), value: dec("120")))
        book.addPrice(Price(commodity: other, currency: .aud, date: day(2026, 6, 1), value: dec("90")))

        let page = detail(book, acme, asOf: day(2026, 6, 2))
        #expect(page.prices.count == 1)
        #expect(page.prices.first?.value == dec("120"))
        #expect(page.events.allSatisfy { $0.accountName.contains("ACME") })
        #expect(page.lots.allSatisfy { $0.symbol == "ACME" })
    }

    // MARK: The chart overlay (`FR-INV-16`)

    @Test("Buys and sells become signed markers with their own unit price")
    func movementsBecomeEvents() {
        let book = Book(baseCurrency: .aud)
        let stock = buy(book, acme, units: "100", cost: "1000", on: day(2026, 1, 5))
        sell(book, from: stock, units: "40", proceeds: "600", on: day(2026, 3, 10))

        let page = detail(book, acme, asOf: day(2026, 6, 1))
        let movements = page.events.filter { $0.kind != .income }
        #expect(movements.count == 2)

        let purchase = movements[0]
        #expect(purchase.kind == .buy)
        #expect(purchase.units == dec("100"))
        // The marker's height on the chart is what you paid per unit, so it can
        // be read against the price line on the same axis.
        #expect(purchase.unitPrice == dec("10"))

        let disposal = movements[1]
        #expect(disposal.kind == .sell)
        #expect(disposal.units == dec("-40"))
        #expect(disposal.amount == dec("600"), "amount is the cash, unsigned")
        #expect(disposal.unitPrice == dec("15"))
    }

    @Test("A transfer in specie has no unit price rather than a price of zero")
    func specieTransferHasNoPrice() {
        // Units arrive with no cash leg — a demutualisation, a bonus issue, a
        // transfer between brokers. Reporting a unit price of 0 would put the
        // marker on the chart's floor and claim the shares were free.
        let book = Book(baseCurrency: .aud)
        let stock = book.addAccount(Account(name: "ACME", type: .stock, commodity: acme))
        let equity = book.addAccount(Account(name: "Opening", type: .equity, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 1, 5), description: "Transfer in")
        txn.addSplit(Split(account: stock, value: 0, quantity: dec("50")))
        txn.addSplit(account: equity, value: 0)
        book.addTransaction(txn)

        let page = detail(book, acme, asOf: day(2026, 6, 1))
        let arrival = page.events.first { $0.kind == .buy }
        #expect(arrival?.units == dec("50"))
        #expect(arrival?.unitPrice == nil)
    }

    @Test("A dividend is an income event, not a unit movement")
    func dividendIsIncome() {
        let book = Book(baseCurrency: .aud)
        let stock = buy(book, acme, units: "100", cost: "1000", on: day(2026, 1, 5))
        dividend(book, on: stock, amount: "35", date: day(2026, 4, 1))

        let page = detail(book, acme, asOf: day(2026, 6, 1))
        let income = page.events.filter { $0.kind == .income }
        #expect(income.count == 1)
        #expect(income.first?.amount == dec("35"))
        #expect(income.first?.units == 0)
        #expect(page.income == dec("35"))
    }

    @Test("Held periods open on the first buy and close on the last sell")
    func holdingPeriodsBracketTheChart() {
        let book = Book(baseCurrency: .aud)
        let stock = buy(book, acme, units: "100", cost: "1000", on: day(2026, 1, 5))
        sell(book, from: stock, units: "100", proceeds: "1500", on: day(2026, 3, 10))
        buy(book, acme, units: "20", cost: "400", on: day(2026, 5, 1), account: stock)

        let page = detail(book, acme, asOf: day(2026, 6, 1))
        #expect(page.holdingPeriods.count == 2)
        #expect(page.holdingPeriods[0].start == day(2026, 1, 5))
        #expect(page.holdingPeriods[0].end == day(2026, 3, 10))
        // Still open: the shading runs to the right-hand edge.
        #expect(page.holdingPeriods[1].end == nil)
    }

    // MARK: The header

    @Test("The previous price is the previous priced day, not the previous row")
    func previousPriceSkipsSameDayRows() {
        // A re-fetch that lands on a day already hand-priced leaves two rows for
        // one observation. Taking "the row before" would compare the day
        // against itself and report no change while the real prior close sits
        // one further back.
        let book = Book(baseCurrency: .aud)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 5, 29), value: dec("100")))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 6, 1),
                            value: dec("110"), source: "user:price"))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 6, 1),
                            value: dec("112"), source: "Finance::Quote:yahoo"))

        let page = detail(book, acme, asOf: day(2026, 6, 2))
        #expect(page.latestPrice == dec("112"))
        #expect(page.previousPrice == dec("100"))
        #expect((page.priceChangeFraction ?? 0) > 0.11)
    }

    @Test("A price dated after asOf never becomes the latest")
    func futurePricesAreNotLatest() {
        let book = Book(baseCurrency: .aud)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 6, 1), value: dec("100")))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 9, 1), value: dec("999")))

        let page = detail(book, acme, asOf: day(2026, 6, 2))
        #expect(page.latestPrice == dec("100"))
        // …but the table still shows it. A price you did not expect is exactly
        // the row a person needs to find, and hiding it is how a typo survives.
        #expect(page.prices.count == 2)
    }

    // MARK: Performance

    @Test("Yield on cost is income over what was paid, and is undefined at zero cost")
    func yieldOnCost() {
        let book = Book(baseCurrency: .aud)
        let stock = buy(book, acme, units: "100", cost: "1000", on: day(2026, 1, 5))
        dividend(book, on: stock, amount: "50", date: day(2026, 4, 1))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 6, 1), value: dec("12")))

        let page = detail(book, acme, asOf: day(2026, 6, 2))
        #expect(page.income == dec("50"))
        #expect(abs((page.yieldOnCost ?? 0) - 0.05) < 0.0001)

        // A holding acquired for nothing yields infinitely, which is not a
        // number a page can print.
        let free = Book(baseCurrency: .aud)
        let stockFree = free.addAccount(Account(name: "ACME", type: .stock, commodity: acme))
        free.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        dividend(free, on: stockFree, amount: "10", date: day(2026, 4, 1))
        #expect(detail(free, acme, asOf: day(2026, 6, 1)).yieldOnCost == nil)
    }

    @Test("A commodity held in two accounts money-weights its return")
    func twoAccountsAreOnePosition() {
        // The arithmetic mean of two returns is not the position's return, and
        // the overview already money-weights — the detail page must give the
        // same answer or the two disagree about the same holding.
        let book = Book(baseCurrency: .aud)
        buy(book, acme, units: "10", cost: "100", on: day(2026, 1, 5))
        let second = book.addAccount(Account(name: "ACME Broker 2", type: .stock, commodity: acme))
        buy(book, acme, units: "90", cost: "900", on: day(2026, 1, 6), account: second)
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 6, 1), value: dec("20")))

        let page = detail(book, acme, asOf: day(2026, 6, 2))
        #expect(page.units == dec("100"))
        #expect(page.costBasis == dec("1000"))
        #expect(page.marketValue == dec("2000"))
        #expect(page.accountNames.count == 2)
        #expect(abs((page.returnFraction ?? 0) - 1.0) < 0.0001)
        #expect(page.averageCost == dec("10"))
    }

    // MARK: Provenance (`FR-INV-27`)

    @Test("Sources are counted, and a provider row is distinguishable from a typed one")
    func provenanceIsCounted() {
        let book = Book(baseCurrency: .aud)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 5, 1),
                            value: dec("100"), source: "user:price"))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 5, 2),
                            value: dec("101"), source: "Finance::Quote:yahoo"))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 5, 3),
                            value: dec("102"), source: "Finance::Quote:yahoo"))

        let page = detail(book, acme, asOf: day(2026, 6, 1))
        #expect(page.sources["Finance::Quote:yahoo"] == 2)
        #expect(page.sources["user:price"] == 1)
        #expect(page.prices.filter(\.isFromProvider).count == 2)
    }

    // MARK: CSV export (`FR-INV-29`)

    @Test("Exported CSV carries the day, the source, and re-importable columns")
    func csvExport() {
        let rows = [
            SecurityPriceRow(id: GncGUID.random(), date: day(2026, 5, 1), value: dec("12.34"),
                             currencyCode: "AUD", source: "user:price"),
            SecurityPriceRow(id: GncGUID.random(), date: day(2026, 5, 2), value: dec("12.50"),
                             currencyCode: "AUD", source: "Finance::Quote:yahoo"),
        ]
        let csv = FinancialReports.priceCSV(rows, symbol: "ACME", calendar: utc)
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Symbol,Date,Price,Currency,Source")
        #expect(lines[1] == "ACME,2026-05-01,12.34,AUD,user:price")
        #expect(lines[2] == "ACME,2026-05-02,12.5,AUD,Finance::Quote:yahoo")
    }

    @Test("A source containing a comma is quoted rather than shifting the columns")
    func csvQuotesDangerousFields() {
        let rows = [SecurityPriceRow(id: GncGUID.random(), date: day(2026, 5, 1), value: dec("1"),
                                     currencyCode: "AUD", source: "odd, source")]
        let csv = FinancialReports.priceCSV(rows, symbol: "ACME", calendar: utc)
        #expect(csv.contains("\"odd, source\""))
        // The four columns a re-import reads are still where they were: only
        // the trailing source column carries the comma, inside its quotes.
        let fields = csv.split(separator: "\n")[1].split(separator: ",")
        #expect(Array(fields.prefix(4)) == ["ACME", "2026-05-01", "1", "AUD"])
    }

    @Test("A source containing a quote is escaped by doubling it")
    func csvEscapesQuotes() {
        let rows = [SecurityPriceRow(id: GncGUID.random(), date: day(2026, 5, 1), value: dec("1"),
                                     currencyCode: "AUD", source: "say \"hi\"")]
        let csv = FinancialReports.priceCSV(rows, symbol: "ACME", calendar: utc)
        #expect(csv.contains("\"say \"\"hi\"\"\""))
    }

    // MARK: Degenerate books

    @Test("A security with nothing recorded reports empty rather than crashing")
    func emptySecurity() {
        let book = Book(baseCurrency: .aud)
        let page = detail(book, acme, asOf: day(2026, 6, 1))
        #expect(page.isEmpty)
        #expect(page.latestPrice == nil)
        #expect(page.priceChangeFraction == nil)
        #expect(page.holdingPeriods.isEmpty)
        #expect(page.units == 0)
    }
}
