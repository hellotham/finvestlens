//
//  PriceHistoryReport.swift
//  FinvestLens — Reports
//
//  One security's price history read the way an investor reads a chart
//  (the owner's brief: "navigate price history intelligently … technical
//  analysis trends"): a range, the price with or without the income it paid
//  per unit, moving averages with their crosses, RSI, the range's change and
//  extremes, the 52-week range, volatility and the worst drawdown, the
//  person's own buys and sells on the chart, and a benchmark to read it
//  against — a cash rate, or any index or security the book has prices for,
//  both rebased to 100 at the range start. The arithmetic is
//  `PriceAnalytics`; the trades and income come from the shared history.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// What a price chart is compared against.
public enum PriceBenchmark: Hashable, Sendable {
    /// A rate per annum, compounding daily from the range start — cash in
    /// the bank at that rate.
    case cashRate(Double)
    /// Another priced commodity — an index the book tracks, an ETF, another
    /// holding.
    case commodity(Commodity)
}

/// The report for one security over a range.
public struct PriceHistoryReport: Sendable {
    public var commodity: Commodity
    public var accountName: String?
    public var currencyCode: String
    public var from: Date
    public var to: Date
    /// The prices in the range, in the report currency, ascending.
    public var series: [PriceSample]
    /// Price plus the cash income the holding paid per unit held, summed
    /// from the range start — the chart's analogue of total return against
    /// capital gain. Equal to ``series`` when no income was paid.
    public var priceWithIncome: [PriceSample]
    /// Moving averages aligned to ``series`` (warmed up on prices before
    /// the range, so the first samples are not blank where history allows).
    public var sma50: [Decimal?]
    public var sma200: [Decimal?]
    public var crossovers: [PriceAnalytics.Crossover]
    /// Wilder's RSI(14) aligned to ``series``.
    public var rsi: [Double?]
    public var latestRSI: Double?
    public var summary: PriceAnalytics.RangeSummary?
    /// The year to the range's end.
    public var fiftyTwoWeekHigh: PriceSample?
    public var fiftyTwoWeekLow: PriceSample?
    public var volatility: Double?
    public var drawdown: PriceAnalytics.Drawdown?
    public var trend: PriceAnalytics.Trend?
    public var trendSlope: Double?
    /// The person's buys and sells in the range.
    public var trades: [InvestmentEvent]
    /// Income paid in the range.
    public var income: [InvestmentEvent]
    public var unitsHeld: Decimal
    /// Average cost of what is held at the range end.
    public var averageCost: Decimal?
    /// The holding rebased to 100 at the range start, on price, and on
    /// price with income.
    public var rebasedPrice: [PriceSample]
    public var rebasedPriceWithIncome: [PriceSample]
    /// The benchmark rebased to 100 at the range start, when one is chosen
    /// and has prices in the range.
    public var benchmark: PriceBenchmark?
    public var benchmarkLabel: String?
    public var benchmarkRebased: [PriceSample]
    /// The range's change on the holding (price, price with income) and on
    /// the benchmark.
    public var benchmarkChangeFraction: Double?
    public var priceWithIncomeChangeFraction: Double?
    /// Month-end closes in the range, for the printed table.
    public var monthlyCloses: [PriceSample]
    public var unconvertedCurrencyCodes: [String]
}

public extension FinancialReports {

    /// Every recorded price of `commodity` in `currency` — priced directly,
    /// or in another currency and converted on the day — ascending, one per
    /// day (the last that day wins).
    static func priceSeries(_ book: Book, commodity: Commodity, currency: Commodity,
                            calendar: Calendar = .current) -> (series: [PriceSample], unconverted: [String]) {
        var byDay: [Date: PriceSample] = [:]
        var unconverted: Set<String> = []
        for price in book.prices where price.commodity == commodity {
            let day = calendar.startOfDay(for: price.date)
            let value: Decimal?
            if price.currency == currency {
                value = price.value
            } else {
                value = book.convert(price.value, from: price.currency, to: currency, on: price.date)
                if value == nil { unconverted.insert(price.currency.mnemonic) }
            }
            guard let value else { continue }
            if let existing = byDay[day], existing.date > price.date { continue }
            byDay[day] = PriceSample(date: price.date, value: value)
        }
        return (byDay.values.sorted { $0.date < $1.date }, unconverted.sorted())
    }

    /// The price history of `commodity` over `[from, to]`, with the trades
    /// and income of `account` (the holding of it) when given.
    static func priceHistory(
        _ book: Book,
        commodity: Commodity,
        account: Account?,
        currency: Commodity,
        from: Date,
        to: Date,
        benchmark: PriceBenchmark? = nil,
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        calendar: Calendar = .current
    ) -> PriceHistoryReport {
        let (all, unconverted) = priceSeries(book, commodity: commodity, currency: currency, calendar: calendar)
        let series = PriceAnalytics.slice(all, from: from, to: to)
        // Averages and RSI warm up on everything before the range.
        func aligned<T>(_ values: [T?]) -> [T?] {
            let dates = Set(series.map(\.date))
            return zip(all, values).filter { dates.contains($0.0.date) }.map(\.1)
        }
        let sma50 = aligned(PriceAnalytics.simpleMovingAverage(all, window: 50))
        let sma200 = aligned(PriceAnalytics.simpleMovingAverage(all, window: 200))
        let rsi = aligned(PriceAnalytics.rsi(all))
        let crossovers = PriceAnalytics.crossovers(all).filter { $0.date >= from && $0.date <= to }
        let yearBack = calendar.date(byAdding: .year, value: -1, to: to) ?? from
        let lastYear = PriceAnalytics.slice(all, from: yearBack, to: to)
        let trend = PriceAnalytics.trend(series)

        // The holding: its trades and income in the range, units and cost.
        var trades: [InvestmentEvent] = []
        var income: [InvestmentEvent] = []
        var units = Decimal(0)
        var averageCost: Decimal?
        var priceWithIncome = series
        if let account {
            let history = investmentHistory(book, account: account, currency: currency, to: to,
                                            method: method, feeTreatment: feeTreatment)
            trades = history.events.filter { ($0.kind == .buy || $0.kind == .sell) && $0.date >= from && $0.date <= to }
            income = history.events.filter { $0.kind.isCashIncome && $0.date >= from && $0.date <= to }
            units = history.unitsHeld
            averageCost = units != 0 ? history.remainingCostBasis / units : nil
            // Income per unit held on the day it was paid, accumulated from
            // the range start, added to every later price.
            var perUnit: [(date: Date, amount: Decimal)] = []
            for payment in income {
                let held = unitsHeld(history, on: payment.date)
                guard held > 0 else { continue }
                perUnit.append((payment.date, payment.amount / held))
            }
            priceWithIncome = series.map { sample in
                let accumulated = perUnit.filter { $0.date <= sample.date }.reduce(Decimal(0)) { $0 + $1.amount }
                return PriceSample(date: sample.date, value: sample.value + accumulated)
            }
        }

        func rebased(_ samples: [PriceSample]) -> [PriceSample] {
            guard let first = samples.first, first.value != 0 else { return [] }
            return samples.map { PriceSample(date: $0.date, value: $0.value / first.value * 100) }
        }
        var benchmarkRebased: [PriceSample] = []
        var benchmarkLabel: String?
        var benchmarkChange: Double?
        switch benchmark {
        case .cashRate(let rate)?:
            benchmarkLabel = nil
            benchmarkRebased = series.map { sample in
                let years = InvestmentYield.years(from: from, to: sample.date)
                return PriceSample(date: sample.date, value: Decimal(100 * pow(1 + rate, years)))
            }
            benchmarkChange = benchmarkRebased.last.map { InvestmentYield.double($0.value) / 100 - 1 }
        case .commodity(let other)?:
            let (otherSeries, _) = priceSeries(book, commodity: other, currency: currency, calendar: calendar)
            let inRange = PriceAnalytics.slice(otherSeries, from: from, to: to)
            benchmarkRebased = rebased(inRange)
            benchmarkLabel = other.mnemonic
            benchmarkChange = PriceAnalytics.summary(inRange)?.changeFraction
        case nil:
            break
        }

        return PriceHistoryReport(
            commodity: commodity, accountName: account?.name, currencyCode: currency.mnemonic,
            from: from, to: to, series: series, priceWithIncome: priceWithIncome,
            sma50: sma50, sma200: sma200, crossovers: crossovers,
            rsi: rsi, latestRSI: rsi.last ?? nil,
            summary: PriceAnalytics.summary(series),
            fiftyTwoWeekHigh: PriceAnalytics.summary(lastYear)?.high,
            fiftyTwoWeekLow: PriceAnalytics.summary(lastYear)?.low,
            volatility: PriceAnalytics.annualisedVolatility(series),
            drawdown: PriceAnalytics.maxDrawdown(series),
            trend: trend?.trend, trendSlope: trend?.annualisedSlope,
            trades: trades, income: income, unitsHeld: units, averageCost: averageCost,
            rebasedPrice: rebased(series), rebasedPriceWithIncome: rebased(priceWithIncome),
            benchmark: benchmark, benchmarkLabel: benchmarkLabel, benchmarkRebased: benchmarkRebased,
            benchmarkChangeFraction: benchmarkChange,
            priceWithIncomeChangeFraction: PriceAnalytics.summary(priceWithIncome)?.changeFraction,
            monthlyCloses: PriceAnalytics.monthlyCloses(series, calendar: calendar),
            unconvertedCurrencyCodes: unconverted)
    }

    /// Units of the holding on a day, from its trades and splits.
    static func unitsHeld(_ history: InvestmentHistory, on date: Date) -> Decimal {
        history.events.filter { $0.date <= date }.reduce(Decimal(0)) { total, event in
            switch event.kind {
            case .buy, .split: total + (event.units ?? 0)
            case .sell: total - (event.units ?? 0)
            default: total
            }
        }
    }
}
