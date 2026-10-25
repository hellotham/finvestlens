//
//  AdvancedPortfolioReport.swift
//  FinvestLens — Reports
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
    /// Latest unit price in the report currency, if available.
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
    /// Cash income (dividends/interest) — GnuCash's "Income": the sum of
    /// income-account splits in transactions that touch this security account.
    public var income: Decimal
    /// Return on investment: (unrealized + realized gain + income) ÷ money in,
    /// if money in ≠ 0 (GnuCash's "Total Return").
    public var returnFraction: Double?
    /// Share of the total portfolio market value, if priced.
    public var allocation: Double?
    /// How long the money has been in, cost-weighted across every parcel —
    /// a held lot to the report date, a sold one to its sale
    /// (``InvestmentYield``); `nil` when nothing was paid.
    public var heldYears: Double?
    /// ``totalGain`` as a simple annual rate on ``moneyIn`` over ``heldYears``.
    public var yieldPerAnnum: Double?

    /// Unrealized, realized and income together — GnuCash's total return, in
    /// money. The figure the holdings are sorted by.
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

    /// Total return: (unrealized + realized + income) ÷ money in (`nil` when
    /// there is no money in). Matches GnuCash's advanced-portfolio total return.
    public var totalReturnFraction: Double? {
        guard totalMoneyIn != 0 else { return nil }
        let gain = totalUnrealized + totalRealized + totalIncome
        return NSDecimalNumber(decimal: gain).doubleValue / NSDecimalNumber(decimal: totalMoneyIn).doubleValue
    }

    /// The whole portfolio's gain as an annual rate on its money in, over the
    /// cost-weighted time the holdings were held.
    public var yieldPerAnnum: Double? {
        InvestmentYield.combined(holdings.map { ($0.totalGain, $0.moneyIn, $0.heldYears) })
    }
}

public extension FinancialReports {

    /// Values every security account using the lot engine for cost basis and the
    /// price DB (with an FX hop for foreign securities) for market value.
    ///
    /// `includeClosed` keeps positions sold out of — their realised gain and
    /// income still count — where `false` reports only what is held (the
    /// Portfolio report's default, as the Investments hub hides them;
    /// `FR-INV-24`). Reported on build 7: "No toggle to show closed positions
    /// in investment tab and reports." `portfolioID` narrows the report to the
    /// security accounts directly under one portfolio.
    static func advancedPortfolio(
        _ book: Book,
        currency: Commodity,
        asOf: Date = Date(),
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = true,
        portfolioID: GncGUID? = nil
    ) -> AdvancedPortfolio {
        struct Raw {
            let account: Account
            let shares: Decimal
            let costBasis: Decimal
            let realized: Decimal
            let moneyIn: Decimal
            let moneyOut: Decimal
            let income: Decimal
            let price: Decimal?
            let marketValue: Decimal?
            let heldYears: Double?
        }

        // Cash income (dividends/interest) attributed to a security: GnuCash's
        // advanced-portfolio sums income-account splits in transactions that
        // touch the security account (a pure cash dividend that never touches
        // the holding is, as in GnuCash, not counted here).
        func income(of account: Account) -> Decimal {
            var total = Decimal(0)
            var counted = Set<GncGUID>()
            for split in book.splits(for: account) {
                guard let txn = split.transaction, txn.datePosted <= asOf,
                      counted.insert(txn.guid).inserted else { continue }
                for other in txn.splits where other.account?.type == .income {
                    let amount = -other.value                 // income splits are credits
                    if txn.currency == currency {
                        total += amount
                    } else if let converted = book.convert(amount, from: txn.currency,
                                                           to: currency, on: txn.datePosted) {
                        total += converted
                    }
                    // No rate for the pair on that date: the dividend is left
                    // out rather than added at face value. Adding the raw
                    // foreign figure put, say, USD into an AUD income column
                    // and thence into `totalReturnFraction` — a wrong number
                    // that reads as a right one.
                }
            }
            return currency.round(total)
        }

        var raws: [Raw] = []
        var totalValue = Decimal(0)

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            let basis = book.costBasis(for: account, asOf: asOf, method: method, feeTreatment: feeTreatment,
                                       currencyFraction: currency.smallestFraction)
            let shares = basis.remainingQuantity
            // Closed: nothing held. With closed positions in, any history at
            // all keeps the row — money in, a gain, income — so a position
            // sold at cost still shows its dividends.
            let hasHistory = shares != 0 || basis.totalRealizedGain != 0
                || basis.remainingCostBasis + basis.totalCostBasis != 0
            guard includeClosed ? hasHistory : shares != 0 else { continue }

            let cost = currency.round(basis.remainingCostBasis)
            // Money In = cost of all acquisitions = cost of held shares + cost
            // basis of the shares since sold. Money Out = disposal proceeds.
            let moneyIn = currency.round(basis.remainingCostBasis + basis.totalCostBasis)
            let moneyOut = currency.round(basis.totalProceeds)
            let price = book.securityUnitValue(account.commodity, in: currency, on: asOf)
            let marketValue = price.map { currency.round(shares * $0) }
            if let marketValue { totalValue += marketValue }

            // Every parcel the money went into, and for how long: a held lot
            // to the report date, a sold one to its sale. A pooled lot has no
            // date of its own and is held from the first purchase.
            let first = pooledLots(basis) ? (firstAcquisition(of: account, in: book) ?? asOf) : asOf
            let parcels = basis.openLots.map {
                HeldParcel(cost: $0.costBasis,
                           years: InvestmentYield.years(from: $0.acquisitionDate ?? first, to: asOf))
            } + basis.realizedGains.map {
                HeldParcel(cost: $0.costBasis,
                           years: InvestmentYield.years(from: $0.acquisitionDate ?? first, to: $0.disposalDate))
            }

            raws.append(Raw(account: account, shares: shares, costBasis: cost,
                            realized: currency.round(basis.totalRealizedGain),
                            moneyIn: moneyIn, moneyOut: moneyOut, income: income(of: account),
                            price: price, marketValue: marketValue,
                            heldYears: InvestmentYield.weightedYears(parcels)))
        }

        var holdings: [AdvancedHolding] = []
        var totalCost = Decimal(0)
        var totalUnrealized = Decimal(0)
        var totalRealized = Decimal(0)
        var totalMoneyIn = Decimal(0)
        var totalMoneyOut = Decimal(0)
        var totalIncome = Decimal(0)

        for raw in raws {
            let unrealized = raw.marketValue.map { $0 - raw.costBasis }
            let unrealizedFraction: Double? = (unrealized != nil && raw.costBasis != 0)
                ? NSDecimalNumber(decimal: unrealized!).doubleValue / NSDecimalNumber(decimal: raw.costBasis).doubleValue
                : nil
            let averageCost = raw.shares != 0 ? raw.costBasis / raw.shares : nil
            let allocation: Double? = (raw.marketValue != nil && totalValue != 0)
                ? NSDecimalNumber(decimal: raw.marketValue!).doubleValue / NSDecimalNumber(decimal: totalValue).doubleValue
                : nil
            let totalGain = (unrealized ?? 0) + raw.realized + raw.income
            let returnFraction: Double? = raw.moneyIn != 0
                ? NSDecimalNumber(decimal: totalGain).doubleValue / NSDecimalNumber(decimal: raw.moneyIn).doubleValue
                : nil

            holdings.append(AdvancedHolding(
                id: raw.account.guid, accountName: raw.account.name,
                symbol: raw.account.commodity.mnemonic,
                portfolio: portfolio(of: raw.account), shares: raw.shares,
                costBasis: raw.costBasis, averageCost: averageCost,
                price: raw.price, marketValue: raw.marketValue,
                unrealizedGain: unrealized, unrealizedFraction: unrealizedFraction,
                realizedGain: raw.realized, moneyIn: raw.moneyIn, moneyOut: raw.moneyOut,
                income: raw.income, returnFraction: returnFraction, allocation: allocation,
                heldYears: raw.heldYears,
                yieldPerAnnum: InvestmentYield.annualised(gain: totalGain, cost: raw.moneyIn,
                                                          years: raw.heldYears)))

            totalCost += raw.costBasis
            if let unrealized { totalUnrealized += unrealized }
            totalRealized += raw.realized
            totalMoneyIn += raw.moneyIn
            totalMoneyOut += raw.moneyOut
            totalIncome += raw.income
        }

        return AdvancedPortfolio(
            asOf: asOf, currencyCode: currency.mnemonic, method: method,
            holdings: holdings.sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) },
            totalCost: currency.round(totalCost),
            totalValue: currency.round(totalValue),
            totalUnrealized: currency.round(totalUnrealized),
            totalRealized: currency.round(totalRealized),
            totalMoneyIn: currency.round(totalMoneyIn),
            totalMoneyOut: currency.round(totalMoneyOut),
            totalIncome: currency.round(totalIncome))
    }
}
