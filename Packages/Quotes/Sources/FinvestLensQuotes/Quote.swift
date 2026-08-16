//
//  Quote.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A single price observation returned by a ``QuoteProvider``.
///
/// The provider reports the price of one unit of ``symbol`` in
/// ``currencyCode`` (when the provider discloses a currency) as of ``date``.
public struct Quote: Sendable, Hashable {
    /// The provider's ticker symbol (e.g. `"CBA.AX"`, `"AAPL"`).
    public var symbol: String
    /// ISO currency code the price is expressed in, when the provider reports
    /// it. Providers such as Alpha Vantage and Finnhub omit it, leaving the
    /// caller to interpret the price in the security's own currency.
    public var currencyCode: String?
    /// Price of one unit of ``symbol``.
    public var price: Decimal
    /// The observation date/time.
    public var date: Date
    /// Seconds from GMT of the **exchange** the price was struck on, when the
    /// provider discloses it (Yahoo's `meta.gmtoffset`).
    ///
    /// A daily close belongs to the trading day of its own exchange, not of
    /// whoever is reading. Yahoo reports the close of a US session as an
    /// instant — 16:00 New York — which in Sydney is 06:00 the *next* morning,
    /// so stamping it in the reader's calendar dated every US close a day
    /// late while the same security's date-only providers dated it correctly.
    /// `nil` means the provider published a civil date rather than an instant,
    /// and ``QuoteDate`` has already put it on neutral ground.
    public var exchangeOffsetFromGMT: Int?

    public init(symbol: String, currencyCode: String? = nil, price: Decimal, date: Date,
                exchangeOffsetFromGMT: Int? = nil) {
        self.symbol = symbol
        self.currencyCode = currencyCode
        self.price = price
        self.date = date
        self.exchangeOffsetFromGMT = exchangeOffsetFromGMT
    }
}

/// Errors surfaced by the quote layer.
public enum QuoteError: Error, Equatable, Sendable {
    /// The provider requires an API key that has not been configured.
    case missingAPIKey(QuoteProviderKind)
    /// The provider does not support the requested operation (e.g. history).
    case unsupported(String)
    /// The HTTP request failed with a non-2xx status.
    case httpStatus(Int)
    /// The response body could not be parsed into quotes.
    case malformedResponse(String)
    /// The provider reported an error for the symbol (e.g. not found).
    case providerError(String)
    /// No data was returned for the symbol/date range.
    case noData
}
