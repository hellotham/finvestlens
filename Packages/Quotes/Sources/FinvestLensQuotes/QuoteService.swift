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
        return commodity.mnemonic
    }

    /// Fetches the latest quote and returns a `Price` of `commodity` in
    /// `currency`.
    public func latestPrice(
        for commodity: Commodity,
        in currency: Commodity,
        using kind: QuoteProviderKind,
        symbolOverride: String? = nil
    ) async throws -> Price {
        let provider = try provider(kind)
        let symbol = kind.providerSymbol(
            for: Self.lookupKey(for: commodity, override: symbolOverride, kind: kind))
        let quote = try await provider.latestQuote(symbol: symbol)
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
