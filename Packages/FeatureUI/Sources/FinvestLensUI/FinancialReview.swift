//
//  FinancialReview.swift
//  FinvestLens — FeatureUI
//
//  The Financial Review deck's data (docs/report-redesign.md §3.3): each
//  slide is one message — a kicker, an action title, two-to-four callouts,
//  one focused chart, and a footnote — built like a CFO's results
//  presentation. Slides appear only when they have meaningful data (the
//  dashboard's content-aware rule), and every headline has a deterministic
//  form so the deck reads well with Apple Intelligence off; the model only
//  ever *improves* a title, from the slide's own facts.
//
//  No new arithmetic: every figure comes from the existing memoised report
//  computations.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

// MARK: - Slide model

struct SlideCallout: Identifiable {
    let id = UUID()
    var label: String
    var value: String
    var delta: String?
    var deltaPositive: Bool?
}

struct WaterfallStep: Identifiable {
    enum Kind { case anchor, rise, fall }
    let id = UUID()
    var label: String
    var start: Decimal
    var end: Decimal
    var kind: Kind
}

struct CategoryBar: Identifiable {
    let id = UUID()
    var label: String
    var current: Decimal
    var prior: Decimal?
}

enum SlideChart {
    case netWorthLine([NetWorthPoint])
    case waterfall([WaterfallStep])
    case categoryBars([CategoryBar])
    case monthlyFlows([MonthlyFlow])
    case allocation([(symbol: String, value: Decimal)])
    case none
}

struct ReviewSlide: Identifiable {
    /// Stable slug — the insight cache key rides on it.
    var id: String
    var kicker: String
    /// The deterministic action title; the narrator may replace it.
    var headline: String
    var callouts: [SlideCallout]
    var chart: SlideChart
    var footnote: String
    var facts: ReviewSlideFacts
}

// MARK: - Builders

@MainActor
extension AppModel {

    /// The deck for a period: every slide with meaningful data, in the
    /// standard results-presentation order.
    func financialReviewSlides(from: Date, to: Date, label: String) -> [ReviewSlide] {
        guard book != nil else { return [] }
        let code = reportCurrency.mnemonic

        let current = incomeStatement(from: from, to: to)
        let calendar = Calendar.current
        let priorFrom = calendar.date(byAdding: .year, value: -1, to: from)
        let priorTo = calendar.date(byAdding: .year, value: -1, to: to)
        let prior: IncomeStatement? = {
            guard let priorFrom, let priorTo,
                  book?.transactions.contains(where: { $0.datePosted < from }) == true
            else { return nil }
            return incomeStatement(from: priorFrom, to: priorTo)
        }()

        let openingDate = from == .distantPast ? from : from.addingTimeInterval(-1)
        let opening = balanceSheet(asOf: openingDate)
        let closing = balanceSheet(asOf: to)

        var slides: [ReviewSlide] = []
        if let slide = highlightsSlide(from: from, to: to, label: label, code: code,
                                       current: current, opening: opening, closing: closing) {
            slides.append(slide)
        }
        if let slide = bridgeSlide(label: label, code: code, opening: opening,
                                   closing: closing, period: current) {
            slides.append(slide)
        }
        if let slide = flowSlide(section: .income, from: from, to: to, label: label,
                                 code: code, current: current, prior: prior) {
            slides.append(slide)
        }
        if let slide = flowSlide(section: .expenses, from: from, to: to, label: label,
                                 code: code, current: current, prior: prior) {
            slides.append(slide)
        }
        if let slide = cashFlowSlide(from: from, to: to, label: label, code: code,
                                     current: current) {
            slides.append(slide)
        }
        if let slide = portfolioSlide(to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = dividendSlide(from: from, to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = gainsSlide(from: from, to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = positionSlide(to: to, label: label, code: code, closing: closing) {
            slides.append(slide)
        }
        return slides
    }

    // MARK: Formatting helpers (deterministic voice)

    // Everything a slide shows or hands the narrator is written here as a
    // whole phrase in `String(localized:)`. `ReviewSlide` and its callouts
    // carry `String`s, which SwiftUI draws as they are, so a literal put
    // straight into one was English in every language: on the slide, and in
    // the facts the narrator writes from. `FinancialReviewTests` reads this
    // file for one that has slipped back.

    private func money(_ value: Decimal, _ code: String) -> String {
        AmountFormat.string(value, code: code)
    }

    /// "$3.8m" — deck callouts breathe better compact (shared formatter).
    private func compact(_ value: Decimal, _ code: String) -> String {
        AmountFormat.compact(value, code: code)
    }

    private func percentDelta(_ current: Decimal, _ prior: Decimal) -> Decimal? {
        guard prior != 0 else { return nil }
        var result = (current - prior) / abs(prior) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 1, .plain)
        return rounded
    }

    /// A percentage as the reader's locale writes it — "8.4%", "8,4 %".
    /// `percent` is already times a hundred, and is shown to at most
    /// `places` decimals.
    func reviewPercent(_ percent: Decimal, places: Int = 1, signed: Bool = false,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let style = Decimal.FormatStyle.Percent(locale: locale).precision(.fractionLength(0...places))
        return (percent / 100).formatted(signed ? style.sign(strategy: .always()) : style)
    }

    private func deltaText(_ percent: Decimal?) -> (String, Bool)? {
        guard let percent else { return nil }
        return (String(localized: "\(reviewPercent(percent, signed: true)) YoY"), percent >= 0)
    }

    // MARK: Slides

    private func highlightsSlide(from: Date, to: Date, label: String, code: String,
                                 current: IncomeStatement?,
                                 opening: BalanceSheet?,
                                 closing: BalanceSheet?) -> ReviewSlide? {
        guard let closing else { return nil }
        let netWorth = closing.totalAssets - closing.totalLiabilities
        let openingNet = opening.map { $0.totalAssets - $0.totalLiabilities }
        let surplus = current?.netIncome ?? 0
        let income = current?.totalIncome ?? 0
        let savingsRate: Decimal? = income > 0 ? surplus / income * 100 : nil

        // Said once each: the narrator's prompt puts a change on the line
        // of the figure with the same label.
        let netWorthLabel = String(localized: "Net worth")
        let surplusLabel = String(localized: "Net surplus")
        let savingsLabel = String(localized: "Savings rate")

        var callouts: [SlideCallout] = [
            SlideCallout(label: netWorthLabel, value: compact(netWorth, code)),
            SlideCallout(label: surplusLabel, value: compact(surplus, code),
                         deltaPositive: surplus >= 0),
        ]
        if let savingsRate {
            var rounded = Decimal(); var raw = savingsRate
            NSDecimalRound(&rounded, &raw, 0, .plain)
            callouts.append(SlideCallout(label: savingsLabel, value: reviewPercent(rounded, places: 0)))
        }

        let months = max(12, Calendar.current.dateComponents([.month], from: from, to: to).month ?? 12)
        let series = netWorthSeries(months: min(months, 24), endingAt: min(to, AppModel.endOfToday()))

        let headline = surplus >= 0
            ? String(localized: "Net worth \(compact(netWorth, code)) with a \(compact(surplus, code)) surplus")
            : String(localized: "Net worth \(compact(netWorth, code)) after a \(compact(-surplus, code)) deficit")
        return ReviewSlide(
            id: "highlights",
            kicker: String(localized: "Financial Review · \(label)"),
            headline: headline,
            callouts: callouts,
            chart: .netWorthLine(series),
            footnote: String(localized: "Net worth as at \(AppDateFormat.current.long(to)) · \(statementEntityName)"),
            facts: {
                var figures: [(String, Decimal)] = [
                    (netWorthLabel, netWorth), (surplusLabel, surplus),
                    (String(localized: "Income"), income),
                    (String(localized: "Expenses"), current?.totalExpenses ?? 0)]
                var deltas: [(String, Decimal)] = []
                var ratios: [(String, Decimal)] = []
                if let openingNet {
                    figures.append((String(localized: "Opening net worth"), openingNet))
                    figures.append((String(localized: "Change in net worth"), netWorth - openingNet))
                    if let percent = percentDelta(netWorth, openingNet) {
                        deltas.append((netWorthLabel, percent))
                    }
                }
                if let savingsRate {
                    var rounded = Decimal(); var raw = savingsRate
                    NSDecimalRound(&rounded, &raw, 1, .plain)
                    ratios.append((savingsLabel, rounded))
                }
                return ReviewSlideFacts(kicker: String(localized: "Highlights"), periodLabel: label,
                                        currencyCode: code, figures: figures, ratios: ratios,
                                        deltaPercents: deltas)
            }())
    }

    private func bridgeSlide(label: String, code: String,
                             opening: BalanceSheet?, closing: BalanceSheet?,
                             period: IncomeStatement?) -> ReviewSlide? {
        guard let opening, let closing, let period else { return nil }
        let openingNet = opening.totalAssets - opening.totalLiabilities
        let closingNet = closing.totalAssets - closing.totalLiabilities
        guard closingNet != openingNet else { return nil }
        let valuation = closingNet - openingNet - period.netIncome

        let openingLabel = String(localized: "Opening")
        let closingLabel = String(localized: "Closing")
        let incomeLabel = String(localized: "Income")
        let expensesLabel = String(localized: "Expenses")
        let valuationLabel = String(localized: "Valuation & FX")

        var steps: [WaterfallStep] = []
        var running = openingNet
        steps.append(WaterfallStep(label: openingLabel, start: 0, end: openingNet, kind: .anchor))
        steps.append(WaterfallStep(label: incomeLabel, start: running,
                                   end: running + period.totalIncome, kind: .rise))
        running += period.totalIncome
        steps.append(WaterfallStep(label: expensesLabel, start: running - period.totalExpenses,
                                   end: running, kind: .fall))
        running -= period.totalExpenses
        steps.append(WaterfallStep(label: valuationLabel,
                                   start: valuation >= 0 ? running : running + valuation,
                                   end: valuation >= 0 ? running + valuation : running,
                                   kind: valuation >= 0 ? .rise : .fall))
        running += valuation
        steps.append(WaterfallStep(label: closingLabel, start: 0, end: closingNet, kind: .anchor))

        let change = closingNet - openingNet
        let percent = percentDelta(closingNet, openingNet)
        let headline: String
        if let percent {
            headline = change >= 0
                ? String(localized: "Net worth grew \(reviewPercent(percent)) to \(compact(closingNet, code))")
                : String(localized: "Net worth eased \(reviewPercent(-percent)) to \(compact(closingNet, code))")
        } else {
            headline = String(localized: "Net worth moved to \(compact(closingNet, code))")
        }
        return ReviewSlide(
            id: "bridge",
            kicker: String(localized: "Net worth"),
            headline: headline,
            callouts: [
                SlideCallout(label: openingLabel, value: compact(openingNet, code)),
                SlideCallout(label: String(localized: "Surplus"), value: compact(period.netIncome, code),
                             deltaPositive: period.netIncome >= 0),
                SlideCallout(label: valuationLabel, value: compact(valuation, code),
                             deltaPositive: valuation >= 0),
                SlideCallout(label: closingLabel, value: compact(closingNet, code)),
            ],
            chart: .waterfall(steps),
            footnote: String(localized: "Valuation & FX derived as closing − opening − net surplus"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Net worth bridge"), periodLabel: label, currencyCode: code,
                figures: [(String(localized: "Opening net worth"), openingNet),
                          (incomeLabel, period.totalIncome),
                          (expensesLabel, period.totalExpenses),
                          (String(localized: "Valuation and currency movement"), valuation),
                          (String(localized: "Change in net worth"), change),
                          (String(localized: "Closing net worth"), closingNet)],
                deltaPercents: percent.map { [(String(localized: "Net worth"), $0)] } ?? []))
    }

    private enum FlowSection { case income, expenses }

    /// Income or spending analysis: the statement layer's own captions as
    /// bars, current vs prior.
    private func flowSlide(section: FlowSection, from: Date, to: Date, label: String,
                           code: String, current: IncomeStatement?,
                           prior: IncomeStatement?) -> ReviewSlide? {
        guard let book, let current else { return nil }
        let lines = section == .income ? current.income : current.expenses
        let total = section == .income ? current.totalIncome : current.totalExpenses
        guard total != 0, !lines.isEmpty else { return nil }
        let priorLines = section == .income ? prior?.income : prior?.expenses
        let priorTotal = section == .income ? prior?.totalIncome : prior?.totalExpenses

        let builder = StatementBuilder(book: book)
        let forest = builder.captionForest(lineSets: [lines] + (priorLines.map { [$0] } ?? []))
        let ordered = StatementBuilder.sort(forest, by: .magnitude).prefix(6)
        let bars = ordered.map { node in
            CategoryBar(label: node.name,
                        current: (node.total.first ?? nil) ?? 0,
                        prior: node.total.count > 1 ? node.total[1] : nil)
        }

        let percent = priorTotal.flatMap { percentDelta(total, $0) }
        let isIncome = section == .income
        let kicker = isIncome ? String(localized: "Income") : String(localized: "Spending")
        let top = ordered.first
        let amount = compact(total, code)
        // A whole sentence for each case. Assembled from "Income" or
        // "Spending" and "up" or "down", it could only be translated a word
        // at a time, and no language but English is built that way.
        let headline: String
        if let percent, let priorTotal, priorTotal != 0 {
            let change = reviewPercent(abs(percent))
            switch (isIncome, percent >= 0) {
            case (true, true): headline = String(localized: "Income up \(change) at \(amount)")
            case (true, false): headline = String(localized: "Income down \(change) at \(amount)")
            case (false, true): headline = String(localized: "Spending up \(change) at \(amount)")
            case (false, false): headline = String(localized: "Spending down \(change) at \(amount)")
            }
        } else if let top {
            headline = isIncome ? String(localized: "Income of \(amount), led by \(top.name)")
                                : String(localized: "Spending of \(amount), led by \(top.name)")
        } else {
            headline = isIncome ? String(localized: "Income of \(amount)")
                                : String(localized: "Spending of \(amount)")
        }

        var callouts: [SlideCallout] = [
            SlideCallout(label: isIncome ? String(localized: "Total income") : String(localized: "Total spending"),
                         value: amount,
                         delta: deltaText(percent)?.0,
                         deltaPositive: deltaText(percent).map { isIncome ? $0.1 : !$0.1 }),
        ]
        if let top {
            let topValue = (top.total.first ?? nil) ?? 0
            callouts.append(SlideCallout(label: String(localized: "Largest: \(top.name)"),
                                         value: compact(topValue, code)))
            if total != 0 {
                var share = topValue / total * 100
                var rounded = Decimal()
                NSDecimalRound(&rounded, &share, 0, .plain)
                callouts.append(SlideCallout(label: String(localized: "Share of total"),
                                             value: reviewPercent(rounded, places: 0)))
            }
        }

        let totalLabel = String(localized: "Total")
        var figures: [(String, Decimal)] = [(totalLabel, total)]
        if let priorTotal, priorTotal != 0 {
            figures.append((String(localized: "Prior period total"), priorTotal))
        }
        figures.append(contentsOf: ordered.map { ($0.name, ($0.total.first ?? nil) ?? 0) })
        var deltas: [(String, Decimal)] = []
        if let percent { deltas.append((totalLabel, percent)) }

        return ReviewSlide(
            id: isIncome ? "income" : "spending",
            kicker: kicker,
            headline: headline,
            callouts: callouts,
            chart: .categoryBars(Array(bars)),
            footnote: prior == nil ? String(localized: "No prior-period comparison available")
                                   : String(localized: "Prior period: one year earlier"),
            facts: ReviewSlideFacts(kicker: kicker, periodLabel: label, currencyCode: code,
                                    figures: figures, deltaPercents: deltas))
    }

    private func cashFlowSlide(from: Date, to: Date, label: String, code: String,
                               current: IncomeStatement?) -> ReviewSlide? {
        guard let months = categoryBreakdown(from: from, to: to)?.months,
              months.count >= 2 else { return nil }
        let net = months.reduce(Decimal(0)) { $0 + $1.income - $1.expenses }
        let average = net / Decimal(months.count)
        let positiveMonths = months.filter { $0.income >= $0.expenses }.count
        let monthlyAverageLabel = String(localized: "Monthly average")

        let headline = average >= 0
            ? String(localized: "Cash flow positive in \(positiveMonths) of \(months.count) months")
            : String(localized: "Cash flow negative on average across \(months.count) months")
        return ReviewSlide(
            id: "cashflow",
            kicker: String(localized: "Cash flow"),
            headline: headline,
            callouts: [
                SlideCallout(label: String(localized: "Net for period"), value: compact(net, code),
                             deltaPositive: net >= 0),
                SlideCallout(label: monthlyAverageLabel, value: compact(average, code),
                             deltaPositive: average >= 0),
                SlideCallout(label: String(localized: "Positive months"),
                             value: "\(positiveMonths)/\(months.count)"),
            ],
            chart: .monthlyFlows(months),
            footnote: String(localized: "Income less expenses, by calendar month"),
            // The two month counts go as counts. They went as figures, and
            // the narrator was told "Months positive: 7 AUD".
            facts: ReviewSlideFacts(
                kicker: String(localized: "Cash flow"), periodLabel: label, currencyCode: code,
                figures: [(String(localized: "Net cash flow"), net), (monthlyAverageLabel, average)],
                counts: [(String(localized: "Months positive"), positiveMonths),
                         (String(localized: "Months in period"), months.count)]))
    }

    private func portfolioSlide(to: Date, label: String, code: String) -> ReviewSlide? {
        guard let portfolio = advancedPortfolio(asOf: to),
              portfolio.totalValue > 0 else { return nil }
        let valued = portfolio.holdings
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        guard !valued.isEmpty else { return nil }

        let winners = portfolio.holdings.compactMap { holding -> (String, Decimal)? in
            guard let gain = holding.unrealizedGain else { return nil }
            return (holding.symbol, gain)
        }
        let best = winners.max { $0.1 < $1.1 }
        let worst = winners.min { $0.1 < $1.1 }
        let marketValueLabel = String(localized: "Market value")
        let unrealisedLabel = String(localized: "Unrealised gain")

        var callouts: [SlideCallout] = [
            SlideCallout(label: marketValueLabel, value: compact(portfolio.totalValue, code)),
            SlideCallout(label: unrealisedLabel, value: compact(portfolio.totalUnrealized, code),
                         deltaPositive: portfolio.totalUnrealized >= 0),
        ]
        if let best { callouts.append(SlideCallout(label: String(localized: "Best: \(best.0)"),
                                                   value: compact(best.1, code),
                                                   deltaPositive: best.1 >= 0)) }
        if let worst, worst.0 != best?.0 {
            callouts.append(SlideCallout(label: String(localized: "Weakest: \(worst.0)"),
                                         value: compact(worst.1, code),
                                         deltaPositive: worst.1 >= 0))
        }

        let top = valued.first!
        let headline = String(localized: "Portfolio of \(compact(portfolio.totalValue, code)) led by \(top.symbol)")
        return ReviewSlide(
            id: "portfolio",
            kicker: String(localized: "Portfolio"),
            headline: headline,
            callouts: callouts,
            chart: .allocation(valued.prefix(12).map { ($0.symbol, $0.marketValue ?? 0) }),
            footnote: String(localized: "Valued at the most recent recorded prices · \(portfolio.method.displayName) basis"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Portfolio"), periodLabel: label, currencyCode: code,
                figures: [(marketValueLabel, portfolio.totalValue),
                          (String(localized: "Cost basis"), portfolio.totalCost),
                          (unrealisedLabel, portfolio.totalUnrealized)]
                    + (best.map { [(String(localized: "Best holding \($0.0)"), $0.1)] } ?? [])
                    + (worst.map { [(String(localized: "Weakest holding \($0.0)"), $0.1)] } ?? [])))
    }

    private func dividendSlide(from: Date, to: Date, label: String, code: String) -> ReviewSlide? {
        guard let dividends = dividendBreakdown(from: from, to: to) else { return nil }
        let franked = dividends.franked
        let unfranked = dividends.unfranked
        let credits = dividends.credits
        let total = franked + unfranked
        guard total != 0 || credits != 0 else { return nil }

        let bars = dividends.cashBySecurity.sorted { $0.value > $1.value }.prefix(8)
            .map { CategoryBar(label: $0.key, current: $0.value, prior: nil) }
        let creditsLabel = String(localized: "Franking credits")

        let headline = String(localized: "Dividends of \(compact(total, code)) carrying \(compact(credits, code)) in credits")
        return ReviewSlide(
            id: "dividends",
            kicker: String(localized: "Dividends & franking"),
            headline: headline,
            callouts: [
                SlideCallout(label: String(localized: "Franked"), value: compact(franked, code)),
                SlideCallout(label: String(localized: "Unfranked"), value: compact(unfranked, code)),
                SlideCallout(label: creditsLabel, value: compact(credits, code)),
                SlideCallout(label: String(localized: "Grossed-up"), value: compact(total + credits, code)),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: String(localized: "Classified from the Dividends income tree"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Dividends"), periodLabel: label, currencyCode: code,
                figures: [(String(localized: "Franked dividends"), franked),
                          (String(localized: "Unfranked dividends"), unfranked),
                          (creditsLabel, credits),
                          (String(localized: "Grossed-up total"), total + credits)]))
    }

    private func gainsSlide(from: Date, to: Date, label: String, code: String) -> ReviewSlide? {
        guard let report = capitalGains(from: from, to: to), !report.lines.isEmpty
        else { return nil }
        let total = report.totalGain
        var bySymbol: [String: Decimal] = [:]
        for line in report.lines { bySymbol[line.symbol, default: 0] += line.gain }
        let ranked = bySymbol.sorted { abs($0.value) > abs($1.value) }
        let bars = ranked.prefix(8).map {
            CategoryBar(label: $0.key, current: $0.value, prior: nil)
        }
        let gains = report.lines.filter { $0.gain > 0 }.count
        let losses = report.lines.filter { $0.gain < 0 }.count
        let disposals = report.lines.count
        let disposalsLabel = String(localized: "Disposals")

        let headline = total >= 0
            ? String(localized: "Realised gains of \(compact(total, code)) across \(disposals) disposals")
            : String(localized: "Realised losses of \(compact(-total, code)) across \(disposals) disposals")
        return ReviewSlide(
            id: "gains",
            kicker: String(localized: "Capital gains"),
            headline: headline,
            callouts: [
                SlideCallout(label: String(localized: "Realised"), value: compact(total, code),
                             deltaPositive: total >= 0),
                SlideCallout(label: disposalsLabel, value: "\(disposals)"),
                SlideCallout(label: String(localized: "Gains / losses"), value: "\(gains) / \(losses)"),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: String(localized: "\(report.method.displayName) cost basis"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Capital gains"), periodLabel: label, currencyCode: code,
                figures: [(String(localized: "Realised gain"), total)] + ranked.prefix(5).map { ($0.key, $0.value) },
                counts: [(disposalsLabel, disposals)]))
    }

    private func positionSlide(to: Date, label: String, code: String,
                               closing: BalanceSheet?) -> ReviewSlide? {
        guard let closing else { return nil }
        let net = closing.totalAssets - closing.totalLiabilities
        guard closing.totalAssets != 0 else { return nil }

        var debtShare = closing.totalLiabilities / closing.totalAssets * 100
        var debtRounded = Decimal()
        NSDecimalRound(&debtRounded, &debtShare, 1, .plain)

        // Liquidity: cash-class assets over average monthly spending (12m).
        let yearBack = Calendar.current.date(byAdding: .year, value: -1, to: to) ?? to
        let spend = incomeStatement(from: yearBack, to: to)?.totalExpenses ?? 0
        let monthlySpend = spend / 12
        let cashAssets: Decimal = {
            guard let book else { return 0 }
            return closing.assets.reduce(Decimal(0)) { sum, line in
                guard let account = book.account(with: line.id),
                      account.type == .bank || account.type == .cash else { return sum }
                return sum + line.amount
            }
        }()
        var liquidityMonths: Decimal? = nil
        if monthlySpend > 0 {
            var months = cashAssets / monthlySpend
            var rounded = Decimal()
            NSDecimalRound(&rounded, &months, 1, .plain)
            liquidityMonths = rounded
        }

        let assetsLabel = String(localized: "Assets")
        let liabilitiesLabel = String(localized: "Liabilities")
        let netWorthLabel = String(localized: "Net worth")
        let debtLabel = String(localized: "Debt to assets")

        var callouts: [SlideCallout] = [
            SlideCallout(label: assetsLabel, value: compact(closing.totalAssets, code)),
            SlideCallout(label: liabilitiesLabel, value: compact(closing.totalLiabilities, code)),
            SlideCallout(label: debtLabel, value: reviewPercent(debtRounded)),
        ]
        if let liquidityMonths {
            // The number is written the reader's way, and "1 months" is not
            // a thing in any of them.
            let count = liquidityMonths.formatted(.number.precision(.fractionLength(0...1)))
            callouts.append(SlideCallout(
                label: String(localized: "Cash covers"),
                value: liquidityMonths == 1 ? String(localized: "\(count) month")
                                            : String(localized: "\(count) months")))
        }

        let headline = String(localized: "Liabilities are \(reviewPercent(debtRounded)) of \(compact(closing.totalAssets, code)) in assets")
        return ReviewSlide(
            id: "position",
            kicker: String(localized: "Financial position"),
            headline: headline,
            callouts: callouts,
            chart: .categoryBars([
                CategoryBar(label: assetsLabel, current: closing.totalAssets, prior: nil),
                CategoryBar(label: liabilitiesLabel, current: closing.totalLiabilities, prior: nil),
                CategoryBar(label: netWorthLabel, current: net, prior: nil),
            ]),
            footnote: String(localized: "Cash cover = bank and cash balances over average monthly spending (trailing 12 months)"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Financial position"), periodLabel: label, currencyCode: code,
                figures: [(assetsLabel, closing.totalAssets),
                          (liabilitiesLabel, closing.totalLiabilities),
                          (netWorthLabel, net)],
                ratios: [(debtLabel, debtRounded)]))
    }

    // MARK: Insights (Apple Intelligence, cached)

    /// The narrator's story for a slide, cached per (slide, book revision).
    /// Returns `nil` — leaving the deterministic headline — when Apple
    /// Intelligence is unavailable or declines.
    ///
    /// Both outcomes are remembered. A story is; and so is the narrator
    /// having had nothing sound to say after its three drafts, because the
    /// slide's facts will not change before the book does and a visit to the
    /// slide should not cost three more requests each time. What is *not*
    /// remembered is a failure of the model rather than of the slide — it is
    /// unavailable, busy, out of allowance, or the visit was cut short — so
    /// the next visit asks again.
    func reviewStory(for slide: ReviewSlide) async -> ReviewSlideStory? {
        let key = "review.story:\(slide.id):\(bookRevision):\(slide.facts.periodLabel)"
        if let cached = reviewStoryCache[key] { return cached }
        guard !reviewStoryDeclined.contains(key),
              isIntelligenceAvailable(for: .reviewNarrator) else { return nil }
        do {
            let story = try await running(.reviewStory) { try await ReviewNarrator.story(facts: slide.facts) }
            reviewStoryCache[key] = story
            return story
        } catch let error as IntelligenceError where !error.endsABatch {
            reviewStoryDeclined.insert(key)
            return nil
        } catch {
            return nil
        }
    }
}
