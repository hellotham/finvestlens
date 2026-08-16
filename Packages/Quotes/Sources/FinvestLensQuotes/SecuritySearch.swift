//
//  SecuritySearch.swift
//  FinvestLens — Quotes
//
//  Looking a security up by name instead of typing its identifier
//  (`FR-INV-41`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// One candidate from a provider's symbol search.
///
/// Carries the provider's **own** symbol, exchange-suffix and all, which is the
/// whole point: a person knows "WAM Income Maximiser", not `WMX.AX`, and a
/// hand-typed `WMX` finds a New York index stub priced at zero. Two of the
/// reference book's securities were entered that way — `WMX` and `MG` — and one
/// of them recorded 836 days of a US company's closes as an Australian super
/// fund's unit price. Letting the provider spell its own identifier removes
/// that class of error at the only moment it can be removed: entry.
public struct SecuritySearchResult: Sendable, Hashable, Identifiable {
    /// The provider's symbol, e.g. `WMX.AX`.
    public let symbol: String
    /// The exchange as the provider names it, e.g. `ASX`.
    public let exchange: String
    /// The security's full name.
    public let name: String
    /// `EQUITY`, `ETF`, `MUTUALFUND`, `CRYPTOCURRENCY`… as the provider says.
    public let kind: String
    /// The currency it trades in, when the provider says.
    public let currencyCode: String?

    public var id: String { symbol }

    public init(symbol: String, exchange: String, name: String,
                kind: String, currencyCode: String? = nil) {
        self.symbol = symbol
        self.exchange = exchange
        self.name = name
        self.kind = kind
        self.currencyCode = currencyCode
    }

    /// The bare ticker, without the exchange suffix — GnuCash's mnemonic is the
    /// whole symbol, but the *namespace* wants just the exchange.
    public var ticker: String {
        symbol.split(separator: ".", maxSplits: 1).first.map(String.init) ?? symbol
    }
}

/// A provider that can find a security from a few words.
public protocol SecuritySearchProvider: Sendable {
    func searchSecurities(matching query: String) async throws -> [SecuritySearchResult]
}

extension YahooQuoteProvider: SecuritySearchProvider {

    /// Yahoo's `v1/finance/search`, which needs no key and no crumb — verified
    /// against the live endpoint on 16 Aug 2026, where "WAM Income" returned
    /// `WMX.AX` (ASX), `3RO.F` (Frankfurt) and `WMX.XA` (Cboe Australia). Three
    /// listings of one company, which is exactly why the person picks rather
    /// than the app guessing.
    public func searchSecurities(matching query: String) async throws -> [SecuritySearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        var components = URLComponents()
        components.scheme = "https"
        components.host = searchHost
        components.path = "/v1/finance/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "quotesCount", value: "12"),
            URLQueryItem(name: "newsCount", value: "0"),
        ]
        guard let url = components.url else { throw QuoteError.noData }
        let data = try await searchHTTP.get(url, headers: ["User-Agent": HTTPDefaults.userAgent])
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.quotes.compactMap { quote in
            guard let symbol = quote.symbol, !symbol.isEmpty else { return nil }
            let name = quote.longname ?? quote.shortname ?? symbol
            return SecuritySearchResult(
                symbol: symbol,
                exchange: quote.exchange ?? "",
                name: name,
                kind: quote.quoteType ?? "",
                currencyCode: nil)
        }
    }

    private struct SearchResponse: Decodable {
        struct Quote: Decodable {
            let symbol: String?
            let exchange: String?
            let shortname: String?
            let longname: String?
            let quoteType: String?
        }
        let quotes: [Quote]
    }
}
