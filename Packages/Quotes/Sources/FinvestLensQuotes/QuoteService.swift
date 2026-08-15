//
//  QuoteService.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Bridges ``QuoteProvider`` results into engine ``Price`` records.
///
/// The service resolves an API key (for keyed providers), fetches latest or
/// historical quotes, and maps each ``Quote`` to a `Price` denominated in the
/// caller-supplied currency — defaulting to the security's own currency when
/// the provider does not report one (Alpha Vantage, Finnhub).
public struct QuoteService: Sendable {
    private let keys: APIKeyStoring
    private let http: HTTPFetching

    public init(keys: APIKeyStoring, http: HTTPFetching = URLSessionHTTPClient()) {
        self.keys = keys
        self.http = http
    }

    /// Builds the provider for `kind`, throwing if a keyed provider lacks a key.
    public func provider(_ kind: QuoteProviderKind) throws -> QuoteProvider {
        let key = kind.requiresAPIKey ? keys.key(for: kind) : nil
        if kind.requiresAPIKey, (key ?? "").isEmpty {
            throw QuoteError.missingAPIKey(kind)
        }
        guard let provider = QuoteProviderFactory.make(kind, apiKey: key, http: http) else {
            throw QuoteError.missingAPIKey(kind)
        }
        return provider
    }

    /// The provider ticker for `commodity`: an explicit override, else its
    /// mnemonic.
    public static func symbol(for commodity: Commodity, override: String? = nil) -> String {
        if let override, !override.isEmpty { return override }
        return commodity.mnemonic
    }

    /// What `kind` should be asked about `commodity`.
    ///
    /// Most providers want a ticker. A provider that
    /// ``QuoteProviderKind/matchesByIdentifier`` — FIIG, keyed by ISIN — wants
    /// GnuCash's `cmdty:xcode` instead, because a corporate bond has no ticker
    /// to send and its mnemonic means nothing to the index.
    ///
    /// An explicit override still wins in both cases: it is the user saying
    /// what to send, and second-guessing that is how a per-security fix stops
    /// working.
    public static func lookupKey(for commodity: Commodity, override: String? = nil,
                                 kind: QuoteProviderKind) -> String {
        if let override, !override.isEmpty { return override }
        if kind.matchesByIdentifier, let code = commodity.exchangeCode,
           !code.trimmingCharacters(in: .whitespaces).isEmpty {
            return code
        }
        return canonicalTicker(for: commodity)
    }

    /// The commodity's ticker in canonical (Yahoo) form, with its exchange
    /// suffix supplied from the namespace when the mnemonic lacks one.
    ///
    /// GnuCash puts the exchange in the **namespace** (`ASX`, `NASDAQ`) and the
    /// bare ticker in the mnemonic, while every provider here expects the
    /// Yahoo spelling `WMX.AX`. Books that came through GnuCash's own quote
    /// setup carry the suffix in the mnemonic already (`BHP.AX`) and are left
    /// exactly as they are; ones added by hand, or by an importer that kept
    /// GnuCash's split, were sent bare.
    ///
    /// Measured on 15 Aug 2026: `WMX` returns an NYSE **index** stub priced at
    /// zero, `WMX.AX` returns WAM Income Maximiser on the ASX at 1.685. The
    /// request succeeded either way, which is why this failed silently — 20 of
    /// one reference book's 49 ASX securities were in the bare form and none
    /// of them had ever been priced.
    ///
    /// Only namespaces that genuinely name an exchange are mapped. `Bond`,
    /// `Super` and `FIIG` describe what a security *is*, not where it trades,
    /// and inventing a suffix for those would turn a security no ticker
    /// provider can price into one it silently mis-prices.
    public static func canonicalTicker(for commodity: Commodity) -> String {
        let mnemonic = commodity.mnemonic.trimmingCharacters(in: .whitespaces)
        // Already qualified, or nothing to qualify.
        guard !mnemonic.isEmpty, !mnemonic.contains(".") else { return mnemonic }
        // Only a security namespace names an exchange; a currency never does.
        guard case let .security(exchange) = commodity.namespace else { return mnemonic }
        guard let suffix = yahooSuffix[exchange.uppercased()] else { return mnemonic }
        return suffix.isEmpty ? mnemonic : "\(mnemonic).\(suffix)"
    }

    /// Whether a lookup key has an ISIN's shape (ISO 6166): two country
    /// letters, nine alphanumerics, a check digit. Shape only — enough to say
    /// "this is not a ticker", which is all it is used for.
    static func looksLikeISIN(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.count == 12 else { return false }
        let characters = Array(trimmed)
        return characters[0...1].allSatisfy(\.isLetter)
            && characters[2...10].allSatisfy { $0.isLetter || $0.isNumber }
            && characters[11].isNumber
    }

    /// Exchange namespace → Yahoo suffix. An empty string means "US, no
    /// suffix" — recorded rather than omitted so the mapping states that those
    /// exchanges were considered and need nothing.
    static let yahooSuffix: [String: String] = [
        "ASX": "AX", "NZX": "NZ", "LSE": "L", "TSX": "TO", "TSXV": "V",
        "HKEX": "HK", "SGX": "SI", "TSE": "T", "XETRA": "DE", "EURONEXT": "PA",
        "AMS": "AS", "SIX": "SW",
        // US venues carry no suffix on Yahoo.
        "NASDAQ": "", "NYSE": "", "NYQ": "", "NMS": "", "AMEX": "", "ARCA": "",
    ]

    /// Fetches the latest quote and returns a `Price` of `commodity` in
    /// `currency`.
    public func latestPrice(
        for commodity: Commodity,
        in currency: Commodity,
        using kind: QuoteProviderKind,
        symbolOverride: String? = nil
    ) async throws -> Price {
        let provider = try provider(kind)
        let key = Self.lookupKey(for: commodity, override: symbolOverride, kind: kind)
        // An ISIN is not a ticker, and a ticker provider will not say so.
        //
        // A bond whose mnemonic is its ISIN, asked of Yahoo, returns a plain
        // "no data" indistinguishable from a delisted share or a typo — which
        // is how a BNP bond looked broken when the real answer was "this needs
        // an identifier-keyed provider". Caught before the request, because
        // the request cannot succeed and its failure is less informative than
        // this one.
        if !kind.matchesByIdentifier, symbolOverride == nil, Self.looksLikeISIN(key) {
            throw QuoteError.malformedResponse(
                "\(key) is an ISIN — \(kind.rawValue) is keyed by ticker. Choose an identifier-keyed provider for this security, or set its quote symbol.")
        }
        let quote = try await provider.latestQuote(symbol: kind.providerSymbol(for: key))
        return Self.price(from: quote, commodity: commodity, currency: currency, kind: kind)
    }

    /// Latest prices for several commodities in **one** provider request, where
    /// the provider supports it (`FR-INV-31`).
    ///
    /// Commodities the provider does not cover are simply absent from the
    /// result: a bond that is not in FIIG's index is not an error, it is a bond
    /// FIIG does not price, and failing the whole run over it would lose the
    /// ten it does.
    ///
    /// Providers without a batch path are served by looping — the call site
    /// then does not have to know which kind it is holding. That loop is a real
    /// request per security, so it is only worth calling this way for a small
    /// set; the app's own bulk fetch has its own per-security progress
    /// reporting and stays on ``latestPrice(for:in:using:symbolOverride:)``.
    public func latestPrices(
        for commodities: [Commodity],
        in currency: Commodity,
        using kind: QuoteProviderKind,
        symbolOverrides: [Commodity: String] = [:]
    ) async throws -> [Commodity: Price] {
        guard !commodities.isEmpty else { return [:] }
        let provider = try provider(kind)

        guard let batch = provider as? BatchQuoteProvider else {
            var out: [Commodity: Price] = [:]
            for commodity in commodities {
                // One failure must not lose the rest, matching the batch path's
                // contract — the caller cannot tell which shape it got.
                if let price = try? await latestPrice(
                    for: commodity, in: currency, using: kind,
                    symbolOverride: symbolOverrides[commodity]) {
                    out[commodity] = price
                }
            }
            return out
        }

        // The key each commodity was asked under, so the response can be routed
        // back. Two commodities can share a key only if the book holds the same
        // identifier twice, which is already a data error; last one wins and
        // neither is silently mispriced, because the price they would get is
        // the same.
        var keys: [Commodity: String] = [:]
        for commodity in commodities {
            keys[commodity] = kind.providerSymbol(
                for: Self.lookupKey(for: commodity, override: symbolOverrides[commodity], kind: kind))
        }
        let quotes = try await batch.latestQuotes(symbols: Array(Set(keys.values)))

        var out: [Commodity: Price] = [:]
        for (commodity, key) in keys {
            guard let quote = quotes[key] else { continue }
            out[commodity] = Self.price(from: quote, commodity: commodity,
                                        currency: currency, kind: kind)
        }
        return out
    }

    /// Fetches daily history and returns one `Price` per observation.
    public func historicalPrices(
        for commodity: Commodity,
        in currency: Commodity,
        from: Date,
        to: Date,
        using kind: QuoteProviderKind,
        symbolOverride: String? = nil
    ) async throws -> [Price] {
        let provider = try provider(kind)
        let symbol = kind.providerSymbol(
            for: Self.lookupKey(for: commodity, override: symbolOverride, kind: kind))
        let quotes = try await provider.history(symbol: symbol, from: from, to: to)
        return quotes.map { Self.price(from: $0, commodity: commodity, currency: currency, kind: kind) }
    }

    /// Maps a ``Quote`` to a `Price`. The provider-reported currency, if any, is
    /// carried in the price `source` for provenance but does not override the
    /// caller's `currency` (multi-currency FX valuation is a higher layer) —
    /// so a USD-listed ticker fetched into an AUD book leaves a visible trace
    /// ("Finance::Quote:yahoo (USD)") instead of an unrecoverable mislabel.
    static func price(from quote: Quote, commodity: Commodity, currency: Commodity, kind: QuoteProviderKind) -> Price {
        var source = "Finance::Quote:\(kind.rawValue)"
        if let reported = quote.currencyCode, !reported.isEmpty,
           reported.caseInsensitiveCompare(currency.mnemonic) != .orderedSame {
            source += " (\(reported))"
        }
        return Price(
            commodity: commodity,
            currency: currency,
            date: quote.date,
            value: quote.price,
            source: source,
            type: "last"
        )
    }
}
