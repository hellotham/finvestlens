//
//  InvestmentLotsReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One tax lot with its valuation (`FR-RPT-02`, Investment Lots): a parcel
/// still held, marked at the price on the report date — or, when the report
/// lists closed positions, a parcel already sold, with what it fetched.
public struct LotDetail: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    /// The security account the parcel belongs to.
    public var accountID: GncGUID
    public var symbol: String
    public var accountName: String
    /// The account above the security's — its portfolio; `nil` at the top of
    /// the tree.
    public var portfolio: PortfolioRef?
    public var acquisitionDate: Date?
    public var quantity: Decimal
    public var costBasis: Decimal
    /// Unit price in the report currency, if available (an open lot).
    public var price: Decimal?
    public var marketValue: Decimal?
    public var unrealizedGain: Decimal?
    /// Whole days held: to the report date for an open lot, to the sale for
    /// a sold one, when an acquisition date is known.
    public var holdingDays: Int?
    /// When the parcel was sold — set only for a sold parcel.
    public var disposalDate: Date?
    /// What a sold parcel fetched.
    public var proceeds: Decimal?
    /// A sold parcel's gain: proceeds less cost.
    public var realizedGain: Decimal?
    /// Years held, for the yield; from the first purchase for a pooled lot.
    public var heldYears: Double?
    /// The parcel's gain as a simple annual rate on its cost
    /// (``InvestmentYield``).
    public var yieldPerAnnum: Double?

    /// A parcel already sold.
    public var isClosed: Bool { disposalDate != nil }
    /// The gain the row shows: realised for a sold parcel, unrealised for one
    /// still held — `nil` for a held parcel with no price.
    public var gain: Decimal? { isClosed ? realizedGain : unrealizedGain }
    /// What the parcel is worth now, or fetched: market value, or proceeds.
    public var value: Decimal? { isClosed ? proceeds : marketValue }
}

public extension FinancialReports {

    /// Every open lot across the security accounts, valued at the price on or
    /// before `asOf` (`FR-RPT-02`, Investment Lots report) — and, with
    /// `includeClosed`, every parcel sold by then, with its proceeds and
    /// realised gain, so a security's whole lot history reads in one place.
    /// `portfolioID` narrows the report to one portfolio's accounts.
    static func investmentLots(
        _ book: Book,
        currency: Commodity,
        asOf: Date = Date(),
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = false,
        portfolioID: GncGUID? = nil
    ) -> [LotDetail] {
        var details: [LotDetail] = []

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            let result = book.costBasis(for: account, asOf: asOf, method: method, feeTreatment: feeTreatment,
                                        currencyFraction: currency.smallestFraction)
            let symbol = account.commodity.mnemonic
            let price = book.securityUnitValue(account.commodity, in: currency, on: asOf)
            let portfolio = portfolio(of: account)
            // A pooled (average-cost) lot has no date of its own: it is held
            // from the first purchase.
            let first = pooledLots(result) ? (firstAcquisition(of: account, in: book) ?? asOf) : asOf

            for lot in result.openLots {
                let cost = currency.round(lot.costBasis)
                let marketValue = price.map { currency.round(lot.quantity * $0) }
                let unrealized = marketValue.map { $0 - cost }
                let days = lot.acquisitionDate.map { wholeCalendarDays(from: $0, to: asOf) }
                let years = InvestmentYield.years(from: lot.acquisitionDate ?? first, to: asOf)
                details.append(LotDetail(
                    id: .random(), accountID: account.guid, symbol: symbol, accountName: account.name,
                    portfolio: portfolio,
                    acquisitionDate: lot.acquisitionDate, quantity: lot.quantity,
                    costBasis: cost, price: price, marketValue: marketValue,
                    unrealizedGain: unrealized, holdingDays: days, heldYears: years,
                    yieldPerAnnum: unrealized.flatMap {
                        InvestmentYield.annualised(gain: $0, cost: cost, years: years)
                    }))
            }

            guard includeClosed else { continue }
            for sold in result.realizedGains {
                let cost = currency.round(sold.costBasis)
                let proceeds = currency.round(sold.proceeds)
                let years = InvestmentYield.years(from: sold.acquisitionDate ?? first, to: sold.disposalDate)
                details.append(LotDetail(
                    id: .random(), accountID: account.guid, symbol: symbol, accountName: account.name,
                    portfolio: portfolio,
                    acquisitionDate: sold.acquisitionDate, quantity: sold.quantity,
                    costBasis: cost, price: nil, marketValue: nil, unrealizedGain: nil,
                    holdingDays: sold.holdingDays, disposalDate: sold.disposalDate,
                    proceeds: proceeds, realizedGain: proceeds - cost, heldYears: years,
                    yieldPerAnnum: InvestmentYield.annualised(gain: proceeds - cost, cost: cost,
                                                              years: years)))
            }
        }

        return details.sorted {
            ($0.acquisitionDate ?? .distantPast) < ($1.acquisitionDate ?? .distantPast)
        }
    }
}
