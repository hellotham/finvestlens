//
//  MultiPeriodReturnReport.swift
//  FinvestLens — Reports
//
//  Each holding's return in each of several periods side by side —
//  Sharesight's Multi-period report — as the period's contribution to its
//  total return (``InvestmentReturnLine/periodReturn``), with the total to
//  the last period's end beside them.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public struct MultiPeriodLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var portfolio: PortfolioRef?
    /// One entry per period, in the report's period order; `nil` where the
    /// period's figure is unknown (unpriced at an end).
    public var periodReturns: [Decimal?]
    /// The total return to the last period's end.
    public var totalReturn: Decimal
    public var annualisedReturn: Double?
}

public struct MultiPeriodReturnReport: Sendable {
    public var periods: [(from: Date, to: Date)]
    public var currencyCode: String
    /// By total return, largest first.
    public var lines: [MultiPeriodLine]
    public var periodTotals: [Decimal?]
    public var totalReturn: Decimal
}

public extension FinancialReports {

    /// The holdings' returns over each of `periods` (ascending, the last the
    /// report date), from the Investment Return report built per period.
    static func multiPeriodReturns(
        _ book: Book,
        currency: Commodity,
        periods: [(from: Date, to: Date)],
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = true,
        portfolioID: GncGUID? = nil
    ) -> MultiPeriodReturnReport {
        guard let last = periods.last else {
            return MultiPeriodReturnReport(periods: [], currencyCode: currency.mnemonic, lines: [],
                                           periodTotals: [], totalReturn: 0)
        }
        let reports = periods.map {
            investmentReturn(book, currency: currency, from: $0.from, to: $0.to, method: method,
                             feeTreatment: feeTreatment, includeClosed: includeClosed, portfolioID: portfolioID)
        }
        let final = reports[reports.count - 1]
        var lines: [MultiPeriodLine] = final.lines.map { line in
            MultiPeriodLine(id: line.id, symbol: line.symbol, accountName: line.accountName,
                            portfolio: line.portfolio,
                            periodReturns: reports.map { report in
                                report.lines.first { $0.id == line.id }?.periodReturn
                            },
                            totalReturn: line.totalReturn, annualisedReturn: line.annualisedReturn)
        }
        lines.sort { $0.totalReturn > $1.totalReturn }
        _ = last
        return MultiPeriodReturnReport(
            periods: periods, currencyCode: currency.mnemonic, lines: lines,
            periodTotals: reports.map(\.totalPeriodReturn),
            totalReturn: final.totalReturn)
    }
}
