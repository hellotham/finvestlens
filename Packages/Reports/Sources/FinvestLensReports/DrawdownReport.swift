//
//  DrawdownReport.swift
//  FinvestLens — Reports
//
//  Each holding's return over a period against its worst fall in it —
//  Sharesight's Drawdown Risk report: "the largest loss from a peak to a
//  trough before a new peak is reached", and RoMaD, return over maximum
//  drawdown, "a RoMaD value above 1 suggests the portfolio achieved a
//  return greater than its worst drawdown" (InvestaLens, TOOLS.md).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public struct DrawdownLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var portfolio: PortfolioRef?
    public var marketValue: Decimal?
    /// The price change over the period.
    public var returnFraction: Double?
    public var drawdown: PriceAnalytics.Drawdown?
    /// Return over the size of the maximum drawdown; `nil` with no fall.
    public var romad: Double?
    public var samples: Int
}

public struct DrawdownReport: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    /// By RoMaD, best first; holdings without a drawdown last.
    public var lines: [DrawdownLine]
}

public extension FinancialReports {

    /// Every held security's price return and worst drawdown over
    /// `[from, to]` (closed positions have no price risk to report).
    static func drawdownRisk(
        _ book: Book,
        currency: Commodity,
        from: Date,
        to: Date,
        portfolioID: GncGUID? = nil,
        calendar: Calendar = .current
    ) -> DrawdownReport {
        var lines: [DrawdownLine] = []
        for history in investmentHistories(book, currency: currency, to: to, portfolioID: portfolioID)
        where !history.isClosed {
            guard let account = book.account(with: history.id) else { continue }
            let (all, _) = priceSeries(book, commodity: account.commodity, currency: currency, calendar: calendar)
            let series = PriceAnalytics.slice(all, from: from, to: to)
            let summary = PriceAnalytics.summary(series)
            let drawdown = PriceAnalytics.maxDrawdown(series)
            var romad: Double?
            if let fraction = summary?.changeFraction, let drawdown, drawdown.fraction < 0 {
                romad = fraction / -drawdown.fraction
            }
            lines.append(DrawdownLine(id: history.id, symbol: history.symbol, accountName: history.accountName,
                                      portfolio: history.portfolio, marketValue: history.marketValue,
                                      returnFraction: summary?.changeFraction, drawdown: drawdown,
                                      romad: romad, samples: series.count))
        }
        return DrawdownReport(from: from, to: to, currencyCode: currency.mnemonic, lines: lines.sorted {
            switch ($0.romad, $1.romad) {
            case let (a?, b?): a > b
            case (nil, nil): $0.symbol < $1.symbol
            case (nil, _): false
            case (_, nil): true
            }
        })
    }
}
