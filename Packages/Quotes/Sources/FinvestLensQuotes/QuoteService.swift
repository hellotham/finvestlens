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

    /// Yahoo suffix → the timezone the exchange keeps its own hours in.
    ///
    /// The keys are the values of ``yahooSuffix``: the suffix is what the
    /// ticker actually carries by the time a provider sees it, so this reads
    /// the exchange straight off the symbol rather than needing the book's
    /// namespace. Only the venues already named there appear here — this adds
    /// no geography the app did not already claim to know.
    static let exchangeTimeZones: [String: String] = [
        "AX": "Australia/Sydney", "NZ": "Pacific/Auckland", "L": "Europe/London",
        "TO": "America/Toronto", "V": "America/Toronto", "HK": "Asia/Hong_Kong",
        "SI": "Asia/Singapore", "T": "Asia/Tokyo", "DE": "Europe/Berlin",
        "PA": "Europe/Paris", "AS": "Europe/Amsterdam", "SW": "Europe/Zurich",
    ]

    /// The timezone to read a bare instant's civil day in, for a provider that
    /// reports no exchange of its own.
    ///
    /// An unsuffixed ticker is a US listing by the convention every provider
    /// here uses, so it reads in New York — which matters for an after-hours
    /// quote, where 20:00 in New York is already tomorrow in UTC. An unknown
    /// suffix falls to UTC: every listed venue closes during its own daytime,
    /// so UTC lands on the right civil day for a close even when the exchange
    /// is not recognised, and unlike the reader's timezone it does not drift
    /// with who happens to be looking.
    static func exchangeTimeZone(forSymbol symbol: String) -> TimeZone {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        guard let dot = symbol.lastIndex(of: ".") else {
            return TimeZone(identifier: "America/New_York") ?? utc
        }
        let suffix = String(symbol[symbol.index(after: dot)...]).uppercased()
        return exchangeTimeZones[suffix].flatMap(TimeZone.init(identifier:)) ?? utc
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
        return try Self.price(from: quote, commodity: commodity, currency: currency, kind: kind)
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
            // A mismatch drops that one security, not the batch: the rest of
            // the index is perfectly good and losing it over one bad ticker is
            // how a whole run's worth of prices goes missing.
            out[commodity] = try? Self.price(from: quote, commodity: commodity,
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
        // History is one instrument, so a mismatch condemns the whole series:
        // half a series in the wrong currency is worse than none.
        return try quotes.map {
            try Self.price(from: $0, commodity: commodity, currency: currency, kind: kind)
        }
    }

    /// Maps a ``Quote`` to a `Price`, refusing one whose currency is not the
    /// caller's —
    /// so a USD-listed ticker fetched into an AUD book leaves a visible trace
    /// ("Finance::Quote:yahoo (USD)") instead of an unrecoverable mislabel.
    /// A quote whose currency is not the one asked for is **not** a price of
    /// this security, and must not be stored as one.
    ///
    /// This used to note the mismatch in the source string — `Finance::Quote:
    /// yahoo (USD)` — and store the provider's number against the requested
    /// currency anyway. So a USD figure was written as AUD. On the reference
    /// book that is 1,205 rows across two securities: `MG` (Mercer Growth, an
    /// Australian super option) sent to Yahoo as a bare mnemonic resolves to a
    /// US-listed namesake, and 836 of that company's USD closes were recorded
    /// as the fund's AUD unit price. Every valuation drawn through them was
    /// wrong by an exchange rate and by being a different company.
    ///
    /// The honest answer is to refuse. A mismatch means the identifier found
    /// the wrong instrument or the price needs converting, and neither is
    /// something a silent relabel can fix.
    struct CurrencyMismatch: Error, CustomStringConvertible {
        let symbol: String, reported: String, expected: String
        /// Whether `reported` came from the provider or was inferred from the
        /// security's exchange. Worth saying: an inference can be wrong in a
        /// way a provider's own answer cannot, and the person reading the
        /// message is the one who can correct the namespace.
        var inferred = false
        var description: String {
            inferred
                ? "\(symbol) trades in \(reported), not \(expected) — \(reported) is what its exchange settles in; set the security's quote symbol or currency"
                : "\(symbol) priced in \(reported), not \(expected) — check the ticker's exchange suffix"
        }
    }

    /// A provider answered, but with something that cannot be a price.
    struct ImplausibleQuote: Error, CustomStringConvertible {
        let symbol: String, reason: String
        var description: String { "\(symbol) \(reason)" }
    }

    /// What an exchange settles in, keyed by the suffix a provider spells it
    /// with — Yahoo's (`AX`, `L`, `T`), EODHD's (`AU`, `LSE`, `TSE`) and
    /// Stooq's (`au`, `uk`, `jp`) alike, because the symbol reaching this
    /// point is in whichever provider's spelling answered.
    ///
    /// This exists so the currency guard can fire on the providers that
    /// **cannot report a currency at all**. EODHD, Alpha Vantage, Finnhub and
    /// Stooq all return `currencyCode: nil`, so the mismatch check below was
    /// unreachable for four of the seven — the exact hole through which a
    /// USD close is stored as an AUD unit price.
    static let suffixCurrency: [String: String] = [
        "AX": "AUD", "AU": "AUD",
        "NZ": "NZD",
        "L": "GBP", "LSE": "GBP", "UK": "GBP",
        "TO": "CAD", "V": "CAD", "CA": "CAD",
        "HK": "HKD",
        "SI": "SGD", "SG": "SGD",
        "T": "JPY", "TSE": "JPY", "JP": "JPY",
        "DE": "EUR", "XETRA": "EUR", "PA": "EUR", "AS": "EUR", "MI": "EUR", "MC": "EUR",
        "SW": "CHF",
        "US": "USD",
    ]

    /// The currency this security's own exchange implies, or `nil` when
    /// nothing names an exchange.
    ///
    /// Two sources, in order of how much they prove. A **namespace** is an
    /// explicit statement about where the security trades, so `NASDAQ` implies
    /// USD even though its Yahoo tickers carry no suffix. A **suffix on the
    /// symbol** is nearly as good. The absence of a suffix implies nothing at
    /// all and must not be read as "US" — a managed fund, a super option or a
    /// bond carries a bare code and is not American; guessing USD for those
    /// would refuse prices that are perfectly correct.
    static func impliedCurrency(for commodity: Commodity, symbol: String) -> String? {
        if case let .security(exchange) = commodity.namespace {
            let name = exchange.uppercased()
            // A US venue's Yahoo suffix is the empty string, so it cannot come
            // through the suffix table; the namespace is what states it.
            if let suffix = yahooSuffix[name] {
                return suffix.isEmpty ? "USD" : suffixCurrency[suffix]
            }
            if let direct = suffixCurrency[name] { return direct }
        }
        let parts = symbol.trimmingCharacters(in: .whitespaces).split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return suffixCurrency[parts[1].uppercased()]
    }

    /// The one gate between a provider's answer and a stored price.
    ///
    /// Every fetch in this file — latest, batch and history — funnels through
    /// here, which is the point: the checks below were previously scattered or
    /// absent. The zero check existed in `YahooQuoteProvider.parseLatest` and
    /// nowhere else, so Yahoo's own *history* and every other provider could
    /// write a zero; the currency check could not fire on the four providers
    /// that report no currency. A rule about what may become a price belongs
    /// where all prices are made, not in one parser.
    static func price(from quote: Quote, commodity: Commodity, currency: Commodity,
                      kind: QuoteProviderKind) throws -> Price {
        // 1. A number that is not a price. Yahoo answers 200 with `0.0` for a
        //    ticker that resolves to an index stub (measured 15 Aug 2026: bare
        //    `WMX` instead of `WMX.AX`); a negative close is malformed data.
        guard quote.price > 0 else {
            throw ImplausibleQuote(symbol: quote.symbol,
                                   reason: "priced at \(quote.price) — check the ticker's exchange suffix")
        }

        // 2. A date that is not a date. Providers fall back to
        //    `Date(timeIntervalSince1970: 0)` when a response carries no
        //    timestamp, and a price dated 1970 outranks nothing but pollutes
        //    every series it lands in. A year ahead is equally impossible and
        //    would win `latestPrice` forever.
        guard quote.date > Self.earliestPlausible else {
            throw ImplausibleQuote(symbol: quote.symbol, reason: "returned no observation date")
        }
        guard quote.date < Date(timeIntervalSinceNow: 366 * 24 * 3600) else {
            throw ImplausibleQuote(symbol: quote.symbol, reason: "is dated more than a year ahead")
        }

        // 3. A price of something else. A quote whose currency is not the one
        //    asked for is not a price of this security — see the type's own
        //    note for the 1,205 rows that taught this.
        let expected = currency.mnemonic
        if let reported = quote.currencyCode?.trimmingCharacters(in: .whitespaces), !reported.isEmpty {
            guard reported.caseInsensitiveCompare(expected) == .orderedSame else {
                throw CurrencyMismatch(symbol: quote.symbol, reported: reported, expected: expected)
            }
        } else if let implied = impliedCurrency(for: commodity, symbol: quote.symbol) {
            guard implied.caseInsensitiveCompare(expected) == .orderedSame else {
                throw CurrencyMismatch(symbol: quote.symbol, reported: implied,
                                       expected: expected, inferred: true)
            }
        }

        // 4. The day it belongs to. A close is a fact about a trading day, so
        //    the instant is reduced to the civil day of the **exchange** when
        //    the provider says which one — Yahoo's 16:00 New York close is the
        //    14th in New York and 06:00 on the 15th in Sydney, and reading it
        //    in the reader's calendar dated every US close a day late.
        //    Date-only providers send no offset and are already neutral, but
        //    three — EODHD, Finnhub and Twelve Data — send a bare Unix
        //    timestamp, which is an instant with no offset at all. Reading
        //    those in `.current` dated every US close a day late for a Sydney
        //    reader, so the exchange is inferred from the symbol instead. The
        //    reader's own timezone is never the answer: it says nothing about
        //    where the security trades.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = quote.exchangeOffsetFromGMT
            .flatMap { TimeZone(secondsFromGMT: $0) }
            ?? exchangeTimeZone(forSymbol: quote.symbol)
        let day = Price.dayNeutral(quote.date, calendar: calendar)

        return Price(
            commodity: commodity,
            currency: currency,
            date: day,
            value: quote.price,
            source: "Finance::Quote:\(kind.rawValue)",
            type: "last",
            preservingTime: true
        )
    }

    /// Before this, a "date" is a provider's missing-value sentinel rather than
    /// an observation. Epoch plus a day, so a genuine 1970-01-01 in a fixture
    /// is still refused but nothing real is near the line.
    static let earliestPlausible = Date(timeIntervalSince1970: 86_400)
}
