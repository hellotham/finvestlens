//
//  InvestmentReview.swift
//  FinvestLens — FeatureUI
//
//  The Investment Review deck: the portfolio presented the way a fund
//  factsheet and a brokerage performance summary present it — overview,
//  allocation with concentration, mark-to-market leaders, income, realised
//  gains with the long/short-term split, and a return decomposition. Built
//  on the same slide machinery (and the same grounded-facts + validator
//  contract) as the Financial Review.
//
//  Every figure comes from the existing verified computations: the advanced
//  portfolio (money in/out, per-holding income, return fraction), the
//  capital-gains engine, and the dividend classification. No new arithmetic.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

@MainActor
extension AppModel {

    /// The investment deck for a period. Empty when the book holds no
    /// valued securities.
    func investmentReviewSlides(from: Date, to: Date, label: String) -> [ReviewSlide] {
        guard let portfolio = advancedPortfolio(asOf: to),
              portfolio.holdings.contains(where: { ($0.marketValue ?? 0) != 0 })
        else { return [] }
        let code = reportCurrency.mnemonic

        var slides: [ReviewSlide] = []
        if let slide = investmentOverviewSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = allocationSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = leadersSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = investmentIncomeSlide(portfolio, from: from, to: to,
                                             label: label, code: code) {
            slides.append(slide)
        }
        if let slide = realisedSlide(from: from, to: to, label: label, code: code) {
            slides.append(slide)
        }
        if let slide = decompositionSlide(portfolio, label: label, code: code) {
            slides.append(slide)
        }
        return slides
    }

    private func compactAmount(_ value: Decimal, _ code: String) -> String {
        AmountFormat.compact(value, code: code)
    }

    private func roundedPercent(_ fraction: Double, places: Int = 1) -> Decimal {
        var value = Decimal(fraction * 100)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, places, .plain)
        return rounded
    }

    // MARK: Slides

    // Every phrase is a whole one in `String(localized:)`, for the reason
    // given in FinancialReview.swift: a slide carries `String`s, and a
    // literal in one is English wherever it is read.

    /// Factsheet page one: value, cost, unrealised, total return.
    private func investmentOverviewSlide(_ portfolio: AdvancedPortfolio,
                                         label: String, code: String) -> ReviewSlide? {
        let valued = portfolio.holdings
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        guard !valued.isEmpty else { return nil }

        let marketValueLabel = String(localized: "Market value")
        let costLabel = String(localized: "Cost basis")
        let returnLabel = String(localized: "Total return")
        let value = compactAmount(portfolio.totalValue, code)

        var callouts: [SlideCallout] = [
            SlideCallout(label: marketValueLabel, value: value),
            SlideCallout(label: costLabel, value: compactAmount(portfolio.totalCost, code)),
            SlideCallout(label: String(localized: "Unrealised"),
                         value: compactAmount(portfolio.totalUnrealized, code),
                         deltaPositive: portfolio.totalUnrealized >= 0),
        ]
        let figures: [(String, Decimal)] = [
            (marketValueLabel, portfolio.totalValue),
            (costLabel, portfolio.totalCost),
            (String(localized: "Unrealised gain"), portfolio.totalUnrealized),
        ]
        var ratios: [(String, Decimal)] = []
        var headline = String(localized: "Portfolio valued at \(value)")
        if let returnFraction = portfolio.totalReturnFraction {
            let percent = roundedPercent(returnFraction)
            callouts.append(SlideCallout(label: returnLabel, value: reviewPercent(percent),
                                         deltaPositive: percent >= 0))
            ratios.append((returnLabel, percent))
            headline = percent >= 0
                ? String(localized: "Portfolio of \(value) returning \(reviewPercent(percent)) on money in")
                : String(localized: "Portfolio of \(value) down \(reviewPercent(-percent)) on money in")
        }

        let bars = valued.prefix(8).map {
            CategoryBar(label: $0.symbol, current: $0.marketValue ?? 0, prior: nil)
        }
        return ReviewSlide(
            id: "inv.dashboard",
            kicker: String(localized: "Investment Review · \(label)"),
            headline: headline,
            callouts: callouts,
            chart: .categoryBars(Array(bars)),
            footnote: String(localized: "Valued at the most recent recorded prices · \(AppModel.costBasisName(portfolio.method)) basis · return = (unrealised + realised + income) over money in"),
            facts: ReviewSlideFacts(kicker: String(localized: "Portfolio overview"), periodLabel: label,
                                    currencyCode: code, figures: figures, ratios: ratios))
    }

    /// Allocation + the factsheet's concentration read.
    private func allocationSlide(_ portfolio: AdvancedPortfolio,
                                 label: String, code: String) -> ReviewSlide? {
        let valued = portfolio.holdings
            .filter { ($0.marketValue ?? 0) > 0 }
            .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }
        guard valued.count >= 2, portfolio.totalValue > 0 else { return nil }

        let top = valued[0]
        let topShare = roundedPercent(
            NSDecimalNumber(decimal: (top.marketValue ?? 0) / portfolio.totalValue).doubleValue)
        let topFive = valued.prefix(5).reduce(Decimal(0)) { $0 + ($1.marketValue ?? 0) }
        let topFiveShare = roundedPercent(
            NSDecimalNumber(decimal: topFive / portfolio.totalValue).doubleValue)
        let holdings = valued.count

        return ReviewSlide(
            id: "inv.allocation",
            kicker: String(localized: "Allocation"),
            headline: String(localized: "\(holdings) holdings; the top five are \(reviewPercent(topFiveShare)) of the portfolio"),
            callouts: [
                SlideCallout(label: String(localized: "Holdings"), value: "\(holdings)"),
                SlideCallout(label: String(localized: "Largest: \(top.symbol)"), value: reviewPercent(topShare)),
                SlideCallout(label: String(localized: "Top five"), value: reviewPercent(topFiveShare)),
            ],
            chart: .allocation(valued.prefix(12).map { ($0.symbol, $0.marketValue ?? 0) }),
            footnote: String(localized: "Share of market value · concentration is the factsheet’s first risk read"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Allocation and concentration"), periodLabel: label, currencyCode: code,
                figures: valued.prefix(5).map { ($0.symbol, $0.marketValue ?? 0) },
                ratios: [(String(localized: "Largest holding"), topShare),
                         (String(localized: "Top five holdings"), topFiveShare)],
                counts: [(String(localized: "Number of holdings"), holdings)]))
    }

    /// Mark-to-market winners and losers.
    private func leadersSlide(_ portfolio: AdvancedPortfolio,
                              label: String, code: String) -> ReviewSlide? {
        let judged = portfolio.holdings
            .compactMap { holding -> (String, Decimal)? in
                guard let gain = holding.unrealizedGain, gain != 0 else { return nil }
                return (holding.symbol, gain)
            }
            .sorted { $0.1 > $1.1 }
        guard let best = judged.first, let worst = judged.last, judged.count >= 2
        else { return nil }

        let bars = (judged.prefix(4) + judged.suffix(2))
            .map { CategoryBar(label: $0.0, current: $0.1, prior: nil) }
        let headline = best.1 >= abs(worst.1)
            ? String(localized: "\(best.0) leads with \(compactAmount(best.1, code)) unrealised")
            : String(localized: "\(worst.0) weighs with \(compactAmount(worst.1, code)) unrealised")
        let totalLabel = String(localized: "Unrealised total")

        return ReviewSlide(
            id: "inv.leaders",
            kicker: String(localized: "Performance"),
            headline: headline,
            callouts: [
                SlideCallout(label: String(localized: "Best: \(best.0)"), value: compactAmount(best.1, code),
                             deltaPositive: true),
                SlideCallout(label: String(localized: "Weakest: \(worst.0)"), value: compactAmount(worst.1, code),
                             deltaPositive: worst.1 >= 0),
                SlideCallout(label: totalLabel,
                             value: compactAmount(portfolio.totalUnrealized, code),
                             deltaPositive: portfolio.totalUnrealized >= 0),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: String(localized: "Unrealised gain and loss per holding, at latest recorded prices"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Winners and losers"), periodLabel: label, currencyCode: code,
                figures: [(totalLabel, portfolio.totalUnrealized)]
                    + judged.prefix(4).map { ($0.0, $0.1) }
                    + judged.suffix(2).map { ($0.0, $0.1) }))
    }

    /// Income: the period's dividends/distributions (classified), with
    /// lifetime income per holding as context.
    private func investmentIncomeSlide(_ portfolio: AdvancedPortfolio,
                                       from: Date, to: Date,
                                       label: String, code: String) -> ReviewSlide? {
        guard let dividends = dividendBreakdown(from: from, to: to) else { return nil }
        let franked = dividends.franked
        let unfranked = dividends.unfranked
        let credits = dividends.credits
        let periodIncome = franked + unfranked
        guard periodIncome != 0 else { return nil }

        let bars = dividends.cashBySecurity.sorted { $0.value > $1.value }.prefix(8)
            .map { CategoryBar(label: $0.key, current: $0.value, prior: nil) }
        let incomeLabel = String(localized: "Period income")
        let creditsLabel = String(localized: "Franking credits")

        var callouts: [SlideCallout] = [
            SlideCallout(label: incomeLabel, value: compactAmount(periodIncome, code)),
            SlideCallout(label: creditsLabel, value: compactAmount(credits, code)),
        ]
        let figures: [(String, Decimal)] = [
            (incomeLabel, periodIncome),
            (String(localized: "Franked"), franked), (String(localized: "Unfranked"), unfranked),
            (creditsLabel, credits),
        ]
        var ratios: [(String, Decimal)] = []
        if portfolio.totalValue > 0 {
            let yield = roundedPercent(
                NSDecimalNumber(decimal: periodIncome / portfolio.totalValue).doubleValue)
            callouts.append(SlideCallout(label: String(localized: "Yield on value"), value: reviewPercent(yield)))
            ratios.append((String(localized: "Income yield"), yield))
        }

        return ReviewSlide(
            id: "inv.income",
            kicker: String(localized: "Income"),
            headline: String(localized: "Investment income of \(compactAmount(periodIncome, code)) for \(label)"),
            callouts: callouts,
            chart: .categoryBars(Array(bars)),
            footnote: String(localized: "Dividends and distributions classified from the Dividends income tree · yield on closing market value"),
            facts: ReviewSlideFacts(kicker: String(localized: "Investment income"), periodLabel: label,
                                    currencyCode: code, figures: figures, ratios: ratios))
    }

    /// Realised gains for the period, with the CGT-relevant term split.
    private func realisedSlide(from: Date, to: Date,
                               label: String, code: String) -> ReviewSlide? {
        guard let report = capitalGains(from: from, to: to), !report.lines.isEmpty
        else { return nil }
        let longTerm = report.lines.filter { $0.longTerm == true }
            .reduce(Decimal(0)) { $0 + $1.gain }
        let shortTerm = report.lines.filter { $0.longTerm == false }
            .reduce(Decimal(0)) { $0 + $1.gain }

        var bySymbol: [String: Decimal] = [:]
        for line in report.lines { bySymbol[line.symbol, default: 0] += line.gain }
        let bars = bySymbol.sorted { abs($0.value) > abs($1.value) }.prefix(8)
            .map { CategoryBar(label: $0.key, current: $0.value, prior: nil) }
        let disposals = report.lines.count
        let disposalsLabel = String(localized: "Disposals")

        let headline = report.totalGain >= 0
            ? String(localized: "Realised \(compactAmount(report.totalGain, code)) across \(disposals) disposals")
            : String(localized: "Realised a \(compactAmount(-report.totalGain, code)) loss across \(disposals) disposals")
        return ReviewSlide(
            id: "inv.realised",
            kicker: String(localized: "Realised gains"),
            headline: headline,
            callouts: [
                SlideCallout(label: String(localized: "Realised"), value: compactAmount(report.totalGain, code),
                             deltaPositive: report.totalGain >= 0),
                SlideCallout(label: String(localized: "Held > 1 year"), value: compactAmount(longTerm, code),
                             deltaPositive: longTerm >= 0),
                SlideCallout(label: String(localized: "Held ≤ 1 year"), value: compactAmount(shortTerm, code),
                             deltaPositive: shortTerm >= 0),
                SlideCallout(label: disposalsLabel, value: "\(disposals)"),
            ],
            chart: .categoryBars(Array(bars)),
            footnote: String(localized: "\(AppModel.costBasisName(report.method)) cost basis · the over-a-year split is the CGT-discount boundary"),
            facts: ReviewSlideFacts(
                kicker: String(localized: "Realised gains"), periodLabel: label, currencyCode: code,
                figures: [(String(localized: "Realised gain"), report.totalGain),
                          (String(localized: "Held over one year"), longTerm),
                          (String(localized: "Held one year or less"), shortTerm)],
                counts: [(disposalsLabel, disposals)]))
    }

    /// Where the return came from: income + realised + unrealised over
    /// money in — the brokerage performance-summary decomposition.
    private func decompositionSlide(_ portfolio: AdvancedPortfolio,
                                    label: String, code: String) -> ReviewSlide? {
        guard portfolio.totalMoneyIn > 0 else { return nil }
        let gain = portfolio.totalUnrealized + portfolio.totalRealized + portfolio.totalIncome

        let moneyInLabel = String(localized: "Money in")
        let moneyOutLabel = String(localized: "Money out")
        let gainLabel = String(localized: "Total gain")
        let returnLabel = String(localized: "Return on money in")
        let incomeLabel = String(localized: "Income")

        var callouts: [SlideCallout] = [
            SlideCallout(label: moneyInLabel, value: compactAmount(portfolio.totalMoneyIn, code)),
            SlideCallout(label: moneyOutLabel, value: compactAmount(portfolio.totalMoneyOut, code)),
            SlideCallout(label: gainLabel, value: compactAmount(gain, code),
                         deltaPositive: gain >= 0),
        ]
        let figures: [(String, Decimal)] = [
            (moneyInLabel, portfolio.totalMoneyIn),
            (moneyOutLabel, portfolio.totalMoneyOut),
            (incomeLabel, portfolio.totalIncome),
            (String(localized: "Realised gain"), portfolio.totalRealized),
            (String(localized: "Unrealised gain"), portfolio.totalUnrealized),
            (gainLabel, gain),
        ]
        var ratios: [(String, Decimal)] = []
        if let returnFraction = portfolio.totalReturnFraction {
            let percent = roundedPercent(returnFraction)
            callouts.append(SlideCallout(label: returnLabel, value: reviewPercent(percent),
                                         deltaPositive: percent >= 0))
            ratios.append((returnLabel, percent))
        }

        return ReviewSlide(
            id: "inv.decomposition",
            kicker: String(localized: "Return decomposition"),
            headline: String(localized: "Gains of \(compactAmount(gain, code)) on \(compactAmount(portfolio.totalMoneyIn, code)) invested"),
            callouts: callouts,
            chart: .categoryBars([
                CategoryBar(label: incomeLabel, current: portfolio.totalIncome, prior: nil),
                CategoryBar(label: String(localized: "Realised"), current: portfolio.totalRealized, prior: nil),
                CategoryBar(label: String(localized: "Unrealised"), current: portfolio.totalUnrealized, prior: nil),
            ]),
            footnote: String(localized: "Gain = income + realised + unrealised · GnuCash’s money-in return model"),
            facts: ReviewSlideFacts(kicker: String(localized: "Return decomposition"), periodLabel: label,
                                    currencyCode: code, figures: figures, ratios: ratios))
    }
}
