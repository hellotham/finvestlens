//
//  QuoteServiceTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Quote service")
struct QuoteServiceTests {

    private let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "Commonwealth Bank", smallestFraction: 10000)

    @Test("Latest quote maps to a Price in the requested currency")
    func latestPrice() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: YahooProviderTests.chartJSON)
        let service = QuoteService(keys: InMemoryAPIKeyStore(), http: http)
        let price = try await service.latestPrice(for: cba, in: .aud, using: .yahoo, symbolOverride: "CBA.AX")
        #expect(price.commodity == cba)
        #expect(price.currency == .aud)
        #expect(price.value == dec("105.20"))
        #expect(price.source == "Finance::Quote:yahoo")
    }

    @Test("History maps to one Price per observation")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: YahooProviderTests.chartJSON)
        let service = QuoteService(keys: InMemoryAPIKeyStore(), http: http)
        let prices = try await service.historicalPrices(
            for: cba, in: .aud,
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_800_000_000),
            using: .yahoo, symbolOverride: "CBA.AX")
        #expect(prices.count == 2)
        #expect(prices.allSatisfy { $0.currency == .aud && $0.commodity == cba })
    }

    @Test("Keyed provider without a key throws missingAPIKey")
    func missingKey() async throws {
        let service = QuoteService(keys: InMemoryAPIKeyStore(), http: StubHTTPClient())
        await #expect(throws: QuoteError.missingAPIKey(.eodhd)) {
            _ = try await service.latestPrice(for: cba, in: .aud, using: .eodhd)
        }
    }

    @Test("Configured key builds an EODHD provider")
    func configuredKey() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"CBA.AU","timestamp":1700000000,"close":105.20}"#)
        let keys = InMemoryAPIKeyStore([.eodhd: "SECRET"])
        let service = QuoteService(keys: keys, http: http)
        let price = try await service.latestPrice(for: cba, in: .aud, using: .eodhd, symbolOverride: "CBA.AU")
        #expect(price.value == dec("105.20"))
        #expect(price.source == "Finance::Quote:eodhd")
    }

    @Test("Symbol defaults to the commodity mnemonic")
    func symbolDefault() {
        #expect(QuoteService.symbol(for: cba) == "CBA")
        #expect(QuoteService.symbol(for: cba, override: "CBA.AX") == "CBA.AX")
    }
}

@Suite("In-memory key store")
struct APIKeyStoreTests {

    @Test("Set, read, and clear a key")
    func roundTrip() throws {
        let store = InMemoryAPIKeyStore()
        #expect(store.key(for: .finnhub) == nil)
        try store.setKey("abc", for: .finnhub)
        #expect(store.key(for: .finnhub) == "abc")
        try store.setKey("", for: .finnhub)
        #expect(store.key(for: .finnhub) == nil)
    }

    @Test("Provider metadata is consistent")
    func metadata() {
        #expect(QuoteProviderKind.yahoo.requiresAPIKey == false)
        #expect(QuoteProviderKind.eodhd.requiresAPIKey)
        #expect(QuoteProviderKind.finnhub.supportsHistory == false)
        #expect(QuoteProviderKind.stooq.requiresAPIKey == false)
        #expect(QuoteProviderKind.twelveData.supportsHistory)
        #expect(QuoteProviderKind.fiig.requiresAPIKey == false)
        #expect(QuoteProviderKind.fiig.supportsHistory)
        #expect(QuoteProviderKind.allCases.count == 7)
    }

    @Test("Only a batch provider claims to be one, and it really implements it")
    func batchClaimsAreHonest() {
        // A kind that says `isBatch` but whose provider is not a
        // `BatchQuoteProvider` would send `latestPrices` down the loop path
        // silently — one request per bond, which is the cost this exists to
        // avoid, and nothing would report the regression.
        for kind in QuoteProviderKind.allCases {
            let provider = QuoteProviderFactory.make(kind, apiKey: "k")
            #expect((provider is BatchQuoteProvider) == kind.isBatch,
                    "\(kind.rawValue): isBatch and the provider disagree")
        }
    }

    @Test("Every kind has a display name, an id, and a signup URL iff keyed")
    func displayMetadata() {
        for kind in QuoteProviderKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(kind.id == kind.rawValue)
            #expect((kind.signupURL != nil) == kind.requiresAPIKey)
        }
    }

    @Test("The factory builds every kind, gating keyed ones on a key")
    func factoryAllKinds() {
        for kind in QuoteProviderKind.allCases {
            let keyless = QuoteProviderFactory.make(kind)
            let keyed = QuoteProviderFactory.make(kind, apiKey: "k")
            #expect(keyed?.kind == kind)
            if kind.requiresAPIKey {
                #expect(keyless == nil)
            } else {
                #expect(keyless?.kind == kind)
            }
        }
    }
}

@Suite("Provider symbol mapping")
struct ProviderSymbolTests {
    @Test("EODHD exchange-qualifies: Yahoo .AX becomes .AU, bare US becomes .US")
    func eodhd() {
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "CBA.AX") == "CBA.AU")
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "AAPL") == "AAPL.US")
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "CBA.NZ") == "CBA.NZ")
    }

    @Test("Stooq is lowercase with .au / .us")
    func stooq() {
        #expect(QuoteProviderKind.stooq.providerSymbol(for: "CBA.AX") == "cba.au")
        #expect(QuoteProviderKind.stooq.providerSymbol(for: "AAPL") == "aapl.us")
    }

    @Test("Yahoo passes the canonical symbol through unchanged")
    func yahoo() {
        #expect(QuoteProviderKind.yahoo.providerSymbol(for: "CBA.AX") == "CBA.AX")
        #expect(QuoteProviderKind.yahoo.providerSymbol(for: "AAPL") == "AAPL")
    }

    @Test("Whitespace is trimmed and empty symbols pass through")
    func trimming() {
        #expect(QuoteProviderKind.yahoo.providerSymbol(for: "  AAPL ") == "AAPL")
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "   ") == "")
        #expect(QuoteProviderKind.stooq.providerSymbol(for: "") == "")
    }

    @Test("Unknown exchange suffixes pass through (case-adjusted)")
    func unknownSuffix() {
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "ABC.XY") == "ABC.XY")
        #expect(QuoteProviderKind.stooq.providerSymbol(for: "ABC.XY") == "abc.xy")
    }
}

/// Supplying the exchange suffix a GnuCash-shaped commodity does not carry.
///
/// GnuCash keeps the exchange in the namespace and the bare ticker in the
/// mnemonic; every provider here wants Yahoo's `TICKER.EXCHANGE`. Sending the
/// bare form does not fail — Yahoo answers 200 with an index stub priced at
/// zero — so this was invisible until a security was found never to have been
/// priced at all (WMX, 15 Aug 2026).
@Suite("Canonical tickers")
struct CanonicalTickerTests {

    private func security(_ namespace: String, _ mnemonic: String) -> Commodity {
        Commodity(namespace: .security(namespace), mnemonic: mnemonic,
                  fullName: mnemonic, smallestFraction: 10_000)
    }

    @Test("An ASX namespace supplies the .AX Yahoo needs")
    func asxSuffix() {
        #expect(QuoteService.canonicalTicker(for: security("ASX", "WMX")) == "WMX.AX")
        #expect(QuoteService.canonicalTicker(for: security("ASX", "WMX")) == "WMX.AX")
    }

    /// The 29 securities that were already working must not become `BHP.AX.AX`.
    @Test("A mnemonic that already carries its suffix is untouched")
    func alreadyQualified() {
        #expect(QuoteService.canonicalTicker(for: security("ASX", "BHP.AX")) == "BHP.AX")
        #expect(QuoteService.canonicalTicker(for: security("ASX", "NABPF.AX")) == "NABPF.AX")
    }

    @Test("US venues take no suffix")
    func usVenues() {
        #expect(QuoteService.canonicalTicker(for: security("NYQ", "F")) == "F")
        #expect(QuoteService.canonicalTicker(for: security("NASDAQ", "AAPL")) == "AAPL")
    }

    /// Namespaces that say what a security *is* rather than where it trades.
    /// Inventing a suffix here would turn "no ticker provider can price this"
    /// into "a ticker provider prices it wrongly".
    @Test("Non-exchange namespaces are left alone")
    func nonExchangeNamespaces() {
        #expect(QuoteService.canonicalTicker(for: security("Bond", "FR0014014MD4"))
                == "FR0014014MD4")
        #expect(QuoteService.canonicalTicker(for: security("Super", "AUSSUPER-BAL"))
                == "AUSSUPER-BAL")
        #expect(QuoteService.canonicalTicker(for: security("FIIG", "SOMEBOND"))
                == "SOMEBOND")
    }

    /// An ISIN reaching a ticker provider is a routing mistake, and the
    /// message has to say which — "no data" from Yahoo reads as "this security
    /// is dead", which is what made a live BNP bond look broken.
    @Test("An ISIN sent to a ticker provider fails with the reason")
    func isinToTickerProvider() async {
        var bond = security("Bond", "FR0014014MD4")
        bond.exchangeCode = "FR0014014MD4"
        let service = QuoteService(keys: CanonicalKeyStore(), http: StubHTTPClient())
        await #expect(throws: QuoteError.self) {
            try await service.latestPrice(for: bond, in: .aud, using: .yahoo)
        }
        do {
            _ = try await service.latestPrice(for: bond, in: .aud, using: .yahoo)
            Issue.record("expected a throw")
        } catch {
            let text = "\(error)"
            #expect(text.contains("ISIN"))
            #expect(text.contains("FR0014014MD4"))
        }
    }

    /// The user's own override is the last word — it is how a security whose
    /// exchange this table does not know gets fixed without a code change.
    @Test("An explicit override still wins")
    func overrideWins() {
        let wmx = security("ASX", "WMX")
        #expect(QuoteService.lookupKey(for: wmx, override: "WMX.AX", kind: .yahoo) == "WMX.AX")
        #expect(QuoteService.lookupKey(for: wmx, override: nil, kind: .yahoo) == "WMX.AX")
        // And a bond still answers with its ISIN for the provider keyed on one.
        var bond = security("Bond", "BNP-7.00%-02Jun31c")
        bond.exchangeCode = "FR0014014MD4"
        #expect(QuoteService.lookupKey(for: bond, kind: .fiig) == "FR0014014MD4")
    }
}

/// Keyless: every provider these tests touch needs no key.
private struct CanonicalKeyStore: APIKeyStoring {
    func key(for kind: QuoteProviderKind) -> String? { nil }
    func setKey(_ key: String?, for kind: QuoteProviderKind) {}
}
