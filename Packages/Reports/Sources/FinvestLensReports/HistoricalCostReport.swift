//
//  HistoricalCostReport.swift
//  FinvestLens — Reports
//
//  Opening and closing balances at cost over a period, with market value
//  beside them — the view an entity preparing annual accounts needs
//  (Sharesight's Historical Cost report; InvestaLens's): what was held at
//  the start and its cost, what was bought, the cost of what was sold, the
//  capital returned, and what is held at the end.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public struct HistoricalCostLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var portfolio: PortfolioRef?
    public var openingUnits: Decimal
    public var openingCost: Decimal
    public var openingValue: Decimal?
    /// Cost of the parcels bought in the period.
    public var purchases: Decimal
    /// Cost basis of the parcels sold in the period, under the method.
    public var costOfSales: Decimal
    /// Returns of capital in the period, as a reduction (negative).
    public var adjustments: Decimal
    public var closingUnits: Decimal
    public var closingCost: Decimal
    public var closingValue: Decimal?
    /// Whether opening + purchases − cost of sales + adjustments meets the
    /// closing cost within rounding; a difference is a conversion or a
    /// pooled-lot effect, and the report says so.
    public var reconciles: Bool
}

public struct HistoricalCostReport: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    public var method: CostBasisMethod
    /// By closing cost, largest first.
    public var lines: [HistoricalCostLine]
    public var totalOpeningCost: Decimal
    public var totalOpeningValue: Decimal
    public var totalPurchases: Decimal
    public var totalCostOfSales: Decimal
    public var totalAdjustments: Decimal
    public var totalClosingCost: Decimal
    public var totalClosingValue: Decimal
    public var unpricedSymbols: [String]
    public var unconvertedCurrencyCodes: [String]
}

public extension FinancialReports {

    /// The cost movement of every holding over `[from, to]` — holdings with
    /// nothing at either end and nothing in between are left out.
    static func historicalCost(
        _ book: Book,
        currency: Commodity,
        from: Date,
        to: Date,
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        portfolioID: GncGUID? = nil
    ) -> HistoricalCostReport {
        var lines: [HistoricalCostLine] = []
        var unpriced: [String] = []
        var unconverted: Set<String> = []
        let before = instantBefore(from)

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            let closing = investmentHistory(book, account: account, currency: currency, to: to,
                                            method: method, feeTreatment: feeTreatment)
            let opening = investmentHistory(book, account: account, currency: currency, to: before,
                                            method: method, feeTreatment: feeTreatment)
            let period = closing.events.filter { $0.date >= from && $0.date <= to }
            guard opening.unitsHeld != 0 || closing.unitsHeld != 0 || !period.isEmpty else { continue }
            unconverted.formUnion(closing.unconvertedCurrencyCodes)
            if closing.unitsHeld != 0, closing.marketValue == nil { unpriced.append(closing.symbol) }

            let purchases = currency.round(period.filter { $0.kind == .buy }.reduce(0) { $0 + $1.amount })
            let costOfSales = currency.round(period.filter { $0.kind == .sell }.reduce(0) { $0 + ($1.costBasis ?? 0) })
            let adjustments = currency.round(-period.filter { $0.kind == .returnOfCapital }.reduce(0) { $0 + $1.amount })
            let expected = opening.remainingCostBasis + purchases - costOfSales + adjustments
            lines.append(HistoricalCostLine(
                id: account.guid, symbol: closing.symbol, accountName: account.name, portfolio: closing.portfolio,
                openingUnits: opening.unitsHeld, openingCost: opening.remainingCostBasis,
                openingValue: opening.marketValue,
                purchases: purchases, costOfSales: costOfSales, adjustments: adjustments,
                closingUnits: closing.unitsHeld, closingCost: closing.remainingCostBasis,
                closingValue: closing.marketValue,
                reconciles: abs(expected - closing.remainingCostBasis) <= Decimal(1) / Decimal(currency.smallestFraction) * 2))
        }
        let sorted = lines.sorted { $0.closingCost > $1.closingCost }
        return HistoricalCostReport(
            from: from, to: to, currencyCode: currency.mnemonic, method: method, lines: sorted,
            totalOpeningCost: sorted.reduce(0) { $0 + $1.openingCost },
            totalOpeningValue: sorted.reduce(0) { $0 + ($1.openingValue ?? 0) },
            totalPurchases: sorted.reduce(0) { $0 + $1.purchases },
            totalCostOfSales: sorted.reduce(0) { $0 + $1.costOfSales },
            totalAdjustments: sorted.reduce(0) { $0 + $1.adjustments },
            totalClosingCost: sorted.reduce(0) { $0 + $1.closingCost },
            totalClosingValue: sorted.reduce(0) { $0 + ($1.closingValue ?? 0) },
            unpricedSymbols: unpriced.sorted(), unconvertedCurrencyCodes: unconverted.sorted())
    }
}
