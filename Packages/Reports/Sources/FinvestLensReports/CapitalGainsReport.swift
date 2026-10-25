//
//  CapitalGainsReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A realised gain line for the capital-gains report, tagged with its security.
public struct CapitalGainLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    /// The security account the parcel was sold from.
    public var accountID: GncGUID
    public var symbol: String
    public var accountName: String
    /// The account above the security's — its portfolio; `nil` at the top of
    /// the tree.
    public var portfolio: PortfolioRef?
    public var disposalDate: Date
    public var acquisitionDate: Date?
    public var quantity: Decimal
    public var proceeds: Decimal
    public var costBasis: Decimal
    public var gain: Decimal
    public var longTerm: Bool?
    /// Whether the security was sold out of entirely by the period's end —
    /// the report's Closed positions switch.
    public var positionClosed: Bool
    /// Years the parcel was held; from the first purchase for a pooled lot.
    public var heldYears: Double?
    /// The gain as a simple annual rate on the parcel's cost
    /// (``InvestmentYield``).
    public var yieldPerAnnum: Double?
}

/// An open (unsold) parcel for the lots report.
public struct OpenLotLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var acquisitionDate: Date?
    public var quantity: Decimal
    public var costBasis: Decimal
}

/// Realised capital gains over a period plus the lots still open at its end
/// (`FR-RPT-03`). Amounts are in the report currency; multi-currency FX is a
/// higher layer, so figures use each security's own transaction amounts.
public struct CapitalGainsReport: Sendable {
    public var currencyCode: String
    public var method: CostBasisMethod
    public var from: Date
    public var to: Date
    /// By disposal date, oldest first.
    public var lines: [CapitalGainLine]
    public var openLots: [OpenLotLine]
    /// Currencies whose figures could **not** be converted to the report
    /// currency, because the book holds no rate for the pair on the relevant
    /// date. Those disposals and lots are left out of `lines`/`openLots` rather
    /// than added at face value — a foreign number summed as if it were the
    /// report currency is a wrong tax figure that looks right. Non-empty means
    /// the report is incomplete and the UI should say so.
    public var unconvertedCurrencyCodes: [String] = []

    public var shortTermGain: Decimal {
        lines.filter { $0.longTerm == false }.reduce(0) { $0 + $1.gain }
    }
    public var longTermGain: Decimal {
        lines.filter { $0.longTerm == true }.reduce(0) { $0 + $1.gain }
    }
    /// Gains with an undefined holding period (average cost / uncovered sales).
    public var otherGain: Decimal {
        lines.filter { $0.longTerm == nil }.reduce(0) { $0 + $1.gain }
    }
    public var totalGain: Decimal { lines.reduce(0) { $0 + $1.gain } }
    public var totalProceeds: Decimal { lines.reduce(0) { $0 + $1.proceeds } }
    public var totalCostBasis: Decimal { lines.reduce(0) { $0 + $1.costBasis } }
    public var openCostBasis: Decimal { openLots.reduce(0) { $0 + $1.costBasis } }
    /// Every disposal's gain as an annual rate on what the parcels cost, over
    /// the cost-weighted time they were held.
    public var yieldPerAnnum: Double? {
        InvestmentYield.combined(lines.map { ($0.gain, $0.costBasis, $0.heldYears) })
    }
}

public extension FinancialReports {

    /// Realised gains disposed within `[from, to]` and the lots open at `to`,
    /// computed per security account under `method` (`FR-RPT-03`).
    ///
    /// `includeClosed` keeps the disposals of securities sold out of entirely
    /// by `to`; `false` reports only gains on what is still held. `portfolioID`
    /// narrows the report to one portfolio's accounts.
    static func capitalGains(
        _ book: Book,
        currency: Commodity,
        from: Date = .distantPast,
        to: Date = .distantFuture,
        method: CostBasisMethod = .fifo,
        longTermThresholdDays: Int = CostBasis.defaultLongTermThresholdDays,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = true,
        portfolioID: GncGUID? = nil
    ) -> CapitalGainsReport {
        var lines: [CapitalGainLine] = []
        var openLots: [OpenLotLine] = []
        var unconverted: Set<String> = []

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            // Lots are matched in date order, so what happens after `to`
            // cannot change a disposal before it; cutting there is what makes
            // "open lots" the lots open at the period's end, and "closed" a
            // position closed by then.
            let result = book.costBasis(for: account, asOf: to, method: method,
                                        longTermThresholdDays: longTermThresholdDays,
                                        feeTreatment: feeTreatment,
                                        currencyFraction: currency.smallestFraction)
            let closed = result.remainingQuantity == 0
            guard includeClosed || !closed else { continue }
            let symbol = account.commodity.mnemonic
            let portfolio = portfolio(of: account)
            let first = pooledLots(result) ? firstAcquisition(of: account, in: book) : nil

            // Cost-basis amounts are in the security's trade currency; convert
            // each to the report currency (dated at the disposal / acquisition)
            // so the totals aren't a meaningless sum across currencies.
            let trade = book.splits(for: account).lazy.compactMap { $0.transaction?.currency }.first ?? currency
            // `nil` when the book has no rate for the pair on that date. It is
            // returned rather than falling back to the unconverted figure: the
            // fallback silently added, say, USD 10,000 of proceeds into an AUD
            // total, understating the gain by a third on the report people file
            // tax from — the exact "meaningless sum across currencies" the
            // conversion above exists to prevent.
            func toReport(_ amount: Decimal, on date: Date) -> Decimal? {
                guard trade != currency else { return amount }
                return book.convert(amount, from: trade, to: currency, on: date)
            }

            for gain in result.realizedGains where gain.disposalDate >= from && gain.disposalDate <= to {
                guard let rawProceeds = toReport(gain.proceeds, on: gain.disposalDate),
                      let rawCostBasis = toReport(gain.costBasis, on: gain.disposalDate) else {
                    unconverted.insert(trade.mnemonic)
                    continue
                }
                let proceeds = currency.round(rawProceeds)
                let costBasis = currency.round(rawCostBasis)
                let years = (gain.acquisitionDate ?? first).map {
                    InvestmentYield.years(from: $0, to: gain.disposalDate)
                }
                lines.append(CapitalGainLine(
                    id: .random(), accountID: account.guid, symbol: symbol, accountName: account.name,
                    portfolio: portfolio, disposalDate: gain.disposalDate, acquisitionDate: gain.acquisitionDate,
                    quantity: gain.quantity,
                    proceeds: proceeds,
                    costBasis: costBasis,
                    gain: proceeds - costBasis,
                    longTerm: gain.longTerm,
                    positionClosed: closed,
                    heldYears: years,
                    yieldPerAnnum: InvestmentYield.annualised(gain: proceeds - costBasis,
                                                              cost: costBasis, years: years)))
            }

            for lot in result.openLots {
                let on = lot.acquisitionDate ?? to
                guard let costBasis = toReport(lot.costBasis, on: on) else {
                    unconverted.insert(trade.mnemonic)
                    continue
                }
                openLots.append(OpenLotLine(
                    id: .random(), symbol: symbol, accountName: account.name,
                    acquisitionDate: lot.acquisitionDate, quantity: lot.quantity,
                    costBasis: currency.round(costBasis)))
            }
        }

        return CapitalGainsReport(
            currencyCode: currency.mnemonic, method: method, from: from, to: to,
            lines: lines.sorted { $0.disposalDate < $1.disposalDate },
            openLots: openLots.sorted { ($0.acquisitionDate ?? .distantPast) < ($1.acquisitionDate ?? .distantPast) },
            unconvertedCurrencyCodes: unconverted.sorted())
    }
}
