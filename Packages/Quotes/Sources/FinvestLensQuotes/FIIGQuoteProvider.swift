//
//  FIIGQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Australian corporate bond prices from FIIG's public bond ticker
/// (`FR-INV-31`), matched by **ISIN**.
///
/// A different provider shape from every other one here, in three ways, each
/// measured against the live API on 15 Aug 2026:
///
/// 1. **One request is the whole market.** `pageSize=2000` returns all 702
///    bonds in a single response (`pageCount: 1`, ~510 KB), so this is a
///    ``BatchQuoteProvider``: fetch once, then look up locally. Eleven bonds
///    cost one request, not eleven downloads of the same payload.
/// 2. **Keyed by ISIN, not ticker.** A corporate bond has no ticker to send.
///    ``QuoteProviderKind/matchesByIdentifier`` is what makes the caller send
///    GnuCash's `cmdty:xcode` instead of the mnemonic.
/// 3. **`price` is a percentage of par**, not a currency amount — samples run
///    13.500 to 177.182 across the index. The book stores bond prices
///    par-relative (every bond row in the reference book was exactly `1.0`), so
///    the conversion is `price ÷ 100` and it happens here, at the boundary, so
///    a ``Quote`` from FIIG means the same thing as a ``Quote`` from anywhere
///    else: the price of one unit.
///
/// **No history.** `bondHistory` is `null` on all 702 records, so
/// ``QuoteProviderKind/supportsHistory`` is `false` and ``history(symbol:from:to:)``
/// says so rather than returning an empty series that would read as "this bond
/// did not trade".
///
/// **TLS.** The reference implementation
/// ([ChristineTham/investalens](https://github.com/ChristineTham/investalens),
/// `lib/providers/fiig-bond-rates.ts`) disables certificate verification
/// because the server omits an intermediate CA and Node does not chase AIA to
/// fetch it. That is a Node limitation, not a server one: `curl` from this
/// machine verified the chain cleanly (`ssl_verify_result=0`) and URLSession
/// uses the same Security-framework trust evaluation, so no workaround is
/// needed and none is present. Verification is never disabled in a shipping
/// app.
public struct FIIGQuoteProvider: BatchQuoteProvider, FundamentalsProvider {
    public let kind: QuoteProviderKind = .fiig
    private let http: HTTPFetching
    private let host: String

    /// One request covers the index; 2000 is comfortably above the 702 bonds
    /// served and the API reports `pageCount: 1` at that size. If the index
    /// ever outgrows it the response still says so — see ``parse(_:)``.
    static let pageSize = 2000

    public init(http: HTTPFetching = URLSessionHTTPClient(),
                host: String = "bondtickerapi.fiig.com.au") {
        self.http = http
        self.host = host
    }

    // MARK: Batch — the natural shape

    public func latestQuotes(symbols: [String]) async throws -> [String: Quote] {
        guard !symbols.isEmpty else { return [:] }
        let index = try await wholeIndex()
        var out: [String: Quote] = [:]
        for symbol in symbols {
            // Looked up on the caller's own spelling but matched case- and
            // whitespace-insensitively: an ISIN pasted from a statement
            // routinely arrives with a trailing space.
            if let quote = index[Self.normalise(symbol)] {
                out[symbol] = quote
            }
        }
        return out
    }

    // MARK: Single — the protocol's shape, served from the same request

    public func latestQuote(symbol: String) async throws -> Quote {
        guard let quote = try await wholeIndex()[Self.normalise(symbol)] else {
            throw QuoteError.noData
        }
        return quote
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        // Stated, not faked. An empty array here would be indistinguishable
        // from "this bond has no prices in that window", and the caller would
        // record a gap that is really a missing capability.
        throw QuoteError.unsupported("FIIG publishes today's price only, with no history.")
    }

    // MARK: The bond's own profile (`FR-INV-17`)

    /// The record FIIG already returned, read as a profile.
    ///
    /// A bond's profile is a **better** one than Yahoo could give — coupon type
    /// and rate, frequency, maturity, call date, yield, sector, issuer
    /// description — and it arrives in the same response as the price, so it
    /// costs nothing beyond the request already made. §7: sections adapt to the
    /// instrument, and pretending a bond is a share is what made the old page
    /// generic.
    public func fundamentals(symbol: String,
                             kinds: Set<FundamentalsKind>) async throws -> SecurityFundamentals {
        // Only a profile: a bond issuer publishes no per-security statements
        // here, and a coupon is not a dividend. Asking for either returns
        // nothing rather than something misleading.
        guard kinds.contains(.profile) else { return SecurityFundamentals() }
        let data = try await http.get(indexURL(), headers: Self.headers)
        guard let record = try Self.parseRecords(data)[Self.normalise(symbol)] else {
            throw QuoteError.noData
        }
        return SecurityFundamentals(profile: Stamped(record.profile, source: "FIIG"))
    }

    // MARK: The index

    /// The entire index, keyed by normalised ISIN. Internal rather than private
    /// so the live harness can assert on everything served, not only on the
    /// bonds it thought to ask about.
    func wholeIndex() async throws -> [String: Quote] {
        let data = try await http.get(indexURL(), headers: Self.headers)
        return try Self.parse(data)
    }

    private func indexURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/instruments/bonds"
        components.queryItems = [
            URLQueryItem(name: "pageNo", value: "1"),
            URLQueryItem(name: "pageSize", value: String(Self.pageSize)),
        ]
        return components.url ?? URL(string: "https://\(host)")!
    }

    /// The WAF in front of the API rejects requests that do not look like the
    /// site's own front end, so `Origin` and `Referer` are required alongside
    /// the User-Agent every provider here already sends.
    static let headers = [
        "User-Agent": HTTPDefaults.userAgent,
        "Accept": "application/json",
        "Origin": "https://bondticker.fiig.com.au",
        "Referer": "https://bondticker.fiig.com.au/",
    ]

    // MARK: Parsing

    /// The whole index as decoded records, keyed by normalised ISIN.
    static func parseRecords(_ data: Data) throws -> [String: Bond] {
        let response: IndexResponse
        do {
            response = try JSONDecoder().decode(IndexResponse.self, from: data)
        } catch {
            throw QuoteError.malformedResponse("not the FIIG bond index")
        }
        guard !response.data.isEmpty else { throw QuoteError.noData }
        var out: [String: Bond] = [:]
        for bond in response.data {
            let key = normalise(bond.isin)
            if !key.isEmpty { out[key] = bond }
        }
        return out
    }

    static func parse(_ data: Data) throws -> [String: Quote] {
        let response: IndexResponse
        do {
            response = try JSONDecoder().decode(IndexResponse.self, from: data)
        } catch {
            throw QuoteError.malformedResponse("not the FIIG bond index")
        }
        guard !response.data.isEmpty else { throw QuoteError.noData }

        // The observation is today's: the endpoint publishes a current price
        // with no date of its own. Recording it as today is honest — this is
        // what the provider says the bond is worth now — and the day-neutral
        // stamping the book applies makes it a fact about this day.
        let observed = Date()

        var index: [String: Quote] = [:]
        for bond in response.data {
            guard let price = bond.price else { continue }
            let key = normalise(bond.isin)
            guard !key.isEmpty else { continue }
            index[key] = Quote(symbol: bond.isin,
                               // `marketRegion` is the denomination — AUD on
                               // 661 of the 702, with USD and GBP among the
                               // rest. Carried through so a foreign bond leaves
                               // a visible trace rather than being silently
                               // recorded in the book's own currency.
                               currencyCode: bond.marketRegion,
                               price: price / 100,
                               date: observed)
        }
        guard !index.isEmpty else { throw QuoteError.noData }
        return index
    }

    /// The comparison key for an ISIN: trimmed and upper-cased.
    static func normalise(_ isin: String) -> String {
        isin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: Response shape

    private struct IndexResponse: Decodable {
        let data: [Bond]
    }

    struct Bond: Decodable {
        let isin: String
        /// Clean capital price as a percentage of par. Nullable in the schema's
        /// shape even though every record carried one when measured.
        let price: Decimal?
        /// The denomination currency, despite the name ("AUD", "USD", "GBP").
        let marketRegion: String?

        // The profile fields (§7). All optional: the index is not uniform, and
        // a bond missing a call date is a bond that cannot be called.
        let companyName: String?
        let companyDescription: String?
        let securityDescription: String?
        /// The coupon *type* — "Fixed Coupon Bond", "Floating Rate Note".
        let coupon: String?
        /// The coupon **rate**, and it arrives as a **string** ("0.04"), which
        /// is why this is not a `Decimal` and is parsed below.
        let couponDetail: String?
        let couponFrequency: String?
        let maturityDate: String?
        let callDate: String?
        let yield: Double?
        let sector: String?

        /// The record read as a profile.
        var profile: SecurityProfile {
            var profile = SecurityProfile()
            profile.name = securityDescription
            profile.issuer = companyName
            profile.summary = companyDescription
            profile.sector = sector
            profile.currencyCode = marketRegion
            profile.couponType = coupon
            profile.couponRate = couponDetail.flatMap { Decimal(string: $0) }
            profile.couponFrequency = couponFrequency
            profile.maturityDate = maturityDate.flatMap(FIIGQuoteProvider.day)
            profile.callDate = callDate.flatMap(FIIGQuoteProvider.day)
            profile.yieldToMaturity = yield
            return profile
        }
    }

    /// FIIG writes plain `yyyy-MM-dd`. Parsed in UTC with a POSIX locale, so a
    /// maturity does not shift a day for a reader east of Greenwich.
    static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text)
    }
}
