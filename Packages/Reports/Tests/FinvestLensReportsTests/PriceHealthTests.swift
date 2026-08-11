//
//  PriceHealthTests.swift
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
private func plus(_ date: Date, _ days: Int) -> Date {
    utc.date(byAdding: .day, value: days, to: date)!
}

private let market = Commodity(namespace: .security("ASX"), mnemonic: "MKT",
                               fullName: "Market", smallestFraction: 10000)
private let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme", smallestFraction: 10000)
private let other = Commodity(namespace: .security("ASX"), mnemonic: "OTHR",
                              fullName: "Other", smallestFraction: 10000)

/// Weekdays walking back from `end`, most recent first.
private func weekdaysBack(from end: Date, count: Int) -> [Date] {
    var out: [Date] = []
    var cursor = end
    while out.count < count {
        if !utc.isDateInWeekend(cursor) { out.append(cursor) }
        cursor = plus(cursor, -1)
    }
    return out
}

/// Seeds enough market-wide prices for the exchange's own trading calendar to
/// be inferred (`TradingCalendar.minimumObservations`), rather than falling
/// back to the book-wide union or to bare weekdays.
@discardableResult
private func seedCalendar(_ book: Book, endingOn end: Date, count: Int = 30) -> [Date] {
    let days = weekdaysBack(from: end, count: count)
    for date in days {
        book.addPrice(Price(commodity: market, currency: .aud, date: date,
                            value: dec("100"), source: "Finance::Quote:yahoo"))
    }
    return days
}

/// A stock account holding `units` of `commodity`, bought on `date`.
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

private func health(_ book: Book, asOf: Date,
                    quotable: @escaping (Commodity) -> Bool = { $0.getQuotes }) -> PortfolioPriceHealth {
    // UTC throughout: the fixtures build UTC midnights, and every date the
    // report returns is a start-of-day in the calendar it was given.
    FinancialReports.priceHealth(book, currency: .aud, asOf: asOf,
                                 quotable: quotable, calendar: utc)
}

private extension PortfolioPriceHealth {
    func find(_ mnemonic: String) -> SecurityPriceHealth? {
        securities.first { $0.commodity.mnemonic == mnemonic }
    }
}

@Suite("Price health")
struct PriceHealthTests {

    // MARK: Freshness

    @Test("A Friday close is current on Monday, not a day stale")
    func weekendDoesNotAge() {
        // The false alarm this whole model exists to prevent: judged by elapsed
        // days, every ASX holding reads as stale every Monday morning.
        let friday = day(2026, 8, 7)
        #expect(utc.component(.weekday, from: friday) == 6, "fixture must really be a Friday")
        let monday = day(2026, 8, 10)

        let book = Book(baseCurrency: .aud)
        seedCalendar(book, endingOn: friday)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: friday, value: dec("120")))

        let result = health(book, asOf: monday)
        #expect(result.find("ACME")?.freshness == .current)
        #expect(result.find("ACME")?.tradingDaysBehind == 0)
    }

    @Test("Staleness counts trading days, not calendar days")
    func countsTradingDays() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        // Priced three trading days back — which spans a weekend, so five
        // calendar days. The answer must be 3.
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[3], value: dec("120")))

        let result = health(book, asOf: friday)
        #expect(result.find("ACME")?.tradingDaysBehind == 3)
        #expect(result.find("ACME")?.freshness == .stale)
    }

    @Test("More than a trading week behind is old, and lands on the worklist")
    func oldBand() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[10], value: dec("120")))

        let result = health(book, asOf: friday)
        #expect(result.find("ACME")?.freshness == .old)
        #expect(result.needsAttention.contains { $0.commodity.mnemonic == "ACME" })
    }

    @Test("A holding that was never priced is missing, not merely old")
    func neverPriced() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        seedCalendar(book, endingOn: friday)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))

        let result = health(book, asOf: friday)
        #expect(result.find("ACME")?.freshness == .missing)
        #expect(result.find("ACME")?.marketValue == nil)
        #expect(result.unvaluedCount == 1)
    }

    // MARK: Holding periods

    @Test("Holding periods open, close on a full sale, and reopen")
    func holdingPeriods() {
        let periods = FinancialReports.holdingPeriods(from: [
            (day(2026, 1, 5), dec("10")),
            (day(2026, 3, 2), dec("-10")),     // out entirely
            (day(2026, 5, 4), dec("7")),       // back in, still held
        ], asOf: day(2026, 8, 7))

        #expect(periods.count == 2)
        #expect(periods.first?.start == day(2026, 1, 5))
        #expect(periods.first?.end == day(2026, 3, 2))
        #expect(periods.last?.start == day(2026, 5, 4))
        #expect(periods.last?.end == nil, "an open position has no end")
        #expect(periods.last?.contains(day(2026, 6, 1)) == true)
        #expect(periods.first?.contains(day(2026, 4, 1)) == false)
    }

    @Test("A partial sale does not close the holding period")
    func partialSale() {
        let periods = FinancialReports.holdingPeriods(from: [
            (day(2026, 1, 5), dec("10")),
            (day(2026, 3, 2), dec("-4")),
        ], asOf: day(2026, 8, 7))
        #expect(periods.count == 1)
        #expect(periods.first?.end == nil)
    }

    // MARK: Gaps

    @Test("A gap inside a holding period is flagged; the same gap after selling is not")
    func gapsAreHoldingAware() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday, count: 40).reversed().map { $0 }

        // Held across the first half of the window, sold before the second.
        let stock = buy(book, acme, units: "10", cost: "1000", on: days[0])
        sell(book, from: stock, units: "10", proceeds: "1200", on: days[20])

        // Priced on every seeded day except two runs: one while held, one after.
        let heldGap = Set([days[5], days[6]])
        let soldGap = Set([days[30], days[31], days[32]])
        for date in days where !heldGap.contains(date) && !soldGap.contains(date) {
            book.addPrice(Price(commodity: acme, currency: .aud, date: date, value: dec("120")))
        }

        let result = health(book, asOf: friday)
        let acmeHealth = result.find("ACME")
        #expect(acmeHealth?.gaps.count == 2)
        #expect(acmeHealth?.missingWhileHeld == 2, "only the run inside the holding period counts")

        let held = acmeHealth?.gaps.first { $0.whileHeld }
        #expect(held?.tradingDays == 2)
        #expect(held?.start == days[5])
        #expect(held?.end == days[6])

        let sold = acmeHealth?.gaps.first { !$0.whileHeld }
        #expect(sold?.tradingDays == 3)
    }

    @Test("Gap scanning starts at the first price, not the first purchase")
    func gapsStartAtFirstPrice() {
        // A security bought long before any history was fetched should not
        // report a hole for every day since purchase — there was no series to
        // have a hole in.
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday, count: 30).reversed().map { $0 }
        buy(book, acme, units: "10", cost: "1000", on: day(2020, 1, 6))
        for date in days.suffix(5) {
            book.addPrice(Price(commodity: acme, currency: .aud, date: date, value: dec("120")))
        }

        #expect(health(book, asOf: friday).find("ACME")?.missingWhileHeld == 0)
    }

    // MARK: Coverage

    @Test("Coverage is weighted by value, so one large stale holding dominates")
    func coverageIsValueWeighted() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday)

        // Large holding, stale. Small holding, fresh. By count that is 50%;
        // by value it is far worse, which is the number a person needs.
        buy(book, acme, units: "1000", cost: "90000", on: day(2026, 1, 5))
        buy(book, other, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[10], value: dec("90")))
        book.addPrice(Price(commodity: other, currency: .aud, date: days[0], value: dec("100")))

        let result = health(book, asOf: friday)
        // Fresh 1,000 of 91,000 total — 1.1%, where a count would say 50%.
        #expect(result.valueCoverage.map { abs($0 - (1000.0 / 91000.0)) < 0.0001 } == true)
        #expect(result.heldCount == 2)
        #expect(result.currentCount == 1)
        #expect(result.oldCount == 1)
    }

    @Test("Closed positions are excluded from coverage and from the worklist")
    func dormantExcluded() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday)

        buy(book, other, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: other, currency: .aud, date: days[0], value: dec("100")))

        // Bought and fully sold: dormant, and years stale.
        let stock = buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        sell(book, from: stock, units: "10", proceeds: "1200", on: day(2026, 2, 2))
        book.addPrice(Price(commodity: acme, currency: .aud, date: day(2026, 2, 2), value: dec("120")))

        let result = health(book, asOf: friday)
        #expect(result.find("ACME")?.isDormant == true)
        #expect(result.heldCount == 1)
        #expect(result.valueCoverage == 1.0, "the only held position is current")
        #expect(result.needsAttention.isEmpty, "a sold position needs nothing")
    }

    @Test("Coverage is nil, not zero, when nothing held can be valued")
    func coverageNilWhenUnvaluable() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        seedCalendar(book, endingOn: friday)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))

        // "No opinion" and "0% fresh" are different statements and the UI must
        // not conflate them.
        #expect(health(book, asOf: friday).valueCoverage == nil)
    }

    // MARK: Provenance and quotability

    @Test("Provenance is counted per source")
    func provenance() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[0],
                            value: dec("120"), source: "Finance::Quote:yahoo"))
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[1],
                            value: dec("119"), source: "user:price"))
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[2],
                            value: dec("118"), source: "user:price"))

        let acmeHealth = health(book, asOf: friday).find("ACME")
        #expect(acmeHealth?.sources["user:price"] == 2)
        #expect(acmeHealth?.sources["Finance::Quote:yahoo"] == 1)
        #expect(acmeHealth?.priceCount == 3)
        #expect(acmeHealth?.pricedDays == 3)
    }

    @Test("Rows and priced days differ exactly by the duplicate same-day prices")
    func duplicateSameDayPrices() {
        // The real book carries these: the auto-refresh once appended an
        // identical close on every open across a closed weekend. Freshness and
        // gaps must count the day once; the detail page still lists both rows.
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        let days = seedCalendar(book, endingOn: friday)
        buy(book, acme, units: "10", cost: "1000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[0],
                            value: dec("120"), source: "Finance::Quote:yahoo"))
        book.addPrice(Price(commodity: acme, currency: .aud, date: days[0],
                            value: dec("120"), source: "user:price"))

        let acmeHealth = health(book, asOf: friday).find("ACME")
        #expect(acmeHealth?.priceCount == 2)
        #expect(acmeHealth?.pricedDays == 1)
        #expect(acmeHealth?.freshness == .current, "two rows on one day is still one priced day")
    }

    @Test("Securities no provider can price are counted as manual, not as failures")
    func manualValuations() {
        let friday = day(2026, 8, 7)
        let book = Book(baseCurrency: .aud)
        seedCalendar(book, endingOn: friday)
        let fund = Commodity(namespace: .security("Super"), mnemonic: "FUND",
                             fullName: "Super Fund", smallestFraction: 10000)
        buy(book, fund, units: "100", cost: "10000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: fund, currency: .aud, date: day(2026, 6, 30),
                            value: dec("110"), source: "user:price"))

        let result = health(book, asOf: friday, quotable: { $0.mnemonic != "FUND" })
        #expect(result.find("FUND")?.isQuotable == false)
        #expect(result.manualCount == 1)
    }

    // MARK: Calendar

    @Test("A weekend-stamped price does not invent a trading day")
    func weekendPricesAreNotSessions() {
        // The book stores prices under several clock conventions, and a 23:00
        // UTC row bucketed into local time lands on the next day — a Friday
        // close becomes Saturday. Believed, that Saturday becomes a trading day
        // every other security is then "missing", which on the reference book
        // inflated the ASX calendar to 278–282 days a year against a real ~250
        // and reported about thirty phantom gaps per security per year.
        let friday = day(2026, 8, 7)
        let saturday = day(2026, 8, 8)
        #expect(utc.isDateInWeekend(saturday), "fixture must really be a weekend")

        let book = Book(baseCurrency: .aud)
        seedCalendar(book, endingOn: friday)
        // One stray weekend row, from one security only.
        book.addPrice(Price(commodity: market, currency: .aud, date: saturday, value: dec("100")))

        let calendar = TradingCalendar(book: book, calendar: utc)
        #expect(calendar.tradingDays(for: "ASX", from: saturday, to: saturday).isEmpty,
                "no exchange trades on a Saturday")
        #expect(calendar.latestTradingDay(for: "ASX", onOrBefore: saturday) == friday)

        // And a security priced every session must show no gap because of it.
        let days = weekdaysBack(from: friday, count: 30)
        buy(book, acme, units: "10", cost: "1000", on: days.last!)
        for date in days {
            book.addPrice(Price(commodity: acme, currency: .aud, date: date, value: dec("120")))
        }
        #expect(health(book, asOf: friday).find("ACME")?.missingWhileHeld == 0)
    }

    @Test("A sparse exchange borrows the book's calendar rather than assuming weekdays")
    func sparseExchangeFallsBackToBook() {
        // Bonds have a handful of prices, so their own series says nothing. The
        // book-wide union still knows Monday has not traded yet.
        let friday = day(2026, 8, 7)
        let monday = day(2026, 8, 10)
        let book = Book(baseCurrency: .aud)
        seedCalendar(book, endingOn: friday)
        let bond = Commodity(namespace: .security("Bond"), mnemonic: "BOND",
                             fullName: "Bond", smallestFraction: 10000)
        buy(book, bond, units: "1000", cost: "100000", on: day(2026, 1, 5))
        book.addPrice(Price(commodity: bond, currency: .aud, date: friday, value: dec("1")))

        let calendar = TradingCalendar(book: book, calendar: utc)
        #expect(calendar.isInferred(for: "Bond") == false)
        #expect(calendar.latestTradingDay(for: "Bond", onOrBefore: monday) == friday)
        #expect(health(book, asOf: monday).find("BOND")?.freshness == .current)
    }
}
