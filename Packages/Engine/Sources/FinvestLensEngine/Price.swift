//
//  Price.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A commodity's value in another commodity at a point in time — one entry in
/// the price database (`FR-ENG-09`).
///
/// `value` is the price of one unit of ``commodity`` expressed in ``currency``
/// (e.g. one CBA share = 105.20 AUD).
public struct Price: Identifiable, Codable, Hashable, Sendable {
    public var id: GncGUID { guid }
    public let guid: GncGUID
    /// The thing being priced (a security or a foreign currency).
    public var commodity: Commodity
    /// The commodity the price is expressed in.
    public var currency: Commodity
    public var date: Date
    /// Price of one unit of ``commodity`` in ``currency``.
    public var value: Decimal
    public var source: String
    public var type: String

    /// - Parameter preservingTime: keep `date` exactly as given instead of
    ///   normalising it. Importers pass `true`: a file's own timestamps are
    ///   data, and rewriting them would break fidelity to the source.
    ///   Everything the app *creates* takes the default.
    public init(guid: GncGUID = .random(), commodity: Commodity, currency: Commodity,
                date: Date, value: Decimal, source: String = "user:price", type: String = "last",
                preservingTime: Bool = false) {
        self.guid = guid
        self.commodity = commodity
        self.currency = currency
        self.date = preservingTime ? date : Self.dayNeutral(date)
        self.value = value
        self.source = source
        self.type = type
    }

    /// GnuCash's **timezone-neutral** time for a price: 10:59:00Z on the day
    /// `date` falls in locally.
    ///
    /// Quoted from `libgnucash/engine/gnc-date.h`: *"The
    /// gnc_time64_get_day_neutral() routine will take the given time in seconds
    /// and adjust it to 10:59:00Z of that day."* Its implementation
    /// (`gnc-date.cpp`, `gnc_tm_get_day_neutral`) takes the day via
    /// `gnc_localtime_r`, so the civil day is the **local** one — which is what
    /// this matches. 10:59Z is neutral because it stays on the same civil day
    /// from UTC−10 through UTC+13, so no reader anywhere shifts it a day.
    ///
    /// A price is a fact about a *day*, not an instant, and storing it as an
    /// instant let several conventions accumulate: the reference book carried
    /// `10:59`, `00:00`, `23:00`, `13:30` and `14:30` for the same idea. Days
    /// then differed by reader, which is how an inferred trading calendar ended
    /// up with 278 days a year against a real 250.
    public static func dayNeutral(_ date: Date, calendar: Calendar = .current) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                             hour: 10, minute: 59, second: 0)) ?? date
    }

    /// What makes two price rows the same row.
    ///
    /// GnuCash's rule, verbatim from `libgnucash/engine/gnc-pricedb.cpp`
    /// (`price_is_duplicate`): *"If the date, currency, commodity and price
    /// match, it's a duplicate"* — and the date it compares is
    /// `time64CanonicalDayTime`, the **day**, not the instant. So a second
    /// observation of the same value on the same day is the same row, while a
    /// *different* value on that day is a new one.
    ///
    /// That distinction is the whole point. Two rules were in use here: the
    /// latest-quote path skipped a row only when day **and value** matched,
    /// while the history path skipped any day it already held at all. The
    /// second is stricter than it looks — it means a correction can never land,
    /// and that the 06:00 auto-refresh's price is the only one a day can ever
    /// have. One rule, GnuCash's, on both paths.
    public struct Identity: Hashable, Sendable {
        public let commodity: Commodity
        public let currency: Commodity
        public let day: Date
        public let value: Decimal
    }

    /// This row's identity under the rule above.
    public var identity: Identity {
        Identity(commodity: commodity, currency: currency,
                 day: Self.dayNeutral(date), value: value)
    }

    /// Whether this price already carries the canonical time.
    public var isDayNeutral: Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.hour, .minute, .second], from: date)
        return parts.hour == 10 && parts.minute == 59 && parts.second == 0
    }
}
