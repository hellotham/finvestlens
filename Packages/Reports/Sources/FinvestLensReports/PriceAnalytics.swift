//
//  PriceAnalytics.swift
//  FinvestLens — Reports
//
//  The arithmetic under the Price History report: a dated price series for
//  one security, in one currency, read for its trend. Moving averages and
//  their crosses, Wilder's RSI, volatility, the worst drawdown, a window's
//  range, a least-squares trend reading and month-end closes — each a pure
//  function of the samples it is given, so the report can slice a window and
//  ask again without touching the book.
//
//  Windows are counted in samples, not calendar days. Our series are sparse:
//  one price per trading day at best, and for a managed fund often one a
//  week or one a month, so a "50-day" average over calendar days would mostly
//  be empty. Fifty samples of a monthly series is four years; the caller
//  labels the window by what the series is.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One price on one day: the unit of every series here. Named apart from
/// FeatureUI's `PricePoint`, which is a point the chart plots, not a sample
/// the arithmetic reads.
public struct PriceSample: Hashable, Sendable {
    public let date: Date
    public let value: Decimal

    public init(date: Date, value: Decimal) {
        self.date = date
        self.value = value
    }
}

/// Trend arithmetic over a price series. Every function takes samples in
/// ascending date order with at most one per day — the caller guarantees it,
/// and each function re-sorts defensively, since every result here depends
/// on neighbours being neighbours.
///
/// The averages and the RSI look back: the first `window − 1` samples have no
/// average, and the RSI carries every earlier change forward. Compute them
/// over the whole history and slice the *results* to the window on show, not
/// the series first — or the line starts late and the figure changes with
/// the zoom.
public enum PriceAnalytics {

    // MARK: - Moving averages

    /// The simple moving average over `window` samples: one value per input
    /// sample from index `window − 1` on, `nil` before, so the chart draws it
    /// against the same positions as the prices. Summed in `Decimal`, so a
    /// long series drifts by nothing. A window under one, or longer than the
    /// series, averages nothing.
    public static func simpleMovingAverage(_ series: [PriceSample], window: Int) -> [Decimal?] {
        let series = ordered(series)
        var result = [Decimal?](repeating: nil, count: series.count)
        guard window >= 1, series.count >= window else { return result }
        var sum = Decimal(0)
        for (i, sample) in series.enumerated() {
            sum += sample.value
            if i >= window { sum -= series[i - window].value }
            if i >= window - 1 { result[i] = sum / Decimal(window) }
        }
        return result
    }

    /// A crossing of a short moving average over a long one.
    public struct Crossover: Hashable, Sendable {
        public enum Kind: String, Sendable {
            /// The short average crossed above the long one — a buy signal.
            case golden
            /// The short average crossed below the long one — a sell signal.
            case death
        }

        public let date: Date
        public let kind: Kind
        /// The price on that date: where the chart puts the marker.
        public let price: Decimal

        public init(date: Date, kind: Kind, price: Decimal) {
            self.date = date
            self.kind = kind
            self.price = price
        }
    }

    /// Where a short simple average crosses a long one, in date order.
    /// Fidelity, "Moving averages": "the 'golden cross' occurs when the
    /// 50-day exponential moving average crosses above a 200-day moving
    /// average"; and the opposite, Fidelity's "2025's biggest chart trends":
    /// "a sell signal (i.e., a death cross) is generated when a short moving
    /// average … crosses below a long moving average". Fidelity's short
    /// average is exponential; ours is simple on both sides, so that a marker
    /// sits exactly where the two lines the chart draws meet.
    ///
    /// A reading where the two averages are equal keeps the previous state —
    /// an average that touches the other and turns back has not crossed it —
    /// and the first strict reading only sets the state: the series does not
    /// say what came before it, so it is never reported as a cross. Windows
    /// that are not short-under-long give no crosses.
    public static func crossovers(_ series: [PriceSample], short: Int = 50, long: Int = 200) -> [Crossover] {
        guard short >= 1, long > short else { return [] }
        let series = ordered(series)
        let shortAverage = simpleMovingAverage(series, window: short)
        let longAverage = simpleMovingAverage(series, window: long)
        var above: Bool?
        var crosses: [Crossover] = []
        for (i, sample) in series.enumerated() {
            guard let s = shortAverage[i], let l = longAverage[i], s != l else { continue }
            let nowAbove = s > l
            if let wasAbove = above, wasAbove != nowAbove {
                crosses.append(Crossover(date: sample.date, kind: nowAbove ? .golden : .death, price: sample.value))
            }
            above = nowAbove
        }
        return crosses
    }

    // MARK: - Relative Strength Index

    /// Wilder's Relative Strength Index, as StockCharts' ChartSchool defines
    /// it: "RSI = 100 − 100 / (1 + RS)" with "RS = Average Gain / Average
    /// Loss", where "First Average Gain = Sum of Gains over the past 14
    /// periods / 14", "First Average Loss = Sum of Losses over the past 14
    /// periods / 14", and from then on "Average Gain = [(previous Average
    /// Gain) x 13 + current Gain] / 14", "Average Loss = [(previous Average
    /// Loss) x 13 + current Loss] / 14". A gain or loss is the change from
    /// one sample to the next; `period` is Wilder's 14 by default. "Wilder
    /// considered RSI overbought above 70 and oversold below 30."
    ///
    /// One value per sample from index `period` on, `nil` before. "If the
    /// Average Loss equals zero, a 'divide by zero' situation occurs for RS,
    /// and RSI is set to 100 by definition"; when nothing has moved at all —
    /// no gain and no loss, which the formula leaves as 0 ÷ 0 — the reading
    /// is 50, the midpoint, which is also where equal gains and losses land.
    ///
    /// The smoothing carries every earlier change forward, so "RSI values may
    /// differ based on the total calculation period"; StockCharts "uses at
    /// least 250 data points before the starting date of any chart". Hence
    /// the rule above: the whole history in, the window's results out.
    public static func rsi(_ series: [PriceSample], period: Int = 14) -> [Double?] {
        let series = ordered(series)
        var result = [Double?](repeating: nil, count: series.count)
        guard period >= 1, series.count > period else { return result }
        let periods = Double(period)
        var averageGain = 0.0
        var averageLoss = 0.0
        for i in 1..<series.count {
            let change = double(series[i].value - series[i - 1].value)
            let gain = max(change, 0)
            let loss = max(-change, 0)
            if i < period {
                averageGain += gain
                averageLoss += loss
            } else if i == period {
                averageGain = (averageGain + gain) / periods
                averageLoss = (averageLoss + loss) / periods
            } else {
                averageGain = (averageGain * (periods - 1) + gain) / periods
                averageLoss = (averageLoss * (periods - 1) + loss) / periods
            }
            if i >= period {
                result[i] = relativeStrengthIndex(averageGain: averageGain, averageLoss: averageLoss)
            }
        }
        return result
    }

    private static func relativeStrengthIndex(averageGain: Double, averageLoss: Double) -> Double {
        guard averageLoss > 0 else { return averageGain > 0 ? 100 : 50 }
        let rs = averageGain / averageLoss
        return 100 - 100 / (1 + rs)
    }

    // MARK: - Volatility

    /// Annualised volatility: the sample standard deviation of the log
    /// returns between consecutive samples, scaled by the square root of the
    /// number of such periods in a year. That number is the series' own —
    /// 365.25 over the median spacing of its samples in whole calendar days
    /// — so a daily series annualises by about √365, a weekly one by √52 and
    /// a monthly one by √12, and a fund priced monthly is not read as many
    /// times calmer than a share priced daily. The median rather than the
    /// mean, so a gap in the data — a holiday, a missing month — does not
    /// move it. `nil` under three samples (two returns are the fewest a
    /// sample deviation can be taken from), or when a price is not positive
    /// and so has no logarithm.
    public static func annualisedVolatility(_ series: [PriceSample]) -> Double? {
        let series = ordered(series)
        guard series.count >= 3, let returns = logReturns(series) else { return nil }
        guard let spacing = medianSpacingDays(series), spacing > 0 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count - 1)
        return variance.squareRoot() * (InvestmentYield.daysPerYear / spacing).squareRoot()
    }

    // MARK: - Drawdown

    /// The worst fall from a peak, as a fraction of that peak, and when it ran.
    public struct Drawdown: Hashable, Sendable {
        /// The loss as a fraction of the peak, negative: −0.25 is a 25% fall.
        public let fraction: Double
        public let peakDate: Date
        public let troughDate: Date
        /// The first date the price was back at or above the peak, or `nil`
        /// if it had not been by the end of the series.
        public let recoveredDate: Date?

        public init(fraction: Double, peakDate: Date, troughDate: Date, recoveredDate: Date?) {
            self.fraction = fraction
            self.peakDate = peakDate
            self.troughDate = troughDate
            self.recoveredDate = recoveredDate
        }
    }

    /// The maximum drawdown — Sharesight, Drawdown Risk Report: "the largest
    /// observed loss … from a peak to a trough before reaching a new peak",
    /// "MDD = (Trough Value − Peak Value) ÷ Peak Value". Each peak opens an
    /// episode that ends when the price is back at that level; the episode
    /// with the deepest trough is reported, with the date it ended, and an
    /// earlier episode wins a tie. `nil` under two samples, or when the price
    /// never falls below an earlier one.
    public static func maxDrawdown(_ series: [PriceSample]) -> Drawdown? {
        let series = ordered(series)
        guard series.count >= 2, var peak = series.first else { return nil }
        var trough: PriceSample?
        var worst: Drawdown?
        func closeEpisode(recovered: Date?) {
            guard let low = trough, peak.value > 0 else { return }
            let fraction = double((low.value - peak.value) / peak.value)
            if let best = worst, best.fraction <= fraction { return }
            worst = Drawdown(fraction: fraction, peakDate: peak.date, troughDate: low.date, recoveredDate: recovered)
        }
        for sample in series.dropFirst() {
            if sample.value >= peak.value {
                closeEpisode(recovered: sample.date)
                peak = sample
                trough = nil
            } else if trough.map({ sample.value < $0.value }) ?? true {
                trough = sample
            }
        }
        closeEpisode(recovered: nil)
        return worst
    }

    // MARK: - Range

    /// What a window did: its first and last samples, the change between
    /// them — absolute, and as a fraction of the first, `nil` when the first
    /// price is zero — and its high and low with their dates.
    public struct RangeSummary: Hashable, Sendable {
        public let first: PriceSample
        public let last: PriceSample
        public let change: Decimal
        public let changeFraction: Double?
        public let high: PriceSample
        public let low: PriceSample

        public init(first: PriceSample, last: PriceSample, change: Decimal, changeFraction: Double?,
                    high: PriceSample, low: PriceSample) {
            self.first = first
            self.last = last
            self.change = change
            self.changeFraction = changeFraction
            self.high = high
            self.low = low
        }
    }

    /// The range statistics of a series; `nil` when it is empty. A tie for
    /// the high or the low goes to the earliest sample.
    public static func summary(_ series: [PriceSample]) -> RangeSummary? {
        let series = ordered(series)
        guard let first = series.first, let last = series.last else { return nil }
        var high = first
        var low = first
        for sample in series.dropFirst() {
            if sample.value > high.value { high = sample }
            if sample.value < low.value { low = sample }
        }
        let change = last.value - first.value
        let fraction: Double? = first.value == 0 ? nil : double(change / first.value)
        return RangeSummary(first: first, last: last, change: change, changeFraction: fraction, high: high, low: low)
    }

    /// The samples dated within `from`…`to`, both ends included.
    public static func slice(_ series: [PriceSample], from: Date, to: Date) -> [PriceSample] {
        ordered(series).filter { $0.date >= from && $0.date <= to }
    }

    // MARK: - Trend

    public enum Trend: String, Sendable {
        case rising, flat, falling
    }

    /// A reading of a window's direction from the least-squares slope of log
    /// price against time in years. The slope of a log price is a
    /// continuously compounded rate, so it reads the same for a $2 share and
    /// a $200 one; fitting the whole window, rather than comparing its ends,
    /// means one odd print at either edge does not decide it. `.rising` when
    /// the slope is over `threshold` a year (5% by default), `.falling` when
    /// under −`threshold`, else `.flat`. Time is continuous here — a price is
    /// a point in time, and no class boundary turns on a whole day. `nil`
    /// under three samples, when every sample shares a date, or when a price
    /// is not positive.
    public static func trend(_ series: [PriceSample], threshold: Double = 0.05) -> (trend: Trend, annualisedSlope: Double)? {
        let series = ordered(series)
        guard series.count >= 3, let first = series.first, let logs = logPrices(series) else { return nil }
        let secondsPerYear = 86_400 * InvestmentYield.daysPerYear
        let years = series.map { $0.date.timeIntervalSince(first.date) / secondsPerYear }
        let meanYears = years.reduce(0, +) / Double(years.count)
        let meanLog = logs.reduce(0, +) / Double(logs.count)
        var covariance = 0.0
        var spread = 0.0
        for (x, y) in zip(years, logs) {
            covariance += (x - meanYears) * (y - meanLog)
            spread += (x - meanYears) * (x - meanYears)
        }
        guard spread > 0 else { return nil }
        let slope = covariance / spread
        let trend: Trend = slope > threshold ? .rising : slope < -threshold ? .falling : .flat
        return (trend, slope)
    }

    // MARK: - Month-end closes

    /// The last sample in each calendar month, for a compact table of a long
    /// series. `calendar` decides where a month ends — the person's, by
    /// default, since a price is dated by the day it was struck.
    public static func monthlyCloses(_ series: [PriceSample], calendar: Calendar = .current) -> [PriceSample] {
        var closes: [PriceSample] = []
        var open: (month: DateComponents, sample: PriceSample)?
        for sample in ordered(series) {
            let month = calendar.dateComponents([.year, .month], from: sample.date)
            if let current = open, current.month != month { closes.append(current.sample) }
            open = (month, sample)
        }
        if let open { closes.append(open.sample) }
        return closes
    }

    // MARK: - Helpers

    /// The series in date order: as given when it already is, which is the
    /// caller's contract; sorted when it is not.
    private static func ordered(_ series: [PriceSample]) -> [PriceSample] {
        zip(series, series.dropFirst()).allSatisfy { $0.date <= $1.date }
            ? series
            : series.sorted { $0.date < $1.date }
    }

    /// The natural logarithm of each price, or `nil` if any is not positive.
    private static func logPrices(_ series: [PriceSample]) -> [Double]? {
        var logs: [Double] = []
        logs.reserveCapacity(series.count)
        for sample in series {
            let price = double(sample.value)
            guard price > 0 else { return nil }
            logs.append(log(price))
        }
        return logs
    }

    /// The log return from each sample to the next, or `nil` if any price is
    /// not positive.
    private static func logReturns(_ series: [PriceSample]) -> [Double]? {
        guard let logs = logPrices(series) else { return nil }
        return zip(logs.dropFirst(), logs).map { $0 - $1 }
    }

    /// The median gap between consecutive samples, in whole calendar days
    /// (UTC, as the Engine counts them); `nil` for fewer than two samples.
    private static func medianSpacingDays(_ series: [PriceSample]) -> Double? {
        let gaps = zip(series.dropFirst(), series)
            .map { Double(wholeCalendarDays(from: $1.date, to: $0.date)) }
            .sorted()
        guard !gaps.isEmpty else { return nil }
        let middle = gaps.count / 2
        return gaps.count.isMultiple(of: 2) ? (gaps[middle - 1] + gaps[middle]) / 2 : gaps[middle]
    }

    private static func double(_ value: Decimal) -> Double { InvestmentYield.double(value) }
}
