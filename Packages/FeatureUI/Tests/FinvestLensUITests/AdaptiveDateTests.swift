//
//  AdaptiveDateTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The user picks the date *order*; the app picks the *form*. These cover the
//  picking — the ladder's order, the ceiling that expresses context, and the
//  width that chooses within it. Widths are measured as characters × a
//  constant so the expectations do not move with a font.
//

import Foundation
import Testing
@testable import FinvestLensUI

@Suite("Adaptive dates")
struct AdaptiveDateTests {

    /// 16 December 2025 — a Tuesday, and a day/month pair that cannot be read
    /// in the wrong order by accident.
    private let date = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2025, month: 12, day: 16))!

    /// One "point" per character.
    private func measure(_ string: String) -> CGFloat { CGFloat(string.count) }

    @Test("The ladder runs richest to tersest")
    func ladderOrder() {
        #expect(AppDateFormat.Form.allCases == [.full, .long, .short, .compact])
        let format = AppDateFormat(order: .dmy)
        let widths = AppDateFormat.Form.allCases.map { measure(format.string(date, $0)) }
        // Each rung is strictly narrower than the one above it, which is the
        // property the whole mechanism rests on: stepping down always buys room.
        #expect(widths == widths.sorted(by: >))
        #expect(Set(widths).count == widths.count)
    }

    @Test("string(_:_:) is the same text as the named methods")
    func formsAgree() {
        for order in DateOrder.allCases {
            let format = AppDateFormat(order: order)
            #expect(format.string(date, .full) == format.full(date))
            #expect(format.string(date, .long) == format.long(date))
            #expect(format.string(date, .short) == format.short(date))
            #expect(format.string(date, .compact) == format.compact(date))
        }
    }

    @Test("The richest form that fits is the one chosen")
    func fittingPicksRichest() {
        let format = AppDateFormat(order: .dmy)
        // 30 characters holds "Tuesday, 16 December 2025" (25).
        #expect(format.fitting(date, width: 30, measure: measure) == format.full(date))
        // 20 holds "16 December 2025" (16) but not the full form.
        #expect(format.fitting(date, width: 20, measure: measure) == format.long(date))
        // 12 holds "16/12/2025" (10) only.
        #expect(format.fitting(date, width: 12, measure: measure) == format.short(date))
        // 9 forces the two-digit year, "16/12/25" (8).
        #expect(format.fitting(date, width: 9, measure: measure) == format.compact(date))
    }

    @Test("When nothing fits, the tersest whole date is shown — never a truncation")
    func fittingFallsBack() {
        let format = AppDateFormat(order: .dmy)
        // Zero room. A register cell this narrow is a layout bug, but the date
        // it shows must still be a date: the failure mode being designed out is
        // "16/12/20…", which hides the year the running balance depends on.
        #expect(format.fitting(date, width: 0, measure: measure) == format.compact(date))
        #expect(format.fitting(date, width: -5, measure: measure) == format.compact(date))
    }

    @Test("The ceiling is the context, and space never overrides it")
    func ceilingCaps() {
        let format = AppDateFormat(order: .dmy)
        // A dense table asks for .short. However much room it is given, it must
        // not start spelling months out — a column of a thousand rows is read
        // by scanning, and prose is harder to scan than digits.
        for width in [12, 40, 400, 4_000] {
            let text = format.fitting(date, width: CGFloat(width), ceiling: .short, measure: measure)
            #expect(text == format.short(date))
        }
        // And the floor still applies underneath the ceiling.
        #expect(format.fitting(date, width: 9, ceiling: .short, measure: measure)
                == format.compact(date))
    }

    @Test("A column's form is the one that fits its widest date, not its first")
    func columnFitsEveryRow() {
        let format = AppDateFormat(order: .dmy)
        let calendar = Calendar(identifier: .gregorian)
        let narrow = calendar.date(from: DateComponents(year: 2025, month: 3, day: 9))!  // 9/3/2025
        let wide = calendar.date(from: DateComponents(year: 2025, month: 12, day: 16))!  // 16/12/2025

        // 9 characters fits "9/3/2025" (8) but not "16/12/2025" (10). Deciding
        // per-row would give a column that disagrees with itself; deciding for
        // the whole column steps every row down together.
        #expect(format.fittingForm(for: [narrow], width: 9, measure: measure) == .short)
        #expect(format.fittingForm(for: [narrow, wide], width: 9, measure: measure) == .compact)
        #expect(format.fittingForm(for: [narrow, wide], width: 11, measure: measure) == .short)
    }

    @Test("An empty column does not crash and does not compress")
    func emptyColumn() {
        let format = AppDateFormat(order: .dmy)
        // `allSatisfy` on an empty list is true, so the richest form wins —
        // which is right: there is nothing that fails to fit.
        #expect(format.fittingForm(for: [], width: 0, measure: measure) == .short)
        #expect(format.fittingForm(for: [], width: 0, ceiling: .full, measure: measure) == .full)
    }

    @Test("A two-digit year is this century, never the year 25")
    func twoDigitYearIsNotYearTwentyFive() {
        // The register displays `16/12/25` when it is narrow. Clicking that
        // cell and pressing Return must not move the transaction to 16 December
        // **0025** — which is exactly what `d/M/yyyy` returns for that text,
        // without error, because DateFormatter is lenient about year width.
        for order in DateOrder.allCases {
            let format = AppDateFormat(order: order)
            let typed = format.compact(date)
            let parsed = format.parseAny(typed)
            #expect(parsed != nil, "\(order): \(typed) did not parse")
            let year = parsed.map { AppDateFormat.gregorian.component(.year, from: $0) }
            #expect(year == 2025, "\(order): \(typed) parsed to year \(year as Any)")
        }
        // Zero-padded spellings do not round-trip against either pattern and
        // land in the plausibility fallback; they must land the same way.
        let dmy = AppDateFormat(order: .dmy)
        #expect(dmy.parseAny("06/12/25").map { AppDateFormat.gregorian.component(.year, from: $0) } == 2025)
        #expect(dmy.parseAny("06/12/2025").map { AppDateFormat.gregorian.component(.year, from: $0) } == 2025)
        // And a genuinely four-digit year is still read as itself.
        #expect(dmy.parseAny("16/12/1999").map { AppDateFormat.gregorian.component(.year, from: $0) } == 1999)
        // Junk is still rejected rather than coerced.
        #expect(dmy.parseAny("not a date") == nil)
    }

    @Test("Every order compresses, and every form of every order parses back")
    func everyOrderRoundTrips() {
        for order in DateOrder.allCases {
            let format = AppDateFormat(order: order)
            #expect(measure(format.compact(date)) < measure(format.short(date)))
            // The register edits in place, so whatever it shows must be
            // typeable back — both numeric rungs, in every order.
            let calendar = Calendar(identifier: .gregorian)
            for form in [AppDateFormat.Form.short, .compact] {
                let text = format.string(date, form)
                let parsed = format.parseAny(text)
                #expect(parsed != nil, "\(order) \(form) — \(text) did not parse")
                if let parsed {
                    #expect(calendar.isDate(parsed, inSameDayAs: date),
                            "\(order) \(form) — \(text) parsed to \(parsed)")
                }
            }
        }
    }

    @Test("A dense table never spells the month out")
    func tableCeiling() {
        // One named decision shared by the AppKit register sheet and every
        // SwiftUI `AdaptiveDate` — neither can see the other, so the constant
        // is what keeps them agreeing. Raising it makes every table in the app
        // start writing "16 December 2025" down a column, which is the thing
        // it exists to prevent.
        #expect(AppDateFormat.Form.table == .short)
        let format = AppDateFormat(order: .dmy)
        #expect(format.fitting(date, width: 10_000, ceiling: .table, measure: measure)
                == format.short(date))
    }
}
