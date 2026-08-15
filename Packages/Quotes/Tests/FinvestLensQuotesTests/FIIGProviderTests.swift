//
//  FIIGProviderTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The fixture reproduces the live response's shape and field types, measured
//  against the API on 15 Aug 2026. The ISINs and issuer names are invented —
//  a real one here would say which bonds someone holds. // synthetic
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

/// Two bonds in the response's real shape: `price` as a percentage of par,
/// `couponDetail` as a **string**, `callDate` and `bondHistory` null,
/// `marketRegion` carrying the denomination currency.
private let indexJSON = """
{"data":[
 {"isin":"AU0EXAMPLE01","georgiaId":1,"companyName":"Example Issuer Ltd",
  "companyDescription":"An invented issuer.","securityDescription":"EXAMPLE-5.00%-01Jan30",
  "coupon":"Fixed Coupon Bond","yield":0.05,"price":98.5,"maturityDate":"2030-01-01",
  "maturityYear":2030,"sector":"Utilities","url":"","couponDetail":"0.05",
  "minimumInvestment":500000,"couponFrequency":"Semi-Annually","callDate":null,
  "liquidity":"LEVEL2B","availableTo":"Wholesale Only","available":true,
  "marketRegion":"AUD","factsheetPublished":false,"bondHistory":null},
 {"isin":"US0EXAMPLE02","georgiaId":2,"companyName":"Second Example Inc",
  "companyDescription":"Also invented.","securityDescription":"EXAMPLE2-3.00%-01Jul28",
  "coupon":"Fixed Coupon Bond","yield":0.03,"price":101.25,"maturityDate":"2028-07-01",
  "maturityYear":2028,"sector":"Financials","url":"","couponDetail":"0.03",
  "minimumInvestment":200000,"couponFrequency":"Quarterly","callDate":null,
  "liquidity":"LEVEL2B","availableTo":"Wholesale Only","available":true,
  "marketRegion":"USD","factsheetPublished":false,"bondHistory":null}],
 "pagination":{"pageNo":1,"pageSize":2000,"pageCount":1,"pageRemainCount":0},
 "stats":{},"links":[]}
"""

private func bond(_ isin: String, code: String?) -> Commodity {
    Commodity(namespace: .security("BOND"), mnemonic: isin, fullName: "A bond",
              smallestFraction: 100, exchangeCode: code)
}

@Suite("FIIG provider")
struct FIIGProviderTests {

    // MARK: The conversion that makes a bond price mean anything

    /// FIIG publishes percent of par and this provider now passes it through
    /// **as published**: whether 98.5 means 98.5 or 0.985 in a book depends on
    /// what a unit of that bond is there, which only the book knows. See
    /// `AppModel.normalisedParPercent(_:from:)` — and `BondPricingTests`, where
    /// the same reference book turned out to hold both conventions at once.
    @Test("A percentage of par is passed through as published")
    func percentOfParIsDividedByOneHundred() async throws {
        // The whole point of the provider. The book stores bond prices
        // par-relative — every bond row in the reference book was exactly 1.0 —
        // and FIIG publishes 98.5 meaning 98.5% of face. Shipping 98.5 into the
        // book would value an $100,000 holding at $9.85 million.
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let quote = try await FIIGQuoteProvider(http: http).latestQuote(symbol: "AU0EXAMPLE01")
        #expect(quote.price == dec("98.5"))
    }

    @Test("The denomination currency is carried through")
    func currencyIsReported() async throws {
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let provider = FIIGQuoteProvider(http: http)
        #expect(try await provider.latestQuote(symbol: "AU0EXAMPLE01").currencyCode == "AUD")
        // `marketRegion` is the currency despite its name — 38 of the live
        // index's 702 bonds are USD and 3 GBP, so this is not hypothetical.
        #expect(try await provider.latestQuote(symbol: "US0EXAMPLE02").currencyCode == "USD")
    }

    // MARK: Batch — one request for the whole market

    @Test("Several bonds cost one request, not one each")
    func batchIsOneRequest() async throws {
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let quotes = try await FIIGQuoteProvider(http: http)
            .latestQuotes(symbols: ["AU0EXAMPLE01", "US0EXAMPLE02"])
        #expect(quotes.count == 2)
        #expect(http.requestedURLs.count == 1,
                "the index is fetched once however many bonds are asked about")
        #expect(http.requestedURLs[0].absoluteString.contains("pageSize=2000"))
    }

    @Test("An unknown ISIN is absent from a batch, not an error")
    func unknownBondDoesNotFailTheBatch() async throws {
        // A batch that threw on the first bond FIIG has never heard of would
        // lose every bond it did find.
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let quotes = try await FIIGQuoteProvider(http: http)
            .latestQuotes(symbols: ["AU0EXAMPLE01", "AU0NOTLIST99"])
        #expect(quotes.keys.sorted() == ["AU0EXAMPLE01"])
    }

    @Test("An unknown ISIN asked for on its own reports no data")
    func unknownBondSingly() async throws {
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        await #expect(throws: QuoteError.noData) {
            try await FIIGQuoteProvider(http: http).latestQuote(symbol: "AU0NOTLIST99")
        }
    }

    @Test("An ISIN pasted with a trailing space or in lower case still matches")
    func isinIsNormalised() async throws {
        // Exactly how an ISIN arrives from a statement or a broker email.
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let quotes = try await FIIGQuoteProvider(http: http)
            .latestQuotes(symbols: [" au0example01 "])
        #expect(quotes[" au0example01 "]?.price == dec("98.5"),
                "the result is keyed on what the caller asked for, matched loosely")
    }

    // MARK: History

    /// A bond FIIG's index does not carry has no id to ask history for, and
    /// saying so beats an empty series that would read as "it did not trade".
    ///
    /// This test used to assert that FIIG had **no** history at all, on the
    /// evidence that `bondHistory` is null on all 703 index records. It is —
    /// but the series lives at `/api/instruments/bonds/{georgiaId}/history`,
    /// which the index never mentions. `FIIGHistoryTests` covers the series.
    @Test("A bond outside the index has no history to fetch")
    func historyNeedsTheIndex() async throws {
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        await #expect(throws: QuoteError.self) {
            try await FIIGQuoteProvider(http: http)
                .history(symbol: "XS0000000000", from: .distantPast, to: .distantFuture)
        }
        #expect(QuoteProviderKind.fiig.supportsHistory)
    }

    @Test("The provider is keyless, batch, and matched by identifier")
    func kindDeclaresItsShape() {
        #expect(!QuoteProviderKind.fiig.requiresAPIKey)
        #expect(QuoteProviderKind.fiig.isBatch)
        #expect(QuoteProviderKind.fiig.matchesByIdentifier)
        // Every other provider takes a ticker; claiming otherwise would route
        // an ISIN to Yahoo.
        #expect(QuoteProviderKind.allCases.filter(\.matchesByIdentifier) == [.fiig])
    }

    @Test("An ISIN is passed through whole, never split on its dots")
    func providerSymbolDoesNotRewriteAnISIN() {
        // The suffix rewriting every other provider needs would corrupt an
        // identifier: `providerSymbol` splits on "." for exchange codes.
        #expect(QuoteProviderKind.fiig.providerSymbol(for: "au0example01") == "AU0EXAMPLE01")
        #expect(QuoteProviderKind.fiig.providerSymbol(for: "XS1234567890") == "XS1234567890")
    }

    // MARK: Malformed and empty responses

    @Test("A response that is not the bond index is reported as malformed")
    func malformedResponse() async throws {
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: "<html>blocked</html>")
        await #expect(throws: QuoteError.malformedResponse("not the FIIG bond index")) {
            try await FIIGQuoteProvider(http: http).latestQuote(symbol: "AU0EXAMPLE01")
        }
    }

    @Test("An empty index reports no data rather than an empty success")
    func emptyIndex() async throws {
        let http = StubHTTPClient()
        http.on("/api/instruments/bonds", body: #"{"data":[],"pagination":{}}"#)
        await #expect(throws: QuoteError.noData) {
            try await FIIGQuoteProvider(http: http).latestQuotes(symbols: ["AU0EXAMPLE01"])
        }
    }

    @Test("A bond with no price is skipped, not decoded as zero")
    func nullPriceIsSkipped() async throws {
        let json = """
        {"data":[{"isin":"AU0EXAMPLE01","price":null,"marketRegion":"AUD"},
                 {"isin":"AU0EXAMPLE03","price":50.0,"marketRegion":"AUD"}],
         "pagination":{}}
        """
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: json)
        let quotes = try await FIIGQuoteProvider(http: http)
            .latestQuotes(symbols: ["AU0EXAMPLE01", "AU0EXAMPLE03"])
        #expect(quotes["AU0EXAMPLE01"] == nil, "a bond with no price is unpriced, not free")
        #expect(quotes["AU0EXAMPLE03"]?.price == dec("50"))
    }
}

// MARK: - Routing a commodity to the right lookup key

@Suite("Identifier routing")
struct IdentifierRoutingTests {

    @Test("A provider keyed by identifier is asked with the ISIN, not the ticker")
    func fiigGetsTheExchangeCode() {
        let held = bond("MYBOND", code: "AU0EXAMPLE01")
        #expect(QuoteService.lookupKey(for: held, kind: .fiig) == "AU0EXAMPLE01")
        // …and every other provider still gets the ticker, or it would ask
        // Yahoo about an ISIN.
        #expect(QuoteService.lookupKey(for: held, kind: .yahoo) == "MYBOND")
    }

    @Test("An explicit override wins over the identifier")
    func overrideWins() {
        // The user saying what to send outranks anything derived; second-
        // guessing it is how a per-security fix stops working.
        let held = bond("MYBOND", code: "AU0EXAMPLE01")
        #expect(QuoteService.lookupKey(for: held, override: "XS9999999999", kind: .fiig)
                == "XS9999999999")
    }

    @Test("A bond with no identifier falls back to its ticker and simply misses")
    func noIdentifierFallsBack() {
        // Honest rather than clever: FIIG will not know the mnemonic, the batch
        // omits it, and the security shows as unpriced — which is true, and is
        // fixed by typing the ISIN on its page.
        let held = bond("MYBOND", code: nil)
        #expect(QuoteService.lookupKey(for: held, kind: .fiig) == "MYBOND")
        #expect(QuoteService.lookupKey(for: bond("MYBOND", code: "   "), kind: .fiig) == "MYBOND")
    }
}

// MARK: - The service's batch path

@Suite("Batch quote service")
struct BatchQuoteServiceTests {

    @Test("Bonds are priced from one request and mapped back to their commodities")
    func batchThroughTheService() async throws {
        let http = StubHTTPClient(); http.on("/api/instruments/bonds", body: indexJSON)
        let service = QuoteService(keys: StubKeyStore(), http: http)
        let first = bond("BOND1", code: "AU0EXAMPLE01")
        let second = bond("BOND2", code: "US0EXAMPLE02")
        let missing = bond("BOND3", code: "AU0NOTLIST99")

        let prices = try await service.latestPrices(
            for: [first, second, missing], in: .aud, using: .fiig)

        #expect(prices[first]?.value == dec("98.5"))
        #expect(prices[first]?.currency == .aud)
        #expect(prices[missing] == nil)
        #expect(http.requestedURLs.count == 1)
        // A USD bond in an AUD book is **dropped**, not relabelled.
        //
        // This test used to assert the opposite — that the row was stored with
        // `source == "Finance::Quote:fiig (USD)"` — and in doing so it encoded
        // the bug: the provider's USD figure was written against AUD, and the
        // only trace was a suffix on a string nothing reads. On the reference
        // book that produced 1,205 wrong rows. A price in the wrong currency is
        // not a price of this security.
        #expect(prices[second] == nil)
        #expect(prices.count == 1)
    }

    @Test("A provider with no batch path is looped, and one failure loses only itself")
    func nonBatchProviderIsLooped() async throws {
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/GOOD", body: """
            {"chart":{"result":[{"meta":{"symbol":"GOOD","currency":"AUD",
            "regularMarketPrice":12.5,"regularMarketTime":1700000000},
            "timestamp":[],"indicators":{"quote":[{"close":[]}]}}]}}
            """)
        // BAD matches no route, so the stub throws for it.
        let service = QuoteService(keys: StubKeyStore(), http: http)
        let good = Commodity(namespace: .security("ASX"), mnemonic: "GOOD",
                             fullName: "Good", smallestFraction: 10000)
        let bad = Commodity(namespace: .security("ASX"), mnemonic: "BAD",
                            fullName: "Bad", smallestFraction: 10000)

        let prices = try await service.latestPrices(for: [good, bad], in: .aud, using: .yahoo)
        #expect(prices[good]?.value == dec("12.5"))
        #expect(prices[bad] == nil)
    }
}

/// A key store for the keyless providers under test.
private struct StubKeyStore: APIKeyStoring {
    func key(for kind: QuoteProviderKind) -> String? { nil }
    func setKey(_ key: String?, for kind: QuoteProviderKind) {}
}

/// FIIG's daily history (`FR-INV-31`).
///
/// The index's `bondHistory` is `null` on all 703 records, which this provider
/// read as "no history" until 15 Aug 2026. The series lives at a second
/// endpoint keyed by FIIG's numeric `georgiaId` — an ISIN 404s there — so a
/// history fetch is index-then-series. Payloads below are trimmed captures of
/// the live responses.
@Suite("FIIG history")
struct FIIGHistoryTests {

    static let indexJSON = """
    {"data":[
      {"isin":"AU3CB0243764","georgiaId":18,"price":99.176,"marketRegion":"AUD"},
      {"isin":"USQ66511AB43","georgiaId":27,"price":133.01,"marketRegion":"USD"}
    ]}
    """

    static let historyJSON = """
    {"data":[
      {"georgiaId":18,"isin":"","yield":0.020432772,"priceDate":"2021-10-27","priceValue":110.082},
      {"georgiaId":18,"isin":"","yield":0.021253863,"priceDate":"2021-10-28","priceValue":109.622},
      {"georgiaId":18,"isin":"","yield":0.022508066,"priceDate":"2021-10-29","priceValue":108.937}
    ]}
    """

    private func client() -> StubHTTPClient {
        let http = StubHTTPClient()
        http.on("/api/instruments/bonds?", body: Self.indexJSON)
        http.on("/api/instruments/bonds/18/history", body: Self.historyJSON)
        return http
    }

    private func day(_ text: String) -> Date {
        FIIGQuoteProvider.day.date(from: text)!
    }

    @Test("An ISIN resolves to FIIG's id and returns the daily series")
    func series() async throws {
        let quotes = try await FIIGQuoteProvider(http: client())
            .history(symbol: "AU3CB0243764", from: day("2021-01-01"), to: day("2026-12-31"))
        #expect(quotes.count == 3)
        #expect(quotes.first?.date == day("2021-10-27"))
        #expect(quotes.first?.symbol == "AU3CB0243764", "the rows carry no ISIN of their own")
        // Percent of par, as published — the book applies the unit.
        #expect(quotes.first?.price == Decimal(string: "110.082"))
        #expect(quotes.map(\.date) == quotes.map(\.date).sorted(), "ascending")
    }

    /// A window means a window: the endpoint returns five years whatever is
    /// asked, so the filtering has to happen here or every fetch would rewrite
    /// the whole series.
    @Test("The requested window is honoured")
    func window() async throws {
        let quotes = try await FIIGQuoteProvider(http: client())
            .history(symbol: "AU3CB0243764", from: day("2021-10-28"), to: day("2021-10-28"))
        #expect(quotes.count == 1)
        #expect(quotes.first?.price == Decimal(string: "109.622"))
    }

    @Test("A bond outside the index has no history to fetch")
    func unknownBond() async {
        await #expect(throws: QuoteError.self) {
            try await FIIGQuoteProvider(http: client())
                .history(symbol: "FR0014014MD4", from: .distantPast, to: .distantFuture)
        }
    }

    @Test("The kind now advertises history")
    func advertises() {
        #expect(QuoteProviderKind.fiig.supportsHistory)
    }
}
