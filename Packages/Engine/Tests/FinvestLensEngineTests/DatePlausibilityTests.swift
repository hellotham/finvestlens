//
//  DatePlausibilityTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Written from a real defect: a book carried `1525-01-31` for a year. The
//  transaction balanced, reconciled and exported perfectly — it had simply
//  left the period it belonged to, so no report and no total ever looked wrong.
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Date plausibility")
struct DatePlausibilityTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("The years a person could have meant")
    func range() {
        #expect(DatePlausibility.isPlausible(date(2025, 1, 31)))
        #expect(DatePlausibility.isPlausible(date(1900, 1, 1)))
        #expect(DatePlausibility.isPlausible(date(2200, 12, 31)))
    }

    @Test("The two slips that actually happen are both caught")
    func slipsAreCaught() {
        // `d/M/yyyy` reading a two-digit year: 16/12/25 -> 0025.
        #expect(!DatePlausibility.isPlausible(date(25, 12, 16)))
        // The one this suite was written for — and the reason the importer's
        // old floor of 1500 was not enough, since 1525 clears it.
        #expect(!DatePlausibility.isPlausible(date(1525, 1, 31)))
        #expect(1525 > 1500, "the old QIF floor would have admitted this")
        #expect(!DatePlausibility.isPlausible(date(1899, 12, 31)))
        #expect(!DatePlausibility.isPlausible(date(2201, 1, 1)))
    }

    @Test("The year is read in UTC, matching how posting dates are stored")
    func yearIsUTC() {
        #expect(DatePlausibility.year(of: date(1525, 1, 31)) == 1525)
        #expect(DatePlausibility.year(of: date(2025, 1, 31)) == 2025)
    }

    @Test("Scrub reports an impossible year, and never repairs it")
    func scrubReportsIt() {
        let book = Book(baseCurrency: .aud)
        let cash = book.addAccount(Account(name: "Cash", type: .bank, commodity: .aud))
        let dining = book.addAccount(Account(name: "Dining Out", type: .expense, commodity: .aud))

        // A perfectly well-formed transaction that is simply in the wrong
        // millennium — balanced, two splits, both accounted for. Nothing except
        // the date check can see anything wrong with it.
        let txn = Transaction(currency: .aud, datePosted: date(1525, 1, 31),
                              description: "Monthly Food Spend")
        txn.addSplit(account: dining, value: 400)
        txn.addSplit(account: cash, value: -400)
        book.addTransaction(txn)

        #expect(txn.isBalanced)
        #expect(Scrub.check(book) == [.implausibleDate(txn.guid, date(1525, 1, 31))])
        // An error, not clutter: a book holding one is not clean.
        #expect(!Scrub.isClean(book))

        // Repair must leave it exactly where it is — the intended year exists
        // only in the owner's head, and a guess moves money into a real period.
        let summary = Scrub.clean(book)
        #expect(summary == Scrub.CleanupSummary())
        #expect(txn.datePosted == date(1525, 1, 31))
        #expect(Scrub.check(book) == [.implausibleDate(txn.guid, date(1525, 1, 31))])
    }

    @Test("A sound book reports nothing")
    func soundBookIsQuiet() {
        let book = Book(baseCurrency: .aud)
        let cash = book.addAccount(Account(name: "Cash", type: .bank, commodity: .aud))
        let dining = book.addAccount(Account(name: "Dining Out", type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: date(2025, 1, 31),
                              description: "Monthly Food Spend")
        txn.addSplit(account: dining, value: 400)
        txn.addSplit(account: cash, value: -400)
        book.addTransaction(txn)

        #expect(Scrub.check(book).isEmpty)
        #expect(Scrub.isClean(book))
    }
}
