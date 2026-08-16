//
//  KeyedFundamentalsTests.swift
//  FinvestLens — Quotes
//
//  Fixtures reproduce each provider's real response shape and field types,
//  measured against their public demo keys on 15 Aug 2026 (AAPL.US, IBM). The
//  securities are the providers' own documentation examples and say nothing
//  about anyone's holdings; the figures are trimmed and invented. // synthetic
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

// MARK: - The shared trap: numbers as text, and three spellings of "nothing"

@Suite("Keyed fundamentals parsing")
struct FundamentalsParsingTests {

    @Test("A number arrives as a string, an int, or a double — all the same figure")
    func numberForms() {
        #expect(FundamentalsParsing.number("1234.5") == dec("1234.5"))
        #expect(FundamentalsParsing.number(1234) == 1234)
        #expect(FundamentalsParsing.number(" 12.75 ") == dec("12.75"))
    }

    @Test("Each provider's way of saying nothing parses to nothing, never zero")
    func absenceIsNotZero() {
        // Alpha Vantage writes the literal "None", EODHD sends null or "-",
        // and any of them read as 0 would state a fact nobody has.
        for spelling in ["None", "-", "null", "", "   ", "n/a"] {
            #expect(FundamentalsParsing.number(spelling) == nil, "\(spelling) parsed as a number")
        }
        #expect(FundamentalsParsing.number(nil) == nil)
        #expect(FundamentalsParsing.text("None") == nil)
    }

    @Test("A double goes through its string form, keeping the decimal it was written as")
    func doubleAvoidsBinaryTail() {
        // The same binary-tail problem the reconciler fixtures document:
        // Decimal(0.1) is 0.1000000000000000055511151231257827.
        #expect(FundamentalsParsing.number(0.1) == dec("0.1"))
    }

    @Test("A period needs a date; a bag of figures belonging to no date cannot be shown")
    func periodNeedsADate() {
        #expect(FundamentalsParsing.period(["totalRevenue": "5"], statement: .income,
                                           dateKeys: ["date"]) == nil)
        let ok = FundamentalsParsing.period(["date": "2026-06-30", "totalRevenue": "5"],
                                            statement: .income, dateKeys: ["date"])
        #expect(ok?.lines["totalRevenue"] == 5)
    }

    @Test("Nested line groups are flattened rather than dropped")
    func nestedGroupsSurvive() {
        // Twelve Data nests a few groups one level down; dropping them would
        // silently lose research and development from every income statement.
        let period = FundamentalsParsing.period([
            "fiscal_date": "2026-06-30",
            "operating_expense": ["research_and_development": 100, "selling": 50],
            "sales": "900",
        ], statement: .income, dateKeys: ["fiscal_date"])
        #expect(period?.lines["operating_expense_research_and_development"] == 100)
        #expect(period?.lines["operating_expense_selling"] == 50)
        #expect(period?.lines["sales"] == 900)
    }

    @Test("Metadata fields are not financial lines")
    func metadataIsSkipped() {
        let period = FundamentalsParsing.period(
            ["date": "2026-06-30", "filing_date": "2026-08-01",
             "currency_symbol": "USD", "totalAssets": "10"],
            statement: .balance, dateKeys: ["date"],
            skip: ["filing_date", "currency_symbol"])
        #expect(period?.lines.keys.sorted() == ["totalAssets"])
    }
}

// MARK: - EODHD

@Suite("EODHD fundamentals")
struct EODHDFundamentalsTests {

    private let bundleJSON = """
    {"General":{"Code":"XYZ","Name":"Example Industries","Exchange":"ASX",
      "CurrencyCode":"AUD","CountryName":"Australia","Sector":"Utilities",
      "Industry":"Water","WebURL":"https://example.com","FullTimeEmployees":4321,
      "Description":"An invented issuer."},
     "Highlights":{"MarketCapitalization":"1000000","PERatio":"12.5",
      "DividendYield":"0.04","EBITDA":"None"},
     "SharesStats":{"SharesOutstanding":"50000"},
     "Financials":{
       "Income_Statement":{"currency_symbol":"AUD","yearly":{
         "2026-06-30":{"date":"2026-06-30","filing_date":"2026-08-01",
           "currency_symbol":"AUD","totalRevenue":"900","grossProfit":null,
           "ebit":"100"},
         "2025-06-30":{"date":"2025-06-30","totalRevenue":"800"}}},
       "Balance_Sheet":{"yearly":{
         "2026-06-30":{"date":"2026-06-30","totalAssets":"5000"}}}}}
    """

    private let dividendJSON = """
    [{"date":"2026-02-20","period":"Interim","value":0.25,"currency":"AUD"},
     {"date":"2025-08-21","period":"Final","value":0.30,"currency":"AUD"},
     {"date":"2025-02-20","period":"Interim","value":0,"currency":"AUD"}]
    """

    @Test("One request yields both the profile and all three statements")
    func bundleIsOneRequest() async throws {
        // The economy that makes EODHD the cheapest of the three: profile and
        // statements arrive together, so a full refresh is two requests
        // including dividends, against Alpha Vantage's five.
        let http = StubHTTPClient()
        http.on("/api/fundamentals/", body: bundleJSON)
        http.on("/api/div/", body: dividendJSON)

        let result = try await EODHDFundamentalsProvider(apiKey: "k", http: http)
            .fundamentals(symbol: "XYZ.AU", kinds: Set(FundamentalsKind.allCases))

        #expect(result.profile?.value.sector == "Utilities")
        #expect(result.profile?.value.employees == 4321)
        #expect(result.profile?.value.marketCap == dec("1000000"))
        #expect(result.profile?.value.currencyCode == "AUD")
        #expect((result.statements?.value.count ?? 0) == 3)
        #expect(result.dividends?.value.count == 2)
        #expect(http.requestedURLs.count == 2, "profile + statements in one; dividends in the other")
        #expect(result.profile?.source == "EODHD")
    }

    @Test("A null line is absent, and metadata is not a line")
    func nullLinesAndMetadata() throws {
        let parsed = try EODHDFundamentalsProvider.parseBundle(Data(bundleJSON.utf8))
        let latest = parsed.periods.first { $0.statement == .income }
        #expect(latest?.lines["totalRevenue"] == 900)
        #expect(latest?.lines["ebit"] == 100)
        #expect(latest?.lines["grossProfit"] == nil, "null — absent, not zero")
        #expect(latest?.lines["filing_date"] == nil)
        #expect(latest?.lines["currency_symbol"] == nil)
        // "None" in Highlights must not become a market cap of nothing either.
        #expect(parsed.profile.trailingPE == dec("12.5"))
    }

    @Test("Periods come back newest first")
    func periodOrder() throws {
        let parsed = try EODHDFundamentalsProvider.parseBundle(Data(bundleJSON.utf8))
        let income = parsed.periods.filter { $0.statement == .income }
        #expect(income.count == 2)
        #expect(income[0].endDate > income[1].endDate)
    }

    @Test("A zero dividend is not a dividend")
    func zeroDividendDropped() throws {
        let parsed = try EODHDFundamentalsProvider.parseDividends(Data(dividendJSON.utf8))
        #expect(parsed.count == 2)
        #expect(parsed[0].date < parsed[1].date, "oldest first")
        #expect(parsed.last?.amount == dec("0.25"))
    }

    @Test("The request carries the key and a ten-year dividend window")
    func urlShape() async throws {
        let http = StubHTTPClient()
        http.on("/api/div/", body: dividendJSON)
        _ = try? await EODHDFundamentalsProvider(apiKey: "SECRET", http: http)
            .fundamentals(symbol: "XYZ.AU", kinds: [.dividends])
        let url = try #require(http.requestedURLs.first?.absoluteString)
        #expect(url.contains("api_token=SECRET"))
        #expect(url.contains("from="))
    }

    @Test("A non-EODHD body is malformed rather than empty")
    func malformed() {
        #expect(throws: QuoteError.malformedResponse("not a EODHD response")) {
            try EODHDFundamentalsProvider.parseBundle(Data("<html>nope</html>".utf8))
        }
    }
}

// MARK: - Alpha Vantage

@Suite("Alpha Vantage fundamentals")
struct AlphaVantageFundamentalsTests {

    private let overviewJSON = """
    {"Symbol":"XYZ","Name":"Example Industries","Description":"An invented issuer.",
     "Sector":"TECHNOLOGY","Industry":"INFORMATION TECHNOLOGY SERVICES",
     "Country":"USA","Currency":"USD","MarketCapitalization":"1000000",
     "SharesOutstanding":"50000","PERatio":"12.5","DividendYield":"0.04",
     "Beta":"0.8","FullTimeEmployees":"None","EBITDA":"None"}
    """

    private let incomeJSON = """
    {"symbol":"XYZ","annualReports":[
      {"fiscalDateEnding":"2026-06-30","reportedCurrency":"USD",
       "totalRevenue":"900","grossProfit":"None","ebit":"100"},
      {"fiscalDateEnding":"2025-06-30","reportedCurrency":"USD",
       "totalRevenue":"800"}],"quarterlyReports":[]}
    """

    private let dividendJSON = """
    {"symbol":"XYZ","data":[
      {"ex_dividend_date":"2026-02-20","declaration_date":"2026-01-10",
       "record_date":"2026-02-21","payment_date":"2026-03-05","amount":"0.25"},
      {"ex_dividend_date":"2025-08-21","declaration_date":"None",
       "record_date":"2025-08-22","payment_date":"None","amount":"0.30"}]}
    """

    @Test("The profile parses, and \"None\" never becomes a number")
    func overview() throws {
        let profile = try AlphaVantageFundamentalsProvider.parseOverview(Data(overviewJSON.utf8))
        #expect(profile.name == "Example Industries")
        #expect(profile.marketCap == dec("1000000"))
        #expect(profile.trailingPE == dec("12.5"))
        #expect((profile.beta ?? 0) > 0.79)
        // The trap this provider is full of: a literal "None" string.
        #expect(profile.employees == nil, "\"None\" is not an employee count of zero")
        // SECTOR shouted in caps reads badly beside every other provider's.
        #expect(profile.sector == "Technology")
    }

    @Test("A spent quota is reported as the provider's own message, not as no data")
    func quotaMessage() {
        // Alpha Vantage answers a spent allowance with HTTP 200 and a `Note`.
        // Reporting that as "no data" sends the user hunting for a missing
        // company instead of waiting out their daily limit.
        let json = #"{"Note":"Thank you for using Alpha Vantage! Our standard API rate limit is 25 requests per day."}"#
        #expect(throws: QuoteError.self) {
            try AlphaVantageFundamentalsProvider.parseOverview(Data(json.utf8))
        }
        let bad = #"{"Error Message":"Invalid API call."}"#
        #expect(throws: QuoteError.providerError("Invalid API call.")) {
            try AlphaVantageFundamentalsProvider.parseOverview(Data(bad.utf8))
        }
    }

    @Test("Annual reports become periods, with \"None\" lines absent")
    func statements() throws {
        let periods = try AlphaVantageFundamentalsProvider
            .parseStatement(Data(incomeJSON.utf8), statement: .income)
        #expect(periods.count == 2)
        #expect(periods[0].lines["totalRevenue"] == 900)
        #expect(periods[0].lines["grossProfit"] == nil)
        #expect(periods[0].lines["reportedCurrency"] == nil, "not a financial line")
    }

    @Test("Dividends key off the ex-date, which every row carries")
    func dividends() throws {
        // `payment_date` can be "None" for a declared-but-unpaid dividend, so
        // keying off it would silently drop the most recent one.
        let parsed = try AlphaVantageFundamentalsProvider.parseDividends(Data(dividendJSON.utf8))
        #expect(parsed.count == 2)
        #expect(parsed.last?.amount == dec("0.25"))
    }

    @Test("A full refresh costs five requests, which is why the TTLs matter here")
    func requestCount() async throws {
        let http = StubHTTPClient()
        http.on("function=OVERVIEW", body: overviewJSON)
        http.on("function=INCOME_STATEMENT", body: incomeJSON)
        http.on("function=BALANCE_SHEET", body: #"{"annualReports":[]}"#)
        http.on("function=CASH_FLOW", body: #"{"annualReports":[]}"#)
        http.on("function=DIVIDENDS", body: dividendJSON)

        let result = try await AlphaVantageFundamentalsProvider(apiKey: "k", http: http)
            .fundamentals(symbol: "XYZ", kinds: Set(FundamentalsKind.allCases))
        #expect(result.profile != nil)
        #expect(result.statements?.value.count == 2)
        #expect(result.dividends?.value.count == 2)
        // On the free tier's 25 a day, that is five securities.
        #expect(http.requestedURLs.count == 5)
    }

    @Test("One failed statement does not lose the profile that came back")
    func partialFailureKeepsWhatWorked() async throws {
        let http = StubHTTPClient()
        http.on("function=OVERVIEW", body: overviewJSON)
        // The three statement calls and DIVIDENDS match no route and throw.
        let result = try await AlphaVantageFundamentalsProvider(apiKey: "k", http: http)
            .fundamentals(symbol: "XYZ", kinds: Set(FundamentalsKind.allCases))
        #expect(result.profile?.value.name == "Example Industries")
        #expect(result.statements == nil)
    }
}

// MARK: - Twelve Data

@Suite("Twelve Data fundamentals")
struct TwelveDataFundamentalsTests {

    private let profileJSON = """
    {"symbol":"XYZ","name":"Example Industries","exchange":"ASX",
     "sector":"Technology","industry":"Consumer Electronics","employees":150000,
     "website":"https://example.com","description":"An invented issuer.",
     "country":"Australia","CEO":"A Person"}
    """

    private let incomeJSON = """
    {"meta":{"symbol":"XYZ"},"income_statement":[
      {"fiscal_date":"2026-06-30","year":"2026","sales":"900",
       "operating_expense":{"research_and_development":100,"selling":50},
       "non_operating_interest":{"income":null,"expense":null},
       "gross_profit":"400"},
      {"fiscal_date":"2025-06-30","year":"2025","sales":"800"}]}
    """

    @Test("The profile parses from Twelve Data's flat shape")
    func profile() throws {
        let profile = try TwelveDataFundamentalsProvider.parseProfile(Data(profileJSON.utf8))
        #expect(profile.name == "Example Industries")
        #expect(profile.sector == "Technology")
        #expect(profile.employees == 150_000)
        #expect(profile.website == "https://example.com")
        #expect(!profile.isFixedIncome)
    }

    @Test("Nested line groups are flattened and null members dropped")
    func nestedStatementLines() throws {
        let periods = try TwelveDataFundamentalsProvider
            .parseStatement(Data(incomeJSON.utf8), key: "income_statement", statement: .income)
        #expect(periods.count == 2)
        let latest = periods[0]
        #expect(latest.lines["sales"] == 900)
        #expect(latest.lines["operating_expense_research_and_development"] == 100)
        #expect(latest.lines["non_operating_interest_income"] == nil, "null member dropped")
        #expect(latest.lines["year"] == nil, "not a financial line")
    }

    @Test("An error inside a 200 body is surfaced as the provider's message")
    func serviceError() {
        // Twelve Data reports a bad key as {"code":401,…,"status":"error"} with
        // HTTP 200, so the status field is the only signal.
        let json = #"{"code":401,"message":"Invalid API key","status":"error"}"#
        #expect(throws: QuoteError.providerError("Invalid API key")) {
            try TwelveDataFundamentalsProvider.parseProfile(Data(json.utf8))
        }
    }

    @Test("Dividends key off the ex-date")
    func dividends() throws {
        let json = #"{"meta":{},"dividends":[{"ex_date":"2026-08-10","amount":0.27},{"ex_date":"2026-05-10","amount":0.26}]}"#
        let parsed = try TwelveDataFundamentalsProvider.parseDividends(Data(json.utf8))
        #expect(parsed.count == 2)
        #expect(parsed[0].date < parsed[1].date, "oldest first")
    }
}

// MARK: - Which provider answers, and when (decision D5)

@Suite("Fundamentals provider selection")
struct FundamentalsSelectionTests {

    @Test("Five providers serve company data; Stooq and Finnhub say so plainly")
    func whoServes() {
        #expect(QuoteProviderKind.allCases.filter(\.servesFundamentals)
                .map(\.rawValue).sorted()
                == ["alphaVantage", "eodhd", "fiig", "twelveData", "yahoo"])
        #expect(!QuoteProviderKind.stooq.servesFundamentals)
        #expect(!QuoteProviderKind.finnhub.servesFundamentals)
        // Wilson publishes a profile on its fund pages but no parser reads it
        // yet, so it says `false` rather than offering a Refetch that fails.
        #expect(!QuoteProviderKind.wilson.servesFundamentals)
    }

    @Test("A keyed provider is preferred over the keyless default (D5)")
    func keyedIsPreferred() {
        // Yahoo is fine as a default and wrong as a first choice: it is an
        // unofficial endpoint behind a rate-limited handshake, while the keyed
        // ones are documented APIs the user signed up to.
        #expect(QuoteProviderKind.allCases.filter(\.preferredForFundamentals)
                .map(\.rawValue).sorted() == ["alphaVantage", "eodhd", "twelveData"])
        #expect(!QuoteProviderKind.yahoo.preferredForFundamentals)
        #expect(!QuoteProviderKind.fiig.preferredForFundamentals, "keyless")
    }

    @Test("A keyed provider with no key builds nothing, so no Refetch is offered that must fail")
    func keyedWithoutAKey() {
        for kind in [QuoteProviderKind.eodhd, .alphaVantage, .twelveData] {
            #expect(FundamentalsProviderFactory.make(kind, apiKey: nil,
                                                     crumbs: YahooCrumbStore()) == nil,
                    "\(kind.rawValue) built without a key")
            #expect(FundamentalsProviderFactory.make(kind, apiKey: "",
                                                     crumbs: YahooCrumbStore()) == nil)
            #expect(FundamentalsProviderFactory.make(kind, apiKey: "k",
                                                     crumbs: YahooCrumbStore())?.kind == kind)
        }
    }

    @Test("The factory and servesFundamentals never disagree")
    func factoryMatchesTheClaim() {
        // A kind that claims to serve company data but builds nothing would put
        // a Fetch button on screen with nothing behind it.
        for kind in QuoteProviderKind.allCases {
            let made = FundamentalsProviderFactory.make(kind, apiKey: "k",
                                                        crumbs: YahooCrumbStore())
            #expect((made != nil) == kind.servesFundamentals, "\(kind.rawValue)")
        }
    }
}
