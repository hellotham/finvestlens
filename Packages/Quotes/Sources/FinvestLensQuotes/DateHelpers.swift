//
//  DateHelpers.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// `YYYY-MM-DD` formatting/parsing shared by the providers that publish a
/// **date** rather than an instant (Stooq, EODHD, Alpha Vantage, FIIG, Wilson).
///
/// The date such a provider prints is a civil day, not a moment, so the instant
/// chosen to represent it must land on that same civil day for every reader.
/// **10:59Z does; midnight UTC does not.** That is not an arbitrary preference:
/// `Price.init` normalises every price it stores to GnuCash's day-neutral time
/// (10:59:00Z of the day the instant falls in *locally*), so a series parsed at
/// 00:00Z is re-read in the reader's own calendar — and west of UTC that is the
/// day before. A Los Angeles reader's Stooq history was therefore stamped one
/// day earlier than the same security's Yahoo history, which carries a real
/// intraday timestamp. Parsing straight to 10:59Z makes the later
/// normalisation a no-op and every date-only provider agree.
///
/// 10:59Z is neutral from UTC−10 through UTC+13, the range GnuCash chose it for
/// (`libgnucash/engine/gnc-date.h`, `gnc_time64_get_day_neutral`).
enum QuoteDate {
    /// The civil day a date-only string names, as a UTC calendar date.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The civil day `date` falls in, in UTC — the inverse of ``date(from:)``
    /// for anything this parsed, and the form request parameters want.
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// The instant representing the civil day `string` names: 10:59:00Z, so the
    /// day survives being re-read in any reader's calendar.
    static func date(from string: String) -> Date? {
        formatter.date(from: string).map(dayNeutral)
    }

    /// Moves an instant to 10:59:00Z of the UTC day it falls in.
    static func dayNeutral(_ date: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = utc.dateComponents([.year, .month, .day], from: date)
        return utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                             hour: 10, minute: 59, second: 0)) ?? date
    }
}
