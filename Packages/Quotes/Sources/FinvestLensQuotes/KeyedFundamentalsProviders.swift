//
//  KeyedFundamentalsProviders.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// Company data from the three keyed providers, which decision **D5** prefers
// over Yahoo whenever a key is configured — and for a good reason: Yahoo's
// `quoteSummary` is an unofficial endpoint behind a cookie-and-crumb handshake
// that is hard rate-limited, while these are documented APIs the user has
// explicitly paid for or signed up to.
//
// All three share one trap, which is why they share a file: **their numbers
// arrive as strings**, and each has its own spelling of "no value" — Alpha
// Vantage writes the literal `"None"`, EODHD sends JSON `null`, Twelve Data
// omits the key. Parsing any of those as zero would state a fact nobody has.

/// Shared parsing for providers that send numbers as text.
enum FundamentalsParsing {

    /// A figure from a provider's string, or `nil` for anything that is not a
    /// number — including the several ways they spell "nothing".
    static func number(_ raw: Any?) -> Decimal? {
        switch raw {
        case let value as Decimal: return value
        case let value as Int: return Decimal(value)
        case let value as Double:
            // Through a string, so 0.1 stays 0.1 rather than becoming
            // 0.1000000000000000055511151231257827 — the same binary-tail
            // problem the reconciler fixtures document.
            return Decimal(string: String(value))
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // Alpha Vantage's literal "None", and EODHD's occasional "-".
            guard !trimmed.isEmpty, trimmed != "None", trimmed != "-",
                  trimmed.lowercased() != "null" else { return nil }
            return Decimal(string: trimmed)
        default: return nil
        }
    }

    /// A non-empty trimmed string, or `nil`.
    static func text(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "None" ? nil : trimmed
    }

    /// `yyyy-MM-dd`, parsed in UTC with a POSIX locale so a fiscal year-end
    /// does not shift a day for a reader east of Greenwich.
    static func day(_ raw: Any?) -> Date? {
        guard let text = text(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(text.prefix(10)))
    }

    /// One reporting period from a flat dictionary of string numbers.
    ///
    /// - Parameter dateKeys: the field naming the period — each provider spells
    ///   it differently, and a column of figures belonging to no date cannot be
    ///   shown at all.
    /// - Parameter skip: metadata fields that are not financial lines.
    static func period(_ row: [String: Any], statement: FinancialPeriod.Statement,
                       dateKeys: [String],
                       skip: Set<String> = []) -> FinancialPeriod? {
        guard let endDate = dateKeys.lazy.compactMap({ day(row[$0]) }).first else { return nil }
        var lines: [String: Decimal] = [:]
        for (name, raw) in row where !skip.contains(name) && !dateKeys.contains(name) {
            // Twelve Data nests a few groups one level down
            // (`operating_expense: {research_and_development: …}`); flatten
            // them rather than dropping the lines they contain.
            if let nested = raw as? [String: Any] {
                for (inner, value) in nested {
                    if let figure = number(value) { lines["\(name)_\(inner)"] = figure }
                }
            } else if let figure = number(raw) {
                lines[name] = figure
            }
        }
        return lines.isEmpty ? nil : FinancialPeriod(statement: statement, endDate: endDate,
                                                     lines: lines)
    }

    /// Decodes a JSON object, or throws the malformed-response error naming
    /// `provider`.
    static func object(_ data: Data, provider: String) throws -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            throw QuoteError.malformedResponse("not a \(provider) response")
        }
        return object
    }
}

// MARK: - EODHD

/// Company data from EODHD (`FR-INV-17`, 18, 19).
///
/// The most economical of the three: **one** `fundamentals` request returns the
/// profile *and* all three statements, so a full refresh costs two requests
/// including dividends — against Alpha Vantage's five.
public struct EODHDFundamentalsProvider: FundamentalsProvider {
    public let kind: QuoteProviderKind = .eodhd
    private let apiKey: String
    private let http: HTTPFetching

    public init(apiKey: String, http: HTTPFetching = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.http = http
    }

    public func fundamentals(symbol: String,
                             kinds: Set<FundamentalsKind>) async throws -> SecurityFundamentals {
        var out = SecurityFundamentals()
        var failures: [Error] = []

        if kinds.contains(.profile) || kinds.contains(.statements) {
            do {
                let data = try await http.get(url("fundamentals", symbol: symbol),
                                              headers: ["User-Agent": HTTPDefaults.userAgent])
                let parsed = try Self.parseBundle(data)
                if kinds.contains(.profile), !parsed.profile.isEmpty {
                    out.profile = Stamped(parsed.profile, source: Self.name)
                }
                if kinds.contains(.statements), !parsed.periods.isEmpty {
                    out.statements = Stamped(parsed.periods, source: Self.name)
                }
            } catch { failures.append(error) }
        }

        if kinds.contains(.dividends) {
            do {
                let data = try await http.get(url("div", symbol: symbol, extra: [
                    URLQueryItem(name: "from", value: Self.tenYearsAgo()),
                ]), headers: ["User-Agent": HTTPDefaults.userAgent])
                out.dividends = Stamped(try Self.parseDividends(data), source: Self.name)
            } catch { failures.append(error) }
        }

        if out.isEmpty, let first = failures.first { throw first }
        return out
    }

    static let name = "EODHD"

    private func url(_ path: String, symbol: String, extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "eodhd.com"
        components.path = "/api/\(path)/\(symbol)"
        components.queryItems = [
            URLQueryItem(name: "api_token", value: apiKey),
            URLQueryItem(name: "fmt", value: "json"),
        ] + extra
        return components.url ?? URL(string: "https://eodhd.com")!
    }

    static func tenYearsAgo(from now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let then = Calendar(identifier: .gregorian).date(byAdding: .year, value: -10, to: now)
        return formatter.string(from: then ?? now)
    }

    // MARK: Parsing

    static func parseBundle(_ data: Data) throws -> (profile: SecurityProfile,
                                                     periods: [FinancialPeriod]) {
        let root = try FundamentalsParsing.object(data, provider: Self.name)
        let general = root["General"] as? [String: Any] ?? [:]
        let highlights = root["Highlights"] as? [String: Any] ?? [:]
        let shares = root["SharesStats"] as? [String: Any] ?? [:]

        var profile = SecurityProfile()
        profile.name = FundamentalsParsing.text(general["Name"])
        profile.sector = FundamentalsParsing.text(general["Sector"])
        profile.industry = FundamentalsParsing.text(general["Industry"])
        profile.country = FundamentalsParsing.text(general["CountryName"])
        profile.currencyCode = FundamentalsParsing.text(general["CurrencyCode"])
        profile.website = FundamentalsParsing.text(general["WebURL"])
        profile.summary = FundamentalsParsing.text(general["Description"])
        profile.employees = FundamentalsParsing.number(general["FullTimeEmployees"])
            .map { NSDecimalNumber(decimal: $0).intValue }
        profile.marketCap = FundamentalsParsing.number(highlights["MarketCapitalization"])
        profile.trailingPE = FundamentalsParsing.number(highlights["PERatio"])
        profile.dividendYield = FundamentalsParsing.number(highlights["DividendYield"])
            .map { NSDecimalNumber(decimal: $0).doubleValue }
        profile.sharesOutstanding = FundamentalsParsing.number(shares["SharesOutstanding"])

        // `Financials.<kind>.yearly` is keyed by date string, so the values are
        // the periods. Yearly only: EODHD returns 40-odd years of quarterlies
        // for a long-listed company and no page shows them.
        let financials = root["Financials"] as? [String: Any] ?? [:]
        let mapping: [(String, FinancialPeriod.Statement)] = [
            ("Income_Statement", .income), ("Balance_Sheet", .balance), ("Cash_Flow", .cashflow),
        ]
        var periods: [FinancialPeriod] = []
        for (key, statement) in mapping {
            let yearly = (financials[key] as? [String: Any])?["yearly"] as? [String: Any] ?? [:]
            for row in yearly.values.compactMap({ $0 as? [String: Any] }) {
                if let period = FundamentalsParsing.period(
                    row, statement: statement, dateKeys: ["date"],
                    skip: ["filing_date", "currency_symbol"]) {
                    periods.append(period)
                }
            }
        }
        periods.sort { $0.endDate > $1.endDate }
        // Six years is what a page can show without becoming an archive.
        return (profile, Array(periods.prefix(18)))
    }

    static func parseDividends(_ data: Data) throws -> [DeclaredDividend] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw QuoteError.malformedResponse("not an \(Self.name) dividend list")
        }
        return rows.compactMap { row in
            guard let date = FundamentalsParsing.day(row["date"]),
                  let amount = FundamentalsParsing.number(row["value"]), amount > 0
            else { return nil }
            return DeclaredDividend(date: date, amount: amount)
        }
        .sorted { $0.date < $1.date }
    }
}

// MARK: - Alpha Vantage

/// Company data from Alpha Vantage (`FR-INV-17`, 18, 19).
///
/// Every value arrives as a **string**, and a missing one arrives as the
/// literal `"None"` — which parses to nothing, never to zero.
///
/// Statements cost one request each, so a full refresh is five requests. On the
/// free tier's 25-a-day that is five securities, which is why the TTLs in
/// ``FundamentalsKind`` matter more here than anywhere else: a cached section
/// is a request not spent.
public struct AlphaVantageFundamentalsProvider: FundamentalsProvider {
    public let kind: QuoteProviderKind = .alphaVantage
    private let apiKey: String
    private let http: HTTPFetching

    public init(apiKey: String, http: HTTPFetching = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.http = http
    }

    public func fundamentals(symbol: String,
                             kinds: Set<FundamentalsKind>) async throws -> SecurityFundamentals {
        var out = SecurityFundamentals()
        var failures: [Error] = []

        if kinds.contains(.profile) {
            do {
                let data = try await http.get(url("OVERVIEW", symbol: symbol),
                                              headers: ["User-Agent": HTTPDefaults.userAgent])
                let profile = try Self.parseOverview(data)
                if !profile.isEmpty { out.profile = Stamped(profile, source: Self.name) }
            } catch { failures.append(error) }
        }

        if kinds.contains(.statements) {
            var periods: [FinancialPeriod] = []
            for (function, statement) in [("INCOME_STATEMENT", FinancialPeriod.Statement.income),
                                          ("BALANCE_SHEET", .balance),
                                          ("CASH_FLOW", .cashflow)] {
                do {
                    let data = try await http.get(url(function, symbol: symbol),
                                                  headers: ["User-Agent": HTTPDefaults.userAgent])
                    periods += try Self.parseStatement(data, statement: statement)
                } catch { failures.append(error) }
            }
            if !periods.isEmpty {
                periods.sort { $0.endDate > $1.endDate }
                out.statements = Stamped(periods, source: Self.name)
            }
        }

        if kinds.contains(.dividends) {
            do {
                let data = try await http.get(url("DIVIDENDS", symbol: symbol),
                                              headers: ["User-Agent": HTTPDefaults.userAgent])
                out.dividends = Stamped(try Self.parseDividends(data), source: Self.name)
            } catch { failures.append(error) }
        }

        if out.isEmpty, let first = failures.first { throw first }
        return out
    }

    static let name = "Alpha Vantage"

    private func url(_ function: String, symbol: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.alphavantage.co"
        components.path = "/query"
        components.queryItems = [
            URLQueryItem(name: "function", value: function),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        return components.url ?? URL(string: "https://www.alphavantage.co")!
    }

    // MARK: Parsing

    /// Alpha Vantage answers a spent quota or a bad key with **HTTP 200** and a
    /// `Note` / `Information` / `Error Message` field. Reporting that as "no
    /// data" would send the user looking for a missing company instead of a
    /// spent allowance.
    static func checkForServiceMessage(_ root: [String: Any]) throws {
        for key in ["Note", "Information", "Error Message"] {
            if let message = FundamentalsParsing.text(root[key]) {
                throw QuoteError.providerError(message)
            }
        }
    }

    static func parseOverview(_ data: Data) throws -> SecurityProfile {
        let root = try FundamentalsParsing.object(data, provider: Self.name)
        try checkForServiceMessage(root)

        var profile = SecurityProfile()
        profile.name = FundamentalsParsing.text(root["Name"])
        profile.summary = FundamentalsParsing.text(root["Description"])
        profile.sector = FundamentalsParsing.text(root["Sector"])?.capitalized
        profile.industry = FundamentalsParsing.text(root["Industry"])?.capitalized
        profile.country = FundamentalsParsing.text(root["Country"])
        profile.currencyCode = FundamentalsParsing.text(root["Currency"])
        profile.employees = FundamentalsParsing.number(root["FullTimeEmployees"])
            .map { NSDecimalNumber(decimal: $0).intValue }
        profile.marketCap = FundamentalsParsing.number(root["MarketCapitalization"])
        profile.sharesOutstanding = FundamentalsParsing.number(root["SharesOutstanding"])
        profile.trailingPE = FundamentalsParsing.number(root["PERatio"])
        profile.dividendYield = FundamentalsParsing.number(root["DividendYield"])
            .map { NSDecimalNumber(decimal: $0).doubleValue }
        profile.beta = FundamentalsParsing.number(root["Beta"])
            .map { NSDecimalNumber(decimal: $0).doubleValue }
        return profile
    }

    static func parseStatement(_ data: Data,
                               statement: FinancialPeriod.Statement) throws -> [FinancialPeriod] {
        let root = try FundamentalsParsing.object(data, provider: Self.name)
        try checkForServiceMessage(root)
        let reports = root["annualReports"] as? [[String: Any]] ?? []
        return reports.prefix(6).compactMap {
            FundamentalsParsing.period($0, statement: statement,
                                       dateKeys: ["fiscalDateEnding"],
                                       skip: ["reportedCurrency"])
        }
    }

    static func parseDividends(_ data: Data) throws -> [DeclaredDividend] {
        let root = try FundamentalsParsing.object(data, provider: Self.name)
        try checkForServiceMessage(root)
        let rows = root["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            // `ex_dividend_date` is the one every row carries; a payment date
            // can be "None" for a declared-but-unpaid dividend.
            guard let date = FundamentalsParsing.day(row["ex_dividend_date"]),
                  let amount = FundamentalsParsing.number(row["amount"]), amount > 0
            else { return nil }
            return DeclaredDividend(date: date, amount: amount)
        }
        .sorted { $0.date < $1.date }
    }
}

// MARK: - Twelve Data

/// Company data from Twelve Data (`FR-INV-17`, 18, 19).
///
/// Its statements nest a few line groups one level down
/// (`operating_expense: {research_and_development: …}`), which
/// ``FundamentalsParsing/period(_:statement:dateKeys:skip:)`` flattens rather
/// than dropping.
public struct TwelveDataFundamentalsProvider: FundamentalsProvider {
    public let kind: QuoteProviderKind = .twelveData
    private let apiKey: String
    private let http: HTTPFetching

    public init(apiKey: String, http: HTTPFetching = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.http = http
    }

    public func fundamentals(symbol: String,
                             kinds: Set<FundamentalsKind>) async throws -> SecurityFundamentals {
        var out = SecurityFundamentals()
        var failures: [Error] = []

        if kinds.contains(.profile) {
            do {
                let data = try await http.get(url("profile", symbol: symbol),
                                              headers: ["User-Agent": HTTPDefaults.userAgent])
                let profile = try Self.parseProfile(data)
                if !profile.isEmpty { out.profile = Stamped(profile, source: Self.name) }
            } catch { failures.append(error) }
        }

        if kinds.contains(.statements) {
            var periods: [FinancialPeriod] = []
            for (path, statement) in [("income_statement", FinancialPeriod.Statement.income),
                                      ("balance_sheet", .balance),
                                      ("cash_flow", .cashflow)] {
                do {
                    let data = try await http.get(url(path, symbol: symbol),
                                                  headers: ["User-Agent": HTTPDefaults.userAgent])
                    periods += try Self.parseStatement(data, key: path, statement: statement)
                } catch { failures.append(error) }
            }
            if !periods.isEmpty {
                periods.sort { $0.endDate > $1.endDate }
                out.statements = Stamped(periods, source: Self.name)
            }
        }

        if kinds.contains(.dividends) {
            do {
                let data = try await http.get(url("dividends", symbol: symbol,
                                                  extra: [URLQueryItem(name: "range",
                                                                       value: "last_10_years")]),
                                              headers: ["User-Agent": HTTPDefaults.userAgent])
                out.dividends = Stamped(try Self.parseDividends(data), source: Self.name)
            } catch { failures.append(error) }
        }

        if out.isEmpty, let first = failures.first { throw first }
        return out
    }

    static let name = "Twelve Data"

    private func url(_ path: String, symbol: String, extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.twelvedata.com"
        components.path = "/" + path
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey),
        ] + extra
        return components.url ?? URL(string: "https://api.twelvedata.com")!
    }

    // MARK: Parsing

    /// Twelve Data reports its own errors inside a 200 body, as
    /// `{"code": 401, "message": …, "status": "error"}`.
    static func checkForServiceMessage(_ root: [String: Any]) throws {
        guard FundamentalsParsing.text(root["status"]) == "error" else { return }
        throw QuoteError.providerError(
            FundamentalsParsing.text(root["message"]) ?? "Twelve Data refused the request.")
    }

    static func parseProfile(_ data: Data) throws -> SecurityProfile {
        let root = try FundamentalsParsing.object(data, provider: Self.name)
        try checkForServiceMessage(root)

        var profile = SecurityProfile()
        profile.name = FundamentalsParsing.text(root["name"])
        profile.summary = FundamentalsParsing.text(root["description"])
        profile.sector = FundamentalsParsing.text(root["sector"])
        profile.industry = FundamentalsParsing.text(root["industry"])
        profile.country = FundamentalsParsing.text(root["country"])
        profile.website = FundamentalsParsing.text(root["website"])
        profile.employees = FundamentalsParsing.number(root["employees"])
            .map { NSDecimalNumber(decimal: $0).intValue }
        return profile
    }

    static func parseStatement(_ data: Data, key: String,
                               statement: FinancialPeriod.Statement) throws -> [FinancialPeriod] {
        let root = try FundamentalsParsing.object(data, provider: Self.name)
        try checkForServiceMessage(root)
        let rows = root[key] as? [[String: Any]] ?? []
        return rows.prefix(6).compactMap {
            FundamentalsParsing.period($0, statement: statement,
                                       dateKeys: ["fiscal_date"], skip: ["year"])
        }
    }

    static func parseDividends(_ data: Data) throws -> [DeclaredDividend] {
        let root = try FundamentalsParsing.object(data, provider: Self.name)
        try checkForServiceMessage(root)
        let rows = root["dividends"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let date = FundamentalsParsing.day(row["ex_date"]),
                  let amount = FundamentalsParsing.number(row["amount"]), amount > 0
            else { return nil }
            return DeclaredDividend(date: date, amount: amount)
        }
        .sorted { $0.date < $1.date }
    }
}
