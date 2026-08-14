//
//  YahooFundamentalsProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Holds a Yahoo crumb for the life of a run.
///
/// `quoteSummary` is gated behind a cookie-plus-crumb handshake: a request
/// without one returns **401 "Invalid Crumb"** — measured 15 Aug 2026. The
/// handshake is two requests, so it is done once and shared rather than per
/// security; a book with thirty holdings would otherwise perform sixty
/// pointless round trips and invite the rate limiter.
///
/// An actor because it is shared state behind an `async` boundary and the
/// providers around it are `Sendable` value types.
public actor YahooCrumbStore {
    private var crumb: String?
    private var fetchedAt: Date?

    /// Crumbs are session-scoped; an hour is comfortably inside their life and
    /// short enough that an expired one is not carried all day.
    private static let lifetime: TimeInterval = 3600

    public init() {}

    /// The current crumb, performing the handshake when there is none.
    ///
    /// - Throws: ``QuoteError/providerError(_:)`` when the handshake is refused
    ///   — Yahoo answers `getcrumb` with **429** when the session has no
    ///   cookie, which reads as a rate limit but is really "you skipped step
    ///   one". The message says so, because a user seeing "too many requests"
    ///   would wait instead of retrying.
    public func value(using http: HTTPFetching, now: Date = Date()) async throws -> String {
        if let crumb, let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.lifetime {
            return crumb
        }
        // Step one: collect the session cookie. This endpoint answers 404 and
        // sets `A3` anyway, which is the whole point of calling it — verified
        // through URLSession, whose shared cookie storage then carries it.
        _ = try? await http.get(URL(string: "https://fc.yahoo.com")!,
                                headers: ["User-Agent": Self.browserAgent])

        let data = try await http.get(
            URL(string: "https://query1.finance.yahoo.com/v1/test/getcrumb")!,
            headers: ["User-Agent": Self.browserAgent, "Accept": "*/*"])
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A crumb is a short opaque token with no spaces. The failure modes all
        // arrive as 200 with prose in the body ("Too Many Requests"), so the
        // shape is the test.
        guard !token.isEmpty, token.count <= 32, !token.contains(" ") else {
            throw QuoteError.providerError(
                "Yahoo would not issue a session token for company data (got \"\(token.prefix(24))\").")
        }
        crumb = token
        fetchedAt = now
        return token
    }

    /// Discards the token, so the next call redoes the handshake.
    public func invalidate() {
        crumb = nil
        fetchedAt = nil
    }

    /// The plain agent Yahoo's price endpoints take is enough here too; the
    /// full Safari string gets bot-flagged when it arrives without a browser's
    /// cookies (`HTTPDefaults`).
    static let browserAgent = HTTPDefaults.userAgent
}

/// Company profile, financial statements, dividends and splits from Yahoo
/// (`FR-INV-17`, `FR-INV-18`, `FR-INV-19`, `FR-INV-21`).
///
/// Two endpoints with different rules, which is why this is one type and not
/// two:
///
/// - **`v10/finance/quoteSummary`** serves the profile and the statements, and
///   needs the crumb handshake above.
/// - **`v8/finance/chart?events=div|split`** serves dividends and splits, needs
///   **no** crumb, and is the same endpoint the price provider already uses.
///   Measured: 10 dividends over five years for an ASX issuer, HTTP 200.
///
/// That second point also settles `FR-INV-36`. `FR-INV-03a` claimed the Yahoo
/// provider returned "dividends, and splits"; it did not — across the whole
/// package the only matches for either word were `String.split`. Now something
/// does, and it is this, not the price provider.
public struct YahooFundamentalsProvider: FundamentalsProvider {
    public let kind: QuoteProviderKind = .yahoo
    private let http: HTTPFetching
    private let crumbs: YahooCrumbStore

    public init(http: HTTPFetching = URLSessionHTTPClient(),
                crumbs: YahooCrumbStore = YahooCrumbStore()) {
        self.http = http
        self.crumbs = crumbs
    }

    public func fundamentals(symbol: String,
                             kinds: Set<FundamentalsKind>) async throws -> SecurityFundamentals {
        var out = SecurityFundamentals()
        var failures: [Error] = []

        // Each section is fetched independently and its failure is kept rather
        // than thrown: an unavailable statements module must not lose a profile
        // that came back fine. Only a run where *everything* failed rethrows.
        if kinds.contains(.profile) || kinds.contains(.statements) {
            do {
                let crumb = try await crumbs.value(using: http)
                var modules: [String] = []
                if kinds.contains(.profile) {
                    modules += ["assetProfile", "summaryDetail", "defaultKeyStatistics"]
                }
                if kinds.contains(.statements) {
                    modules += ["incomeStatementHistory", "balanceSheetHistory",
                                "cashflowStatementHistory"]
                }
                let data = try await http.get(summaryURL(symbol: symbol, modules: modules,
                                                         crumb: crumb),
                                              headers: ["User-Agent": YahooCrumbStore.browserAgent])
                let parsed = try Self.parseSummary(data)
                if kinds.contains(.profile), !parsed.profile.isEmpty {
                    out.profile = Stamped(parsed.profile, source: Self.sourceName)
                }
                if kinds.contains(.statements), !parsed.periods.isEmpty {
                    out.statements = Stamped(parsed.periods, source: Self.sourceName)
                }
            } catch {
                // A rejected crumb is usually an expired one; drop it so the
                // next attempt redoes the handshake instead of failing forever.
                await crumbs.invalidate()
                failures.append(error)
            }
        }

        if kinds.contains(.dividends) {
            do {
                let data = try await http.get(eventsURL(symbol: symbol),
                                              headers: ["User-Agent": HTTPDefaults.userAgent])
                let events = try Self.parseEvents(data)
                out.dividends = Stamped(events.dividends, source: Self.sourceName)
                out.splits = Stamped(events.splits, source: Self.sourceName)
            } catch {
                failures.append(error)
            }
        }

        if out.isEmpty, let first = failures.first { throw first }
        return out
    }

    private static let sourceName = "Yahoo Finance"

    // MARK: URLs

    private func summaryURL(symbol: String, modules: [String], crumb: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query2.finance.yahoo.com"
        components.path = "/v10/finance/quoteSummary/" + symbol
        components.queryItems = [
            URLQueryItem(name: "modules", value: modules.joined(separator: ",")),
            URLQueryItem(name: "crumb", value: crumb),
        ]
        return components.url ?? URL(string: "https://query2.finance.yahoo.com")!
    }

    private func eventsURL(symbol: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        components.percentEncodedPath = "/v8/finance/chart/" + encoded
        components.queryItems = [
            URLQueryItem(name: "interval", value: "1d"),
            // Ten years: long enough for yield-on-cost over a real holding
            // period, short enough that the payload stays a few hundred KB.
            URLQueryItem(name: "range", value: "10y"),
            URLQueryItem(name: "events", value: "div|split"),
        ]
        return components.url ?? URL(string: "https://query1.finance.yahoo.com")!
    }

    // MARK: Parsing

    /// Yahoo wraps almost every number as `{"raw": …, "fmt": …}`, and an
    /// **empty object** where it has nothing. `raw` is the only field worth
    /// reading; the empty case must decode to `nil` rather than to zero, or a
    /// bank with no reported gross profit reports a gross profit of nothing.
    struct Figure: Decodable {
        let raw: Decimal?
        init(from decoder: any Decoder) throws {
            // A statement row is not uniform. Most values are the wrapped form,
            // but `maxAge` is a **bare integer** sitting in the same
            // dictionary — so a decoder that assumes an object throws on the
            // first row and loses the whole statement. Both shapes are
            // accepted, and anything else decodes to "no figure" rather than
            // failing the response.
            if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
                raw = try? keyed.decodeIfPresent(Decimal.self, forKey: .raw)
            } else if let single = try? decoder.singleValueContainer() {
                raw = try? single.decode(Decimal.self)
            } else {
                raw = nil
            }
        }
        enum CodingKeys: String, CodingKey { case raw }
    }

    static func parseSummary(_ data: Data) throws -> (profile: SecurityProfile,
                                                      periods: [FinancialPeriod]) {
        let response: SummaryResponse
        do {
            response = try JSONDecoder().decode(SummaryResponse.self, from: data)
        } catch {
            throw QuoteError.malformedResponse("not a Yahoo quoteSummary response")
        }
        if let error = response.quoteSummary.error {
            throw QuoteError.providerError(error.description ?? error.code)
        }
        guard let result = response.quoteSummary.result?.first else { throw QuoteError.noData }

        var profile = SecurityProfile()
        if let asset = result.assetProfile {
            profile.summary = asset.longBusinessSummary
            profile.sector = asset.sector
            profile.industry = asset.industry
            profile.country = asset.country
            profile.website = asset.website
            profile.employees = asset.fullTimeEmployees
        }
        if let detail = result.summaryDetail {
            profile.currencyCode = detail.currency
            profile.marketCap = detail.marketCap?.raw
            profile.trailingPE = detail.trailingPE?.raw
            profile.dividendYield = detail.dividendYield?.raw.map(Self.double)
            profile.beta = detail.beta?.raw.map(Self.double)
        }
        if let stats = result.defaultKeyStatistics {
            profile.sharesOutstanding = stats.sharesOutstanding?.raw
            if profile.beta == nil { profile.beta = stats.beta?.raw.map(Self.double) }
        }

        var periods: [FinancialPeriod] = []
        periods += Self.periods(result.incomeStatementHistory?.incomeStatementHistory, .income)
        periods += Self.periods(result.balanceSheetHistory?.balanceSheetStatements, .balance)
        periods += Self.periods(result.cashflowStatementHistory?.cashflowStatements, .cashflow)
        periods.sort { $0.endDate > $1.endDate }

        return (profile, periods)
    }

    private static func periods(_ rows: [[String: Figure]]?,
                                _ statement: FinancialPeriod.Statement) -> [FinancialPeriod] {
        (rows ?? []).compactMap { row in
            // `endDate` is the period; without it a column of figures belongs
            // to no date and cannot be shown.
            guard let epoch = row["endDate"]?.raw else { return nil }
            var lines: [String: Decimal] = [:]
            for (name, figure) in row where name != "endDate" && name != "maxAge" {
                // Absent, not zero: Yahoo sends `{}` for a line it does not
                // report, and recording that as 0 states a fact nobody has.
                if let value = figure.raw { lines[name] = value }
            }
            guard !lines.isEmpty else { return nil }
            return FinancialPeriod(
                statement: statement,
                endDate: Date(timeIntervalSince1970: Self.double(epoch)),
                lines: lines)
        }
    }

    static func parseEvents(_ data: Data) throws -> (dividends: [DeclaredDividend],
                                                     splits: [DeclaredSplit]) {
        let response: ChartResponse
        do {
            response = try JSONDecoder().decode(ChartResponse.self, from: data)
        } catch {
            throw QuoteError.malformedResponse("not a Yahoo chart response")
        }
        guard let result = response.chart.result?.first else { throw QuoteError.noData }

        let dividends = (result.events?.dividends ?? [:]).values
            .compactMap { event -> DeclaredDividend? in
                guard let amount = event.amount, let date = event.date else { return nil }
                return DeclaredDividend(date: Date(timeIntervalSince1970: Double(date)),
                                        amount: amount)
            }
            .sorted { $0.date < $1.date }

        let splits = (result.events?.splits ?? [:]).values
            .compactMap { event -> DeclaredSplit? in
                guard let date = event.date,
                      let numerator = event.numerator, let denominator = event.denominator,
                      denominator != 0 else { return nil }
                return DeclaredSplit(date: Date(timeIntervalSince1970: Double(date)),
                                     numerator: numerator, denominator: denominator)
            }
            .sorted { $0.date < $1.date }

        return (dividends, splits)
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private static func double(_ value: Int) -> Double { Double(value) }

    // MARK: Response shapes

    private struct SummaryResponse: Decodable {
        let quoteSummary: Wrapper
        struct Wrapper: Decodable {
            let result: [Result]?
            let error: SummaryError?
        }
        struct SummaryError: Decodable {
            let code: String
            let description: String?
        }
        struct Result: Decodable {
            let assetProfile: AssetProfile?
            let summaryDetail: SummaryDetail?
            let defaultKeyStatistics: KeyStatistics?
            let incomeStatementHistory: IncomeHistory?
            let balanceSheetHistory: BalanceHistory?
            let cashflowStatementHistory: CashflowHistory?
        }
        struct AssetProfile: Decodable {
            let longBusinessSummary: String?
            let sector: String?
            let industry: String?
            let country: String?
            let website: String?
            let fullTimeEmployees: Int?
        }
        struct SummaryDetail: Decodable {
            let currency: String?
            let marketCap: Figure?
            let trailingPE: Figure?
            let dividendYield: Figure?
            let beta: Figure?
        }
        struct KeyStatistics: Decodable {
            let sharesOutstanding: Figure?
            let beta: Figure?
        }
        struct IncomeHistory: Decodable { let incomeStatementHistory: [[String: Figure]]? }
        struct BalanceHistory: Decodable { let balanceSheetStatements: [[String: Figure]]? }
        struct CashflowHistory: Decodable { let cashflowStatements: [[String: Figure]]? }
    }

    private struct ChartResponse: Decodable {
        let chart: Chart
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable { let events: Events? }
        struct Events: Decodable {
            let dividends: [String: DividendEvent]?
            let splits: [String: SplitEvent]?
        }
        struct DividendEvent: Decodable {
            let amount: Decimal?
            let date: Int?
        }
        struct SplitEvent: Decodable {
            let date: Int?
            let numerator: Decimal?
            let denominator: Decimal?
        }
    }
}
