//
//  WilsonProviderTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The fixtures below are the shapes the live Wilson Asset Management Founders
//  Fund page served on 16 Aug 2026, read in this session through the Browser
//  pane (the page is server-rendered, so its markup is what a fetch gets):
//
//  - the Historical Prices table, header `Date | Price | Redemption Price |
//    Application Price`, first three rows `13/08/2026 $1.0200`,
//    `08/12/2026 $1.0150`, `08/11/2026 $1.0222`;
//  - eight key facts as `<p class="leader">…</p><p class="details">…</p>` pairs
//    — Inception date, Asset class, Benchmark index, Investment timeframe,
//    APIR code (ETL5957AU), ARSN, Management fee, Performance fee.
//

import Foundation
import Testing
@testable import FinvestLensQuotes

@Suite("Wilson Asset Management provider")
struct WilsonProviderTests {

    /// The table exactly as the page emits it, inconsistent dates and all.
    static let pricesHTML = """
    <table><thead><tr><th>Date</th><th>Price</th><th>Redemption Price</th>
    <th>Application Price</th></tr></thead><tbody>
    <tr><td>13/08/2026</td><td>$1.0200</td><td>$1.0179</td><td>$1.0220</td></tr>
    <tr><td>08/12/2026</td><td>$1.0150</td><td>$1.0130</td><td>$1.0171</td></tr>
    <tr><td>08/11/2026</td><td>$1.0222</td><td>$1.0202</td><td>$1.0243</td></tr>
    <tr><td>08/10/2026</td><td>$1.0180</td><td>$1.0160</td><td>$1.0201</td></tr>
    <tr><td>31/07/2026</td><td>$1.0100</td><td>$1.0080</td><td>$1.0120</td></tr>
    </tbody></table>
    """

    private func utcDay(_ date: Date) -> DateComponents {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.dateComponents([.year, .month, .day], from: date)
    }

    // MARK: The date format the page is not consistent about

    /// The heart of it, and the reason this provider needed a bespoke reader.
    ///
    /// `13/08/2026` is unambiguous — 13 cannot be a month — so it is 13 August.
    /// The rows below it read `08/12`, `08/11`, `08/10`: as day-first those
    /// would be December, November and October *after* 13 August in a table
    /// that runs newest first. As month-first they are 12, 11 and 10 August,
    /// descending exactly as the order requires. So the page emits day-first
    /// above the 12th and month-first below it, and each row is settled by the
    /// one above rather than by a format guess.
    @Test("Both date spellings on one page resolve to a descending August run")
    func mixedDateFormatsResolve() throws {
        let quotes = try WilsonQuoteProvider.parse(html: Self.pricesHTML, symbol: "founders")
        #expect(quotes.count == 5)
        let days = quotes.map { utcDay($0.date) }
        #expect(days.map(\.month) == [8, 8, 8, 8, 7])
        #expect(days.map(\.day) == [13, 12, 11, 10, 31])
        #expect(days.allSatisfy { $0.year == 2026 })
    }

    /// Strictly descending, which is what the resolution is anchored on: if a
    /// reading ever jumped forward the table's own order would have been broken.
    @Test("The resolved series never runs backwards")
    func seriesDescends() throws {
        let quotes = try WilsonQuoteProvider.parse(html: Self.pricesHTML, symbol: "founders")
        for (earlier, later) in zip(quotes, quotes.dropFirst()) {
            #expect(later.date < earlier.date)
        }
    }

    /// A civil date has to name the same day for every reader — the defect that
    /// dated a Los Angeles reader's series one day earlier than a Sydney one.
    @Test("A published date is the same day in any timezone")
    func datesAreNeutral() throws {
        let quotes = try WilsonQuoteProvider.parse(html: Self.pricesHTML, symbol: "founders")
        let first = try #require(quotes.first).date
        for offset in [-10, -7, 0, 5, 10, 13] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: offset * 3600)!
            #expect(calendar.component(.day, from: first) == 13,
                    "shifted at UTC\(offset >= 0 ? "+" : "")\(offset)")
        }
    }

    @Test("The price column is the fund's own, not the spread around it")
    func takesThePriceColumn() throws {
        let quotes = try WilsonQuoteProvider.parse(html: Self.pricesHTML, symbol: "founders")
        #expect(quotes.first?.price == Decimal(string: "1.0200"))
        #expect(quotes.first?.currencyCode == "AUD")
    }

    @Test("A page with no table is no data, not an empty success")
    func noTableIsNoData() {
        #expect(throws: (any Error).self) {
            try WilsonQuoteProvider.parse(html: "<html><body>Nothing here</body></html>",
                                          symbol: "founders")
        }
    }

    // MARK: The profile

    static let profileHTML = """
    <html><head><title>
    Wilson Asset Management Founders Fund - Wilson Asset Management</title></head>
    <body><div class="wam-leader-content-right"><div class="row">
    <div class="col-md-6"><div class="right-content">
    <p class="leader" style="color:#d0af79">Inception date</p>
    <p class="details">February 2025</p></div></div>
    <div class="col-md-6"><div class="right-content">
    <p class="leader" style="color:#d0af79">Asset class</p>
    <p class="details">Equity</p></div></div>
    <div class="col-md-6"><div class="right-content">
    <p class="leader" style="color:#d0af79">Benchmark index </p>
    <p class="details">RBA cash rate + 4% p.a.</p></div></div>
    <div class="col-md-6"><div class="right-content">
    <p class="leader" style="color:#d0af79">APIR code</p>
    <p class="details">ETL5957AU</p></div></div>
    <div class="col-md-6"><div class="right-content">
    <p class="leader" style="color:#d0af79">Management fee</p>
    <p class="details">1.025% p.a. of the Net Asset Value (&quot;NAV&quot;) of the Fund.</p>
    </div></div></div></div></body></html>
    """

    @Test("The fund's key facts are read as label/value pairs")
    func profilePairs() {
        let facts = WilsonQuoteProvider.keyFacts(in: Self.profileHTML)
        #expect(facts.count == 5)
        #expect(facts.map(\.label) == ["Inception date", "Asset class", "Benchmark index",
                                       "APIR code", "Management fee"])
        #expect(facts.first { $0.label == "APIR code" }?.value == "ETL5957AU")
    }

    /// The name comes from `<title>`: the page carries three `h1`s and two of
    /// them run the words together because of the spans inside.
    @Test("The profile names the fund, not the manager's website")
    func profileName() {
        let profile = WilsonQuoteProvider.parseProfile(
            html: Self.profileHTML,
            url: URL(string: "https://wilsonassetmanagement.com.au/trusts/founders/"))
        #expect(profile.name == "Wilson Asset Management Founders Fund")
        #expect(profile.currencyCode == "AUD")
        #expect(profile.sector == "Equity")
        #expect(profile.website?.contains("founders") == true)
    }

    /// A trust is not a company: nothing here may set the fields that make the
    /// security page draw a bond's or an equity's shape around it.
    @Test("A fund's profile is not mistaken for a bond's")
    func profileIsNotFixedIncome() {
        let profile = WilsonQuoteProvider.parseProfile(html: Self.profileHTML, url: nil)
        #expect(!profile.isFixedIncome)
        #expect(profile.couponRate == nil)
        #expect(profile.maturityDate == nil)
    }

    @Test("Entities and stray markup are decoded out of a value")
    func entitiesDecoded() {
        let facts = WilsonQuoteProvider.keyFacts(in: Self.profileHTML)
        let fee = facts.first { $0.label == "Management fee" }?.value
        #expect(fee?.contains("\"NAV\"") == true)
        #expect(fee?.contains("&quot;") == false)
    }

    // MARK: The claim matches the factory

    /// The rule P13.0 caught this provider breaking in the other direction: it
    /// declared `servesFundamentals: true` while its factory returned `nil`.
    @Test("Wilson serves fundamentals and the factory builds one")
    func factoryMatchesTheClaim() {
        #expect(QuoteProviderKind.wilson.servesFundamentals)
        #expect(FundamentalsProviderFactory.make(.wilson, crumbs: YahooCrumbStore()) != nil)
        #expect(QuoteProviderFactory.make(.wilson) != nil)
    }
}
