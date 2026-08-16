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
public struct WilsonQuoteProvider: QuoteProvider {
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
        let slug = symbol.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !slug.isEmpty else { throw QuoteError.noData }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/trusts/\(slug)/"
        guard let url = components.url else { throw QuoteError.noData }
        let data = try await http.get(url, headers: ["User-Agent": HTTPDefaults.userAgent])
        guard let html = String(data: data, encoding: .utf8) else {
            throw QuoteError.malformedResponse("not UTF-8")
        }
        return try Self.parse(html: html, symbol: slug)
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .current
        func date(day: Int, month: Int, year: Int) -> Date? {
            guard (1...31).contains(day), (1...12).contains(month) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
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
