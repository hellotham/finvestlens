//
//  ProviderParsingTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Yahoo provider")
struct YahooProviderTests {

    // Trimmed v8/finance/chart payload with a meta block and a 3-day close series.
    static let chartJSON = """
    {"chart":{"result":[{"meta":{"currency":"AUD","symbol":"CBA.AX",
    "regularMarketPrice":105.20,"regularMarketTime":1700000000},
    "timestamp":[1699800000,1699886400,1699972800],
    "indicators":{"quote":[{"close":[104.10,null,105.20]}]}}],"error":null}}
    """

    @Test("Latest quote parses price, currency and time")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/CBA.AX", body: Self.chartJSON)
        let quote = try await YahooQuoteProvider(http: http).latestQuote(symbol: "CBA.AX")
        #expect(quote.symbol == "CBA.AX")
        #expect(quote.currencyCode == "AUD")
        #expect(quote.price == dec("105.20"))
        #expect(quote.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The exact payload Yahoo returns for an ASX ticker sent without its
    /// `.AX` suffix, captured live on 15 Aug 2026: a 200, an NYSE **index**
    /// stub, no currency, no name — and a price of zero.
    static let zeroPriceJSON = """
    {"chart":{"result":[{"meta":{"symbol":"WMX","exchangeName":"NYS",
    "fullExchangeName":"NYSE","instrumentType":"INDEX","currency":null,
    "regularMarketPrice":0.0,"regularMarketTime":1700000000},
    "timestamp":[],"indicators":{"quote":[{"close":[]}]}}],"error":null}}
    """

    /// The parser's job is to report what Yahoo said; deciding whether that may
    /// become a price is `QuoteService`'s, and is exercised in
    /// ``QuoteGuardTests``. This pins the split: the zero still arrives intact,
    /// carrying the symbol that produced it, so the guard can name it.
    ///
    /// It used to be refused here and *only* here, which is why the identical
    /// zero from EODHD, Stooq, Alpha Vantage, Finnhub or Yahoo's own history
    /// went straight into a book.
    @Test("A zero parses, carrying the symbol that produced it")
    func zeroPriceReachesTheGuard() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: Self.zeroPriceJSON)
        let quote = try await YahooQuoteProvider(http: http).latestQuote(symbol: "WMX")
        #expect(quote.price == 0)
        #expect(quote.symbol == "WMX")
    }

    @Test("Decimal price is exact (no binary-float drift)")
    func exactDecimal() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: Self.chartJSON)
        let quote = try await YahooQuoteProvider(http: http).latestQuote(symbol: "CBA.AX")
        #expect("\(quote.price)" == "105.2")
    }

    @Test("History skips null closes and pairs timestamps")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: Self.chartJSON)
        let quotes = try await YahooQuoteProvider(http: http)
            .history(symbol: "CBA.AX", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(quotes.count == 2)
        #expect(quotes.first?.price == dec("104.10"))
        #expect(quotes.first?.date == Date(timeIntervalSince1970: 1_699_800_000))
        #expect(quotes.last?.price == dec("105.20"))
    }

    @Test("Provider error surfaces")
    func providerError() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: #"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found"}}}"#)
        await #expect(throws: QuoteError.self) {
            _ = try await YahooQuoteProvider(http: http).latestQuote(symbol: "NOPE")
        }
    }
}

@Suite("EODHD provider")
struct EODHDProviderTests {

    @Test("Real-time latest parses close and timestamp")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("/api/real-time/CBA.AU",
                body: #"{"code":"CBA.AU","timestamp":1700000000,"close":105.20}"#)
        let quote = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "CBA.AU")
        #expect(quote.price == dec("105.20"))
        #expect(quote.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Real-time NA close yields noData")
    func naClose() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"X","timestamp":"NA","close":"NA"}"#)
        await #expect(throws: QuoteError.noData) {
            _ = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "X")
        }
    }

    @Test("EOD history parses and sorts oldest-first")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("/api/eod/CBA.AU", body: """
        [{"date":"2023-11-15","close":105.20},{"date":"2023-11-13","close":104.10}]
        """)
        let quotes = try await EODHDQuoteProvider(apiKey: "K", http: http)
            .history(symbol: "CBA.AU", from: QuoteDate.date(from: "2023-11-01")!, to: QuoteDate.date(from: "2023-11-30")!)
        #expect(quotes.count == 2)
        #expect(quotes.first?.date == QuoteDate.date(from: "2023-11-13"))
        #expect(quotes.last?.price == dec("105.20"))
    }

    @Test("API key travels in the query")
    func keyInQuery() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"X","timestamp":1,"close":1.0}"#)
        _ = try await EODHDQuoteProvider(apiKey: "SECRET", http: http).latestQuote(symbol: "X")
        #expect(http.requestedURLs.first?.absoluteString.contains("api_token=SECRET") == true)
    }

    @Test("Real-time close as a JSON string parses too")
    func stringClose() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"CBA.AU","timestamp":1700000000,"close":"105.20"}"#)
        let quote = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "CBA.AU")
        #expect(quote.symbol == "CBA.AU")
        #expect(quote.price == dec("105.20"))
    }

    @Test("Real-time row without a close yields noData")
    func missingClose() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"X","timestamp":1700000000}"#)
        await #expect(throws: QuoteError.noData) {
            _ = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "X")
        }
    }

    @Test("Real-time row without a timestamp falls back to the epoch")
    func missingTimestamp() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"X","close":105.20}"#)
        let quote = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "X")
        #expect(quote.date == Date(timeIntervalSince1970: 0))
    }

    @Test("Real-time row without a code falls back to the request symbol")
    func missingCode() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"timestamp":1700000000,"close":105.20}"#)
        let quote = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "CBA.AU")
        #expect(quote.symbol == "CBA.AU")
    }

    @Test("Empty EOD history yields noData")
    func emptyHistory() async throws {
        let http = StubHTTPClient()
        http.on("/api/eod/", body: "[]")
        await #expect(throws: QuoteError.noData) {
            _ = try await EODHDQuoteProvider(apiKey: "K", http: http)
                .history(symbol: "X", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1))
        }
    }

    @Test("History rows with unparseable dates are dropped; none left is noData")
    func badHistoryDates() async throws {
        let http = StubHTTPClient()
        http.on("/api/eod/", body: #"[{"date":"15/11/2023","close":105.20}]"#)
        await #expect(throws: QuoteError.noData) {
            _ = try await EODHDQuoteProvider(apiKey: "K", http: http)
                .history(symbol: "X", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1))
        }
    }

    @Test("A non-array history body (HTML error page) throws")
    func malformedHistory() async throws {
        let http = StubHTTPClient()
        http.on("/api/eod/", body: "<html>Forbidden</html>")
        await #expect(throws: (any Error).self) {
            _ = try await EODHDQuoteProvider(apiKey: "K", http: http)
                .history(symbol: "X", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1))
        }
    }
}

@Suite("Alpha Vantage provider")
struct AlphaVantageProviderTests {

    @Test("Global quote parses string price and date")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("GLOBAL_QUOTE", body: """
        {"Global Quote":{"01. symbol":"IBM","05. price":"182.4500","07. latest trading day":"2023-11-15"}}
        """)
        let quote = try await AlphaVantageQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "IBM")
        #expect(quote.price == dec("182.45"))
        #expect(quote.date == QuoteDate.date(from: "2023-11-15"))
    }

    @Test("Time series filters to the requested window")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("TIME_SERIES_DAILY", body: """
        {"Time Series (Daily)":{
          "2023-11-15":{"4. close":"182.45"},
          "2023-11-14":{"4. close":"181.00"},
          "2023-10-01":{"4. close":"170.00"}}}
        """)
        let quotes = try await AlphaVantageQuoteProvider(apiKey: "K", http: http)
            .history(symbol: "IBM", from: QuoteDate.date(from: "2023-11-01")!, to: QuoteDate.date(from: "2023-11-30")!)
        #expect(quotes.count == 2)
        #expect(quotes.map(\.price).contains(dec("170.00")) == false)
    }

    @Test("Rate-limit note surfaces as providerError")
    func rateLimit() async throws {
        let http = StubHTTPClient()
        http.on("GLOBAL_QUOTE", body: #"{"Note":"Thank you for using Alpha Vantage! Our standard API rate limit..."}"#)
        await #expect(throws: QuoteError.self) {
            _ = try await AlphaVantageQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "IBM")
        }
    }

    @Test("An unparseable price string is malformedResponse")
    func badPrice() async throws {
        let http = StubHTTPClient()
        http.on("GLOBAL_QUOTE", body: """
        {"Global Quote":{"01. symbol":"IBM","05. price":"None","07. latest trading day":"2023-11-15"}}
        """)
        await #expect(throws: QuoteError.malformedResponse("unparseable price None")) {
            _ = try await AlphaVantageQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "IBM")
        }
    }

    @Test("A body with no Global Quote yields noData")
    func noGlobalQuote() async throws {
        let http = StubHTTPClient()
        http.on("GLOBAL_QUOTE", body: "{}")
        await #expect(throws: QuoteError.noData) {
            _ = try await AlphaVantageQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "NOPE")
        }
    }

    @Test("An invalid-key Error Message surfaces on history too")
    func historyErrorMessage() async throws {
        let http = StubHTTPClient()
        http.on("TIME_SERIES_DAILY", body: #"{"Error Message":"the parameter apikey is invalid or missing."}"#)
        await #expect(throws: QuoteError.providerError("the parameter apikey is invalid or missing.")) {
            _ = try await AlphaVantageQuoteProvider(apiKey: "BAD", http: http)
                .history(symbol: "IBM", from: QuoteDate.date(from: "2023-11-01")!, to: QuoteDate.date(from: "2023-11-30")!)
        }
    }

    @Test("A symbol-less row and an unparseable trading day use their fallbacks")
    func fallbacks() async throws {
        let http = StubHTTPClient()
        http.on("GLOBAL_QUOTE", body: """
        {"Global Quote":{"05. price":"182.4500","07. latest trading day":"pending"}}
        """)
        let quote = try await AlphaVantageQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "IBM")
        #expect(quote.symbol == "IBM")
        #expect(quote.currencyCode == nil)
        #expect(quote.date == Date(timeIntervalSince1970: 0))
    }

    @Test("A window with no surviving bars yields noData")
    func emptyWindow() async throws {
        let http = StubHTTPClient()
        http.on("TIME_SERIES_DAILY", body: """
        {"Time Series (Daily)":{"2023-10-01":{"4. close":"170.00"}}}
        """)
        await #expect(throws: QuoteError.noData) {
            _ = try await AlphaVantageQuoteProvider(apiKey: "K", http: http)
                .history(symbol: "IBM", from: QuoteDate.date(from: "2023-11-01")!, to: QuoteDate.date(from: "2023-11-30")!)
        }
    }
}

@Suite("Finnhub provider")
struct FinnhubProviderTests {

    @Test("Quote parses current and timestamp")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("/api/v1/quote", body: #"{"c":182.45,"h":183.0,"l":181.0,"o":181.5,"pc":181.0,"t":1700000000}"#)
        let quote = try await FinnhubQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "AAPL")
        #expect(quote.price == dec("182.45"))
        #expect(quote.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Zero current price (unknown symbol) yields noData")
    func unknown() async throws {
        let http = StubHTTPClient()
        http.on("quote", body: #"{"c":0,"t":0}"#)
        await #expect(throws: QuoteError.noData) {
            _ = try await FinnhubQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "NOPE")
        }
    }

    @Test("History is unsupported")
    func historyUnsupported() async throws {
        let http = StubHTTPClient()
        await #expect(throws: QuoteError.self) {
            _ = try await FinnhubQuoteProvider(apiKey: "K", http: http)
                .history(symbol: "AAPL", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1))
        }
    }

    @Test("A quote without a timestamp falls back to the epoch")
    func missingTimestamp() async throws {
        let http = StubHTTPClient()
        http.on("quote", body: #"{"c":182.45}"#)
        let quote = try await FinnhubQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "AAPL")
        #expect(quote.symbol == "AAPL")
        #expect(quote.price == dec("182.45"))
        #expect(quote.date == Date(timeIntervalSince1970: 0))
    }

    @Test("A non-JSON body throws")
    func malformed() async throws {
        let http = StubHTTPClient()
        http.on("quote", body: "You don't have access to this resource.")
        await #expect(throws: (any Error).self) {
            _ = try await FinnhubQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "AAPL")
        }
    }
}

@Suite("Alpha Vantage — unknown-symbol answer")
struct AlphaVantageEmptyQuoteTests {
    @Test("An empty Global Quote object is noData, not a decoding failure")
    func emptyGlobalQuote() async {
        let http = StubHTTPClient()
        // Alpha Vantage's documented answer for an unknown symbol.
        http.on("GLOBAL_QUOTE", body: #"{"Global Quote": {}}"#)
        await #expect(throws: QuoteError.noData) {
            _ = try await AlphaVantageQuoteProvider(apiKey: "K", http: http)
                .latestQuote(symbol: "NOPE")
        }
    }
}

@Suite("Alpha Vantage history window")
struct AlphaVantageWindowTests {

    static let seriesJSON = """
    {"Meta Data":{"2. Symbol":"IBM"},
     "Time Series (Daily)":{
       "2026-08-12":{"4. close":"100.00"},
       "2026-08-13":{"4. close":"101.00"},
       "2026-08-14":{"4. close":"102.00"}}}
    """

    @Test("The last day of the window is returned, not dropped")
    func lastDayKept() throws {
        // Bars parse to 10:59Z (the module's day-neutral instant) but the
        // window's end was built with `startOfDay` — 00:00Z — so the final
        // day was tested as `10:59 <= 00:00` and silently lost from every
        // history request ever made.
        let quotes = try AlphaVantageQuoteProvider.parseHistory(
            Data(Self.seriesJSON.utf8), fallbackSymbol: "IBM",
            from: QuoteDate.date(from: "2026-08-12")!,
            to: QuoteDate.date(from: "2026-08-14")!)
        #expect(quotes.count == 3)
        #expect(quotes.last?.price == dec("102.00"))
        #expect(quotes.last?.date == QuoteDate.date(from: "2026-08-14"))
    }

    @Test("Both edges are inclusive, and a wall-clock time on either does not shift them")
    func edgesAreInclusive() throws {
        // A caller passing "now" rather than a clean day must get the same
        // window; the comparison is by civil day.
        let from = QuoteDate.date(from: "2026-08-13")!.addingTimeInterval(6 * 3600)
        let to = QuoteDate.date(from: "2026-08-14")!.addingTimeInterval(-6 * 3600)
        let quotes = try AlphaVantageQuoteProvider.parseHistory(
            Data(Self.seriesJSON.utf8), fallbackSymbol: "IBM", from: from, to: to)
        #expect(quotes.count == 2)
        #expect(quotes.first?.date == QuoteDate.date(from: "2026-08-13"))
        #expect(quotes.last?.date == QuoteDate.date(from: "2026-08-14"))
    }

    @Test("A window that excludes everything still throws rather than returning nothing")
    func emptyWindow() {
        #expect(throws: (any Error).self) {
            try AlphaVantageQuoteProvider.parseHistory(
                Data(Self.seriesJSON.utf8), fallbackSymbol: "IBM",
                from: QuoteDate.date(from: "2026-09-01")!,
                to: QuoteDate.date(from: "2026-09-30")!)
        }
    }
}

@Suite("Exchange timezone for offset-less providers")
struct ExchangeTimeZoneTests {

    @Test("A suffixed ticker reads its own exchange's clock")
    func suffixedTickers() {
        #expect(QuoteService.exchangeTimeZone(forSymbol: "CBA.AX").identifier == "Australia/Sydney")
        #expect(QuoteService.exchangeTimeZone(forSymbol: "VOD.L").identifier == "Europe/London")
        #expect(QuoteService.exchangeTimeZone(forSymbol: "7203.T").identifier == "Asia/Tokyo")
        #expect(QuoteService.exchangeTimeZone(forSymbol: "SHOP.TO").identifier == "America/Toronto")
    }

    @Test("A bare ticker is a US listing; an unknown suffix falls to UTC")
    func bareAndUnknown() {
        #expect(QuoteService.exchangeTimeZone(forSymbol: "IBM").identifier == "America/New_York")
        // Never the reader's own zone: it says nothing about where the
        // security trades, and it dated every US close a day late in Sydney.
        #expect(QuoteService.exchangeTimeZone(forSymbol: "XYZ.ZZZ").secondsFromGMT() == 0)
    }

    @Test("A New York close keeps its own civil day whoever is reading")
    func closeKeepsItsDay() {
        // 14 Aug 2026, 16:00 America/New_York (EDT, UTC−4) = 20:00Z. In
        // Sydney that instant is 06:00 on the 15th, which is exactly the
        // day the reader's own calendar used to stamp it with.
        let close = Date(timeIntervalSince1970: 1_786_737_600)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = QuoteService.exchangeTimeZone(forSymbol: "IBM")
        let day = cal.dateComponents([.year, .month, .day], from: close)
        #expect(day.year == 2026 && day.month == 8 && day.day == 14)
    }
}
