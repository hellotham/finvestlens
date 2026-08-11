//
//  PriceDayNeutralTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private let aud = Commodity.aud
private let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme", smallestFraction: 10000)
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
}

/// A price is a fact about a *day*. Storing it as an instant let twenty-four
/// clock conventions accumulate in one real book, after which two readers
/// disagreed about which day a price belonged to.
@Suite("Price day-neutral time")
struct PriceDayNeutralTests {

    @Test("A new price is stamped 10:59:00Z of its day")
    func normalisesOnCreation() {
        // GnuCash's own neutral time — gnc-date.h: "adjust it to 10:59:00Z of
        // that day". Neutral because it stays on the same civil day from UTC−10
        // through UTC+13, so no reader shifts it.
        let noon = utc.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 12))!
        let price = Price(commodity: acme, currency: aud, date: noon, value: 1)
        let parts = utc.dateComponents([.hour, .minute, .second], from: price.date)
        #expect(parts.hour == 10 && parts.minute == 59 && parts.second == 0)
        #expect(price.isDayNeutral)
    }

    @Test("Normalising is idempotent, so a migration can be re-run")
    func idempotent() {
        let noon = utc.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 12))!
        let once = Price.dayNeutral(noon)
        #expect(Price.dayNeutral(once) == once)
    }

    @Test("It never moves a price to another day")
    func staysOnItsDay() {
        // Every hour of a day must land on that same day, in whatever calendar
        // the caller is using — the whole point of a neutral time.
        for hour in 0..<24 {
            let instant = utc.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: hour))!
            let neutral = Price.dayNeutral(instant, calendar: utc)
            #expect(utc.dateComponents([.year, .month, .day], from: neutral)
                    == utc.dateComponents([.year, .month, .day], from: instant),
                    "hour \(hour) moved to a different day")
        }
    }

    @Test("An importer can keep the source's own timestamp")
    func preservingTime() {
        // A file's timestamps are data. Rewriting them would break fidelity to
        // the source, so importers opt out and only what the app *creates* is
        // normalised.
        let odd = utc.date(from: DateComponents(year: 2026, month: 8, day: 7,
                                                hour: 23, minute: 17, second: 3))!
        let imported = Price(commodity: acme, currency: aud, date: odd, value: 1,
                             preservingTime: true)
        #expect(imported.date == odd)
        #expect(!imported.isDayNeutral)
    }
}
