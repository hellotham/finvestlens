//
//  WilsonQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Unit prices for Wilson Asset Management's unlisted trusts (`FR-INV-42`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Unit prices published by Wilson Asset Management for its unlisted funds.
///
/// An unlisted trust has no ticker and no exchange, so no quote service carries
/// it — the manager's own page is the only source there is. Asking Yahoo for
/// `WAMFF` finds a US over-the-counter namesake instead, whose closes then sit
/// in the book as this fund's unit price; that is not a gap in coverage, it is
/// a wrong answer, and it is why this provider exists.
///
/// **Keyed by the fund's page slug**, e.g.
/// `wilson-asset-management-founders-fund`, stored as the security's quote
/// symbol. Any of the manager's trusts works without new code.
///
/// The page carries the whole series server-rendered — 69 rows for the Founders
/// Fund on 16 Aug 2026, from inception at $1.0000 on 28/02/2025 — so one
/// request yields both the latest price and the history.
public struct WilsonQuoteProvider: QuoteProvider, FundamentalsProvider {
    public let kind: QuoteProviderKind = .wilson
    private let http: HTTPFetching
    private let host: String

    public init(http: HTTPFetching = URLSessionHTTPClient(),
                host: String = "wilsonassetmanagement.com.au") {
        self.http = http
        self.host = host
    }

    public func latestQuote(symbol: String) async throws -> Quote {
        let quotes = try await allQuotes(symbol: symbol)
        guard let newest = quotes.max(by: { $0.date < $1.date }) else {
            throw QuoteError.noData
        }
        return newest
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        let quotes = try await allQuotes(symbol: symbol)
        let wanted = quotes.filter { $0.date >= from && $0.date <= to }
        guard !wanted.isEmpty else { throw QuoteError.noData }
        return wanted.sorted { $0.date < $1.date }
    }

    private func allQuotes(symbol: String) async throws -> [Quote] {
        try Self.parse(html: try await page(symbol: symbol), symbol: Self.slug(symbol))
    }

    /// The fund page's URL for a slug — the one place the path is spelled.
    static func url(host: String, symbol: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/trusts/\(slug(symbol))/"
        return components.url
    }

    static func slug(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func page(symbol: String) async throws -> String {
        guard !Self.slug(symbol).isEmpty,
              let url = Self.url(host: host, symbol: symbol) else { throw QuoteError.noData }
        let data = try await http.get(url, headers: ["User-Agent": HTTPDefaults.userAgent])
        guard let html = String(data: data, encoding: .utf8) else {
            throw QuoteError.malformedResponse("not UTF-8")
        }
        return html
    }

    // MARK: The fund's own profile (`FR-INV-17`)

    /// The page's key facts, read from the same request the prices come from.
    ///
    /// A fund is not a company: there is no sector, no market cap, no P/E, and
    /// asking an equity service for those about `WAMFF` is what returns a US
    /// namesake's. What the manager publishes instead — asset class, benchmark,
    /// timeframe, APIR, ARSN, fees, inception — is the profile that actually
    /// describes this instrument, so that is what this returns.
    public func fundamentals(symbol: String,
                             kinds: Set<FundamentalsKind>) async throws -> SecurityFundamentals {
        // Profile only. A trust publishes no per-security income statement here,
        // and its distributions are not dividends per share; returning nothing
        // for those beats returning something misleading.
        guard kinds.contains(.profile) else { return SecurityFundamentals() }
        let profile = Self.parseProfile(html: try await page(symbol: symbol),
                                        url: Self.url(host: host, symbol: symbol))
        return SecurityFundamentals(profile: Stamped(profile, source: "Wilson Asset Management"))
    }

    // MARK: Parsing

    /// One `<tr>` of the Historical Prices table: date, price, redemption,
    /// application. Only the first two are taken — the price is the fund's own
    /// valuation, and the other two are the spread around it.
    static func parse(html: String, symbol: String) throws -> [Quote] {
        let rowPattern = #"<tr[^>]*>\s*<td[^>]*>\s*(\d{1,2}/\d{1,2}/\d{4})\s*</td>\s*<td[^>]*>\s*\$?([0-9]+\.[0-9]+)\s*</td>"#
        guard let regex = try? NSRegularExpression(pattern: rowPattern, options: [.caseInsensitive])
        else { throw QuoteError.malformedResponse("bad pattern") }
        let range = NSRange(html.startIndex..., in: html)
        var raw: [(day: Int, other: Int, year: Int, price: Decimal)] = []
        for match in regex.matches(in: html, range: range) {
            guard let dateRange = Range(match.range(at: 1), in: html),
                  let priceRange = Range(match.range(at: 2), in: html),
                  let price = Decimal(string: String(html[priceRange])), price > 0
            else { continue }
            let parts = String(html[dateRange]).split(separator: "/").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            raw.append((parts[0], parts[1], parts[2], price))
        }
        guard !raw.isEmpty else { throw QuoteError.noData }
        return resolveDates(raw, symbol: symbol)
    }

    /// The page's key-fact block, read from its own markup.
    ///
    /// Verified against the live Founders Fund page on 16 Aug 2026, which
    /// renders each fact as a pair inside one `div.right-content`:
    ///
    /// ```html
    /// <p class="leader" style="color:#d0af79">Asset class</p>
    /// <p class="details">Equity</p>
    /// ```
    ///
    /// Eight pairs that day — Inception date, Asset class, Benchmark index,
    /// Investment timeframe, APIR code (`ETL5957AU`), ARSN, Management fee,
    /// Performance fee. Read as pairs rather than by position, so a fund with
    /// more or fewer of them still parses and a reordering does not silently
    /// swap two values.
    ///
    /// The name comes from `<title>` rather than `<h1>`: the page carries three
    /// `h1`s and two of them run the words together
    /// ("Wilson AssetManagementFounders Fund") because of the styling spans
    /// inside.
    static func parseProfile(html: String, url: URL?) -> SecurityProfile {
        var profile = SecurityProfile()
        profile.currencyCode = "AUD"
        profile.website = url?.absoluteString

        if let title = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html) {
            let cleaned = plainText(title)
            // The site appends its own name; the fund's is what is wanted.
            profile.name = cleaned
                .replacingOccurrences(of: " - Wilson Asset Management", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let pairs = keyFacts(in: html)
        profile.sector = pairs.first { $0.label.caseInsensitiveCompare("Asset class") == .orderedSame }?.value
        // Everything the manager states, in the order the page states it —
        // which is the fund's profile. Deliberately not squeezed into the
        // equity fields above: a benchmark is not a sector and an APIR code is
        // not a ticker, and putting them there would make the security page
        // draw a company's shape around a trust.
        let summary = pairs
            .filter { $0.label.caseInsensitiveCompare("Asset class") != .orderedSame }
            .map { "\($0.label): \($0.value)" }
            .joined(separator: " · ")
        profile.summary = summary.isEmpty ? nil : summary
        return profile
    }

    /// The `leader`/`details` pairs, in page order.
    static func keyFacts(in html: String) -> [(label: String, value: String)] {
        let pattern = #"<p[^>]*class="[^"]*\bleader\b[^"]*"[^>]*>(.*?)</p>\s*"#
            + #"<p[^>]*class="[^"]*\bdetails\b[^"]*"[^>]*>(.*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            .compactMap { match in
                guard let l = Range(match.range(at: 1), in: html),
                      let v = Range(match.range(at: 2), in: html) else { return nil }
                let label = plainText(String(html[l])), value = plainText(String(html[v]))
                guard !label.isEmpty, !value.isEmpty else { return nil }
                return (label, value)
            }
    }

    private static func firstMatch(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    /// Inner markup as readable text: tags dropped, the handful of entities the
    /// page actually uses decoded, whitespace collapsed.
    static func plainText(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: "<[^>]+>", with: "",
                                                 options: [.regularExpression])
        for (entity, character) in [("&amp;", "&"), ("&nbsp;", " "), ("&quot;", "\""),
                                    ("&#039;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the dates, working around a source that is **not consistent about
    /// its own format**.
    ///
    /// Observed on the Founders Fund page, 16 Aug 2026, in this order:
    /// `13/08/2026`, `08/12/2026`, `08/11/2026`, `08/10/2026`, `08/07/2026`,
    /// … then `31/07/2026`, `30/07/2026`. The first is unambiguous — 13 cannot
    /// be a month, so it is 13 August. The ones after it descend 12, 11, 10, 7,
    /// 6, 5, 4, 3 *within August*, which only reads correctly as month-first.
    /// So the page emits day-first for days past the 12th and month-first
    /// below it — the signature of a value round-tripped through a
    /// locale-guessing formatter.
    ///
    /// Rather than pick a format and be wrong half the time, each row is read
    /// both ways and the reading that keeps the table's own **descending order**
    /// is taken. Where a row is genuinely ambiguous and no neighbour settles it,
    /// it is dropped: a unit price on the wrong day is worse than one missing,
    /// because it silently misvalues a holding on both days.
    static func resolveDates(_ raw: [(day: Int, other: Int, year: Int, price: Decimal)],
                             symbol: String) -> [Quote] {
        // The page prints a civil date, so the instant that represents it must
        // name that same day for every reader: 10:59Z, like every other
        // date-only provider here (see ``QuoteDate``). It used to build Sydney
        // midnight, which a reader west of UTC re-reads as the day before —
        // and `Price.dayNeutral` would then store it one day early.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(day: Int, month: Int, year: Int) -> Date? {
            guard (1...31).contains(day), (1...12).contains(month) else { return nil }
            let parts = DateComponents(year: year, month: month, day: day,
                                       hour: 10, minute: 59, second: 0)
            // `date(from:)` rolls 31 April forward to 1 May; the page never
            // prints one, but a rolled date would be silently wrong rather than
            // absent.
            guard let candidate = utc.date(from: parts),
                  utc.component(.day, from: candidate) == day,
                  utc.component(.month, from: candidate) == month else { return nil }
            return candidate
        }

        var quotes: [Quote] = []
        var previous: Date?          // the row above, which must be later
        for row in raw {
            // `a/b/yyyy` read both ways.
            let dayFirst = date(day: row.day, month: row.other, year: row.year)
            let monthFirst = date(day: row.other, month: row.day, year: row.year)
            let chosen: Date?
            switch (dayFirst, monthFirst) {
            case let (value?, nil): chosen = value          // unambiguous
            case let (nil, value?): chosen = value
            case let (first?, second?):
                if first == second {
                    chosen = first                          // e.g. 05/05
                } else if let previous {
                    // The table runs newest first, so take whichever reading is
                    // at or before the row above — and prefer the *closer* of
                    // the two, which is what keeps a run of consecutive days
                    // together instead of jumping a month.
                    let ok = [first, second].filter { $0 <= previous }
                    chosen = ok.max()
                } else {
                    // The first row has nothing above it. Day-first is the
                    // Australian convention and the page's own unambiguous
                    // rows use it.
                    chosen = first
                }
            case (nil, nil): chosen = nil
            }
            guard let when = chosen else { continue }
            previous = when
            quotes.append(Quote(symbol: symbol, currencyCode: "AUD",
                                price: row.price, date: when))
        }
        return quotes
    }
}
