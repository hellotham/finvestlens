//
//  InvestmentRowsTests.swift
//  FinvestLens — FeatureUI
//
//  Phase I2 of the Investments hub: the grouping, sparkline segmentation and
//  worklist the destination renders (docs/investments-design.md §6).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
import FinvestLensPersistence
@testable import FinvestLensUI

/// A model over a real (temporary) document — `AppModel.book` is get-only, and
/// the hub reads book kvp, so a hand-made `Book` cannot stand in.
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

private func daysAgo(_ days: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: -days, to: Date())!
}

private let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme", smallestFraction: 10000, getQuotes: true)
private let fund = Commodity(namespace: .security("Super"), mnemonic: "FUND",
                             fullName: "Super Fund", smallestFraction: 10000)
/// A second quotable security, for tests that need two lines on one axis.
private let other = Commodity(namespace: .security("ASX"), mnemonic: "OTHR",
                              fullName: "Other", smallestFraction: 10000, getQuotes: true)

@MainActor
private func makeModel() throws -> AppModel {
    let model = AppModel()
    try model.newDocument(at: tempURL())
    return model
}

@MainActor
@discardableResult
private func buy(_ model: AppModel, _ commodity: Commodity, units: String, cost: String,
                 daysBack: Int) -> Account {
    let book = model.book!
    let bank = book.accounts.first { $0.type == .bank }
        ?? book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
    let stock = book.accounts.first { $0.commodity == commodity }
        ?? book.addAccount(Account(name: commodity.mnemonic, type: .stock, commodity: commodity))
    let txn = Transaction(currency: .aud, datePosted: daysAgo(daysBack), description: "Buy")
    txn.addSplit(Split(account: stock, value: dec(cost), quantity: dec(units)))
    txn.addSplit(account: bank, value: -dec(cost))
    book.addTransaction(txn)
    return stock
}

@MainActor
@Suite("Investment rows")
struct InvestmentRowsTests {

    @Test("Held, hand-valued, watched and closed land in different groups")
    func grouping() throws {
        let model = try makeModel()
        let book = model.book!

        buy(model, acme, units: "10", cost: "1000", daysBack: 60)
        book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(1), value: dec("120")))

        // No provider can price a super fund: a category, not a failure.
        buy(model, fund, units: "100", cost: "10000", daysBack: 60)
        book.addPrice(Price(commodity: fund, currency: .aud, date: daysAgo(1), value: dec("110")))

        // Bought and fully sold — closed.
        let gone = Commodity(namespace: .security("ASX"), mnemonic: "GONE",
                             fullName: "Gone", smallestFraction: 10000, getQuotes: true)
        let stock = buy(model, gone, units: "5", cost: "500", daysBack: 90)
        let sell = Transaction(currency: .aud, datePosted: daysAgo(70), description: "Sell")
        sell.addSplit(Split(account: stock, value: dec("-600"), quantity: dec("-5")))
        sell.addSplit(account: book.accounts.first { $0.type == .bank }!, value: dec("600"))
        book.addTransaction(sell)
        book.addPrice(Price(commodity: gone, currency: .aud, date: daysAgo(70), value: dec("120")))

        model.addWatchSecurity(exchange: "NASDAQ", ticker: "WTCH", name: "Watched")
        model.refreshAll()

        let rows = model.investmentRows()
        func group(_ symbol: String) -> InvestmentGroup? {
            rows.first { $0.symbol == symbol }?.group
        }
        #expect(group("ACME") == .held)
        #expect(group("FUND") == .manual, "no provider covers it — hand-valued, not broken")
        #expect(group("GONE") == .closed)
        #expect(group("WTCH") == .watching)
    }

    @Test("Closed positions are hidden until asked for, and the choice is a book preference")
    func showClosedIsPersisted() throws {
        let model = try makeModel()
        #expect(model.showsClosedPositions == false, "hidden by default")
        model.showsClosedPositions = true
        #expect(model.showsClosedPositions == true)
        #expect(model.book?.kvp["finvestlens/showClosedPositions"] != nil,
                "stored in the book, so it travels with the history it describes")
    }

    @Test("A ticker override makes a security quotable even when the book never marked it")
    func overrideMakesQuotable() throws {
        let model = try makeModel()
        let plain = Commodity(namespace: .security("ASX"), mnemonic: "PLAIN",
                              fullName: "Plain", smallestFraction: 10000)
        #expect(model.canFetchQuotes(for: plain) == false)
        model.setQuoteSymbol("PLAIN.AX", for: plain)
        #expect(model.canFetchQuotes(for: plain) == true)
        #expect(model.canFetchQuotes(for: acme) == true, "the book's own flag still counts")
    }

    @Test("A sparkline breaks at a gap instead of drawing through it")
    func sparklineBreaksAtGaps() throws {
        let model = try makeModel()
        let book = model.book!
        buy(model, acme, units: "10", cost: "1000", daysBack: 80)
        // Two clusters a month apart: the line must not be drawn across the void.
        for day in [60, 59, 58, 57] {
            book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(day), value: dec("100")))
        }
        for day in [4, 3, 2, 1] {
            book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(day), value: dec("120")))
        }
        model.refreshAll()

        let spark = model.investmentRows().first { $0.symbol == "ACME" }?.spark
        #expect(spark?.count == 2, "one segment per contiguous run")
        #expect(spark?.allSatisfy { $0.points.count == 4 } == true)
    }

    @Test("A security a provider actually prices is not filed as hand-valued")
    func providerPricedBeatsTheFlag() throws {
        // A book imported from GnuCash can carry get_quotes = false on a
        // security a provider prices every day; the fetch never consults that
        // flag, so it stayed current while the table called it hand-valued.
        let model = try makeModel()
        let book = model.book!
        let quiet = Commodity(namespace: .security("ASX"), mnemonic: "QUIET",
                              fullName: "Flag says no", smallestFraction: 10000)
        buy(model, quiet, units: "10", cost: "1000", daysBack: 40)
        model.refreshAll()
        #expect(model.canFetchQuotes(for: quiet) == false, "nothing yet says a provider can price it")

        book.addPrice(Price(commodity: quiet, currency: .aud, date: daysAgo(1),
                            value: dec("100"), source: "Finance::Quote:yahoo (USD)"))
        model.refreshAll()

        #expect(model.canFetchQuotes(for: quiet) == true, "a provider-sourced price is the proof")
        #expect(model.investmentRows().first { $0.symbol == "QUIET" }?.group == .held)
    }

    @Test("A security marked no-longer-trading stops being chased, and is not stale")
    func delistedIsFinalNotStale() throws {
        let model = try makeModel()
        let book = model.book!
        buy(model, acme, units: "10", cost: "1000", daysBack: 400)
        // Priced long ago and never since — indistinguishable from a neglected
        // holding until someone says the series has ended.
        book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(200),
                            value: dec("100"), source: "Finance::Quote:eodhd"))
        model.refreshAll()

        let before = model.investmentRows().first { $0.symbol == "ACME" }
        #expect(before?.freshness == .old)
        #expect(before?.needsAttention == true)
        #expect(model.investmentIssues().contains { $0.kind == .stale })
        #expect(model.fetchableSecurities.contains(acme), "still worth asking about")

        model.setDelisted(acme, true)
        model.refreshAll()

        let after = model.investmentRows().first { $0.symbol == "ACME" }
        #expect(after?.freshness == .ceased, "the last price is final, not late")
        #expect(after?.needsAttention == false)
        #expect(model.investmentIssues().contains { $0.kind == .stale } == false,
                "a worklist item nobody can ever clear is worse than none")
        #expect(model.fetchableSecurities.contains(acme) == false,
                "asking a provider again spends a request to be told nothing")
        #expect(model.priceHealth()?.ceasedCount == 1)
        #expect(model.book?.kvp["finvestlens/delistedSecurities"] != nil, "remembered with the book")

        // And it is reversible — a mistaken mark must not be a one-way door.
        model.setDelisted(acme, false)
        model.refreshAll()
        #expect(model.investmentRows().first { $0.symbol == "ACME" }?.freshness == .old)
    }

    @Test("A ceased holding does not hold valuation confidence below 100%")
    func ceasedIsOutOfCoverage() throws {
        let model = try makeModel()
        let book = model.book!
        // Enough observations for the exchange's own trading calendar to be
        // inferred; with only a couple of priced days it falls back to bare
        // weekdays and yesterday's close reads as a day behind.
        let market = Commodity(namespace: .security("ASX"), mnemonic: "MKT",
                               fullName: "Market", smallestFraction: 10000, getQuotes: true)
        var seeded: [Date] = []
        var back = 0
        while seeded.count < 30 {
            let day = daysAgo(back)
            if !Calendar.current.isDateInWeekend(day) {
                seeded.append(day)
                book.addPrice(Price(commodity: market, currency: .aud, date: day, value: dec("100")))
            }
            back += 1
        }
        let latest = seeded[0]

        buy(model, acme, units: "10", cost: "1000", daysBack: 400)
        buy(model, other, units: "10", cost: "1000", daysBack: 400)
        book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(200), value: dec("100")))
        book.addPrice(Price(commodity: other, currency: .aud, date: latest, value: dec("100")))
        model.refreshAll()
        #expect(model.investmentRows().first { $0.symbol == "OTHR" }?.freshness == .current)
        #expect((model.priceHealth()?.valueCoverage ?? 1) < 1, "one stale holding drags it down")

        model.setDelisted(acme, true)
        model.refreshAll()
        // Not counted as fresh either — it is out of the question entirely.
        #expect(model.priceHealth()?.valueCoverage == 1.0)
    }

    @Test("A hand-entered price is not mistaken for a provider's")
    func userPricesStayManual() throws {
        // The other direction, which is what keeps the super funds honest:
        // typed, imported and dialog-entered prices all carry a `user:` source.
        let model = try makeModel()
        let book = model.book!
        buy(model, fund, units: "100", cost: "10000", daysBack: 40)
        for source in ["user:price", "user:price-editor", "user:split-import", "user:xfer-dialog"] {
            book.addPrice(Price(commodity: fund, currency: .aud, date: daysAgo(2),
                                value: dec("110"), source: source))
        }
        model.refreshAll()

        #expect(model.canFetchQuotes(for: fund) == false)
        #expect(model.investmentRows().first { $0.symbol == "FUND" }?.group == .manual)
    }

    @Test("The sparkline period is adjustable, named, and remembered in the book")
    func sparkRangeIsAPreference() throws {
        let model = try makeModel()
        #expect(model.sparkRange == .quarter, "a sensible default, not the longest")

        model.sparkRange = .year
        #expect(model.sparkRange == .year)
        #expect(model.book?.kvp["finvestlens/sparkRange"] != nil, "persisted with the book")

        // Every period says what it is in words. An abbreviation is what made
        // the axis unreadable, and VoiceOver would say "three em".
        for range in AppModel.SparkRange.allCases {
            #expect(!range.label.isEmpty)
            #expect(range.label.rangeOfCharacter(from: .letters) != nil)
        }
    }

    @Test("The window follows the chosen period, and is the same for every row")
    func windowIsSharedAndFollowsRange() throws {
        let model = try makeModel()
        let book = model.book!
        buy(model, acme, units: "10", cost: "1000", daysBack: 400)
        buy(model, other, units: "10", cost: "1000", daysBack: 400)
        // ACME priced right up to today; OTHR stopped six months ago.
        for day in [3, 2, 1] {
            book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(day), value: dec("100")))
        }
        for day in [184, 183, 182] {
            book.addPrice(Price(commodity: other, currency: .aud, date: daysAgo(day), value: dec("50")))
        }
        model.refreshAll()

        // At three months the stale holding contributes no points at all, so it
        // cannot possibly draw across the full width as though it were current
        // — which is what a per-row axis did.
        model.sparkRange = .quarter
        let quarterWindow = model.sparkWindow
        let quarterRows = model.investmentRows()
        #expect(quarterRows.first { $0.symbol == "OTHR" }?.spark.isEmpty == true)
        #expect(quarterRows.first { $0.symbol == "ACME" }?.spark.isEmpty == false)

        // Widen the period and the same security comes into view.
        model.sparkRange = .year
        let yearWindow = model.sparkWindow
        #expect(model.investmentRows().first { $0.symbol == "OTHR" }?.spark.isEmpty == false)

        // The window is what widened, and it ends at the same clock reading for
        // every row rather than at each row's own last price.
        #expect(yearWindow.upperBound == quarterWindow.upperBound)
        #expect(yearWindow.lowerBound < quarterWindow.lowerBound)
        for row in model.investmentRows() {
            for point in row.spark.flatMap(\.points) {
                #expect(yearWindow.contains(point.date) || point.date >= yearWindow.lowerBound)
            }
        }
    }

    @Test("The same gap breaks a short window and not a long one")
    func gapThresholdScales() throws {
        let model = try makeModel()
        let book = model.book!
        buy(model, acme, units: "10", cost: "1000", daysBack: 400)
        // Daily prices for over a year, with one 19-day hole inside the last
        // month. Nineteen days is a third of a one-month chart and half a
        // percent of a five-year one, so the *same* data must break in one and
        // not the other — a fixed threshold cannot be right for both.
        for day in 0...400 where !(8...26).contains(day) {
            book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(day), value: dec("100")))
        }
        model.refreshAll()

        model.sparkRange = .month
        let monthly = model.investmentRows().first { $0.symbol == "ACME" }?.spark.count ?? 0

        model.sparkRange = .fiveYears
        let fiveYears = model.investmentRows().first { $0.symbol == "ACME" }?.spark.count ?? 0

        #expect(monthly == 2, "the hole is a third of the chart — it must read as a break")
        #expect(fiveYears == 1, "the same hole is sub-pixel over five years")
    }

    @Test("The worklist is empty on a healthy book and names the problem on a broken one")
    func worklist() throws {
        let model = try makeModel()
        let book = model.book!
        buy(model, acme, units: "10", cost: "1000", daysBack: 60)
        for day in 1...40 {
            book.addPrice(Price(commodity: acme, currency: .aud, date: daysAgo(day), value: dec("120")))
        }
        model.refreshAll()
        #expect(model.investmentIssues().isEmpty, "nothing to say about a current holding")

        // A second holding that has never been priced is a blocking problem:
        // today's total is wrong, not merely history.
        buy(model, fund, units: "100", cost: "10000", daysBack: 60)
        model.refreshAll()
        let issues = model.investmentIssues()
        #expect(issues.contains { $0.kind == .unpriced && $0.symbols.contains("FUND") })
    }

    @Test("Rows sort by value, so the position that most affects the total is first")
    func sortedByValue() throws {
        let model = try makeModel()
        // Names chosen so alphabetical order is the *opposite* of value order:
        // with BIG/SMALL a name sort would have produced the same answer and
        // the test would have passed while proving nothing.
        let big = Commodity(namespace: .security("ASX"), mnemonic: "ZULU",
                            fullName: "Zulu", smallestFraction: 10000, getQuotes: true)
        let small = Commodity(namespace: .security("ASX"), mnemonic: "ALPHA",
                              fullName: "Alpha", smallestFraction: 10000, getQuotes: true)
        buy(model, small, units: "1", cost: "10", daysBack: 30)
        buy(model, big, units: "1000", cost: "90000", daysBack: 30)
        model.book!.addPrice(Price(commodity: small, currency: .aud, date: daysAgo(1), value: dec("10")))
        model.book!.addPrice(Price(commodity: big, currency: .aud, date: daysAgo(1), value: dec("90")))
        model.refreshAll()

        let held = model.investmentRows().filter { $0.group == .held }
        #expect(held.first?.symbol == "ZULU", "sorted by value; alphabetically ALPHA would win")
    }

    @Test("Rate health names the currency a holding cannot be valued in")
    func rateHealth() throws {
        let model = try makeModel()
        let book = model.book!
        let usd = Commodity(namespace: .currency, mnemonic: "USD",
                            fullName: "US Dollar", smallestFraction: 100)
        book.registerCommodity(usd)
        book.addAccount(Account(name: "US Cash", type: .bank, commodity: usd))
        model.refreshAll()

        let health = model.rateHealth()
        #expect(health.currencies == 1)
        #expect(health.missing == ["USD"])

        model.addExchangeRate(from: usd, to: .aud, rate: dec("1.5"), date: Date())
        model.refreshAll()
        #expect(model.rateHealth().missing.isEmpty)
    }
}
