//
//  InvestmentHistory.swift
//  FinvestLens — Reports
//
//  One dated history per security account, in the report currency, that
//  every investment report reads from: each purchase, each parcel sold with
//  the realised gain the lot engine struck on it, each dividend, franking
//  credit, distribution or interest payment, each return of capital and each
//  split. The reports used to walk the book four different ways — Capital
//  Gains converted currencies and the others did not, Portfolio counted
//  income by one rule and Investment Return by another — so the same holding
//  showed different figures depending on which report was open (consistency
//  audit, 25 Oct 2026, items 6 and 7). Now there is one walk, and a report is
//  a presentation of it.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One thing that happened to a holding, as money in the report currency.
public struct InvestmentEvent: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case buy, sell, dividendFranked, dividendUnfranked, frankingCredit,
             distribution, interest, otherIncome, returnOfCapital, split

        /// Money the holding paid out, other than by being sold.
        public var isIncome: Bool {
            switch self {
            case .dividendFranked, .dividendUnfranked, .frankingCredit, .distribution,
                 .interest, .otherIncome: true
            default: false
            }
        }
        /// Income that arrived as cash. A franking credit is a tax credit the
        /// book records as income against an offset expense; it is part of the
        /// return but never of a cash flow.
        public var isCashIncome: Bool { isIncome && self != .frankingCredit }
    }

    public let id: GncGUID
    public let date: Date
    public let kind: Kind
    /// The transaction's description.
    public let description: String
    /// Units bought or sold, or added by a split (negative for a reverse
    /// split); `nil` for income and returns of capital.
    public let units: Decimal?
    /// A purchase's cost (with its fee under include-in-basis), a sale's
    /// proceeds, an income payment, or the capital returned — all positive,
    /// in the report currency; 0 when ``converted`` is false.
    public let amount: Decimal
    /// Brokerage on a trade, for the record.
    public let fee: Decimal
    /// For a parcel sold: when it was acquired (`nil` under average cost).
    public let acquisitionDate: Date?
    /// For a parcel sold: its cost basis, in the report currency.
    public let costBasis: Decimal?
    /// For a parcel sold: proceeds less cost basis.
    public let realizedGain: Decimal?
    /// For a parcel sold: the lot engine's term flag (held at least the
    /// long-term threshold); `nil` when undefined.
    public let longTerm: Bool?
    /// Whether the amount could be converted to the report currency; when
    /// not, it is left out rather than added at face value, and the report
    /// says so (the capital-gains rule, applied to every event).
    public let converted: Bool
    /// The currency the event was recorded in — foreign income is income in
    /// another currency.
    public let currencyCode: String

    /// The sign the event carries in a cash-flow series: money out for a
    /// purchase, in for a sale, cash income and a return of capital.
    public var cashFlow: Decimal? {
        switch kind {
        case .buy: -amount
        case .sell, .returnOfCapital: amount
        case .split, .frankingCredit: nil
        default: kind.isCashIncome ? amount : nil
        }
    }
}

/// A parcel still held at the report date, at its cost in the report
/// currency — what the lot engine left open, converted on the day it was
/// bought.
public struct InvestmentParcel: Hashable, Sendable {
    /// `nil` for a pooled (average-cost) lot.
    public let acquisitionDate: Date?
    public let quantity: Decimal
    public let costBasis: Decimal
    /// Whether the cost could be converted to the report currency; when not,
    /// ``costBasis`` is 0 and the history names the currency.
    public let converted: Bool
}

/// A security account's whole history to a date, with what it adds up to.
public struct InvestmentHistory: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public let accountName: String
    public let symbol: String
    public let portfolio: PortfolioRef?
    /// The currency the account's trades are recorded in.
    public let tradeCurrencyCode: String
    public let currencyCode: String
    /// To the report date, ascending.
    public let events: [InvestmentEvent]
    /// Units held at the report date.
    public let unitsHeld: Decimal
    /// The cost basis of what is held, in the report currency.
    public let remainingCostBasis: Decimal
    /// What is held, parcel by parcel — the lot engine's open lots, so no
    /// report has to run it a second time.
    public let openParcels: [InvestmentParcel]
    /// The price of one unit at the report date in the report currency, and
    /// what the holding is worth — `nil` when units are held and no price
    /// is known.
    public let price: Decimal?
    public let marketValue: Decimal?
    /// When the first parcel was bought.
    public let firstAcquisition: Date?
    /// Currencies an event could not be converted from.
    public let unconvertedCurrencyCodes: [String]

    public var moneyIn: Decimal { sum(.buy) }
    public var moneyOut: Decimal { sum(.sell) }
    public var realizedGain: Decimal { events.reduce(0) { $0 + ($1.realizedGain ?? 0) } }
    /// Market value less cost of what is held; 0 for nothing held; `nil`
    /// when held and unpriced.
    public var unrealizedGain: Decimal? {
        guard unitsHeld != 0 else { return 0 }
        return marketValue.map { $0 - remainingCostBasis }
    }
    /// Cash income: dividends, distributions, interest and the unclassified.
    public var dividends: Decimal { events.filter { $0.kind.isCashIncome }.reduce(0) { $0 + $1.amount } }
    public var frankingCredits: Decimal { sum(.frankingCredit) }
    public var returnOfCapital: Decimal { sum(.returnOfCapital) }
    /// GnuCash's total return — total gain plus income — with the franking
    /// credits the book records: realised plus unrealised gain, dividends and
    /// credits. Unrealised counts as 0 when unpriced; the report says so.
    public var totalReturn: Decimal { realizedGain + (unrealizedGain ?? 0) + dividends + frankingCredits }
    /// ``totalReturn`` over ``moneyIn`` — GnuCash's rate of return, a simple
    /// ratio; `nil` when nothing was put in.
    public var returnOnMoneyIn: Double? {
        guard moneyIn != 0 else { return nil }
        return InvestmentYield.double(totalReturn) / InvestmentYield.double(moneyIn)
    }
    public var isClosed: Bool { unitsHeld == 0 }

    /// The dated cash flows of the holding to `date`, with what it is worth
    /// then as a final inflow — the series the money-weighted rate is the
    /// internal rate of return of. `nil` when a held position has no price.
    public func cashFlows(valuedAt date: Date) -> [(date: Date, amount: Decimal)]? {
        var flows = events.compactMap { event in event.cashFlow.map { (date: event.date, amount: $0) } }
        if unitsHeld != 0 {
            guard let marketValue else { return nil }
            flows.append((date: date, amount: marketValue))
        }
        return flows
    }

    private func sum(_ kind: InvestmentEvent.Kind) -> Decimal {
        events.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount }
    }
}

public extension FinancialReports {

    /// `account`'s history to `to`.
    static func investmentHistory(
        _ book: Book,
        account: Account,
        currency: Commodity,
        to: Date = .distantFuture,
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore
    ) -> InvestmentHistory {
        var events: [InvestmentEvent] = []
        var unconverted: Set<String> = []
        let includeFees = feeTreatment == .includeInBasis

        // The lot engine sums a security's trades in one currency — the
        // account's trade currency, which its first trade names — so every
        // figure it strikes is converted from that currency on its own date.
        let splits = book.splits(for: account)
        let trade = splits.lazy.compactMap { $0.transaction?.currency }.first ?? currency
        func toReport(_ amount: Decimal, in from: Commodity, on date: Date) -> (Decimal, Bool) {
            guard from != currency else { return (amount, true) }
            if let converted = book.convert(amount, from: from, to: currency, on: date) {
                return (converted, true)
            }
            unconverted.insert(from.mnemonic)
            return (0, false)
        }
        // The transaction behind a lot event: the split on that day with the
        // event's own quantity, else the first on the day with its sign (a
        // sale's parcels sum to the split, so a parcel matches by sign).
        func describe(_ date: Date, quantity: Decimal?, selling: Bool) -> String {
            let onDay = splits.filter { split in
                guard let transaction = split.transaction, transaction.datePosted == date else { return false }
                return selling ? split.quantity < 0 : split.quantity > 0
            }
            let exact = quantity.flatMap { wanted in onDay.first { $0.quantity.magnitude == wanted.magnitude } }
            return (exact ?? onDay.first)?.transaction?.transactionDescription ?? ""
        }

        // Purchases, splits and returns of capital, from the same events the
        // lot engine reads.
        for lotEvent in book.lotEvents(for: account, asOf: to) {
            if lotEvent.isSplit {
                events.append(InvestmentEvent(
                    id: .random(), date: lotEvent.date, kind: .split,
                    description: describe(lotEvent.date, quantity: lotEvent.quantity, selling: false),
                    units: lotEvent.quantity, amount: 0, fee: 0, acquisitionDate: nil,
                    costBasis: nil, realizedGain: nil, longTerm: nil, converted: true,
                    currencyCode: trade.mnemonic))
            } else if lotEvent.isReturnOfCapital {
                let (amount, converted) = toReport(-lotEvent.value, in: trade, on: lotEvent.date)
                events.append(InvestmentEvent(
                    id: .random(), date: lotEvent.date, kind: .returnOfCapital,
                    description: describe(lotEvent.date, quantity: nil, selling: false),
                    units: nil, amount: amount, fee: 0, acquisitionDate: nil,
                    costBasis: nil, realizedGain: nil, longTerm: nil, converted: converted,
                    currencyCode: trade.mnemonic))
            } else if lotEvent.quantity > 0 {
                let cost = lotEvent.value + (includeFees ? lotEvent.fee : 0)
                let (amount, converted) = toReport(cost, in: trade, on: lotEvent.date)
                let (fee, _) = toReport(lotEvent.fee, in: trade, on: lotEvent.date)
                events.append(InvestmentEvent(
                    id: .random(), date: lotEvent.date, kind: .buy,
                    description: describe(lotEvent.date, quantity: lotEvent.quantity, selling: false),
                    units: lotEvent.quantity, amount: amount, fee: fee, acquisitionDate: nil,
                    costBasis: nil, realizedGain: nil, longTerm: nil, converted: converted,
                    currencyCode: trade.mnemonic))
            }
        }

        // Parcels sold: one event per parcel the lot engine matched, carrying
        // the parcel's acquisition date and cost — the capital-gains view of
        // a sale, which a tax return wants per parcel.
        let basis = book.costBasis(for: account, asOf: to, method: method, feeTreatment: feeTreatment,
                                   currencyFraction: currency.smallestFraction)
        for gain in basis.realizedGains {
            let (proceeds, proceedsConverted) = toReport(gain.proceeds, in: trade, on: gain.disposalDate)
            let (cost, costConverted) = toReport(gain.costBasis, in: trade, on: gain.disposalDate)
            let converted = proceedsConverted && costConverted
            events.append(InvestmentEvent(
                id: .random(), date: gain.disposalDate, kind: .sell,
                description: describe(gain.disposalDate, quantity: gain.quantity, selling: true),
                units: gain.quantity, amount: converted ? proceeds : 0, fee: 0,
                acquisitionDate: gain.acquisitionDate,
                costBasis: converted ? cost : nil,
                realizedGain: converted ? proceeds - cost : nil,
                longTerm: gain.longTerm, converted: converted, currencyCode: trade.mnemonic))
        }

        // Income, attributed two ways and each transaction counted once
        // (FR-RPT-02b): GnuCash's — the income legs of a transaction that
        // touches the holding — and by name, an income account that is, or
        // sits under one, named for the security.
        var counted = Set<GncGUID>()
        func takeIncome(_ split: Split, in transaction: Transaction) {
            guard let incomeAccount = split.account else { return }
            let (amount, converted) = toReport(-split.value, in: transaction.currency, on: transaction.datePosted)
            events.append(InvestmentEvent(
                id: .random(), date: transaction.datePosted, kind: incomeKind(of: incomeAccount),
                description: transaction.transactionDescription, units: nil, amount: amount, fee: 0,
                acquisitionDate: nil, costBasis: nil, realizedGain: nil, longTerm: nil,
                converted: converted, currencyCode: transaction.currency.mnemonic))
        }
        for split in splits {
            guard let transaction = split.transaction, transaction.datePosted <= to,
                  split.reconcileState != .voided,
                  counted.insert(transaction.guid).inserted else { continue }
            for other in transaction.splits where other.account?.type == .income && other.reconcileState != .voided {
                takeIncome(other, in: transaction)
            }
        }
        let named = namedIncomeAccounts(for: account, in: book)
        let namedIDs = Set(named.map { ObjectIdentifier($0) })
        for incomeAccount in named {
            for split in book.splits(for: incomeAccount) {
                guard let transaction = split.transaction, transaction.datePosted <= to,
                      split.reconcileState != .voided,
                      counted.insert(transaction.guid).inserted else { continue }
                for other in transaction.splits
                where other.reconcileState != .voided
                    && other.account.map({ namedIDs.contains(ObjectIdentifier($0)) }) == true {
                    takeIncome(other, in: transaction)
                }
            }
        }

        events.sort { lhs, rhs in
            lhs.date != rhs.date ? lhs.date < rhs.date : order(lhs.kind) < order(rhs.kind)
        }

        // What is held, at its cost converted on the day each parcel was
        // bought, and its worth at the report date.
        var remainingCost = Decimal(0)
        var parcels: [InvestmentParcel] = []
        for lot in basis.openLots {
            let (cost, converted) = toReport(lot.costBasis, in: trade, on: lot.acquisitionDate ?? to)
            remainingCost += cost
            parcels.append(InvestmentParcel(acquisitionDate: lot.acquisitionDate, quantity: lot.quantity,
                                            costBasis: cost, converted: converted))
        }
        let units = basis.remainingQuantity
        let price = units != 0 ? book.securityUnitValue(account.commodity, in: currency, on: to) : nil
        return InvestmentHistory(
            id: account.guid, accountName: account.name, symbol: account.commodity.mnemonic,
            portfolio: portfolio(of: account), tradeCurrencyCode: trade.mnemonic,
            currencyCode: currency.mnemonic, events: events, unitsHeld: units,
            remainingCostBasis: currency.round(remainingCost), openParcels: parcels, price: price,
            marketValue: price.map { currency.round(units * $0) },
            firstAcquisition: events.first { $0.kind == .buy }?.date,
            unconvertedCurrencyCodes: unconverted.sorted())
    }

    /// The histories of every security account a report covers — all of
    /// them, or one portfolio's.
    static func investmentHistories(
        _ book: Book, currency: Commodity, to: Date = .distantFuture,
        method: CostBasisMethod = .fifo, feeTreatment: FeeTreatment = .ignore,
        portfolioID: GncGUID? = nil
    ) -> [InvestmentHistory] {
        securityAccounts(book, inPortfolio: portfolioID).map {
            investmentHistory(book, account: $0, currency: currency, to: to,
                              method: method, feeTreatment: feeTreatment)
        }
    }

    /// What an income account's name says the payment is — the shape the
    /// book's own dividend transactions use (Dividends ▸ TICKER ▸ Franked /
    /// Unfranked / Imputation Credit), with distributions and interest told
    /// apart for the Income report.
    static func incomeKind(of account: Account) -> InvestmentEvent.Kind {
        var node: Account? = account
        var names: [String] = []
        while let current = node, !current.isRoot {
            names.append(current.name.lowercased())
            node = current.parent
        }
        // The leaf says what kind of dividend it is; a parent says what the
        // tree holds (Distributions ▸ VAS, Interest ▸ Bonds).
        let own = names.first ?? ""
        if own.contains("imputation") || own.contains("franking") { return .frankingCredit }
        if own.contains("unfranked") { return .dividendUnfranked }
        if own.contains("frank") { return .dividendFranked }
        if names.contains(where: { $0.contains("interest") }) { return .interest }
        if names.contains(where: { $0.contains("distribution") }) { return .distribution }
        if names.contains(where: { $0.contains("dividend") }) { return .dividendUnfranked }
        return .otherIncome
    }

    /// The income accounts named for `account`'s security: the account's own
    /// name, its ticker, or the ticker before an exchange suffix ("BHP.AX" →
    /// "BHP"), matched against the account and its ancestors.
    static func namedIncomeAccounts(for account: Account, in book: Book) -> [Account] {
        var names: Set<String> = [account.name.lowercased(), account.commodity.mnemonic.lowercased()]
        if let bare = account.commodity.mnemonic.split(separator: ".").first {
            names.insert(String(bare).lowercased())
        }
        return book.accounts.filter { candidate in
            guard candidate.type == .income, !candidate.isPlaceholder else { return false }
            var node: Account? = candidate
            while let current = node, !current.isRoot {
                if names.contains(current.name.lowercased()) { return true }
                node = current.parent
            }
            return false
        }
    }

    /// Events on one day read in the order money moves: a purchase before a
    /// sale, income after.
    private static func order(_ kind: InvestmentEvent.Kind) -> Int {
        switch kind {
        case .split: 0
        case .buy: 1
        case .sell: 2
        case .returnOfCapital: 3
        default: 4
        }
    }
}
