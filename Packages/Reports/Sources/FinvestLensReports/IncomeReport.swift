//
//  IncomeReport.swift
//  FinvestLens — Reports
//
//  Investment income over a period, the way a tax return asks for it: each
//  payment, and each holding's franked and unfranked dividends, franking
//  credits, distributions and interest — Sharesight's Taxable Income report
//  and InvestaLens's, read from the shared history so the figures are the
//  ones Investment Return and the review decks use.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One payment, as the book recorded it.
public struct IncomePayment: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var date: Date
    public var symbol: String
    public var kind: InvestmentEvent.Kind
    public var amount: Decimal
    public var description: String
    /// Recorded in another currency than the report's — foreign income.
    public var isForeign: Bool
}

/// One holding's income over the period.
public struct IncomeLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var accountName: String
    public var portfolio: PortfolioRef?
    public var franked: Decimal
    public var unfranked: Decimal
    public var frankingCredits: Decimal
    public var distributions: Decimal
    public var interest: Decimal
    /// Income the account names did not classify.
    public var other: Decimal
    /// The part of the cash income recorded in another currency.
    public var foreign: Decimal
    public var payments: [IncomePayment]

    /// Cash received.
    public var cash: Decimal { franked + unfranked + distributions + interest + other }
    /// Cash plus the credits — the grossed-up figure assessed.
    public var grossedUp: Decimal { cash + frankingCredits }
}

/// The Income report over a period.
public struct IncomeReport: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    /// By cash received, largest first.
    public var lines: [IncomeLine]
    public var totalFranked: Decimal
    public var totalUnfranked: Decimal
    public var totalFrankingCredits: Decimal
    public var totalDistributions: Decimal
    public var totalInterest: Decimal
    public var totalOther: Decimal
    public var totalForeign: Decimal
    public var totalCash: Decimal { totalFranked + totalUnfranked + totalDistributions + totalInterest + totalOther }
    public var totalGrossedUp: Decimal { totalCash + totalFrankingCredits }
    public var unconvertedCurrencyCodes: [String]
}

public extension FinancialReports {

    /// Every holding's income dated in `[from, to]`, by the shared
    /// attribution (`FR-RPT-02b`). `portfolioID` narrows the report.
    static func incomeReport(
        _ book: Book,
        currency: Commodity,
        from: Date,
        to: Date,
        portfolioID: GncGUID? = nil
    ) -> IncomeReport {
        var lines: [IncomeLine] = []
        var unconverted: Set<String> = []
        for history in investmentHistories(book, currency: currency, to: to, portfolioID: portfolioID) {
            let payments = history.events.filter { $0.kind.isIncome && $0.date >= from && $0.date <= to }
            guard !payments.isEmpty else { continue }
            unconverted.formUnion(history.unconvertedCurrencyCodes)
            var line = IncomeLine(id: history.id, symbol: history.symbol, accountName: history.accountName,
                                  portfolio: history.portfolio, franked: 0, unfranked: 0, frankingCredits: 0,
                                  distributions: 0, interest: 0, other: 0, foreign: 0, payments: [])
            for event in payments {
                let foreign = event.currencyCode != currency.mnemonic
                switch event.kind {
                case .dividendFranked: line.franked += event.amount
                case .dividendUnfranked: line.unfranked += event.amount
                case .frankingCredit: line.frankingCredits += event.amount
                case .distribution: line.distributions += event.amount
                case .interest: line.interest += event.amount
                default: line.other += event.amount
                }
                if foreign, event.kind.isCashIncome { line.foreign += event.amount }
                line.payments.append(IncomePayment(id: event.id, date: event.date, symbol: history.symbol,
                                                   kind: event.kind, amount: event.amount,
                                                   description: event.description, isForeign: foreign))
            }
            line.franked = currency.round(line.franked)
            line.unfranked = currency.round(line.unfranked)
            line.frankingCredits = currency.round(line.frankingCredits)
            line.distributions = currency.round(line.distributions)
            line.interest = currency.round(line.interest)
            line.other = currency.round(line.other)
            line.foreign = currency.round(line.foreign)
            lines.append(line)
        }
        let sorted = lines.sorted { $0.cash > $1.cash }
        return IncomeReport(
            from: from, to: to, currencyCode: currency.mnemonic, lines: sorted,
            totalFranked: sorted.reduce(0) { $0 + $1.franked },
            totalUnfranked: sorted.reduce(0) { $0 + $1.unfranked },
            totalFrankingCredits: sorted.reduce(0) { $0 + $1.frankingCredits },
            totalDistributions: sorted.reduce(0) { $0 + $1.distributions },
            totalInterest: sorted.reduce(0) { $0 + $1.interest },
            totalOther: sorted.reduce(0) { $0 + $1.other },
            totalForeign: sorted.reduce(0) { $0 + $1.foreign },
            unconvertedCurrencyCodes: unconverted.sorted())
    }
}
