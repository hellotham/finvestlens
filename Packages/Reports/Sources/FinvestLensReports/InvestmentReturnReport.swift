//
//  InvestmentReturnReport.swift
//  FinvestLens — Reports
//
//  Total return means total return: everything a holding has earned since it
//  was first bought — realised and unrealised gain, dividends and franking
//  credits — to the report date, with the history that produced it. A figure
//  measured only inside a period is a different thing, and is kept apart as
//  the period's contribution. (Build 10 printed the period figure under the
//  total's name; the owner's words: "Simply calculating based on filtered
//  period is wrong - that is not total return.")
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One security's return since its first purchase, to the report date.
public struct InvestmentReturnLine: Identifiable, Hashable, Sendable {
    /// The security account.
    public let id: GncGUID
    public var accountName: String
    public var symbol: String
    public var portfolio: PortfolioRef?
    /// Everything that happened to the holding, to the report date.
    public var history: InvestmentHistory
    /// The cost of every purchase (GnuCash's "Money In").
    public var moneyIn: Decimal
    /// The proceeds of every sale (GnuCash's "Money Out").
    public var moneyOut: Decimal
    public var realizedGain: Decimal
    /// Market value less cost of what is held at the report date; 0 when
    /// nothing is held; `nil` when held and unpriced.
    public var unrealizedGain: Decimal?
    /// Cash income: dividends, distributions, interest.
    public var dividends: Decimal
    public var frankingCredits: Decimal
    /// Realised plus unrealised.
    public var capitalGain: Decimal { realizedGain + (unrealizedGain ?? 0) }
    /// Capital gain, dividends and franking credits together — GnuCash's
    /// Total Return (total gain plus income), with the credits the book
    /// records against the security.
    public var totalReturn: Decimal { capitalGain + dividends + frankingCredits }
    /// ``totalReturn`` over ``moneyIn`` — GnuCash's Rate of Return, a simple
    /// ratio; `nil` when nothing was put in.
    public var returnOnMoneyIn: Double?
    /// The money-weighted annual rate: the internal rate of return of the
    /// holding's dated cash flows with its value at the report date as the
    /// last (Excel's XIRR; Sharesight's method). `nil` under a year of
    /// holding — a return for less than a year is not annualised (GIPS) —
    /// or when a held position has no price.
    public var annualisedReturn: Double?
    public var firstAcquisition: Date?
    /// Years from the first purchase to the report date (or the last sale
    /// of a closed position).
    public var heldYears: Double?
    /// The period's contribution to the total: the total return at the
    /// period's end less the total return the day before it began. `nil`
    /// when the period has no start, or either end is unpriced.
    public var periodReturn: Decimal?
    public var unitsHeld: Decimal
    public var isClosed: Bool { unitsHeld == 0 }
    /// Held, but no price at the report date: the unrealised gain and the
    /// annualised rate are missing, and the report names the security.
    public var isUnpriced: Bool
}

/// The Investment Return report: every security's total return to a date,
/// and the whole portfolio's (`FR-RPT-02b`).
public struct InvestmentReturnReport: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    public var method: CostBasisMethod
    public var feeTreatment: FeeTreatment
    /// By total return, largest first.
    public var lines: [InvestmentReturnLine]
    public var totalMoneyIn: Decimal
    public var totalMoneyOut: Decimal
    public var totalRealized: Decimal
    public var totalUnrealized: Decimal
    public var totalDividends: Decimal
    public var totalFranking: Decimal
    public var totalCapitalGain: Decimal { totalRealized + totalUnrealized }
    public var totalReturn: Decimal { totalCapitalGain + totalDividends + totalFranking }
    /// The period's contribution across every line that has one.
    public var totalPeriodReturn: Decimal?
    public var totalReturnFraction: Double? {
        guard totalMoneyIn != 0 else { return nil }
        return InvestmentYield.double(totalReturn) / InvestmentYield.double(totalMoneyIn)
    }
    /// The money-weighted annual rate of the whole report's cash flows.
    public var annualisedReturn: Double?
    public var unpricedSymbols: [String]
    public var unconvertedCurrencyCodes: [String]
}

public extension FinancialReports {

    /// The seconds before `date` — the instant a period's "before" is read
    /// at, and the instant before 1 July 2027 the CGT reform values an asset
    /// at.
    static func instantBefore(_ date: Date) -> Date { date.addingTimeInterval(-1) }

    /// Every security's total return to `to`, from the shared history
    /// (``investmentHistory(_:account:currency:to:method:feeTreatment:)``).
    /// `from` bounds nothing in the totals — it only gives the period's
    /// contribution — so the figures are the same whatever period is chosen
    /// with the same end. `includeClosed` keeps positions sold out of by
    /// `to`; `portfolioID` narrows the report to one portfolio.
    static func investmentReturn(
        _ book: Book,
        currency: Commodity,
        from: Date = .distantPast,
        to: Date = Date(),
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = true,
        portfolioID: GncGUID? = nil
    ) -> InvestmentReturnReport {
        var lines: [InvestmentReturnLine] = []
        var unpriced: [String] = []
        var unconverted: Set<String> = []
        var allFlows: [DatedCashFlow] = []
        var flowsComplete = true
        let bounded = from != .distantPast
        let before = instantBefore(from)

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            let history = investmentHistory(book, account: account, currency: currency, to: to,
                                            method: method, feeTreatment: feeTreatment)
            guard !history.events.isEmpty else { continue }
            guard includeClosed || !history.isClosed else { continue }
            unconverted.formUnion(history.unconvertedCurrencyCodes)
            let isUnpriced = history.unitsHeld != 0 && history.marketValue == nil
            if isUnpriced { unpriced.append(history.symbol) }

            // The holding's span: from its first purchase to the report
            // date, or to its last sale once it is closed.
            let end = history.isClosed ? (history.events.last { $0.kind == .sell }?.date ?? to) : to
            let heldYears = history.firstAcquisition.map { InvestmentYield.years(from: $0, to: end) }
            var annualised: Double?
            if let flows = history.cashFlows(valuedAt: to) {
                let dated = flows.map { DatedCashFlow(date: $0.date, amount: $0.amount) }
                allFlows.append(contentsOf: dated)
                if let first = history.firstAcquisition, InvestmentYield.isAnnualisable(from: first, to: end) {
                    annualised = MoneyWeightedReturn.rate(of: dated)
                }
            } else {
                flowsComplete = false
            }

            var periodReturn: Decimal?
            if bounded {
                // Nothing before the period: the whole total is the period's.
                if let first = history.events.first?.date, first >= from {
                    periodReturn = history.unrealizedGain == nil ? nil : history.totalReturn
                } else {
                    let opening = investmentHistory(book, account: account, currency: currency, to: before,
                                                    method: method, feeTreatment: feeTreatment)
                    if let closing = history.unrealizedGain, opening.unrealizedGain != nil {
                        _ = closing
                        periodReturn = history.totalReturn - opening.totalReturn
                    }
                }
            }

            lines.append(InvestmentReturnLine(
                id: account.guid, accountName: account.name, symbol: history.symbol,
                portfolio: history.portfolio, history: history,
                moneyIn: history.moneyIn, moneyOut: history.moneyOut,
                realizedGain: currency.round(history.realizedGain),
                unrealizedGain: history.unrealizedGain.map { currency.round($0) },
                dividends: currency.round(history.dividends),
                frankingCredits: currency.round(history.frankingCredits),
                returnOnMoneyIn: history.returnOnMoneyIn,
                annualisedReturn: annualised,
                firstAcquisition: history.firstAcquisition, heldYears: heldYears,
                periodReturn: periodReturn.map { currency.round($0) },
                unitsHeld: history.unitsHeld, isUnpriced: isUnpriced))
        }

        let sorted = lines.sorted { $0.totalReturn > $1.totalReturn }
        let periodTotal: Decimal? = bounded && sorted.contains { $0.periodReturn != nil }
            ? sorted.reduce(Decimal(0)) { $0 + ($1.periodReturn ?? 0) } : nil
        // The report's own rate: every holding's flows together, valued at
        // the report date — annualised only once the portfolio is a year old.
        var reportRate: Double?
        if flowsComplete, let first = allFlows.map(\.date).min(),
           InvestmentYield.isAnnualisable(from: first, to: to) {
            reportRate = MoneyWeightedReturn.rate(of: allFlows)
        }
        return InvestmentReturnReport(
            from: from, to: to, currencyCode: currency.mnemonic, method: method, feeTreatment: feeTreatment,
            lines: sorted,
            totalMoneyIn: currency.round(sorted.reduce(0) { $0 + $1.moneyIn }),
            totalMoneyOut: currency.round(sorted.reduce(0) { $0 + $1.moneyOut }),
            totalRealized: currency.round(sorted.reduce(0) { $0 + $1.realizedGain }),
            totalUnrealized: currency.round(sorted.reduce(0) { $0 + ($1.unrealizedGain ?? 0) }),
            totalDividends: currency.round(sorted.reduce(0) { $0 + $1.dividends }),
            totalFranking: currency.round(sorted.reduce(0) { $0 + $1.frankingCredits }),
            totalPeriodReturn: periodTotal.map { currency.round($0) },
            annualisedReturn: reportRate,
            unpricedSymbols: unpriced.sorted(),
            unconvertedCurrencyCodes: unconverted.sorted())
    }
}
