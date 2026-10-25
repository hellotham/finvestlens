//
//  MoneyWeightedReturnTests.swift
//  FinvestLens — Reports
//
//  XIRR as Excel defines it: Microsoft's own worked example to the digit, the
//  two-flow case agreeing with GnuCash's CAGR, a loss that needs the
//  bracketing fallback, and the inputs that have no rate.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }
private func flow(_ days: Int, _ amount: Decimal) -> DatedCashFlow { DatedCashFlow(date: day(days), amount: amount) }

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Money-weighted return (XIRR)")
struct MoneyWeightedReturnTests {

    @Test("Microsoft's worked example comes out at 0.373362535")
    func microsoftExample() throws {
        let flows = [
            DatedCashFlow(date: date(2008, 1, 1), amount: -10_000),
            DatedCashFlow(date: date(2008, 3, 1), amount: 2_750),
            DatedCashFlow(date: date(2008, 10, 30), amount: 4_250),
            DatedCashFlow(date: date(2009, 2, 15), amount: 3_250),
            DatedCashFlow(date: date(2009, 4, 1), amount: 2_750),
        ]
        let rate = try #require(MoneyWeightedReturn.rate(of: flows, guess: 0.1))
        #expect(abs(rate - 0.373362535) < 1e-6)
    }

    @Test("Two flows give the compound annual growth rate, whatever the guess")
    func twoFlowsAreCAGR() throws {
        // −100 then +121 exactly 730 days on: (121 ÷ 100)^(1 ÷ 2) − 1 = 0.10,
        // which is what GnuCash's lots report prints as CAGR.
        let flows = [flow(0, -100), flow(730, 121)]
        for guess in [0.1, 0.5, -0.5, 3.0] {
            let rate = try #require(MoneyWeightedReturn.rate(of: flows, guess: guess))
            #expect(abs(rate - 0.10) < 1e-9, "guess \(guess)")
        }
    }

    @Test("A year is 365 days, as in Excel")
    func excelYear() throws {
        // +10% over 365 days is exactly 10% a year on a 365-day year; over
        // 365.25 it would read 0.1000…7.
        let rate = try #require(MoneyWeightedReturn.rate(of: [flow(0, -100), flow(365, 110)]))
        #expect(abs(rate - 0.10) < 1e-9)
    }

    @Test("No sign change, one flow, or a span under a day has no rate")
    func undefined() {
        #expect(MoneyWeightedReturn.rate(of: [flow(0, 100), flow(365, 110)]) == nil)
        #expect(MoneyWeightedReturn.rate(of: [flow(0, -100), flow(365, -110)]) == nil)
        #expect(MoneyWeightedReturn.rate(of: [flow(0, -100), flow(365, 0)]) == nil)
        #expect(MoneyWeightedReturn.rate(of: [flow(0, -100)]) == nil)
        #expect(MoneyWeightedReturn.rate(of: []) == nil)
        #expect(MoneyWeightedReturn.rate(of: [flow(0, -100), flow(0, 150)]) == nil)
    }

    @Test("A loss is a negative rate")
    func loss() throws {
        // −100 then +50 a year later: 50 ÷ 100 − 1 = −0.5. Newton from 10%
        // steps past −100% here, so this exercises the bracketing fallback.
        let rate = try #require(MoneyWeightedReturn.rate(of: [flow(0, -100), flow(365, 50)]))
        #expect(abs(rate + 0.5) < 1e-9)
    }

    @Test("Flows out of date order are sorted first")
    func unsorted() throws {
        let rate = try #require(MoneyWeightedReturn.rate(of: [flow(730, 121), flow(0, -100)]))
        #expect(abs(rate - 0.10) < 1e-9)
    }

    @Test("A same-day flow cancelling the first still converges")
    func sameDayCancellation() throws {
        // A purchase and its same-day reversal sit at day fraction zero and
        // net to nothing at every rate; the dated pair left over is the
        // two-flow case at 20%: (144 ÷ 100)^(1 ÷ 2) − 1.
        let flows = [flow(0, -100), flow(0, 100), flow(365, -100), flow(1095, 144)]
        let rate = try #require(MoneyWeightedReturn.rate(of: flows))
        #expect(abs(rate - 0.20) < 1e-9)
    }

    @Test("Dividends along the way are dated flows like any other")
    func dividends() throws {
        // −1000, then 30 a year for three years, then 1000 back with the last
        // coupon: a bond at par paying 3%, whose yield is 3% to the digit.
        let flows = [flow(0, -1000), flow(365, 30), flow(730, 30), flow(1095, 1030)]
        let rate = try #require(MoneyWeightedReturn.rate(of: flows))
        #expect(abs(rate - 0.03) < 1e-9)
    }
}
