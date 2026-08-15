//
//  QuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The quote services FinvestLens ships with (`FR-INV-03`).
public enum QuoteProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Keyless yfinance-like Yahoo Finance client.
    case yahoo
    /// EODHD — historical data incl. delisted securities (keyed).
    case eodhd
    /// Alpha Vantage (keyed).
    case alphaVantage
    /// Finnhub (keyed, latest quotes only).
    case finnhub
    /// Twelve Data — latest + daily history (keyed).
    case twelveData
    /// Stooq — keyless CSV end-of-day fallback.
    case stooq
    /// FIIG — Australian corporate bonds, matched by ISIN (`FR-INV-31`).
    case fiig

    public var id: String { rawValue }

    /// Human-readable name for settings UI.
    public var displayName: String {
        switch self {
        case .yahoo: return "Yahoo Finance"
        case .eodhd: return "EODHD"
        case .alphaVantage: return "Alpha Vantage"
        case .finnhub: return "Finnhub"
        case .twelveData: return "Twelve Data"
        case .stooq: return "Stooq"
        case .fiig: return "FIIG"
        }
    }

    /// Whether the provider needs a user-supplied API key.
    public var requiresAPIKey: Bool {
        switch self {
        case .yahoo, .stooq, .fiig: return false
        case .eodhd, .alphaVantage, .finnhub, .twelveData: return true
        }
    }

    /// Whether the provider can return historical series.
    public var supportsHistory: Bool {
        switch self {
        case .yahoo, .eodhd, .alphaVantage, .twelveData, .stooq: return true
        // FIIG serves history from a second endpoint keyed by its own numeric
        // id — `/api/instruments/bonds/{georgiaId}/history`. The `bondHistory`
        // field on the *index* is null on all 703 records, which is why this
        // said `false` until 15 Aug 2026; the list simply does not embed the
        // series. Measured: 1,181 daily rows from 2021-10-27.
        case .fiig: return true
        case .finnhub: return false
        }
    }

    /// Whether this provider identifies a security by its **identifier** — an
    /// ISIN in GnuCash's `cmdty:xcode` — rather than by a ticker.
    ///
    /// A bond has no ticker to send. FIIG's whole index is keyed by ISIN, which
    /// is also why this needs saying at all: every other provider in the list
    /// takes a symbol, so a caller that assumed one would silently ask FIIG
    /// about a mnemonic it has never heard of and report "not found" forever.
    public var matchesByIdentifier: Bool { self == .fiig }

    /// Whether this provider publishes prices as a **percentage of par**
    /// rather than as a price per unit.
    ///
    /// Bond markets quote per 100 of face value. Whether that becomes `98.345`
    /// or `0.98345` in a book depends on what a "unit" is there — $100 parcels
    /// or dollars of face — which only the book knows, so the conversion
    /// cannot happen in a provider.
    public var reportsParPercent: Bool { self == .fiig }

    /// Whether one request serves the whole market rather than one security.
    ///
    /// FIIG returns its entire index — 702 bonds, ~510 KB — in a single
    /// response, so fetching eleven bonds means one request and eleven local
    /// lookups. Asking per security would be eleven full downloads of the same
    /// payload.
    public var isBatch: Bool { self == .fiig }

    /// Where the user can obtain an API key.
    public var signupURL: URL? {
        switch self {
        // Keyless. This URL is specifically where a key is *obtained*, and the
        // settings row renders it as "Get key" — pointing a keyless provider at
        // an information page would offer the user a key they neither need nor
        // can get.
        case .yahoo, .stooq, .fiig: return nil
        case .eodhd: return URL(string: "https://eodhd.com/register")
        case .alphaVantage: return URL(string: "https://www.alphavantage.co/support/#api-key")
        case .finnhub: return URL(string: "https://finnhub.io/register")
        case .twelveData: return URL(string: "https://twelvedata.com/pricing")
        }
    }

    /// Rewrites a canonical (Yahoo-style) ticker into this provider's expected
    /// form. Commodities are stored Yahoo-style — a bare ticker for US symbols,
    /// `TICKER.EXCHANGE` elsewhere (e.g. `CBA.AX` for the ASX). Providers disagree
    /// on the exchange suffix (EODHD wants `CBA.AU`, Stooq `cba.au`), which is why
    /// a symbol that works on Yahoo returns "no data" on EODHD. A per-security
    /// override, when set, is assumed already correct and passed through.
    public func providerSymbol(for canonical: String) -> String {
        let trimmed = canonical.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        let parts = trimmed.split(separator: ".", maxSplits: 1)
        let ticker = String(parts[0])
        let suffix = parts.count > 1 ? String(parts[1]).uppercased() : nil

        switch self {
        case .yahoo, .alphaVantage, .finnhub, .twelveData:
            // Canonical is Yahoo-style; these accept it (Alpha Vantage/Finnhub/
            // Twelve Data are US-centric — use an override for odd exchanges).
            return trimmed
        case .fiig:
            // An ISIN, not a ticker: no exchange suffix to rewrite, and
            // splitting on "." would corrupt one. Upper-cased because ISINs are
            // defined upper-case and the index is matched exactly.
            return trimmed.uppercased()
        case .eodhd:
            // EODHD always exchange-qualifies, incl. US: AAPL.US, CBA.AU.
            let exchange = suffix.map { Self.eodhdExchange[$0] ?? $0 } ?? "US"
            return "\(ticker).\(exchange)"
        case .stooq:
            // Stooq is lowercase and .us / .au / .uk …
            let exchange = suffix.map { Self.stooqExchange[$0] ?? $0.lowercased() } ?? "us"
            return "\(ticker.lowercased()).\(exchange)"
        }
    }

    /// Yahoo exchange suffix → EODHD exchange code (the confident, common ones;
    /// unknown suffixes pass through unchanged).
    private static let eodhdExchange: [String: String] = [
        "AX": "AU", "NZ": "NZ", "L": "LSE", "TO": "TO", "V": "V", "HK": "HK",
        "T": "TSE", "SI": "SG", "PA": "PA", "AS": "AS", "SW": "SW", "DE": "XETRA",
    ]

    /// Yahoo exchange suffix → Stooq exchange code.
    private static let stooqExchange: [String: String] = [
        "AX": "au", "L": "uk", "TO": "ca", "HK": "hk", "T": "jp", "DE": "de",
    ]
}

/// A source of security prices — latest and (optionally) historical.
///
/// Providers are stateless value types built with an injectable ``HTTPFetching``
/// transport, so their URL construction and response parsing can be unit-tested
/// against captured fixtures without touching the network.
public protocol QuoteProvider: Sendable {
    /// Which service this is.
    var kind: QuoteProviderKind { get }

    /// The most recent quote for `symbol`.
    func latestQuote(symbol: String) async throws -> Quote

    /// Daily closes for `symbol` in `[from, to]` (inclusive), oldest first.
    func history(symbol: String, from: Date, to: Date) async throws -> [Quote]
}

/// A provider whose natural unit of work is **the whole market**, not one
/// security (`FR-INV-31`).
///
/// FIIG returns its entire bond index in one response and is then a local
/// lookup. Expressing that as `latestQuote(symbol:)` in a loop would download
/// half a megabyte once per holding; expressing it as a batch lets the caller
/// pay for one request no matter how many bonds it holds — and suits any future
/// provider with the same shape.
public protocol BatchQuoteProvider: QuoteProvider {
    /// Latest quotes for as many of `symbols` as the provider knows, keyed by
    /// the symbol asked for.
    ///
    /// Symbols the provider does not cover are **absent from the result**
    /// rather than an error: a batch that threw on the first unknown bond would
    /// lose the ten it did find.
    func latestQuotes(symbols: [String]) async throws -> [String: Quote]
}

/// Builds the shipped provider for a given kind, wiring in an API key and
/// transport. Returns `nil` when a keyed provider has no key configured.
public enum QuoteProviderFactory {
    public static func make(
        _ kind: QuoteProviderKind,
        apiKey: String? = nil,
        http: HTTPFetching = URLSessionHTTPClient()
    ) -> QuoteProvider? {
        switch kind {
        case .yahoo:
            return YahooQuoteProvider(http: http)
        case .eodhd:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return EODHDQuoteProvider(apiKey: apiKey, http: http)
        case .alphaVantage:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return AlphaVantageQuoteProvider(apiKey: apiKey, http: http)
        case .finnhub:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return FinnhubQuoteProvider(apiKey: apiKey, http: http)
        case .twelveData:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return TwelveDataQuoteProvider(apiKey: apiKey, http: http)
        case .stooq:
            return StooqQuoteProvider(http: http)
        case .fiig:
            return FIIGQuoteProvider(http: http)
        }
    }
}
