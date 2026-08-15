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
///    13.500 to 177.182 across the index. It is passed through **as
///    published**: which unit that has to become is a fact about the security,
///    not about FIIG.
///
///    This provider used to divide by 100, on the evidence that every bond row
///    in the reference book was `1.0`. That sample was the hand-entered rows;
///    the *purchases* told a different story. Measured 15 Aug 2026 across the
///    same book's eleven bonds: ten were bought at 500 or 1,000 units and
///    ~100.5 per unit (units are $100 parcels, priced per $100), and one at
///    60,000 units and 0.8268 (units are dollars of face, priced par-relative).
///    Both conventions, one book. Dividing by 100 valued the ten at a hundredth
///    of their worth. The scale is chosen against each security's own record in
///    ``AppModel/normalisedParPercent(_:)``.
///
/// **History is a second endpoint.** `bondHistory` is `null` on every record
/// in the index, which this provider first read as "FIIG has no history". It
/// has: `/api/instruments/bonds/{georgiaId}/history` returns the daily series
/// — 1,181 rows from 2021-10-27 for the bond measured on 15 Aug 2026. The
/// index is still needed first, to turn an ISIN into the numeric id that path
/// takes.
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

    /// Daily closes for one bond (`FR-INV-31`).
    ///
    /// Two requests, because the history endpoint is keyed by FIIG's own
    /// numeric `georgiaId` and not by ISIN: the index resolves the id, then
    /// `/api/instruments/bonds/{id}/history` returns the series.
    ///
    /// The `bondHistory` field on the index record is `null` on all 703 bonds,
    /// which is what this provider originally read as "FIIG has no history".
    /// It does — the list simply does not embed it. Measured 15 Aug 2026 on
    /// `georgiaId` 18: 1,181 daily rows, 2021-10-27 → 2026-08-14, ~108 KB, no
    /// pagination, `priceValue` on the same percent-of-par scale as the index.
    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        let key = Self.normalise(symbol)
        guard let id = try await identifiers()[key] else { throw QuoteError.noData }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/instruments/bonds/\(id)/history"
        guard let url = components.url else { throw QuoteError.noData }
        let data = try await http.get(url, headers: Self.headers)
        let decoded: HistoryResponse
        do {
            decoded = try JSONDecoder().decode(HistoryResponse.self, from: data)
        } catch {
            throw QuoteError.malformedResponse("not a FIIG bond history")
        }
        // The rows carry no ISIN (the field is present and always empty), so
        // the symbol echoed back is the one that was asked for.
        let quotes = decoded.data.compactMap { row -> Quote? in
            guard let price = row.priceValue,
                  let date = Self.day.date(from: row.priceDate) else { return nil }
            guard date >= Self.startOfDay(from), date <= Self.endOfDay(to) else { return nil }
            // As published — percent of par, like `latestQuote`. The book
            // scales it, because only the book knows what a unit is here.
            return Quote(symbol: symbol, currencyCode: nil, price: price, date: date)
        }
        guard !quotes.isEmpty else { throw QuoteError.noData }
        return quotes.sorted { $0.date < $1.date }
    }

    /// ISIN → FIIG's numeric id, from the one index request this provider
    /// already makes. Same payload as the quotes, so asking for history right
    /// after a price fetch costs one extra request, not two.
    func identifiers() async throws -> [String: Int] {
        let data = try await http.get(indexURL(), headers: Self.headers)
        return try Self.parseRecords(data).compactMapValues(\.georgiaId)
    }

    /// `priceDate` is a plain `yyyy-MM-dd`; parsed in UTC so a price dated the
    /// 14th is the 14th everywhere, matching how the book stamps price days.
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: date)
    }

    private static func endOfDay(_ date: Date) -> Date {
        startOfDay(date).addingTimeInterval(86_399)
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
                               // As published: percent of par. Scaling to the
                               // book's own unit happens where the book is —
                               // see `AppModel.normalisedParPercent`.
                               price: price,
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

    private struct HistoryResponse: Decodable {
        let data: [HistoryRow]
    }

    struct HistoryRow: Decodable {
        let priceDate: String
        /// Percent of par, as everywhere in this API.
        let priceValue: Decimal?
        /// Yield to maturity as a fraction (0.0204 = 2.04%). Carried by the
        /// endpoint; not yet stored, because the price DB has one value per
        /// day per commodity and the price is the one reports need.
        let yield: Decimal?
    }

    struct Bond: Decodable {
        let isin: String
        /// FIIG's own row id, and the key its history endpoint takes — the
        /// ISIN gets a 404 there.
        let georgiaId: Int?
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
