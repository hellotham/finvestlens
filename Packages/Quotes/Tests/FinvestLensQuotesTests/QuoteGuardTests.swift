//
//  QuoteGuardTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensQuotes

/// The one gate between a provider's answer and a stored price.
///
/// These test `QuoteService.price(from:commodity:currency:kind:)` directly and
/// **not** any one provider, because that is the whole point of the fix: the
/// zero check lived in `YahooQuoteProvider.parseLatest` and nowhere else, and
/// the currency check could not fire at all on the four providers that report
/// no currency. Both are properties of "may this become a price", so they are
/// tested where all prices are made.
@Suite("Quote guard")
struct QuoteGuardTests {

    private let asx = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "Commonwealth Bank", smallestFraction: 10000)
    private let nasdaq = Commodity(namespace: .security("NASDAQ"), mnemonic: "AAPL",
                                   fullName: "Apple", smallestFraction: 10000)
    /// A namespace that names no exchange — a super option, a managed fund, a
    /// bond. Nothing about it implies a currency and nothing may be inferred.
    private let opaque = Commodity(namespace: .security("Super"), mnemonic: "MG",
                                   fullName: "Mercer Growth", smallestFraction: 10000)

    private func made(_ quote: Quote, _ commodity: Commodity, _ currency: Commodity = .aud,
                      _ kind: QuoteProviderKind = .yahoo) throws -> Price {
        try QuoteService.price(from: quote, commodity: commodity, currency: currency, kind: kind)
    }

    private func now() -> Date { Date(timeIntervalSince1970: 1_755_000_000) }

    // MARK: Magnitude

    @Test("A zero is refused for every provider, not just Yahoo",
          arguments: QuoteProviderKind.allCases)
    func zeroRefusedEverywhere(kind: QuoteProviderKind) throws {
        let quote = Quote(symbol: "WMX", currencyCode: "AUD", price: 0, date: now())
        #expect(throws: (any Error).self) { try made(quote, asx, .aud, kind) }
        // The message names the symbol, so the cause is findable in a run of 30.
        do {
            _ = try made(quote, asx, .aud, kind)
            Issue.record("expected a throw")
        } catch {
            #expect("\(error)".contains("WMX"))
        }
    }

    @Test("A negative close is refused")
    func negativeRefused() throws {
        let quote = Quote(symbol: "CBA.AX", currencyCode: "AUD", price: -3, date: now())
        #expect(throws: (any Error).self) { try made(quote, asx) }
    }

    // MARK: Date

    @Test("The epoch-0 fallback date is refused")
    func epochRefused() throws {
        // Providers stamp this when a response carries no timestamp; a price
        // dated 1970 pollutes every series it lands in.
        let quote = Quote(symbol: "CBA.AX", currencyCode: "AUD", price: 105,
                          date: Date(timeIntervalSince1970: 0))
        #expect(throws: (any Error).self) { try made(quote, asx) }
    }

    @Test("A date more than a year ahead is refused")
    func futureRefused() throws {
        let quote = Quote(symbol: "CBA.AX", currencyCode: "AUD", price: 105,
                          date: Date(timeIntervalSinceNow: 400 * 86_400))
        #expect(throws: (any Error).self) { try made(quote, asx) }
    }

    @Test("Today is not refused")
    func todayAccepted() throws {
        let quote = Quote(symbol: "CBA.AX", currencyCode: "AUD", price: 105, date: Date())
        #expect(try made(quote, asx).value == 105)
    }

    // MARK: Currency

    @Test("A reported currency that is not the one asked for is refused")
    func reportedMismatchRefused() throws {
        let quote = Quote(symbol: "MG", currencyCode: "USD", price: 41.2, date: now())
        #expect(throws: (any Error).self) { try made(quote, opaque, .aud) }
    }

    /// The hole that wrote 1,205 rows. EODHD, Alpha Vantage, Finnhub and Stooq
    /// all answer `currencyCode: nil`, so the mismatch check above could never
    /// run for them — a US close was stored as an AUD unit price with nothing
    /// to say so. The security's own exchange is the evidence they do not give.
    @Test("A currency-blind provider is still caught by the security's exchange")
    func inferredMismatchRefused() throws {
        let quote = Quote(symbol: "AAPL", currencyCode: nil, price: 230, date: now())
        #expect(throws: (any Error).self) { try made(quote, nasdaq, .aud, .eodhd) }
    }

    @Test("An exchange suffix on the symbol is evidence too")
    func inferredFromSuffix() throws {
        // Stooq's own spelling, and no namespace to go on.
        let quote = Quote(symbol: "cba.au", currencyCode: nil, price: 105, date: now())
        #expect(throws: (any Error).self) { try made(quote, opaque, .usd, .stooq) }
    }

    /// The other half of the rule, and the one that keeps it safe to ship: a
    /// bare code implies nothing. Reading "no suffix" as "American" would
    /// refuse every correctly-priced managed fund, super option and bond.
    @Test("A bare mnemonic implies no currency and is not refused")
    func bareMnemonicAccepted() throws {
        let quote = Quote(symbol: "MG", currencyCode: nil, price: 41.2, date: now())
        #expect(try made(quote, opaque, .aud, .eodhd).value == 41.2)
    }

    @Test("A matching exchange currency passes")
    func matchingExchangeAccepted() throws {
        let quote = Quote(symbol: "CBA.AX", currencyCode: nil, price: 105, date: now())
        #expect(try made(quote, asx, .aud, .stooq).value == 105)
    }

    // MARK: The trading day

    /// A US close is 16:00 New York. Read in Sydney that is 06:00 the next
    /// morning, which dated every US close a day late for an Australian book
    /// while the same security's date-only providers dated it correctly.
    @Test("An instant is dated by the exchange's day, not the reader's")
    func exchangeDayWins() throws {
        // 2026-08-14 20:00 UTC = 16:00 on the 14th in New York (UTC−4).
        let close = Date(timeIntervalSince1970: 1_786_478_400)
        let quote = Quote(symbol: "AAPL", currencyCode: "USD", price: 230, date: close,
                          exchangeOffsetFromGMT: -4 * 3600)
        let price = try made(quote, nasdaq, .usd)
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        let expected = Price.dayNeutral(close, calendar: newYork)
        #expect(price.date == expected)
        // And it is stored day-neutral, so no reader shifts it again.
        #expect(price.isDayNeutral)
    }

    @Test("A date-only provider's day survives any reader's calendar")
    func dateOnlyIsNeutral() throws {
        // This is the defect in the other direction: parsed at midnight UTC,
        // `2026-08-14` re-read in Los Angeles is the 13th.
        let parsed = try #require(QuoteDate.date(from: "2026-08-14"))
        let quote = Quote(symbol: "cba.au", currencyCode: nil, price: 105, date: parsed)
        let price = try made(quote, asx, .aud, .stooq)
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = TimeZone(secondsFromGMT: 10 * 3600)!
        #expect(la.dateComponents([.year, .month, .day], from: price.date).day == 14)
        #expect(sydney.dateComponents([.year, .month, .day], from: price.date).day == 14)
    }

    // MARK: The sweep's preference order

    /// The fallback sweep sorted candidates by `rawValue`, which is
    /// alphabetical and therefore put `alphaVantage`, `eodhd` and `finnhub`
    /// ahead of `yahoo` for every security — preferring exactly the providers
    /// whose answers the guard above cannot check.
    @Test("Providers that report a currency are the checkable ones")
    func currencyReportingIsAccurate() {
        for kind in QuoteProviderKind.allCases where kind.reportsCurrency {
            #expect([.yahoo, .twelveData, .fiig, .wilson].contains(kind),
                    "\(kind) claims to report a currency")
        }
    }
}
