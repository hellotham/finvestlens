//
//  InvestmentReturnReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One security's return to date: capital gain, dividends and franking
/// credits, and the three together against the money put in (`FR-RPT-02b`).
public struct InvestmentReturnLine: Identifiable, Hashable, Sendable {
    /// The security account.
    public let id: GncGUID
    public var accountName: String
    public var symbol: String
    /// Units still held; zero for a closed position.
    public var units: Decimal
    /// The cost of every acquisition, held and since sold (GnuCash's "Money In").
    public var moneyIn: Decimal
    /// Realised gain on every disposal, from the lot engine.
    public var realizedGain: Decimal
    /// Market value less cost of what is still held; `nil` when units are held
    /// and no price is known.
    public var unrealizedGain: Decimal?
    /// Cash income — franked, unfranked, and dividends the account names did
    /// not classify.
    public var dividends: Decimal
    /// Franking (imputation) credits recorded as income against the security.
    public var frankingCredits: Decimal
    /// Realised plus unrealised.
    public var capitalGain: Decimal { realizedGain + (unrealizedGain ?? 0) }
    /// Capital gain, dividends and franking credits together.
    public var totalReturn: Decimal { capitalGain + dividends + frankingCredits }
    /// ``totalReturn`` over ``moneyIn``; `nil` when nothing was put in.
    public var returnFraction: Double?
    public var isClosed: Bool { units == 0 }
}

/// The Investment Return report: every security's capital gain, dividends and
/// franking credits to a date, and the whole portfolio's (`FR-RPT-02b`).
public struct InvestmentReturnReport: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var method: CostBasisMethod
    /// By total return, largest first.
    public var lines: [InvestmentReturnLine]
    public var totalMoneyIn: Decimal
    public var totalRealized: Decimal
    public var totalUnrealized: Decimal
    public var totalDividends: Decimal
    public var totalFranking: Decimal
    public var totalCapitalGain: Decimal { totalRealized + totalUnrealized }
    public var totalReturn: Decimal { totalCapitalGain + totalDividends + totalFranking }
    /// ``totalReturn`` over ``totalMoneyIn``; `nil` when nothing was put in.
    public var totalReturnFraction: Double? {
        guard totalMoneyIn != 0 else { return nil }
        return NSDecimalNumber(decimal: totalReturn).doubleValue
            / NSDecimalNumber(decimal: totalMoneyIn).doubleValue
    }
    /// Held securities with no price on the date: their unrealised gain is
    /// left out, so the report says so.
    public var unpricedSymbols: [String]
    /// Currencies whose income could not be converted to the report currency
    /// for want of a rate on the day — left out rather than added at face
    /// value, as the capital-gains report does.
    public var unconvertedCurrencyCodes: [String]
}

public extension FinancialReports {

    /// Every security's return to `asOf`: the lot engine's realised and
    /// unrealised gain, and the income the book records against it.
    ///
    /// Income is attributed to a security two ways, each transaction counted
    /// once. GnuCash's: the income splits of a transaction that touches the
    /// security account — the zero-unit "link" leg its advanced portfolio
    /// relies on (`advanced-portfolio.scm`, `trans-income`). And by name: an
    /// income account that is, or sits under one, named for the security —
    /// its ticker or its account's name — the shape the book's own dividend
    /// transactions use (Dividends ▸ TICKER ▸ Franked / Unfranked / Imputation
    /// Credit), which never touch the holding. An income account named with
    /// "imputation" or "franking" is a credit; every other is a dividend.
    ///
    /// `includeClosed` keeps positions sold out of — their realised gain and
    /// income are return too; without them the whole-portfolio figure is only
    /// what is still held.
    static func investmentReturn(
        _ book: Book,
        currency: Commodity,
        asOf: Date = Date(),
        method: CostBasisMethod = .fifo,
        feeTreatment: FeeTreatment = .ignore,
        includeClosed: Bool = true
    ) -> InvestmentReturnReport {
        var lines: [InvestmentReturnLine] = []
        var unpriced: [String] = []
        var unconverted: Set<String> = []
        var totalMoneyIn = Decimal(0), totalRealized = Decimal(0), totalUnrealized = Decimal(0)
        var totalDividends = Decimal(0), totalFranking = Decimal(0)

        /// The income accounts named for `account`'s security: the account's
        /// own name, its ticker, or the ticker before an exchange suffix
        /// ("BHP.AX" → "BHP"), matched against the account and its ancestors.
        func namedIncomeAccounts(for account: Account) -> [Account] {
            var names: Set<String> = [account.name.lowercased(),
                                      account.commodity.mnemonic.lowercased()]
            if let bare = account.commodity.mnemonic.split(separator: ".").first {
                names.insert(String(bare).lowercased())
            }
            return book.accounts.filter { candidate in
                guard candidate.type == .income, !candidate.isPlaceholder else { return false }
                var node: Account? = candidate
                while let current = node, current !== book.rootAccount {
                    if names.contains(current.name.lowercased()) { return true }
                    node = current.parent
                }
                return false
            }
        }

        func isFrankingCredit(_ incomeAccount: Account) -> Bool {
            let name = incomeAccount.name.lowercased()
            return name.contains("imputation") || name.contains("franking")
        }

        /// `split`'s income, in the report currency — `nil` when the day has
        /// no rate for its currency.
        func incomeAmount(of split: Split, in transaction: Transaction) -> Decimal? {
            let amount = -split.value                     // income splits are credits
            if transaction.currency == currency { return amount }
            if let converted = book.convert(amount, from: transaction.currency,
                                            to: currency, on: transaction.datePosted) {
                return converted
            }
            unconverted.insert(transaction.currency.mnemonic)
            return nil
        }

        for account in book.accounts where account.type.isSecurityType && !account.isPlaceholder {
            let basis = book.costBasis(for: account, asOf: asOf, method: method, feeTreatment: feeTreatment,
                                       currencyFraction: currency.smallestFraction)
            let units = basis.remainingQuantity
            let moneyIn = currency.round(basis.remainingCostBasis + basis.totalCostBasis)
            let realized = currency.round(basis.totalRealizedGain)

            var dividends = Decimal(0), franking = Decimal(0)
            var counted = Set<GncGUID>()
            func take(_ split: Split, in transaction: Transaction) {
                guard let amount = incomeAmount(of: split, in: transaction) else { return }
                if let incomeAccount = split.account, isFrankingCredit(incomeAccount) {
                    franking += amount
                } else {
                    dividends += amount
                }
            }
            // GnuCash's way: a transaction that touches the holding.
            for split in book.splits(for: account) {
                guard let transaction = split.transaction, transaction.datePosted <= asOf,
                      counted.insert(transaction.guid).inserted else { continue }
                for other in transaction.splits where other.account?.type == .income {
                    take(other, in: transaction)
                }
            }
            // By name: the security's own income accounts, for the
            // transactions the holding never saw.
            let named = namedIncomeAccounts(for: account)
            let namedIDs = Set(named.map { ObjectIdentifier($0) })
            for incomeAccount in named {
                for split in book.splits(for: incomeAccount) {
                    guard let transaction = split.transaction, transaction.datePosted <= asOf,
                          counted.insert(transaction.guid).inserted else { continue }
                    for other in transaction.splits
                    where other.account.map({ namedIDs.contains(ObjectIdentifier($0)) }) == true {
                        take(other, in: transaction)
                    }
                }
            }
            dividends = currency.round(dividends)
            franking = currency.round(franking)

            let hasHistory = units != 0 || moneyIn != 0 || realized != 0 || dividends != 0 || franking != 0
            guard includeClosed ? hasHistory : units != 0 else { continue }

            var unrealized: Decimal?
            if units != 0 {
                if let price = book.securityUnitValue(account.commodity, in: currency, on: asOf) {
                    unrealized = currency.round(units * price) - currency.round(basis.remainingCostBasis)
                } else {
                    unpriced.append(account.commodity.mnemonic)
                }
            } else {
                unrealized = 0
            }

            let total = realized + (unrealized ?? 0) + dividends + franking
            let fraction: Double? = moneyIn != 0
                ? NSDecimalNumber(decimal: total).doubleValue / NSDecimalNumber(decimal: moneyIn).doubleValue
                : nil
            lines.append(InvestmentReturnLine(
                id: account.guid, accountName: account.name, symbol: account.commodity.mnemonic,
                units: units, moneyIn: moneyIn, realizedGain: realized, unrealizedGain: unrealized,
                dividends: dividends, frankingCredits: franking, returnFraction: fraction))

            totalMoneyIn += moneyIn
            totalRealized += realized
            totalUnrealized += unrealized ?? 0
            totalDividends += dividends
            totalFranking += franking
        }

        return InvestmentReturnReport(
            asOf: asOf, currencyCode: currency.mnemonic, method: method,
            lines: lines.sorted { $0.totalReturn > $1.totalReturn },
            totalMoneyIn: currency.round(totalMoneyIn),
            totalRealized: currency.round(totalRealized),
            totalUnrealized: currency.round(totalUnrealized),
            totalDividends: currency.round(totalDividends),
            totalFranking: currency.round(totalFranking),
            unpricedSymbols: unpriced.sorted(),
            unconvertedCurrencyCodes: unconverted.sorted())
    }
}
