//
//  FundamentalsTests.swift
//  FinvestLens — Quotes
//
//  Fixtures reproduce the live responses' shape and field types, measured
//  15 Aug 2026. Figures are invented. // synthetic
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

private func tempCache() -> (FundamentalsCache, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fund-\(UUID().uuidString)", isDirectory: true)
    return (FundamentalsCache(directory: directory), directory)
}

// MARK: - The sidecar

@Suite("Fundamentals cache")
struct FundamentalsCacheTests {

    @Test("A record round-trips through the sidecar")
    func roundTrip() {
        let (cache, directory) = tempCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        var profile = SecurityProfile()
        profile.sector = "Utilities"
        profile.employees = 1234
        cache.save(SecurityFundamentals(profile: Stamped(profile, source: "Test")),
                   namespace: "security(\"ASX\")", mnemonic: "XYZ")

        let loaded = cache.load(namespace: "security(\"ASX\")", mnemonic: "XYZ")
        #expect(loaded?.profile?.value.sector == "Utilities")
        #expect(loaded?.profile?.value.employees == 1234)
        #expect(loaded?.profile?.source == "Test")
    }

    @Test("A namespace containing a slash cannot escape the cache directory")
    func namespaceIsEscaped() {
        // A namespace is user-defined. `/` in one would write into a directory
        // that does not exist — or, worse, one that does.
        let (cache, directory) = tempCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = cache.url(namespace: "other(\"../../etc\")", mnemonic: "X")
        #expect(url.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL)
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test("A record from a different shape version is discarded, not decoded")
    func versionGate() throws {
        let (cache, directory) = tempCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = #"{"version":999,"profile":null,"statements":null,"dividends":null}"#
        try Data(stale.utf8).write(to: cache.url(namespace: "n", mnemonic: "m"))
        #expect(cache.load(namespace: "n", mnemonic: "m") == nil)
    }

    @Test("An absent or corrupt file reads as nothing rather than throwing")
    func missingAndCorrupt() throws {
        let (cache, directory) = tempCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(cache.load(namespace: "n", mnemonic: "never-written") == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cache.url(namespace: "n", mnemonic: "m"))
        #expect(cache.load(namespace: "n", mnemonic: "m") == nil)
    }

    @Test("Clearing forgets one security, or all of them")
    func clearing() {
        let (cache, directory) = tempCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mnemonic in ["A", "B"] {
            cache.save(SecurityFundamentals(profile: Stamped(SecurityProfile(), source: "T")),
                       namespace: "n", mnemonic: mnemonic)
        }
        #expect(cache.count() == 2)
        cache.remove(namespace: "n", mnemonic: "A")
        #expect(cache.count() == 1)
        cache.removeAll()
        #expect(cache.count() == 0)
        #expect(cache.sizeOnDisk() == 0)
    }
}

// MARK: - Staleness and merging

@Suite("Fundamentals freshness")
struct FundamentalsFreshnessTests {

    @Test("TTLs differ by section, because the facts do")
    func ttls() {
        #expect(FundamentalsKind.dividends.ttl < FundamentalsKind.profile.ttl)
        #expect(FundamentalsKind.profile.ttl < FundamentalsKind.statements.ttl)
    }

    @Test("A section past its own TTL needs fetching; a fresh one does not")
    func staleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eightDaysAgo = now.addingTimeInterval(-8 * 86_400)
        let record = SecurityFundamentals(
            profile: Stamped(SecurityProfile(), fetchedAt: eightDaysAgo, source: "T"),
            dividends: Stamped([], fetchedAt: eightDaysAgo, source: "T"))

        // Dividends go stale weekly, a profile monthly — so at eight days one
        // is due and the other is not. One timestamp for the whole record could
        // not express that.
        #expect(record.needsFetch(.dividends, now: now))
        #expect(!record.needsFetch(.profile, now: now))
        #expect(record.needsFetch(.statements, now: now), "never fetched")
    }

    @Test("Merging keeps sections the new fetch did not supply")
    func merging() {
        // A provider that serves a profile but no statements must not erase
        // statements fetched last quarter.
        let old = SecurityFundamentals(
            profile: Stamped(SecurityProfile(), source: "Old"),
            statements: Stamped([FinancialPeriod(statement: .income, endDate: .distantPast,
                                                 lines: ["totalRevenue": dec("1")])],
                                source: "Old"))
        var fresh = SecurityProfile()
        fresh.sector = "New sector"
        let merged = old.merging(SecurityFundamentals(profile: Stamped(fresh, source: "New")))

        #expect(merged.profile?.value.sector == "New sector")
        #expect(merged.statements?.source == "Old", "statements survived")
        #expect(merged.statements?.value.count == 1)
    }
}

// MARK: - Yahoo parsing

private let summaryJSON = """
{"quoteSummary":{"result":[{
 "assetProfile":{"sector":"Financial Services","industry":"Banks","country":"Australia",
   "website":"https://example.com","fullTimeEmployees":4321,
   "longBusinessSummary":"An invented issuer."},
 "summaryDetail":{"currency":"AUD","marketCap":{"raw":1000000,"fmt":"1M"},
   "trailingPE":{"raw":12.5,"fmt":"13"},"dividendYield":{"raw":0.04,"fmt":"4%"},
   "beta":{"raw":0.8,"fmt":"0.8"}},
 "defaultKeyStatistics":{"sharesOutstanding":{"raw":50000,"fmt":"50k"},
   "sharesShort":{},"category":null},
 "incomeStatementHistory":{"incomeStatementHistory":[
   {"maxAge":1,"endDate":{"raw":1782777600,"fmt":"2026-06-30"},
    "totalRevenue":{"raw":900,"fmt":"900"},"grossProfit":{},"ebit":{"raw":100,"fmt":"100"}},
   {"maxAge":1,"endDate":{"raw":1751241600,"fmt":"2025-06-30"},
    "totalRevenue":{"raw":800,"fmt":"800"}}]}
}],"error":null}}
"""

private let eventsJSON = """
{"chart":{"result":[{"meta":{"symbol":"XYZ.AX"},
 "events":{
   "dividends":{"1771369200":{"amount":2.35,"date":1771369200},
                "1755000000":{"amount":2.10,"date":1755000000}},
   "splits":{"1600000000":{"date":1600000000,"numerator":2,"denominator":1,
                            "splitRatio":"2:1"}}}
}],"error":null}}
"""

@Suite("Yahoo fundamentals")
struct YahooFundamentalsTests {

    @Test("A profile is read from the three summary modules")
    func profile() throws {
        let parsed = try YahooFundamentalsProvider.parseSummary(Data(summaryJSON.utf8))
        #expect(parsed.profile.sector == "Financial Services")
        #expect(parsed.profile.employees == 4321)
        #expect(parsed.profile.marketCap == dec("1000000"))
        #expect(parsed.profile.sharesOutstanding == dec("50000"))
        #expect(parsed.profile.currencyCode == "AUD")
        #expect((parsed.profile.dividendYield ?? 0) > 0.039)
        #expect(!parsed.profile.isFixedIncome, "a share is not a bond")
    }

    @Test("An empty figure object is absent, never zero")
    func emptyFiguresAreAbsent() throws {
        // Yahoo sends `{}` for a line it does not report. Recording that as 0
        // states a fact nobody has — "this bank's gross profit was nothing".
        let parsed = try YahooFundamentalsProvider.parseSummary(Data(summaryJSON.utf8))
        let latest = parsed.periods.first { $0.statement == .income }
        #expect(latest?.lines["totalRevenue"] == dec("900"))
        #expect(latest?.lines["ebit"] == dec("100"))
        #expect(latest?.lines["grossProfit"] == nil, "reported as {} — absent, not zero")
        #expect(latest?.lines["maxAge"] == nil, "not a financial line")
        #expect(latest?.lines["endDate"] == nil, "the period, not a line")
    }

    @Test("Periods come back newest first")
    func periodOrder() throws {
        let parsed = try YahooFundamentalsProvider.parseSummary(Data(summaryJSON.utf8))
        let income = parsed.periods.filter { $0.statement == .income }
        #expect(income.count == 2)
        #expect(income[0].endDate > income[1].endDate)
    }

    @Test("Dividends and splits are read from the chart's events")
    func events() throws {
        let parsed = try YahooFundamentalsProvider.parseEvents(Data(eventsJSON.utf8))
        #expect(parsed.dividends.count == 2)
        #expect(parsed.dividends[0].date < parsed.dividends[1].date, "oldest first")
        #expect(parsed.dividends.last?.amount == dec("2.35"))
        #expect(parsed.splits.count == 1)
        #expect(parsed.splits[0].ratio == 2)
    }

    @Test("A split with a zero denominator is dropped rather than dividing by it")
    func degenerateSplit() throws {
        let json = """
        {"chart":{"result":[{"events":{"splits":{"1":{"date":1,"numerator":2,"denominator":0}}}}]}}
        """
        #expect(try YahooFundamentalsProvider.parseEvents(Data(json.utf8)).splits.isEmpty)
    }

    @Test("A provider error is surfaced, not swallowed as no data")
    func providerError() {
        let json = #"{"quoteSummary":{"result":null,"error":{"code":"Unauthorized","description":"Invalid Crumb"}}}"#
        #expect(throws: QuoteError.providerError("Invalid Crumb")) {
            try YahooFundamentalsProvider.parseSummary(Data(json.utf8))
        }
    }

    @Test("A non-Yahoo body is malformed rather than empty")
    func malformed() {
        #expect(throws: QuoteError.malformedResponse("not a Yahoo quoteSummary response")) {
            try YahooFundamentalsProvider.parseSummary(Data("<html>nope</html>".utf8))
        }
    }

    @Test("Dividends are fetched without a crumb, and one bad section keeps the other")
    func dividendsSurviveAFailedSummary() async throws {
        // The measured shape of the world: the chart endpoint needs no
        // handshake, `quoteSummary` does. A refused crumb must not lose the
        // dividend list that came back fine.
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/", body: eventsJSON)
        http.on("getcrumb", body: "Too Many Requests")
        http.on("fc.yahoo.com", body: "")

        let result = try await YahooFundamentalsProvider(http: http)
            .fundamentals(symbol: "XYZ.AX", kinds: Set(FundamentalsKind.allCases))
        #expect(result.dividends?.value.count == 2)
        #expect(result.profile == nil, "the summary was refused")
        #expect(result.splits?.value.count == 1)
    }
}

// MARK: - The crumb handshake

@Suite("Yahoo crumb")
struct YahooCrumbTests {

    @Test("A crumb is fetched once and reused")
    func cached() async throws {
        let http = StubHTTPClient()
        http.on("fc.yahoo.com", body: "")
        http.on("getcrumb", body: "abc123XYZ")
        let store = YahooCrumbStore()

        #expect(try await store.value(using: http) == "abc123XYZ")
        #expect(try await store.value(using: http) == "abc123XYZ")
        // Two calls, one handshake: fc.yahoo.com + getcrumb, not four requests.
        #expect(http.requestedURLs.count == 2)
    }

    @Test("Prose in the body is refused, because Yahoo answers 200 with it")
    func proseIsNotACrumb() async throws {
        // The failure modes all arrive as 200 with words in the body, so the
        // shape is the test. "Too Many Requests" really means "you skipped the
        // cookie step", which is why the message says so.
        let http = StubHTTPClient()
        http.on("fc.yahoo.com", body: "")
        http.on("getcrumb", body: "Too Many Requests")
        await #expect(throws: QuoteError.self) {
            try await YahooCrumbStore().value(using: http)
        }
    }

    @Test("An expired crumb is refetched after its lifetime")
    func expiry() async throws {
        let http = StubHTTPClient()
        http.on("fc.yahoo.com", body: "")
        http.on("getcrumb", body: "first")
        let store = YahooCrumbStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(try await store.value(using: http, now: start) == "first")
        #expect(http.requestedURLs.count == 2)
        _ = try await store.value(using: http, now: start.addingTimeInterval(7200))
        #expect(http.requestedURLs.count == 4, "past its lifetime, the handshake repeats")
    }
}

// MARK: - The bond's own profile

@Suite("FIIG bond profile")
struct FIIGProfileTests {

    private let indexJSON = """
    {"data":[{"isin":"AU0EXAMPLE01","price":98.5,"marketRegion":"AUD",
      "companyName":"Example Issuer Ltd","companyDescription":"An invented issuer.",
      "securityDescription":"EXAMPLE-5.00%-01Jan30","coupon":"Fixed Coupon Bond",
      "couponDetail":"0.05","couponFrequency":"Semi-Annually",
      "maturityDate":"2030-01-01","callDate":null,"yield":0.0512,
      "sector":"Utilities","bondHistory":null}],"pagination":{}}
    """

    @Test("A bond's profile comes from the same response as its price")
    func bondProfile() async throws {
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let result = try await FIIGQuoteProvider(http: http)
            .fundamentals(symbol: "AU0EXAMPLE01", kinds: [.profile])
        let profile = try #require(result.profile?.value)

        #expect(profile.issuer == "Example Issuer Ltd")
        #expect(profile.couponType == "Fixed Coupon Bond")
        // `couponDetail` arrives as a **string**, which is the trap.
        #expect(profile.couponRate == dec("0.05"))
        #expect(profile.couponFrequency == "Semi-Annually")
        #expect(profile.maturityDate != nil)
        #expect(profile.callDate == nil, "this bond cannot be called")
        #expect(profile.sector == "Utilities")
        #expect(profile.isFixedIncome, "a coupon and a maturity make it a bond")
        #expect(result.profile?.source == "FIIG")
    }

    @Test("A bond issuer publishes no statements or dividends here")
    func onlyAProfile() async throws {
        // A coupon is not a dividend, and asking would return something
        // misleading rather than nothing.
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let result = try await FIIGQuoteProvider(http: http)
            .fundamentals(symbol: "AU0EXAMPLE01", kinds: [.statements, .dividends])
        #expect(result.isEmpty)
        #expect(http.requestedURLs.isEmpty, "and nothing is fetched to find that out")
    }

}

// Which providers serve company data — and which are *preferred* — moved to
// `FundamentalsSelectionTests` in KeyedFundamentalsTests.swift when the three
// keyed providers were implemented. The assertion here said "only Yahoo and
// FIIG", which was true of the code and false of decision D5.
