//
//  ReportsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

/// A tabbed reports view: Balance Sheet, Income Statement, and a Net-Worth chart.
/// Wraps the reports workspace for presentation in its own window (HIG:
/// sheets are for brief, focused tasks — an analytics workspace gets a
/// window so it doesn't block the register).
public struct ReportsWindow: View {
    @Bindable var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        if model.isOpen {
            NavigationStack { ReportsHome(model: model) }
        } else {
            ContentUnavailableView("No book open", systemImage: "chart.pie",
                                   description: Text("Open a book to see its reports."))
                .windowFloor(minWidth: 520, minHeight: 440)
        }
    }
}

// MARK: - Price History

/// The quick ranges above the price chart — Apple's Stocks app's, less the
/// intraday ones a book of daily prices has no use for — each a period the
/// window's selector could have been set to, so the two never disagree.
enum PriceRange: String, CaseIterable, Identifiable {
    case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M", yearToDate = "YTD",
         oneYear = "1Y", fiveYears = "5Y", all = "All"

    var id: String { rawValue }

    /// The chip's text: the abbreviations stand, "All" is a word.
    var label: String { self == .all ? String(localized: "All") : rawValue }

    func period(today: Date = Date(), calendar: Calendar = .current) -> ReportPeriod {
        let day = calendar.startOfDay(for: today)
        func back(_ components: DateComponents) -> ReportPeriod {
            .custom(from: calendar.date(byAdding: components, to: day) ?? day, to: day)
        }
        switch self {
        case .oneMonth: return back(DateComponents(month: -1))
        case .threeMonths: return back(DateComponents(month: -3))
        case .sixMonths: return back(DateComponents(month: -6))
        case .yearToDate: return .calendarYearToDate
        case .oneYear: return .last12Months
        case .fiveYears: return back(DateComponents(year: -5))
        case .all: return .allTime
        }
    }

    /// The range a period is, if it is one of these.
    static func matching(_ period: ReportPeriod, today: Date = Date()) -> PriceRange? {
        allCases.first { $0.period(today: today) == period }
    }
}

extension Commodity {
    /// The key a configuration stores a security under
    /// (``ReportConfiguration/securityKey``): the namespace's own name and
    /// the mnemonic, so a favourite reads the same in any build.
    var priceHistoryKey: String {
        switch namespace {
        case .currency: "currency|\(mnemonic)"
        case .security(let name): "\(name)|\(mnemonic)"
        case .other(let name): "other:\(name)|\(mnemonic)"
        }
    }
}

extension AppModel {
    /// The benchmark a configuration names: a cash rate (`"cash:0.0435"`), or
    /// a priced commodity by its key.
    func priceBenchmark(for configuration: ReportConfiguration) -> PriceBenchmark? {
        guard let text = configuration.benchmark, !text.isEmpty else { return nil }
        if text.hasPrefix("cash:") {
            return Double(text.dropFirst(5)).map { .cashRate($0) }
        }
        return securitiesWithPriceHistory.first { $0.priceHistoryKey == text }.map { .commodity($0) }
    }

    /// The security Price History shows: the configuration's, if it is still
    /// priced and in the chosen portfolio, else the first that is.
    func priceHistorySecurity(for configuration: ReportConfiguration) -> Commodity? {
        let candidates = pricedSecurities(inPortfolio: portfolioFilter(configuration))
        if let key = configuration.securityKey, let chosen = candidates.first(where: { $0.priceHistoryKey == key }) {
            return chosen
        }
        return candidates.first
    }
}

/// Price History's own controls, in the report's parameter bar beside the
/// period and the portfolio: which security, what to compare it with, and
/// the price alone against the price with the income it paid.
struct PriceHistoryControls: View {
    @Bindable var model: AppModel
    @Binding var configuration: ReportConfiguration
    @State private var cashRateText = ""
    @FocusState private var rateFocused: Bool

    private enum BenchmarkChoice: Hashable {
        case none, cash, commodity(String)
    }

    private var choice: BenchmarkChoice {
        switch model.priceBenchmark(for: configuration) {
        case .cashRate?: .cash
        case .commodity(let other)?: .commodity(other.priceHistoryKey)
        case nil: .none
        }
    }

    private var cashRate: Double? {
        if case .cashRate(let rate)? = model.priceBenchmark(for: configuration) { return rate }
        return nil
    }

    var body: some View {
        let securities = model.pricedSecurities(inPortfolio: model.portfolioFilter(configuration))
        if !securities.isEmpty {
            Picker("Security", selection: Binding(
                get: { model.priceHistorySecurity(for: configuration)?.priceHistoryKey ?? "" },
                set: { configuration.securityKey = $0 })) {
                ForEach(securities, id: \.priceHistoryKey) { security in
                    Text(security.mnemonic).tag(security.priceHistoryKey)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("The security whose prices to show")

            let current = model.priceHistorySecurity(for: configuration)
            Picker("Benchmark", selection: Binding(get: { choice }, set: { setChoice($0) })) {
                Text("No benchmark").tag(BenchmarkChoice.none)
                Text("Cash rate").tag(BenchmarkChoice.cash)
                ForEach(model.securitiesWithPriceHistory.filter { $0 != current }, id: \.priceHistoryKey) { other in
                    Text(other.mnemonic).tag(BenchmarkChoice.commodity(other.priceHistoryKey))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Compare the security with cash at a rate you set, or with another priced security or index")
            if choice == .cash {
                HStack(spacing: 4) {
                    TextField("Cash rate", text: $cashRateText, prompt: Text(verbatim: "4.35"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .focused($rateFocused)
                        .onSubmit(applyCashRate)
                        // A rate typed and left applies when the field is left,
                        // not only on Return.
                        .onChange(of: rateFocused) { _, focused in if !focused { applyCashRate() } }
                        .accessibilityLabel("Cash rate, per cent a year")
                    Text("% p.a.").foregroundStyle(.secondary)
                }
                .onAppear {
                    if let rate = cashRate { cashRateText = (rate * 100).formatted(.number.precision(.fractionLength(0...2))) }
                }
            }

            Picker("Series", selection: Binding(
                get: { configuration.withIncome ?? false },
                set: { configuration.withIncome = $0 ? true : nil })) {
                Text("Price").tag(false)
                Text("Price + income").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("The price alone, or the price with the income the holding paid per unit added — the chart’s capital gain against its total return")
        }
    }

    private func setChoice(_ choice: BenchmarkChoice) {
        switch choice {
        case .none: configuration.benchmark = nil
        case .cash:
            let rate = cashRate ?? 0.0435
            configuration.benchmark = "cash:\(rate)"
            cashRateText = (rate * 100).formatted(.number.precision(.fractionLength(0...2)))
        case .commodity(let key): configuration.benchmark = key
        }
    }

    private func applyCashRate() {
        guard let percent = Double(cashRateText.replacingOccurrences(of: ",", with: ".")), percent >= 0, percent < 100 else { return }
        configuration.benchmark = "cash:\(percent / 100)"
    }
}

/// The Price History report: one security's prices over the window's period,
/// read as a person reads a price chart — the 50- and 200-day averages and
/// their crosses, the relative-strength index, the person's own buys and
/// sells with their average cost, the range's high, low, change, volatility
/// and worst fall, a benchmark rebased alongside, and the price with the
/// income it paid against the price alone. Asked for on build 10: "the user
/// wants to navigate price history intelligently … technical analysis
/// trends etc."
struct PriceHistoryView: View {
    @Environment(\.isCompactShell) private var compact
    @Bindable var model: AppModel
    @Binding var configuration: ReportConfiguration
    @State private var report: PriceHistoryReport?
    @State private var showSMA50 = true
    @State private var showSMA200 = true
    @State private var showRSI = false
    @State private var showTrades = true

    /// Everything the report is computed from.
    private struct Key: Hashable {
        var security: String?
        var period: ReportPeriod
        var benchmark: String?
        var portfolio: GncGUID?
        var revision: Int
    }
    private var key: Key {
        Key(security: model.priceHistorySecurity(for: configuration)?.priceHistoryKey,
            period: model.period, benchmark: configuration.benchmark,
            portfolio: model.portfolioFilter(configuration), revision: model.bookRevision)
    }
    private var withIncome: Bool { configuration.withIncome ?? false }
    private var periodLabel: String { model.label(for: model.period) }

    var body: some View {
        Group {
            if let security = model.priceHistorySecurity(for: configuration) {
                VStack(alignment: .leading, spacing: 0) {
                    ReportMasthead(entity: model.statementEntityName,
                                   title: String(localized: "Price History — \(security.mnemonic)"),
                                   period: periodLabel,
                                   code: model.reportCurrency.mnemonic)
                        .padding(.top, 12)
                    rangeBar
                    Divider()
                    if let report, key.security == security.priceHistoryKey {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if report.series.count < 2 {
                                    ContentUnavailableView("Not enough prices", systemImage: "chart.xyaxis.line",
                                                           description: Text("Record at least two prices in this period, or widen it."))
                                } else {
                                    statsStrip(report)
                                    priceChart(report)
                                    overlayBar(report)
                                    if showRSI { rsiChart(report) }
                                    readings(report)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: 1120, alignment: .leading)
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        ProgressView("Reading prices…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .task(id: key) {
                    let requested = key
                    await Task.yield()
                    let (from, to) = model.resolve(model.period)
                    let built = model.priceHistory(commodity: security, from: from, to: to,
                                                   benchmark: model.priceBenchmark(for: configuration),
                                                   portfolioID: model.portfolioFilter(configuration))
                    guard !Task.isCancelled, requested == key else { return }
                    report = built
                }
            } else {
                ContentUnavailableView("No prices", systemImage: "chart.xyaxis.line",
                                       description: Text("Record security prices to plot them over time."))
            }
        }
        .reportPDFToolbar(title: String(localized: "Price History"), entity: model.statementEntityName) {
            guard let security = model.priceHistorySecurity(for: configuration) else { return nil }
            let (from, to) = model.resolve(model.period)
            return model.priceHistoryDocument(commodity: security, from: from, to: to, periodLabel: periodLabel,
                                              benchmark: model.priceBenchmark(for: configuration),
                                              portfolioID: model.portfolioFilter(configuration))
        }
    }

    // MARK: Range

    private var rangeBar: some View {
        HStack {
            Picker("Range", selection: Binding(
                get: { PriceRange.matching(model.period) },
                set: { if let range = $0 { model.period = range.period() } })) {
                ForEach(PriceRange.allCases) { range in
                    Text(range.label).tag(Optional(range))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("A quick range; the period selector above takes any other")
            .accessibilityLabel("Chart range")
            Spacer()
        }
        .scaledFont(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: Statistics

    private struct Stat: Identifiable {
        var id: String { label }
        var label: String
        var value: String
        var signed: Double?
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—"
    }

    private func money(_ value: Decimal, code: String) -> String { AmountFormat.string(value, code: code) }

    private func stats(_ report: PriceHistoryReport) -> [Stat] {
        guard let summary = report.summary else { return [] }
        let code = report.currencyCode
        var stats: [Stat] = [
            Stat(label: String(localized: "Last"), value: money(summary.last.value, code: code)),
            Stat(label: withIncome ? String(localized: "Change with income") : String(localized: "Change"),
                 value: withIncome
                    ? percent(report.priceWithIncomeChangeFraction)
                    : "\(money(summary.change, code: code)) (\(percent(summary.changeFraction)))",
                 signed: withIncome ? report.priceWithIncomeChangeFraction : summary.changeFraction),
            Stat(label: String(localized: "High"), value: money(summary.high.value, code: code)),
            Stat(label: String(localized: "Low"), value: money(summary.low.value, code: code)),
        ]
        if let high = report.fiftyTwoWeekHigh, let low = report.fiftyTwoWeekLow {
            stats.append(Stat(label: String(localized: "52-week range"),
                              value: "\(money(low.value, code: code)) – \(money(high.value, code: code))"))
        }
        if let volatility = report.volatility {
            stats.append(Stat(label: String(localized: "Volatility p.a."), value: percent(volatility)))
        }
        if let drawdown = report.drawdown {
            stats.append(Stat(label: String(localized: "Max drawdown"), value: percent(drawdown.fraction), signed: drawdown.fraction))
        }
        if let trend = report.trend {
            let word = switch trend {
            case .rising: String(localized: "Rising")
            case .flat: String(localized: "Flat")
            case .falling: String(localized: "Falling")
            }
            stats.append(Stat(label: String(localized: "Trend"), value: word))
        }
        if let rsi = report.latestRSI {
            let reading = rsi >= 70 ? String(localized: "overbought") : rsi <= 30 ? String(localized: "oversold") : String(localized: "neutral")
            stats.append(Stat(label: String(localized: "RSI (14)"),
                              value: "\(rsi.formatted(.number.precision(.fractionLength(0)))) · \(reading)"))
        }
        if report.benchmark != nil, let change = report.benchmarkChangeFraction {
            stats.append(Stat(label: report.benchmarkLabel ?? String(localized: "Cash"), value: percent(change), signed: change))
        }
        if report.unitsHeld > 0, let average = report.averageCost {
            stats.append(Stat(label: String(localized: "Average cost (\(report.unitsHeld.formatted()) held)"),
                              value: money(average, code: code)))
        }
        return stats
    }

    private func statsStrip(_ report: PriceHistoryReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 140 : 160), spacing: 10, alignment: .top)],
                  alignment: .leading, spacing: 10) {
            ForEach(stats(report)) { stat in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stat.label)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .lineLimit(1)
                    Text(stat.value)
                        .scaledFont(.callout)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle((stat.signed ?? 0) < 0 ? Color.negativeAmount : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Chart

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let series: String
    }

    private static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

    private var priceSeriesName: String { withIncome ? String(localized: "Price + income") : String(localized: "Price") }
    private var sma50Name: String { String(localized: "50-day average") }
    private var sma200Name: String { String(localized: "200-day average") }

    /// With a benchmark the chart is an index — both rebased to 100 at the
    /// range start — because a share and an index share no price scale.
    private func rebased(_ report: PriceHistoryReport) -> Bool { report.benchmark != nil && !report.benchmarkRebased.isEmpty }

    private func points(_ report: PriceHistoryReport) -> [Point] {
        var points: [Point] = []
        let main: [PriceSample] = rebased(report)
            ? (withIncome ? report.rebasedPriceWithIncome : report.rebasedPrice)
            : (withIncome ? report.priceWithIncome : report.series)
        let mainName = rebased(report) ? report.commodity.mnemonic : priceSeriesName
        points += main.map { Point(id: "p\($0.date.timeIntervalSinceReferenceDate)", date: $0.date, value: Self.double($0.value), series: mainName) }
        if rebased(report) {
            let name = report.benchmarkLabel ?? String(localized: "Cash")
            points += report.benchmarkRebased.map { Point(id: "b\($0.date.timeIntervalSinceReferenceDate)", date: $0.date, value: Self.double($0.value), series: name) }
        } else if !withIncome {
            if showSMA50 {
                for (sample, average) in zip(report.series, report.sma50) {
                    if let average { points.append(Point(id: "s50\(sample.date.timeIntervalSinceReferenceDate)", date: sample.date, value: Self.double(average), series: sma50Name)) }
                }
            }
            if showSMA200 {
                for (sample, average) in zip(report.series, report.sma200) {
                    if let average { points.append(Point(id: "s200\(sample.date.timeIntervalSinceReferenceDate)", date: sample.date, value: Self.double(average), series: sma200Name)) }
                }
            }
        }
        return points
    }

    private func seriesColours(_ report: PriceHistoryReport) -> KeyValuePairs<String, Color> {
        if rebased(report) {
            return [report.commodity.mnemonic: Color.appAccent,
                    (report.benchmarkLabel ?? String(localized: "Cash")): Color.orange]
        }
        return [priceSeriesName: Color.appAccent, sma50Name: Color.orange, sma200Name: Color.teal]
    }

    @ViewBuilder
    private func priceChart(_ report: PriceHistoryReport) -> some View {
        let points = points(report)
        let isIndex = rebased(report)
        let overlays = !isIndex && showTrades
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: point.series == priceSeriesName || point.series == report.commodity.mnemonic ? 2 : 1))
            }
            if overlays {
                ForEach(report.trades) { trade in
                    if let units = trade.units, units != 0 {
                        PointMark(x: .value("Date", trade.date),
                                  y: .value("Value", Self.double(trade.amount / units.magnitude)))
                            .symbol(by: .value("Trade", trade.kind == .buy ? String(localized: "Buy") : String(localized: "Sell")))
                            .foregroundStyle(trade.kind == .buy ? Color.green : Color.negativeAmount)
                            .symbolSize(70)
                    }
                }
                if let average = report.averageCost, report.unitsHeld > 0 {
                    RuleMark(y: .value("Average cost", Self.double(average)))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("Average cost").scaledFont(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            if !isIndex, !withIncome, showSMA50, showSMA200 {
                ForEach(report.crossovers, id: \.date) { crossover in
                    PointMark(x: .value("Date", crossover.date), y: .value("Value", Self.double(crossover.price)))
                        .foregroundStyle(crossover.kind == .golden ? Color.green : Color.negativeAmount)
                        .symbolSize(90)
                        .annotation(position: .top) {
                            Text(crossover.kind == .golden ? "Golden cross" : "Death cross")
                                .scaledFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
        }
        .chartForegroundStyleScale(seriesColours(report))
        .chartLegend(position: .bottom)
        .chartXAxis {
            if compact { AxisMarks(values: .automatic(desiredCount: 4)) } else { AxisMarks() }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: compact ? 240 : 320)
        .accessibilityLabel(isIndex
            ? "\(report.commodity.mnemonic) and its benchmark, both rebased to 100, over \(periodLabel)"
            : "\(report.commodity.mnemonic) prices over \(periodLabel)")
    }

    private func overlayBar(_ report: PriceHistoryReport) -> some View {
        HStack(spacing: 14) {
            if !rebased(report), !withIncome {
                Toggle("50-day", isOn: $showSMA50).help("The 50-day simple moving average")
                Toggle("200-day", isOn: $showSMA200).help("The 200-day simple moving average")
                Toggle("RSI", isOn: $showRSI).help("The 14-day relative strength index, under the chart")
            }
            if !rebased(report), !report.trades.isEmpty || report.averageCost != nil {
                Toggle("Trades", isOn: $showTrades).help("Your buys and sells, and the average cost of what you hold")
            }
            Spacer()
        }
        .toggleStyle(.button)
        .scaledFont(.callout)
    }

    private func rsiChart(_ report: PriceHistoryReport) -> some View {
        let points = zip(report.series, report.rsi).compactMap { sample, value in
            value.map { Point(id: "r\(sample.date.timeIntervalSinceReferenceDate)", date: sample.date, value: $0, series: "RSI") }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("RSI (14)").scaledFont(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("RSI", point.value))
                        .foregroundStyle(.tint)
                }
                RuleMark(y: .value("Overbought", 70))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(.secondary)
                RuleMark(y: .value("Oversold", 30))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(.secondary)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [30, 50, 70]) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: compact ? 4 : 6)) }
            .frame(height: 90)
            .accessibilityLabel("Relative strength index over \(periodLabel); 70 is overbought, 30 oversold")
        }
    }

    // MARK: Readings

    /// What the figures say, in sentences — the same ones the PDF prints.
    @ViewBuilder
    private func readings(_ report: PriceHistoryReport) -> some View {
        let lines = readingLines(report)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Label {
                        Text(line).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "text.bubble").foregroundStyle(.tint)
                    }
                }
                Text("Prices as recorded in the book, in the report currency; the 50- and 200-day averages, the RSI and the crosses are computed on them, with earlier prices warming the averages. Nothing here is a recommendation.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func readingLines(_ report: PriceHistoryReport) -> [String] {
        var lines: [String] = []
        let long = { (date: Date) in AppDateFormat.current.long(date) }
        if report.priceWithIncome != report.series, let withIncome = report.priceWithIncomeChangeFraction,
           let change = report.summary?.changeFraction {
            lines.append(String(localized: "With the income paid per unit added, the holding returned \(percent(withIncome)) over the range, against \(percent(change)) on price alone."))
        }
        if let change = report.benchmarkChangeFraction, let own = withIncome ? report.priceWithIncomeChangeFraction : report.summary?.changeFraction {
            let name = report.benchmarkLabel ?? String(localized: "cash")
            lines.append(own >= change
                ? String(localized: "Ahead of \(name) over the range: \(percent(own)) against \(percent(change)).")
                : String(localized: "Behind \(name) over the range: \(percent(own)) against \(percent(change))."))
        }
        if let drawdown = report.drawdown {
            let recovered = drawdown.recoveredDate.map { String(localized: "and regained it on \(long($0))") } ?? String(localized: "and has not regained it")
            lines.append(String(localized: "The largest fall was \(percent(drawdown.fraction)), from the peak of \(long(drawdown.peakDate)) to \(long(drawdown.troughDate)), \(recovered)."))
        }
        for crossover in report.crossovers {
            lines.append(crossover.kind == .golden
                ? String(localized: "Golden cross on \(long(crossover.date)): the 50-day average rose through the 200-day.")
                : String(localized: "Death cross on \(long(crossover.date)): the 50-day average fell through the 200-day."))
        }
        if report.unitsHeld > 0, let average = report.averageCost, let last = report.summary?.last.value {
            let gain = last - average
            lines.append(gain >= 0
                ? String(localized: "The last price is \(AmountFormat.string(gain, code: report.currencyCode)) a unit above your average cost.")
                : String(localized: "The last price is \(AmountFormat.string(-gain, code: report.currencyCode)) a unit below your average cost."))
        }
        return lines
    }
}

struct ForecastView: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @Binding var configuration: ReportConfiguration
    @State private var showAddWhatIf = false
    @State private var wiDate = Date()
    @State private var wiAmount = ""
    @State private var wiLabel = ""
    @State private var insights: ForecastInsights?
    @State private var generatingOutlook = false
    @State private var outlookError: String?
    /// The projection, built by a task after the frame that asked for it —
    /// it used to be computed in `body`, so the first look after any edit
    /// held the window while it walked the book (Performance Review P3.2).
    /// Kept while a newer one builds, with a small indicator, rather than
    /// blanking the chart: a what-if added should not blink the page.
    @State private var forecast: (key: ForecastKey, points: [CashFlowPoint])?
    /// The day the projection starts from, moved on at midnight by the view
    /// itself — the projection is the book's from today, and nothing else
    /// redraws a Forecast left open overnight.
    @State private var today = AppModel.endOfToday()
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }
    private var balanceWidth: CGFloat { 96 * appFontScale }

    /// What a projection was built for: the account, the book, the what-ifs,
    /// and the day it starts from — the memo's own key has the day, and a
    /// view key without it kept yesterday's projection past midnight
    /// (17 October review).
    struct ForecastKey: Hashable {
        var accountID: GncGUID
        var months: Int
        var revision: Int
        var whatIf: [WhatIfEvent]
        var day: Date
    }

    private var months: Int { configuration.horizonMonths ?? 6 }

    var body: some View {
        Group {
        if let accountID = model.singleAccount(for: configuration, kind: .forecast) {
            let key = ForecastKey(accountID: accountID, months: months, revision: model.bookRevision,
                                  whatIf: model.whatIfEvents, day: today)
            // The projection for this key once built, or the memo's if it is
            // already there — drawn in the first frame rather than a
            // placeholder — or the last one, under an indicator, while this
            // one builds.
            let current = forecast?.key == key ? forecast
                : model.cachedCashFlowForecast(accountID: accountID, months: months).map { (key: key, points: $0) }
            let shown = current ?? forecast
            VStack(spacing: 0) {
                ReportMasthead(entity: model.statementEntityName,
                               title: String(localized: "Forecast"),
                               period: model.accountName(accountID) ?? String(localized: "Projected balances"),
                               code: model.reportCurrency.mnemonic)
                    .padding(.top, 12)
                    .overlay(alignment: .topTrailing) {
                        if shown != nil, current == nil {
                            ProgressView().controlSize(.small).padding(12)
                                .accessibilityLabel("Updating the forecast")
                        }
                    }
                whatIfBar
                Divider()
                if let points = shown?.points {
                    projection(points)
                } else {
                    LoadingPlaceholder("Projecting balances…")
                }
            }
            .task(id: key) {
                let requested = key
                // One yield so the frame paints first, as the other reports
                // do — unless the projection is already built.
                if model.cachedCashFlowForecast(accountID: requested.accountID, months: requested.months) == nil { await Task.yield() }
                let points = model.cashFlowForecast(accountID: requested.accountID, months: requested.months)
                guard !Task.isCancelled else { return }
                forecast = (requested, points)
            }
            .reportPDFToolbar(title: String(localized: "Forecast"), entity: model.statementEntityName) {
                // From the projection on screen — never a second walk of the
                // book inside the toolbar's own body — under the account it
                // was built for, which during a rebuild is not always the one
                // now chosen.
                shown.flatMap { model.forecastDocument(accountID: $0.key.accountID, points: $0.points) }
            }
        } else {
            ContentUnavailableView("No account to forecast", systemImage: "banknote",
                                   description: Text("Create an asset account first."))
        }
        }
        // Wakes at midnight, so the projection moves on with the day — and
        // sleeps again if it woke a moment early.
        .task(id: today) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1, today.timeIntervalSinceNow)))
                let day = AppModel.endOfToday()
                if day != today, !Task.isCancelled { today = day; return }
            }
        }
    }

    /// The chart, the outlook and the list of what moves the balance.
    @ViewBuilder
    private func projection(_ points: [CashFlowPoint]) -> some View {
        let events = points.filter { $0.change != 0 }
                if events.isEmpty {
                    ContentUnavailableView("No upcoming activity", systemImage: "calendar",
                                           description: Text("Add scheduled transactions or a what-if event to forecast cash flow."))
                } else {
                    Chart {
                        ForEach(points) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                                .interpolationMethod(.stepEnd)
                        }
                        ForEach(points.filter(\.isWhatIf)) { point in
                            // Hypotheticals in a reserved tint, distinct from
                            // the accent-coloured actual projection.
                            PointMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                                .foregroundStyle(.purple)
                        }
                        RuleMark(y: .value("Zero", 0))
                            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 170)
                    .padding()
                    .accessibilityLabel("Projected cash-flow balance")
                    Divider()
                    if model.isIntelligenceAvailable(for: .forecastNarrator) {
                        outlookBar
                        Divider()
                    }
                    List(events) { event in
                        HStack {
                            AdaptiveDate(event.date)
                                .foregroundStyle(.secondary)
                                .frame(width: dateWidth, alignment: .leading)
                            Text(event.label)
                            if event.isWhatIf {
                                Text("what-if").scaledFont(.caption2)
                                    .padding(.horizontal, 4).background(.purple.opacity(0.2)).clipShape(Capsule())
                            }
                            Spacer()
                            Text(AmountFormat.string(event.change, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .foregroundStyle(event.change < 0 ? Color.negativeAmount : Color.positiveAmount)
                            Text(AmountFormat.string(event.balance, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .frame(width: balanceWidth, alignment: .trailing)
                                .foregroundStyle(event.balance < 0 ? Color.negativeAmount : Color.primary)
                        }
                    }
                }
    }

    private var whatIfBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What-if scenario").scaledFont(.subheadline).fontWeight(.medium)
                Spacer()
                Button(showAddWhatIf ? "Close" : "Add event", systemImage: "plus") {
                    showAddWhatIf.toggle()
                }
                .scaledFont(.caption)
            }
            if showAddWhatIf {
                HStack {
                    DatePicker("", selection: $wiDate, displayedComponents: .date).labelsHidden()
                    TextField("Amount (+in / −out)", text: $wiAmount)
                        .frame(width: 130).multilineTextAlignment(.trailing)
                    TextField("Label", text: $wiLabel).frame(width: 120)
                    Button("Add") { addWhatIf() }.disabled(EditableSplit.strictDecimal(wiAmount.trimmingCharacters(in: .whitespaces)) == nil)
                }
                .scaledFont(.caption)
            }
            ForEach(model.whatIfEvents) { event in
                HStack(spacing: 4) {
                    Button(role: .destructive) { model.removeWhatIfEvent(event.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Remove what-if event \(event.label)")
                    Text("\(event.label): \(AmountFormat.string(event.amount, code: model.reportCurrency.mnemonic)) on \(dateFormat.short(event.date))")
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func addWhatIf() {
        guard let amount = EditableSplit.strictDecimal(wiAmount.trimmingCharacters(in: .whitespaces)) else { return }
        model.addWhatIfEvent(date: wiDate, amount: amount, label: wiLabel)
        wiAmount = ""; wiLabel = ""; showAddWhatIf = false
    }

    /// Plain-language outlook on the forecast, written from the computed
    /// numbers (`FR-AI-06`) — on the model the person chose, which the bar
    /// says when that is not this device.
    private var outlookBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Outlook", systemImage: "sparkles")
                    .scaledFont(.subheadline).fontWeight(.medium)
                Spacer()
                Button {
                    generateOutlook()
                } label: {
                    // A spinner while the model writes, not only new words.
                    if generatingOutlook {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Generating…")
                        }
                    } else {
                        Text(insights == nil ? "Generate" : "Refresh")
                    }
                }
                .scaledFont(.caption)
                .disabled(generatingOutlook)
            }
            IntelligenceRunsNote(.forecast)
            if let insights {
                Text(insights.headline).scaledFont(.callout).fontWeight(.medium)
                ForEach(insights.insights, id: \.self) { insight in
                    Text("•  \(insight)").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            if let outlookError {
                Text(outlookError).scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func generateOutlook() {
        generatingOutlook = true
        outlookError = nil
        Task {
            defer { generatingOutlook = false }
            do {
                insights = try await model.forecastInsights()
            } catch {
                outlookError = error.localizedDescription
            }
        }
    }
}
