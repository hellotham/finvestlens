//
//  CapitalGainsReport.swift
//  FinvestLens — Reports
//
//  The capital-gains report a tax return is prepared from: every parcel sold,
//  with when it was acquired and sold, what it cost and what it fetched, how
//  long it was held, and how the ATO treats the gain — the 50% discount for a
//  parcel owned at least twelve months, and from 1 July 2027 the reform's
//  split of a gain into the part accrued before that date (discounted) and
//  the part after (indexed by CPI). Sources: ATO, "How to calculate your
//  CGT", "CGT discount" and "Capital gains tax reform" (13 Oct 2026), all
//  opened on 25 Oct 2026; the arithmetic lives in `CapitalGainsTaxRules`.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One parcel sold: a CGT event, as the tax return wants it.
public struct CapitalGainLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    /// The security account the parcel was sold from.
    public var accountID: GncGUID
    public var symbol: String
    public var accountName: String
    public var portfolio: PortfolioRef?
    /// When the parcel was acquired — `nil` for a pooled (average-cost)
    /// parcel, whose term the ATO's rules cannot settle.
    public var acquisitionDate: Date?
    /// The CGT event: the sale.
    public var disposalDate: Date
    public var quantity: Decimal
    /// What the parcel cost (the cost base), in the report currency.
    public var costBasis: Decimal
    /// What it fetched (the capital proceeds, the consideration).
    public var proceeds: Decimal
    /// Proceeds less cost base — a loss when negative.
    public var gain: Decimal
    /// Whole days held, when the acquisition date is known.
    public var holdingDays: Int?
    /// Owned at least twelve months before the event, by the ATO's count
    /// (the acquisition day and the event day excluded): eligible for the
    /// discount, or for indexation after the reform. `nil` when the
    /// acquisition date is unknown.
    public var longTerm: Bool?
    /// The ATO treatment of the gain, in one or two slices (two for a parcel
    /// bought before 1 July 2027 and sold on or after it).
    public var components: [CGTComponent]
    /// Whether the parcel was sold out of a position that is closed at the
    /// report date.
    public var positionClosed: Bool
    /// Whether the sale falls in the report's period; a parcel outside it
    /// is listed as history, with the Closed positions switch on.
    public var inPeriod: Bool
    /// The parcel's own compound annual rate — the money-weighted rate of
    /// its two flows, which is GnuCash's lots-report CAGR — `nil` under a
    /// year or without an acquisition date.
    public var annualisedReturn: Double?
    /// Returns ``gain`` as the lot engine's term flag reads it, for the
    /// surfaces that split gains by term.
    public var description: String
    /// How a parcel owned across 1 July 2027 was split: by its value on the
    /// day, or by the days held each side of it; `nil` for a parcel the
    /// reform does not divide.
    public var transitionMethod: CGTTransitionMethod?
    /// A parcel bought before the reform and sold after it whose value just
    /// before 1 July 2027 is not in the price list: the gain is split by
    /// apportionment, and the report says so.
    public var transitionalValueMissing: Bool
    /// A post-reform gain that should have been indexed but had no CPI.
    public var unindexed: Bool {
        components.contains { $0.treatment == .indexation && !$0.indexed && $0.gain > 0 }
    }
}

/// An open (unsold) parcel at the period's end, for the tax-estimate
/// surfaces that read the open cost.
public struct OpenLotLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var acquisitionDate: Date?
    public var quantity: Decimal
    public var costBasis: Decimal
}

/// Realised capital gains: the period's CGT events, and with closed positions
/// on, the whole history of every position sold out of by the period's end
/// (`FR-RPT-03`).
public struct CapitalGainsReport: Sendable {
    public var currencyCode: String
    public var method: CostBasisMethod
    public var feeTreatment: FeeTreatment
    public var from: Date
    public var to: Date
    public var entity: CGTEntity
    public var foreignResident: Bool
    /// By disposal date, oldest first; history parcels (outside the period)
    /// included when closed positions are on.
    public var lines: [CapitalGainLine]
    public var openLots: [OpenLotLine]
    /// The ATO's net capital gain over the period's events alone — gains,
    /// losses offset (from the non-discountable gains first), the discount
    /// on what remains — never over the history parcels, which belong to
    /// other years' returns.
    public var net: CapitalGainsTaxRules.NetGain
    public var unconvertedCurrencyCodes: [String] = []
    /// Securities with a transitional parcel whose value before 1 July 2027
    /// is not in the price list, split by apportionment instead.
    public var transitionalValueMissingSymbols: [String] = []
    /// Parcels whose post-reform gain could not be indexed for want of CPI.
    public var unindexedCount: Int = 0
    /// The period's parcels split at the reform, by either method.
    public var transitionalCount: Int { periodLines.filter { $0.transitionMethod != nil }.count }

    /// The period's parcels.
    public var periodLines: [CapitalGainLine] { lines.filter(\.inPeriod) }
    /// Gains on parcels held under twelve months, in the period.
    public var shortTermGain: Decimal {
        periodLines.filter { $0.longTerm == false }.reduce(0) { $0 + $1.gain }
    }
    /// Gains on parcels held twelve months or more, in the period.
    public var longTermGain: Decimal {
        periodLines.filter { $0.longTerm == true }.reduce(0) { $0 + $1.gain }
    }
    /// Gains whose term is undetermined (pooled lots, uncovered sales).
    public var otherGain: Decimal {
        periodLines.filter { $0.longTerm == nil }.reduce(0) { $0 + $1.gain }
    }
    public var totalGain: Decimal { periodLines.reduce(0) { $0 + $1.gain } }
    public var totalProceeds: Decimal { periodLines.reduce(0) { $0 + $1.proceeds } }
    public var totalCostBasis: Decimal { periodLines.reduce(0) { $0 + $1.costBasis } }
    public var openCostBasis: Decimal { openLots.reduce(0) { $0 + $1.costBasis } }
}

public extension FinancialReports {

    /// The CGT events in `[from, to]` — every parcel sold then, with the
    /// acquisition date it carries however early — and, with
    /// `includeClosed`, every parcel of every position sold out of by `to`.
    /// Each parcel's gain is assessed by the ATO's rules for its dates:
    /// `entity` sets the discount (individual 50%, super fund 33⅓%, company
    /// none) and whether the reform indexes, `foreignResident` turns both
    /// off, `cpi` supplies the quarterly CPI the indexation reads, and a
    /// transitional parcel's value before 1 July 2027 comes from the price
    /// list — without one it is split by apportionment. `portfolioID`
    /// narrows the report to one portfolio.
    static func capitalGains(
        _ book: Book,
        currency: Commodity,
        from: Date = .distantPast,
        to: Date = .distantFuture,
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = false,
        portfolioID: GncGUID? = nil,
        entity: CGTEntity = .individual,
        foreignResident: Bool = false,
        carriedForwardLoss: Decimal = 0,
        cpi: @Sendable (Date) -> Double? = { _ in nil },
        calendar: Calendar = .current
    ) -> CapitalGainsReport {
        var lines: [CapitalGainLine] = []
        var openLots: [OpenLotLine] = []
        var unconverted: Set<String> = []
        var transitionalMissing: Set<String> = []
        var unindexed = 0
        let reformEve = instantBefore(CapitalGainsTaxRules.reformDate)

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            let history = investmentHistory(book, account: account, currency: currency, to: to,
                                            method: method, feeTreatment: feeTreatment)
            unconverted.formUnion(history.unconvertedCurrencyCodes)
            let closed = history.isClosed
            // The value of one unit just before the reform, for the parcels
            // the reform splits — priced once per security.
            lazy var unitValueBeforeReform: Decimal? =
                book.securityUnitValue(account.commodity, in: currency, on: reformEve)

            for event in history.events where event.kind == .sell {
                let inPeriod = event.date >= from && event.date <= to
                guard inPeriod || (includeClosed && closed) else { continue }
                guard event.converted, let cost = event.costBasis, let units = event.units else { continue }
                let proceeds = event.amount
                let transitional = event.acquisitionDate.map { $0 < CapitalGainsTaxRules.reformDate } ?? false
                    && event.date >= CapitalGainsTaxRules.reformDate
                var valueBefore: Decimal?
                if transitional {
                    valueBefore = unitValueBeforeReform.map { currency.round(units * $0) }
                    if valueBefore == nil { transitionalMissing.insert(history.symbol) }
                }
                let assessed = CapitalGainsTaxRules.assess(
                    CGTParcelDisposal(acquisitionDate: event.acquisitionDate, eventDate: event.date,
                                      costBase: cost, proceeds: proceeds, valueBefore2027: valueBefore),
                    entity: entity, foreignResident: foreignResident, cpi: cpi, calendar: calendar)
                if assessed.components.contains(where: { $0.treatment == .indexation && !$0.indexed && $0.gain > 0 }) {
                    unindexed += 1
                }
                var annualised: Double?
                if let acquired = event.acquisitionDate, InvestmentYield.isAnnualisable(from: acquired, to: event.date) {
                    annualised = MoneyWeightedReturn.rate(of: [
                        DatedCashFlow(date: acquired, amount: -cost),
                        DatedCashFlow(date: event.date, amount: proceeds)])
                }
                lines.append(CapitalGainLine(
                    id: event.id, accountID: account.guid, symbol: history.symbol,
                    accountName: account.name, portfolio: history.portfolio,
                    acquisitionDate: event.acquisitionDate, disposalDate: event.date,
                    quantity: units, costBasis: currency.round(cost), proceeds: currency.round(proceeds),
                    gain: currency.round(proceeds - cost),
                    holdingDays: assessed.holdingDays,
                    longTerm: event.acquisitionDate == nil ? nil : assessed.heldTwelveMonths,
                    components: assessed.components,
                    positionClosed: closed, inPeriod: inPeriod,
                    annualisedReturn: annualised,
                    description: event.description,
                    transitionMethod: assessed.transitionMethod,
                    transitionalValueMissing: assessed.transitionalValueMissing))
            }

            // What is still open at the period's end, at its cost — the lot
            // engine's open lots, already run for the history.
            for parcel in history.openParcels where parcel.converted {
                openLots.append(OpenLotLine(id: .random(), symbol: history.symbol, accountName: account.name,
                                            acquisitionDate: parcel.acquisitionDate, quantity: parcel.quantity,
                                            costBasis: currency.round(parcel.costBasis)))
            }
        }

        let sorted = lines.sorted { $0.disposalDate < $1.disposalDate }
        let net = CapitalGainsTaxRules.net(
            components: sorted.filter(\.inPeriod).flatMap(\.components),
            entity: entity, carriedForwardLoss: carriedForwardLoss)
        return CapitalGainsReport(
            currencyCode: currency.mnemonic, method: method, feeTreatment: feeTreatment,
            from: from, to: to, entity: entity, foreignResident: foreignResident, lines: sorted,
            openLots: openLots.sorted { ($0.acquisitionDate ?? .distantPast) < ($1.acquisitionDate ?? .distantPast) },
            net: net,
            unconvertedCurrencyCodes: unconverted.sorted(),
            transitionalValueMissingSymbols: transitionalMissing.sorted(),
            unindexedCount: unindexed)
    }
}
