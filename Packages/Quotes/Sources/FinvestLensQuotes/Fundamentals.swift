//
//  Fundamentals.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// Phase I5 of the Investments hub (docs/investments-design.md §10): what a
// provider knows about a security beyond its price.
//
// **None of this enters the book** (decision D2). Prices remain the only
// fetched thing stored there, so the two invariants — splits balance to zero,
// GnuCash XML round-trips byte-identically — are untouched by any of it. The
// sidecar (``FundamentalsCache``) is discardable at any time with no data loss.

/// A value with the provenance a rendering has to show beside it.
///
/// Per-section rather than per-file because the TTLs differ by an order of
/// magnitude — a profile changes yearly, a dividend list weekly — and because
/// "as of" is a different date for each. One timestamp for the whole record
/// would either refetch a company description every week or show a stale
/// dividend list as current.
public struct Stamped<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value
    /// When this section was retrieved.
    public var fetchedAt: Date
    /// Who supplied it, for the "source · as of" line.
    public var source: String

    public init(_ value: Value, fetchedAt: Date = Date(), source: String) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Whether this section is older than `ttl`.
    public func isStale(after ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > ttl
    }
}

/// What kind of fetched fact a section holds, and how long it stays fresh.
public enum FundamentalsKind: String, CaseIterable, Sendable {
    case profile, statements, dividends

    /// Time-to-live, from the design's §10: profile monthly, statements
    /// quarterly, dividends weekly.
    ///
    /// A company's sector does not move; a quarter's revenue is fixed once
    /// filed; a dividend list gains a row a few times a year but you want to
    /// see it the week it lands.
    public var ttl: TimeInterval {
        switch self {
        case .profile: 30 * 86_400
        case .statements: 91 * 86_400
        case .dividends: 7 * 86_400
        }
    }
}

/// Who and what a security is (`FR-INV-17`).
///
/// Deliberately one type for shares and bonds. The fields differ — a share has
/// a sector and employees, a bond has a coupon and a maturity — and a page that
/// renders whichever are present adapts to the instrument without a second
/// model to keep in step. §7: pretending an ASX share, a bond and a super fund
/// are the same thing is what made the old page generic and useless.
public struct SecurityProfile: Codable, Sendable, Equatable {
    // Shared
    public var name: String?
    public var summary: String?
    public var sector: String?
    public var website: String?
    public var currencyCode: String?

    // Equity
    public var industry: String?
    public var country: String?
    public var employees: Int?
    public var marketCap: Decimal?
    public var sharesOutstanding: Decimal?
    public var trailingPE: Decimal?
    public var dividendYield: Double?
    public var beta: Double?

    // Fixed income — from the bond provider's own record, which knows things
    // about a bond that no equity service does.
    public var issuer: String?
    public var couponRate: Decimal?
    public var couponType: String?
    public var couponFrequency: String?
    public var maturityDate: Date?
    public var callDate: Date?
    public var yieldToMaturity: Double?

    public init() {}

    /// Whether this profile is a bond's, which decides which sections a page
    /// draws.
    public var isFixedIncome: Bool {
        couponRate != nil || maturityDate != nil
    }

    /// Whether anything at all is known.
    public var isEmpty: Bool { self == SecurityProfile() }
}

/// One reporting period's figures (`FR-INV-18`).
///
/// A sparse bag rather than a fixed schema: providers disagree about which
/// lines they publish, and for some issuers most of them come back empty. A
/// struct of optionals would turn "this provider does not report gross profit
/// for a bank" into a field that reads as zero.
public struct FinancialPeriod: Codable, Sendable, Equatable, Identifiable {
    public enum Statement: String, Codable, Sendable, CaseIterable {
        case income, balance, cashflow
    }
    public var id: String { "\(statement.rawValue)|\(endDate.timeIntervalSince1970)" }
    public var statement: Statement
    public var endDate: Date
    /// Line label as the provider names it → value. Empty lines are absent, not
    /// zero.
    public var lines: [String: Decimal]
    public var currencyCode: String?

    public init(statement: Statement, endDate: Date, lines: [String: Decimal],
                currencyCode: String? = nil) {
        self.statement = statement
        self.endDate = endDate
        self.lines = lines
        self.currencyCode = currencyCode
    }
}

/// A dividend the issuer declared, as distinct from one the book recorded
/// (`FR-INV-19`). The difference between the two is what I6 reconciles.
public struct DeclaredDividend: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var amount: Decimal

    public init(date: Date, amount: Decimal) {
        self.date = date
        self.amount = amount
    }
}

/// A capital change the provider reports (`FR-INV-21`).
public struct DeclaredSplit: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public var date: Date
    /// Shares after, per `denominator` shares before — a 2-for-1 is 2 and 1.
    public var numerator: Decimal
    public var denominator: Decimal

    public init(date: Date, numerator: Decimal, denominator: Decimal) {
        self.date = date
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The multiplier applied to a holding, or `nil` for a nonsense ratio.
    public var ratio: Decimal? {
        denominator == 0 ? nil : numerator / denominator
    }
}

/// Everything fetched about one security, cached beside the book and never in
/// it (`FR-INV-35`).
public struct SecurityFundamentals: Codable, Sendable {
    /// Bumped when the shape changes, so a cache written by an older build is
    /// discarded rather than decoded into something that no longer means the
    /// same thing.
    public static let currentVersion = 1
    public var version: Int = SecurityFundamentals.currentVersion

    public var profile: Stamped<SecurityProfile>?
    public var statements: Stamped<[FinancialPeriod]>?
    public var dividends: Stamped<[DeclaredDividend]>?
    public var splits: Stamped<[DeclaredSplit]>?

    public init(profile: Stamped<SecurityProfile>? = nil,
                statements: Stamped<[FinancialPeriod]>? = nil,
                dividends: Stamped<[DeclaredDividend]>? = nil,
                splits: Stamped<[DeclaredSplit]>? = nil) {
        self.profile = profile
        self.statements = statements
        self.dividends = dividends
        self.splits = splits
    }

    public var isEmpty: Bool {
        profile == nil && statements == nil && dividends == nil && splits == nil
    }

    /// Whether `kind` is missing or past its TTL.
    public func needsFetch(_ kind: FundamentalsKind, now: Date = Date()) -> Bool {
        switch kind {
        case .profile:
            guard let profile else { return true }
            return profile.isStale(after: kind.ttl, now: now)
        case .statements:
            guard let statements else { return true }
            return statements.isStale(after: kind.ttl, now: now)
        case .dividends:
            // Splits ride along with dividends — one request returns both — so
            // a missing split list is not separately stale.
            guard let dividends else { return true }
            return dividends.isStale(after: kind.ttl, now: now)
        }
    }

    /// Merges `other` over this, section by section, keeping what the new fetch
    /// did not supply.
    ///
    /// A provider that serves a profile but no statements must not erase
    /// statements a keyed provider fetched last quarter.
    public func merging(_ other: SecurityFundamentals) -> SecurityFundamentals {
        SecurityFundamentals(
            profile: other.profile ?? profile,
            statements: other.statements ?? statements,
            dividends: other.dividends ?? dividends,
            splits: other.splits ?? splits)
    }
}

/// A source of everything about a security except its price.
///
/// Separate from ``QuoteProvider`` because the two capabilities do not travel
/// together: Stooq serves prices and nothing else, FIIG serves a bond profile
/// no equity service could, and Yahoo serves both through entirely different
/// endpoints with different authentication.
public protocol FundamentalsProvider: Sendable {
    var kind: QuoteProviderKind { get }

    /// The sections listed in `kinds` for `symbol`.
    ///
    /// A provider returns only what it has; a section it cannot serve is
    /// `nil` rather than an error, so one unavailable module does not lose the
    /// other two.
    func fundamentals(symbol: String, kinds: Set<FundamentalsKind>) async throws -> SecurityFundamentals
}

public extension QuoteProviderKind {
    /// Whether this provider can serve anything beyond a price.
    ///
    /// Stooq is a CSV of closes and nothing else, and Finnhub's free tier does
    /// not include company fundamentals — claiming otherwise would offer the
    /// user a Refetch that can only fail.
    var servesFundamentals: Bool {
        switch self {
        // Wilson serves a *fund's* profile — inception, asset class, benchmark,
        // timeframe, APIR, ARSN, fees — from the same page request the prices
        // come from. It said `false` while the parser did not exist, which was
        // the honest answer then and is the wrong one now.
        case .yahoo, .fiig, .eodhd, .alphaVantage, .twelveData, .wilson: true
        case .finnhub, .stooq: false
        }
    }

    /// Whether this provider should be **preferred** for company data over the
    /// keyless default when the user has configured it (decision **D5**).
    ///
    /// The keyed services are documented APIs the user signed up to. Yahoo's
    /// `quoteSummary` is an unofficial endpoint behind a cookie-and-crumb
    /// handshake that is hard rate-limited — fine as a default, wrong as a
    /// first choice when something better is configured.
    var preferredForFundamentals: Bool {
        servesFundamentals && requiresAPIKey
    }
}

/// Builds the fundamentals provider for a kind, or `nil` when that kind serves
/// only prices — or is keyed and has no key.
public enum FundamentalsProviderFactory {
    public static func make(_ kind: QuoteProviderKind,
                            apiKey: String? = nil,
                            http: HTTPFetching = URLSessionHTTPClient(),
                            crumbs: YahooCrumbStore) -> FundamentalsProvider? {
        // A keyed provider with no key cannot serve anything, and returning one
        // anyway would put a Refetch on screen that fails every time.
        func keyed(_ build: (String) -> FundamentalsProvider) -> FundamentalsProvider? {
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return build(apiKey)
        }
        switch kind {
        case .yahoo: return YahooFundamentalsProvider(http: http, crumbs: crumbs)
        case .fiig: return FIIGQuoteProvider(http: http)
        case .wilson: return WilsonQuoteProvider(http: http)
        case .eodhd: return keyed { EODHDFundamentalsProvider(apiKey: $0, http: http) }
        case .alphaVantage: return keyed { AlphaVantageFundamentalsProvider(apiKey: $0, http: http) }
        case .twelveData: return keyed { TwelveDataFundamentalsProvider(apiKey: $0, http: http) }
        case .finnhub, .stooq: return nil
        }
    }
}
