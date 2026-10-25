//
//  AdvancedPortfolioReport.swift
//  FinvestLens — Reports
//
//  GnuCash's Advanced Portfolio, read from the shared investment history:
//  per holding its units, price, cost basis, value, money in and out,
//  realised and unrealised gain, income, total return and rate of return —
//  "Total Return = Total Gain + Income" and "Rate of Return = Total Return /
//  Money In" (gnucash-user, March 2014; advanced-portfolio.scm) — plus the
//  money-weighted annual rate every investment report prints.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A holding in the advanced portfolio, tying market value to the lot engine so
/// cost basis reflects only the shares still held (`FR-RPT-02a`).
public struct AdvancedHolding: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var accountName: String
    public var symbol: String
    /// The account above the holding's — its portfolio; `nil` at the top of
    /// the tree.
    public var portfolio: PortfolioRef?
    /// Shares still held (from the lot engine).
    public var shares: Decimal
    /// Cost basis of the shares still held.
    public var costBasis: Decimal
    /// Average cost per held share, if any shares remain.
    public var averageCost: Decimal?
    /// Unit price in the report currency on the report date, if available.
    public var price: Decimal?
    /// shares × price, if priced.
    public var marketValue: Decimal?
    /// Market value − cost basis, if priced.
    public var unrealizedGain: Decimal?
    /// Unrealized gain as a fraction of cost, if priced and cost ≠ 0.
    public var unrealizedFraction: Double?
    /// Realized gain to date from disposals (from the lot engine).
    public var realizedGain: Decimal
    /// Total cost of every acquisition (held + since-sold) — GnuCash's
    /// "Money In".
    public var moneyIn: Decimal
    /// Total proceeds from disposals — GnuCash's "Money Out".
    public var moneyOut: Decimal
    /// Cash income — dividends, distributions, interest — attributed to the
    /// security by the shared rule (`FR-RPT-02b`): GnuCash's "Income".
    public var income: Decimal
    /// Franking credits recorded against the security — not cash, so not in
    /// ``income``; shown beside it.
    public var frankingCredits: Decimal
    /// Return on investment: (unrealized + realized gain + income) ÷ money in,
    /// if money in ≠ 0 (GnuCash's "Rate of Return").
    public var returnFraction: Double?
    /// Share of the total portfolio market value, if priced.
    public var allocation: Double?
    /// When the first parcel was bought.
    public var firstAcquisition: Date?
    /// Years from the first purchase to the report date.
    public var heldYears: Double?
    /// The money-weighted annual rate of the holding's cash flows with its
    /// value on the report date (XIRR); `nil` under a year or unpriced.
    public var annualisedReturn: Double?

    /// Unrealized, realized and income together — GnuCash's total return, in
    /// money. The figure the holdings are sorted by in the report.
    public var totalGain: Decimal { (unrealizedGain ?? 0) + realizedGain + income }
    /// Nothing held: a position sold out of, kept for its history.
    public var isClosed: Bool { shares == 0 }
}

/// A richer portfolio valuation: per-holding cost basis, average cost,
/// unrealized/realized gains, and asset allocation (`FR-RPT-02a`).
public struct AdvancedPortfolio: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var method: CostBasisMethod
    /// By market value, largest first — the order the Investments hub and the
    /// review decks read; a report that wants another order sorts for itself.
    public var holdings: [AdvancedHolding]
    public var totalCost: Decimal
    public var totalValue: Decimal
    public var totalUnrealized: Decimal
    public var totalRealized: Decimal
    /// Total acquisition cost across all holdings (GnuCash "Money In").
    public var totalMoneyIn: Decimal
    /// Total disposal proceeds across all holdings (GnuCash "Money Out").
    public var totalMoneyOut: Decimal
    /// Total cash income across all holdings (GnuCash "Income").
    public var totalIncome: Decimal
    public var totalFranking: Decimal
    /// The money-weighted annual rate of every holding's flows together.
    public var annualisedReturn: Double?
    public var unpricedSymbols: [String]
    public var unconvertedCurrencyCodes: [String]

    /// Total return: (unrealized + realized + income) ÷ money in (`nil` when
    /// there is no money in). Matches GnuCash's advanced-portfolio total return.
    public var totalReturnFraction: Double? {
        guard totalMoneyIn != 0 else { return nil }
        let gain = totalUnrealized + totalRealized + totalIncome
        return InvestmentYield.double(gain) / InvestmentYield.double(totalMoneyIn)
    }
}

public extension FinancialReports {

    /// Values every security account from the shared history: the lot
    /// engine for cost basis, the price list (with an FX hop for foreign
    /// securities) for market value, every amount in the report currency.
    ///
    /// `includeClosed` keeps positions sold out of — their realised gain and
    /// income still count — where `false` reports only what is held (the
    /// Portfolio report's default, as the Investments hub hides them;
    /// `FR-INV-24`). `portfolioID` narrows the report to one portfolio.
    static func advancedPortfolio(
        _ book: Book,
        currency: Commodity,
        asOf: Date = Date(),
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = true,
        portfolioID: GncGUID? = nil
    ) -> AdvancedPortfolio {
        var holdings: [AdvancedHolding] = []
        var totalValue = Decimal(0)
        var unpriced: [String] = []
        var unconverted: Set<String> = []
        var allFlows: [DatedCashFlow] = []
        var flowsComplete = true

        for history in investmentHistories(book, currency: currency, to: asOf, method: method,
                                           feeTreatment: feeTreatment, portfolioID: portfolioID) {
            // Closed: nothing held. With closed positions in, any history at
            // all keeps the row — a position sold at cost still shows its
            // dividends.
            guard !history.events.isEmpty else { continue }
            guard includeClosed || !history.isClosed else { continue }
            unconverted.formUnion(history.unconvertedCurrencyCodes)
            if history.unitsHeld != 0, history.marketValue == nil { unpriced.append(history.symbol) }
            if let marketValue = history.marketValue { totalValue += marketValue }

            let cost = history.remainingCostBasis
            let unrealized = history.unrealizedGain.map { currency.round($0) }
            let income = currency.round(history.dividends)
            let realized = currency.round(history.realizedGain)
            let totalGain = (unrealized ?? 0) + realized + income
            let heldYears = history.firstAcquisition.map { InvestmentYield.years(from: $0, to: asOf) }
            var annualised: Double?
            if let flows = history.cashFlows(valuedAt: asOf) {
                let dated = flows.map { DatedCashFlow(date: $0.date, amount: $0.amount) }
                allFlows.append(contentsOf: dated)
                if let first = history.firstAcquisition, InvestmentYield.isAnnualisable(from: first, to: asOf) {
                    annualised = MoneyWeightedReturn.rate(of: dated)
                }
            } else {
                flowsComplete = false
            }

            holdings.append(AdvancedHolding(
                id: history.id, accountName: history.accountName, symbol: history.symbol,
                portfolio: history.portfolio, shares: history.unitsHeld, costBasis: cost,
                averageCost: history.unitsHeld != 0 ? cost / history.unitsHeld : nil,
                price: history.price, marketValue: history.marketValue,
                unrealizedGain: unrealized,
                unrealizedFraction: (unrealized != nil && cost != 0)
                    ? InvestmentYield.double(unrealized!) / InvestmentYield.double(cost) : nil,
                realizedGain: realized, moneyIn: history.moneyIn, moneyOut: history.moneyOut,
                income: income, frankingCredits: currency.round(history.frankingCredits),
                returnFraction: history.moneyIn != 0
                    ? InvestmentYield.double(totalGain) / InvestmentYield.double(history.moneyIn) : nil,
                allocation: nil, firstAcquisition: history.firstAcquisition, heldYears: heldYears,
                annualisedReturn: annualised))
        }

        // Allocation needs the whole: a second pass once the total is known.
        for index in holdings.indices {
            if let value = holdings[index].marketValue, totalValue != 0 {
                holdings[index].allocation = InvestmentYield.double(value) / InvestmentYield.double(totalValue)
            }
        }
        var portfolioRate: Double?
        if flowsComplete, let first = allFlows.map(\.date).min(), InvestmentYield.isAnnualisable(from: first, to: asOf) {
            portfolioRate = MoneyWeightedReturn.rate(of: allFlows)
        }

        return AdvancedPortfolio(
            asOf: asOf, currencyCode: currency.mnemonic, method: method,
            holdings: holdings.sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) },
            totalCost: currency.round(holdings.reduce(0) { $0 + $1.costBasis }),
            totalValue: currency.round(totalValue),
            totalUnrealized: currency.round(holdings.reduce(0) { $0 + ($1.unrealizedGain ?? 0) }),
            totalRealized: currency.round(holdings.reduce(0) { $0 + $1.realizedGain }),
            totalMoneyIn: currency.round(holdings.reduce(0) { $0 + $1.moneyIn }),
            totalMoneyOut: currency.round(holdings.reduce(0) { $0 + $1.moneyOut }),
            totalIncome: currency.round(holdings.reduce(0) { $0 + $1.income }),
            totalFranking: currency.round(holdings.reduce(0) { $0 + $1.frankingCredits }),
            annualisedReturn: portfolioRate,
            unpricedSymbols: unpriced.sorted(),
            unconvertedCurrencyCodes: unconverted.sorted())
    }
}
