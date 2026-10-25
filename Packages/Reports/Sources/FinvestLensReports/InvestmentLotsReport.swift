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
/// lists sold parcels, one already sold, with what it fetched. Carries what
/// Sharesight's Unrealised CGT report asks of an open parcel: whether it has
/// been owned twelve months, so its gain would be discounted (or, after the
/// reform, indexed) if sold on the report date.
public struct LotDetail: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    /// The security account the parcel belongs to.
    public var accountID: GncGUID
    public var symbol: String
    public var accountName: String
    public var portfolio: PortfolioRef?
    public var acquisitionDate: Date?
    public var quantity: Decimal
    /// What the parcel cost, in the report currency.
    public var costBasis: Decimal
    /// Unit price in the report currency on the report date, if available
    /// (an open lot).
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
    /// Years held, for the rates; `nil` without an acquisition date.
    public var heldYears: Double?
    /// The parcel's gain over its cost — GnuCash's lots-report ROI.
    public var returnFraction: Double?
    /// The parcel's compound annual rate — the money-weighted rate of its
    /// cost and its value or proceeds, GnuCash's lots-report CAGR; `nil`
    /// under a year.
    public var annualisedReturn: Double?
    /// Owned at least twelve months by the ATO's count at the report date
    /// (open) or the sale (sold): the gain would be discounted, or indexed
    /// after the reform. `nil` without an acquisition date.
    public var longTerm: Bool?

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
        portfolioID: GncGUID? = nil,
        calendar: Calendar = .current
    ) -> [LotDetail] {
        var details: [LotDetail] = []

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            let history = investmentHistory(book, account: account, currency: currency, to: asOf,
                                            method: method, feeTreatment: feeTreatment)
            let symbol = account.commodity.mnemonic
            let price = history.price ?? book.securityUnitValue(account.commodity, in: currency, on: asOf)
            // A pooled (average-cost) lot has no date of its own: it is held
            // from the first purchase.
            let first = history.firstAcquisition

            for lot in history.openParcels where lot.converted {
                let cost = currency.round(lot.costBasis)
                let marketValue = price.map { currency.round(lot.quantity * $0) }
                let unrealized = marketValue.map { $0 - cost }
                let acquired = lot.acquisitionDate ?? first
                let days = acquired.map { wholeCalendarDays(from: $0, to: asOf) }
                let years = acquired.map { InvestmentYield.years(from: $0, to: asOf) }
                var annualised: Double?
                if let acquired, let marketValue, InvestmentYield.isAnnualisable(from: acquired, to: asOf) {
                    annualised = MoneyWeightedReturn.rate(of: [DatedCashFlow(date: acquired, amount: -cost),
                                                               DatedCashFlow(date: asOf, amount: marketValue)])
                }
                details.append(LotDetail(
                    id: .random(), accountID: account.guid, symbol: symbol, accountName: account.name,
                    portfolio: history.portfolio,
                    acquisitionDate: lot.acquisitionDate, quantity: lot.quantity,
                    costBasis: cost, price: price, marketValue: marketValue,
                    unrealizedGain: unrealized, holdingDays: days, heldYears: years,
                    returnFraction: unrealized.flatMap { cost != 0 ? InvestmentYield.double($0) / InvestmentYield.double(cost) : nil },
                    annualisedReturn: annualised,
                    longTerm: lot.acquisitionDate.map {
                        CapitalGainsTaxRules.heldTwelveMonths(acquired: $0, event: asOf, calendar: calendar)
                    }))
            }

            guard includeClosed else { continue }
            for sold in history.events where sold.kind == .sell && sold.converted {
                guard let cost = sold.costBasis, let units = sold.units else { continue }
                let proceeds = sold.amount
                let acquired = sold.acquisitionDate ?? first
                let years = acquired.map { InvestmentYield.years(from: $0, to: sold.date) }
                var annualised: Double?
                if let acquired, InvestmentYield.isAnnualisable(from: acquired, to: sold.date) {
                    annualised = MoneyWeightedReturn.rate(of: [DatedCashFlow(date: acquired, amount: -cost),
                                                               DatedCashFlow(date: sold.date, amount: proceeds)])
                }
                details.append(LotDetail(
                    id: sold.id, accountID: account.guid, symbol: symbol, accountName: account.name,
                    portfolio: history.portfolio,
                    acquisitionDate: sold.acquisitionDate, quantity: units,
                    costBasis: currency.round(cost), price: nil, marketValue: nil, unrealizedGain: nil,
                    holdingDays: acquired.map { wholeCalendarDays(from: $0, to: sold.date) },
                    disposalDate: sold.date, proceeds: currency.round(proceeds),
                    realizedGain: currency.round(proceeds - cost), heldYears: years,
                    returnFraction: cost != 0 ? InvestmentYield.double(proceeds - cost) / InvestmentYield.double(cost) : nil,
                    annualisedReturn: annualised,
                    longTerm: sold.acquisitionDate.map {
                        CapitalGainsTaxRules.heldTwelveMonths(acquired: $0, event: sold.date, calendar: calendar)
                    }))
            }
        }

        return details.sorted {
            ($0.acquisitionDate ?? .distantPast) < ($1.acquisitionDate ?? .distantPast)
        }
    }
}

/// What the open parcels would be assessed at if sold on the report date —
/// Sharesight's and InvestaLens's Unrealised CGT view, "a forecasting tool
/// only": each parcel through the same ATO rules as a real disposal, with
/// its market value as the proceeds.
public struct UnrealisedCapitalGains: Sendable {
    public var asOf: Date
    public var entity: CGTEntity
    /// Gains on parcels held twelve months or more — discountable, or
    /// indexed after the reform.
    public var longTermGains: Decimal
    /// Gains on parcels held under twelve months.
    public var shortTermGains: Decimal
    public var losses: Decimal
    public var net: CapitalGainsTaxRules.NetGain
    public var unpricedCount: Int
}

public extension FinancialReports {

    static func unrealisedCapitalGains(
        _ lots: [LotDetail], asOf: Date, entity: CGTEntity = .individual, foreignResident: Bool = false,
        valueBefore2027: (LotDetail) -> Decimal? = { _ in nil },
        cpi: @Sendable (Date) -> Double? = { _ in nil },
        calendar: Calendar = .current
    ) -> UnrealisedCapitalGains {
        var components: [CGTComponent] = []
        var longTerm = Decimal(0), shortTerm = Decimal(0), losses = Decimal(0), unpriced = 0
        for lot in lots where !lot.isClosed {
            guard let marketValue = lot.marketValue else { unpriced += 1; continue }
            let assessed = CapitalGainsTaxRules.assess(
                CGTParcelDisposal(acquisitionDate: lot.acquisitionDate, eventDate: asOf,
                                  costBase: lot.costBasis, proceeds: marketValue,
                                  valueBefore2027: valueBefore2027(lot)),
                entity: entity, foreignResident: foreignResident, cpi: cpi, calendar: calendar)
            components.append(contentsOf: assessed.components)
            let gain = marketValue - lot.costBasis
            if gain < 0 { losses += -gain } else if assessed.heldTwelveMonths { longTerm += gain } else { shortTerm += gain }
        }
        return UnrealisedCapitalGains(
            asOf: asOf, entity: entity, longTermGains: longTerm, shortTermGains: shortTerm, losses: losses,
            net: CapitalGainsTaxRules.net(components: components, entity: entity), unpricedCount: unpriced)
    }
}
