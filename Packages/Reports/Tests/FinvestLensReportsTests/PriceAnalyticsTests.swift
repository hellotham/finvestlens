//
//  PriceAnalyticsTests.swift
//  FinvestLens — Reports
//
//  The Price History report's arithmetic, each figure checked by hand on a
//  series small enough to work on paper: moving averages and their crosses,
//  Wilder's RSI against StockCharts' definition, volatility, drawdown, range,
//  trend and month-end closes.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensReports

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day))!
}

/// `values` as one sample a day from `start`.
private func daily(_ values: [String], from start: Date = date(2025, 1, 1)) -> [PriceSample] {
    values.enumerated().map { i, value in
        PriceSample(date: utc.date(byAdding: .day, value: i, to: start)!, value: dec(value))
    }
}

@Suite("Price analytics")
struct PriceAnalyticsTests {

    @Test("A simple moving average covers a window of samples, nil before the window fills")
    func simpleMovingAverage() {
        let series = daily(["1", "2", "3", "4", "5"])
        #expect(PriceAnalytics.simpleMovingAverage(series, window: 3) == [nil, nil, 2, 3, 4])
        #expect(PriceAnalytics.simpleMovingAverage(series, window: 1) == [1, 2, 3, 4, 5])
        #expect(PriceAnalytics.simpleMovingAverage(series, window: 6) == [nil, nil, nil, nil, nil])
        #expect(PriceAnalytics.simpleMovingAverage(series, window: 0) == [nil, nil, nil, nil, nil])
        #expect(PriceAnalytics.simpleMovingAverage([], window: 3).isEmpty)
    }

    @Test("The short average crossing above the long is a golden cross; crossing below, a death cross")
    func crossovers() {
        // Falls, rises, falls. SMA2 and SMA3 by hand:
        //   i      0    1    2    3      4      5    6     7       8
        //   price  10   9    8    9      11     13   12    10      8
        //   SMA2        9.5  8.5  8.5    10     12   12.5  11      9
        //   SMA3             9    8.667  9.333  11   12    11.667  10
        // Short below long at 2–3, above from 4 (golden), below from 7 (death).
        let series = daily(["10", "9", "8", "9", "11", "13", "12", "10", "8"])
        #expect(PriceAnalytics.crossovers(series, short: 2, long: 3) == [
            PriceAnalytics.Crossover(date: date(2025, 1, 5), kind: .golden, price: 11),
            PriceAnalytics.Crossover(date: date(2025, 1, 8), kind: .death, price: 10),
        ])
        // Equal averages never cross, and the windows must be short under long.
        #expect(PriceAnalytics.crossovers(daily(["5", "5", "5", "5", "5"]), short: 2, long: 3).isEmpty)
        #expect(PriceAnalytics.crossovers(series, short: 3, long: 2).isEmpty)
        // A series that only rises starts with the short above the long: no cross to report.
        #expect(PriceAnalytics.crossovers(daily(["1", "2", "3", "4", "5"]), short: 2, long: 3).isEmpty)
    }

    @Test("RSI's first value averages 14 changes simply; the next is Wilder-smoothed")
    func rsiByHand() throws {
        // Fourteen changes: +1 −0.5 +2 −1 +0.5 +1.5 −2 +1 −0.5 +3 −1.5 +0.5 +1 −1.
        // Gains sum to 10.5, losses to 6.5.
        let series = daily(["100", "101", "100.5", "102.5", "101.5", "102", "103.5", "101.5",
                            "102.5", "102", "105", "103.5", "104", "105", "104"])
        let rsi = PriceAnalytics.rsi(series)
        #expect(rsi.count == 15)
        #expect(rsi[0..<14].allSatisfy { $0 == nil })
        let firstGain = 10.5 / 14
        let firstLoss = 6.5 / 14
        let first = 100 - 100 / (1 + firstGain / firstLoss)
        let firstValue = try #require(rsi[14])
        #expect(abs(firstValue - first) < 1e-9)

        // One more sample, up 2: Wilder carries 13/14 of each average forward.
        let more = PriceAnalytics.rsi(series + [PriceSample(date: date(2025, 1, 16), value: 106)])
        let gain = (firstGain * 13 + 2) / 14
        let loss = (firstLoss * 13 + 0) / 14
        let second = 100 - 100 / (1 + gain / loss)
        let secondValue = try #require(more[15])
        #expect(abs(secondValue - second) < 1e-9)
        let repeated = try #require(more[14])
        #expect(abs(repeated - first) < 1e-9)
    }

    @Test("RSI of a series that only rises is 100; one that never moves reads 50")
    func rsiEdges() {
        let rising = daily((0..<20).map { String(100 + $0) })
        #expect(PriceAnalytics.rsi(rising).compactMap { $0 } == Array(repeating: 100, count: 6))
        let falling = daily((0..<20).map { String(100 - $0) })
        #expect(PriceAnalytics.rsi(falling).compactMap { $0 } == Array(repeating: 0, count: 6))
        let flat = daily(Array(repeating: "100", count: 20))
        #expect(PriceAnalytics.rsi(flat).compactMap { $0 } == Array(repeating: 50, count: 6))
        // A period needs one more sample than its length before it has a value.
        #expect(PriceAnalytics.rsi(daily(["1", "2", "3"]), period: 3).allSatisfy { $0 == nil })
        #expect(PriceAnalytics.rsi(daily(["1", "2", "3", "4"]), period: 3).compactMap { $0 } == [100])
    }

    @Test("Volatility is the deviation of log returns, scaled by the series' own periods a year")
    func volatility() throws {
        #expect(PriceAnalytics.annualisedVolatility(daily(["100", "100", "100", "100"])) == 0)
        #expect(PriceAnalytics.annualisedVolatility(daily(["100", "110"])) == nil)
        #expect(PriceAnalytics.annualisedVolatility([]) == nil)
        // Weekly, up 10% then back: returns ±ln 1.1 about a mean of zero, so the sample
        // deviation is ln 1.1 × √2, and a week's spacing annualises by √(365.25 / 7).
        let weekly = ["100", "110", "100"].enumerated().map { i, value in
            PriceSample(date: date(2025, 1, 1 + 7 * i), value: dec(value))
        }
        let vol = try #require(PriceAnalytics.annualisedVolatility(weekly))
        #expect(abs(vol - log(1.1) * 2.0.squareRoot() * (365.25 / 7).squareRoot()) < 1e-9)
        // A price that is not positive has no log return.
        #expect(PriceAnalytics.annualisedVolatility(daily(["100", "0", "100"])) == nil)
    }

    @Test("Max drawdown is the deepest fall from a peak before the price regains it")
    func maxDrawdown() throws {
        let drawdown = try #require(PriceAnalytics.maxDrawdown(daily(["100", "120", "90", "130"])))
        #expect(abs(drawdown.fraction - -0.25) < 1e-12)
        #expect(drawdown.peakDate == date(2025, 1, 2))
        #expect(drawdown.troughDate == date(2025, 1, 3))
        #expect(drawdown.recoveredDate == date(2025, 1, 4))
        #expect(PriceAnalytics.maxDrawdown(daily(["100", "100", "110", "120"])) == nil)
        #expect(PriceAnalytics.maxDrawdown(daily(["100"])) == nil)
        // Two episodes: the later, deeper one wins, and it has not recovered.
        let open = try #require(PriceAnalytics.maxDrawdown(daily(["100", "90", "100", "80", "90"])))
        #expect(abs(open.fraction - -0.20) < 1e-12)
        #expect(open.peakDate == date(2025, 1, 3) && open.troughDate == date(2025, 1, 4))
        #expect(open.recoveredDate == nil)
    }

    @Test("A range summary carries first, last, change, high and low")
    func summary() throws {
        let values = ["100", "125", "80", "110"]
        let summary = try #require(PriceAnalytics.summary(daily(values)))
        #expect(summary.first == PriceSample(date: date(2025, 1, 1), value: 100))
        #expect(summary.last == PriceSample(date: date(2025, 1, 4), value: 110))
        #expect(summary.change == 10)
        let fraction = try #require(summary.changeFraction)
        #expect(abs(fraction - 0.10) < 1e-12)
        #expect(summary.high == PriceSample(date: date(2025, 1, 2), value: 125))
        #expect(summary.low == PriceSample(date: date(2025, 1, 3), value: 80))
        #expect(PriceAnalytics.summary([]) == nil)
        // The series is put in date order before it is read.
        let reversed = try #require(PriceAnalytics.summary(Array(daily(values).reversed())))
        #expect(reversed.first.value == 100 && reversed.last.value == 110 && reversed.change == 10)
        // A zero first price has no fraction.
        #expect(PriceAnalytics.summary(daily(["0", "5"]))?.changeFraction == nil)
    }

    @Test("A slice keeps the samples dated within the bounds, both included")
    func slice() {
        let series = daily(["1", "2", "3", "4", "5"])   // 1–5 January
        #expect(PriceAnalytics.slice(series, from: date(2025, 1, 2), to: date(2025, 1, 4)).map(\.value) == [2, 3, 4])
        #expect(PriceAnalytics.slice(series, from: date(2025, 1, 3), to: date(2025, 1, 3)).map(\.value) == [3])
        #expect(PriceAnalytics.slice(series, from: date(2025, 1, 6), to: date(2025, 1, 9)).isEmpty)
        #expect(PriceAnalytics.slice(series, from: date(2024, 12, 1), to: date(2025, 2, 1)).count == 5)
    }

    @Test("Trend reads the log-price slope a year: doubling rises, halving falls, constant is flat")
    func trend() throws {
        let year = 365.25 * 86_400
        /// `values` spread evenly over exactly one year from 1 January 2025.
        func overAYear(_ values: [String]) -> [PriceSample] {
            values.enumerated().map { i, value in
                let offset = Double(i) / Double(values.count - 1) * year
                return PriceSample(date: date(2025, 1, 1).addingTimeInterval(offset), value: dec(value))
            }
        }
        // Exactly exponential: 100 → 100·√2 → 200 at 0, ½ and 1 year, so the slope is ln 2.
        let doubling = try #require(PriceAnalytics.trend(overAYear(["100", "141.4213562373095", "200"])))
        #expect(doubling.trend == .rising)
        #expect(abs(doubling.annualisedSlope - log(2.0)) < 1e-9)
        let halving = try #require(PriceAnalytics.trend(overAYear(["200", "141.4213562373095", "100"])))
        #expect(halving.trend == .falling)
        #expect(abs(halving.annualisedSlope + log(2.0)) < 1e-9)
        let flat = try #require(PriceAnalytics.trend(overAYear(["100", "100", "100"])))
        #expect(flat.trend == .flat)
        #expect(abs(flat.annualisedSlope) < 1e-12)
        // About 3% a year is flat against the 5% bar, rising against a 1% one.
        let gentle = overAYear(["100", "101.4889", "103"])
        #expect(PriceAnalytics.trend(gentle)?.trend == .flat)
        #expect(PriceAnalytics.trend(gentle, threshold: 0.01)?.trend == .rising)
        // Too few samples, no spread in time, or a price without a logarithm: no reading.
        #expect(PriceAnalytics.trend(overAYear(["100", "200"])) == nil)
        #expect(PriceAnalytics.trend(Array(repeating: PriceSample(date: date(2025, 1, 1), value: 100), count: 3)) == nil)
        #expect(PriceAnalytics.trend(daily(["100", "0", "100"])) == nil)
    }

    @Test("Monthly closes keep the last sample of each calendar month")
    func monthlyCloses() {
        let series = [
            (date(2025, 1, 2), "10"), (date(2025, 1, 31), "11"),
            (date(2025, 2, 3), "12"), (date(2025, 2, 14), "13"), (date(2025, 2, 27), "14"),
            (date(2025, 4, 1), "15"),
            (date(2026, 1, 15), "16"),
        ].map { PriceSample(date: $0.0, value: dec($0.1)) }
        let closes = PriceAnalytics.monthlyCloses(series, calendar: utc)
        #expect(closes.map(\.value) == [11, 14, 15, 16])
        #expect(closes.map(\.date) == [date(2025, 1, 31), date(2025, 2, 27), date(2025, 4, 1), date(2026, 1, 15)])
        #expect(PriceAnalytics.monthlyCloses([], calendar: utc).isEmpty)
    }
}
