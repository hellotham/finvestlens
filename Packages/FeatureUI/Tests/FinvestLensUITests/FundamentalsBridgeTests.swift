//
//  FundamentalsBridgeTests.swift
//  FinvestLens — FeatureUI
//
//  Phase I5 of the Investments hub: fetched company data reaches the sidecar
//  and **never the book** (decision D2, `FR-INV-35`). Figures invented.
//  // synthetic
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Synchronization
import Testing
import FinvestLensEngine
import FinvestLensQuotes
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

private let summaryJSON = """
{"quoteSummary":{"result":[{
 "assetProfile":{"sector":"Utilities","industry":"Water","country":"Australia",
   "fullTimeEmployees":42,"longBusinessSummary":"An invented issuer."},
 "summaryDetail":{"currency":"AUD","marketCap":{"raw":1000,"fmt":"1.00k"}},
 "defaultKeyStatistics":{"sharesOutstanding":{"raw":500,"fmt":"500"}}
}],"error":null}}
"""

private let eventsJSON = """
{"chart":{"result":[{"events":{"dividends":{"100":{"amount":1.5,"date":100}}}}],"error":null}}
"""

private let bondIndexJSON = """
{"data":[{"isin":"AU0EXAMPLE01","price":98.5,"marketRegion":"AUD",
  "companyName":"Example Issuer Ltd","coupon":"Fixed Coupon Bond","couponDetail":"0.05",
  "couponFrequency":"Semi-Annually","maturityDate":"2030-01-01","callDate":null,
  "yield":0.0512,"sector":"Utilities","bondHistory":null}],"pagination":{}}
"""

private let eodhdJSON = """
{"General":{"Name":"Example","Sector":"Mining","CurrencyCode":"AUD"},
 "Highlights":{"MarketCapitalization":"2000"},"SharesStats":{},"Financials":{}}
"""

/// Serves each endpoint the fundamentals path touches, and counts requests.
private final class FundamentalsHTTP: HTTPFetching, @unchecked Sendable {
    private let hits = Mutex<[String: Int]>([:])

    func data(for request: URLRequest) async throws -> Data {
        let url = request.url!.absoluteString
        func record(_ name: String) { hits.withLock { $0[name, default: 0] += 1 } }

        if url.contains("fc.yahoo.com") { record("cookie"); return Data() }
        if url.contains("getcrumb") { record("crumb"); return Data("crumb123".utf8) }
        if url.contains("quoteSummary") { record("summary"); return Data(summaryJSON.utf8) }
        if url.contains("/v8/finance/chart/") { record("chart"); return Data(eventsJSON.utf8) }
        if url.contains("instruments/bonds") { record("fiig"); return Data(bondIndexJSON.utf8) }
        if url.contains("eodhd.com/api/fundamentals") {
            record("eodhd"); return Data(eodhdJSON.utf8)
        }
        if url.contains("eodhd.com/api/div") { record("eodhd-div"); return Data("[]".utf8) }
        throw QuoteError.noData
    }

    func count(_ name: String) -> Int { hits.withLock { $0[name] ?? 0 } }
}

@MainActor
@Suite("Fundamentals bridge")
struct FundamentalsBridgeTests {

    private func model(_ http: HTTPFetching) throws -> (AppModel, URL, URL) {
        let bookURL = tempURL()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbridge-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(apiKeys: InMemoryAPIKeyStore(), quoteHTTP: http,
                             fundamentalsCache: FundamentalsCache(directory: cacheDirectory))
        try model.newDocument(at: bookURL)
        return (model, bookURL, cacheDirectory)
    }

    private func share(_ model: AppModel) -> Commodity {
        let commodity = Commodity(namespace: .security("ASX"), mnemonic: "XYZ",
                                  fullName: "Example", smallestFraction: 10000)
        _ = model.addAccount(name: "XYZ", type: .stock, commodity: commodity)
        return commodity
    }

    // MARK: The invariant this whole feature is shaped around

    @Test("Fetched company data reaches the sidecar and never the book")
    func nothingFetchedEntersTheBook() async throws {
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let commodity = share(model)

        let pricesBefore = model.book?.prices.count ?? 0
        let transactionsBefore = model.book?.transactions.count ?? 0
        let kvpBefore = model.book?.kvp.slots.count ?? 0

        await model.fetchFundamentals(for: commodity)

        // The sidecar has it…
        let cached = try #require(model.fundamentals(for: commodity))
        #expect(cached.profile?.value.sector == "Utilities")
        #expect(cached.dividends?.value.count == 1)

        // …and the book is byte-for-byte unmoved. Prices remain the only
        // fetched thing that enters a document, which is what keeps the
        // double-entry and GnuCash round-trip invariants out of this feature's
        // reach entirely.
        #expect(model.book?.prices.count == pricesBefore)
        #expect(model.book?.transactions.count == transactionsBefore)
        #expect(model.book?.kvp.slots.count == kvpBefore)
    }

    // MARK: Freshness

    @Test("A second fetch inside the TTL asks the provider nothing")
    func cachedDataIsNotRefetched() async throws {
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let commodity = share(model)

        await model.fetchFundamentals(for: commodity)
        let first = http.count("summary")
        #expect(first == 1)

        await model.fetchFundamentals(for: commodity)
        #expect(http.count("summary") == first, "everything was still fresh")

        // …unless the user asks, which must always be possible: a figure
        // somebody believes is wrong has to be re-checkable without waiting out
        // a month.
        await model.fetchFundamentals(for: commodity, force: true)
        #expect(http.count("summary") == first + 1)
    }

    @Test("The crumb handshake happens once for a run, not once per security")
    func crumbIsShared() async throws {
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let first = share(model)
        let second = Commodity(namespace: .security("ASX"), mnemonic: "ABC",
                               fullName: "Another", smallestFraction: 10000)
        _ = model.addAccount(name: "ABC", type: .stock, commodity: second)

        await model.fetchFundamentals(for: first)
        await model.fetchFundamentals(for: second)

        #expect(http.count("summary") == 2, "each security is fetched")
        #expect(http.count("crumb") == 1, "but the session token is established once")
    }

    // MARK: Routing

    @Test("A bond's profile comes from its own provider, not from Yahoo")
    func bondUsesItsOwnProvider() async throws {
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let bond = Commodity(namespace: .security("Bond"), mnemonic: "BOND1",
                             fullName: "A bond", smallestFraction: 100,
                             exchangeCode: "AU0EXAMPLE01")
        _ = model.addAccount(name: "BOND1", type: .stock, commodity: bond)
        model.setQuoteProvider(.fiig, for: bond)

        await model.fetchFundamentals(for: bond)

        let profile = try #require(model.fundamentals(for: bond)?.profile?.value)
        #expect(profile.isFixedIncome)
        #expect(profile.couponRate == Decimal(string: "0.05"))
        #expect(profile.maturityDate != nil)
        #expect(http.count("fiig") == 1)
        #expect(http.count("summary") == 0, "a bond is not looked up as a share")
    }

    @Test("A provider that serves no company data says so instead of failing")
    func providerWithoutFundamentals() async throws {
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let commodity = share(model)
        // Stooq is a CSV of closes and nothing else. Falling back to Yahoo is
        // right: the alternative is a Refetch button that can only fail.
        model.setQuoteProvider(.stooq, for: commodity)

        await model.fetchFundamentals(for: commodity)
        #expect(model.fundamentals(for: commodity)?.profile != nil)
        #expect(http.count("summary") == 1)
    }

    // MARK: Clearing

    @Test("Clearing forgets a security, and the page can fetch again")
    func clearing() async throws {
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let commodity = share(model)

        await model.fetchFundamentals(for: commodity)
        #expect(model.fundamentalsCacheSummary().securities == 1)

        model.clearFundamentals(for: commodity)
        #expect(model.fundamentals(for: commodity) == nil)

        await model.fetchFundamentals(for: commodity)
        #expect(model.fundamentals(for: commodity) != nil)

        model.clearAllFundamentals()
        #expect(model.fundamentalsCacheSummary().securities == 0)
    }

    @Test("A provider's \"nothing here\" is remembered, so it is not re-asked forever")
    func negativeAnswersAreCached() async throws {
        // The defect this prevents: the fixture serves a profile and dividends
        // but **no statements**, so the statements section stays empty — and
        // without recording the absence it stays "never fetched", so every
        // single page visit asks again. Measured before the fix: two summary
        // requests where one was expected.
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let commodity = share(model)

        await model.fetchFundamentals(for: commodity)
        let cached = try #require(model.fundamentals(for: commodity))
        #expect(cached.statements?.value.isEmpty == true, "asked, and there were none")
        #expect(!cached.needsFetch(.statements), "and that answer is now fresh")

        // A failed request records nothing, so a network blip does not suppress
        // retries for a quarter — the negative is only cached when the provider
        // actually answered.
        #expect(cached.profile?.value.sector == "Utilities")
    }

    // MARK: Decision D5 — a configured keyed provider outranks the default

    @Test("A configured keyed provider is asked before Yahoo")
    func keyedProviderIsPreferred() async throws {
        // D5's actual rule, not just its sentiment: Yahoo's `quoteSummary` is
        // an unofficial endpoint behind a rate-limited handshake, so it is the
        // right default and the wrong first choice when the user has signed up
        // to a documented API.
        let http = FundamentalsHTTP()
        let keys = InMemoryAPIKeyStore()
        try keys.setKey("a-key", for: .eodhd)
        let bookURL = tempURL()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbridge-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(apiKeys: keys, quoteHTTP: http,
                             fundamentalsCache: FundamentalsCache(directory: cacheDirectory))
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        try model.newDocument(at: bookURL)
        let commodity = share(model)

        await model.fetchFundamentals(for: commodity)

        #expect(http.count("eodhd") == 1)
        #expect(http.count("summary") == 0, "Yahoo was not asked")
        #expect(model.fundamentals(for: commodity)?.profile?.value.sector == "Mining")
        #expect(model.fundamentals(for: commodity)?.profile?.source == "EODHD")
    }

    @Test("Without a key, the keyed provider is skipped and Yahoo answers")
    func noKeyFallsBackToYahoo() async throws {
        // The same book with no key must not offer a Refetch that can only
        // fail — it quietly uses the keyless default instead.
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let commodity = share(model)

        await model.fetchFundamentals(for: commodity)
        #expect(http.count("eodhd") == 0)
        #expect(http.count("summary") == 1)
    }

    @Test("A security's own provider still outranks the keyed preference")
    func perSecurityChoiceWinsOverPreference() async throws {
        // FR-INV-22 sits above D5: a bond's profile comes from the bond
        // service whatever else is configured, because asking EODHD about an
        // ISIN-keyed corporate bond returns nothing.
        let http = FundamentalsHTTP()
        let keys = InMemoryAPIKeyStore()
        try keys.setKey("a-key", for: .eodhd)
        let bookURL = tempURL()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbridge-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(apiKeys: keys, quoteHTTP: http,
                             fundamentalsCache: FundamentalsCache(directory: cacheDirectory))
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        try model.newDocument(at: bookURL)
        let bond = Commodity(namespace: .security("Bond"), mnemonic: "BOND1",
                             fullName: "A bond", smallestFraction: 100,
                             exchangeCode: "AU0EXAMPLE01")
        _ = model.addAccount(name: "BOND1", type: .stock, commodity: bond)
        model.setQuoteProvider(.fiig, for: bond)

        await model.fetchFundamentals(for: bond)
        #expect(http.count("fiig") == 1)
        #expect(http.count("eodhd") == 0)
    }

    @Test("A revision counter changes so a fetched profile actually redraws")
    func revisionAdvances() async throws {
        // The cache is a file, not an observed object. Without this the profile
        // would sit on disk while the page kept drawing the absence of one.
        let http = FundamentalsHTTP()
        let (model, bookURL, cacheDirectory) = try model(http)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: bookURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let commodity = share(model)
        let before = model.fundamentalsRevision
        await model.fetchFundamentals(for: commodity)
        #expect(model.fundamentalsRevision != before)
    }
}
