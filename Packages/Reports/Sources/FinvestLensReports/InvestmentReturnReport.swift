//
//  InvestmentReturnReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One security's return over a period: capital gain, dividends and franking
/// credits, and the three together against the money put in (`FR-RPT-02b`).
public struct InvestmentReturnLine: Identifiable, Hashable, Sendable {
    /// The security account.
    public let id: GncGUID
    public var accountName: String
    public var symbol: String
    /// The account above the security's — its portfolio; `nil` at the top of
    /// the tree.
    public var portfolio: PortfolioRef?
    /// Units still held at the period's end; zero for a closed position.
    public var units: Decimal
    /// The cost of every parcel held at any time in the period — what is held
    /// at its end plus what was sold during it (over all time, GnuCash's
    /// "Money In").
    public var moneyIn: Decimal
    /// Realised gain on the disposals in the period, from the lot engine.
    public var realizedGain: Decimal
    /// How far the unrealised gain on what is held moved over the period:
    /// market value less cost at the end, less the same at the start. `nil`
    /// when units are held and a price is missing at either end.
    public var unrealizedGain: Decimal?
    /// Cash income in the period — franked, unfranked, and dividends the
    /// account names did not classify.
    public var dividends: Decimal
    /// Franking (imputation) credits recorded as income against the security
    /// in the period.
    public var frankingCredits: Decimal
    /// How long the money was in, inside the period, cost-weighted across
    /// every parcel (``InvestmentYield``).
    public var heldYears: Double?
    /// Realised plus unrealised.
    public var capitalGain: Decimal { realizedGain + (unrealizedGain ?? 0) }
    /// Capital gain, dividends and franking credits together.
    public var totalReturn: Decimal { capitalGain + dividends + frankingCredits }
    /// ``totalReturn`` over ``moneyIn``; `nil` when nothing was put in.
    public var returnFraction: Double?
    /// ``totalReturn`` as a simple annual rate on ``moneyIn`` over ``heldYears``.
    public var yieldPerAnnum: Double?
    public var isClosed: Bool { units == 0 }
}

/// The Investment Return report: every security's capital gain, dividends and
/// franking credits over a period, and the whole portfolio's (`FR-RPT-02b`).
public struct InvestmentReturnReport: Sendable {
    public var from: Date
    public var to: Date
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
    /// The whole report's return as an annual rate on its money in, over the
    /// cost-weighted time the money was in.
    public var yieldPerAnnum: Double? {
        InvestmentYield.combined(lines.map { ($0.totalReturn, $0.moneyIn, $0.heldYears) })
    }
    /// Held securities with no price at an end of the period: their unrealised
    /// gain is left out, so the report says so.
    public var unpricedSymbols: [String]
    /// Currencies whose income could not be converted to the report currency
    /// for want of a rate on the day — left out rather than added at face
    /// value, as the capital-gains report does.
    public var unconvertedCurrencyCodes: [String]
}

public extension FinancialReports {

    /// Every security's return over `[from, to]`: the lot engine's realised
    /// gain on the period's disposals, the move in the unrealised gain on what
    /// is held, and the income the book records against it in the period.
    /// Over all time (`from` at the distant past) that is the return since the
    /// first purchase; over a financial year, that year's.
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
    /// `includeClosed` keeps positions sold out of by `to` — their realised
    /// gain and income are return too; without them the whole-portfolio figure
    /// is only what is still held. `portfolioID` narrows the report to one
    /// portfolio's accounts.
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
        var totalMoneyIn = Decimal(0), totalRealized = Decimal(0), totalUnrealized = Decimal(0)
        var totalDividends = Decimal(0), totalFranking = Decimal(0)
        // The instant before the period: what was held and what it was worth
        // going in. A period with no start has no "before".
        let bounded = from != .distantPast
        let before = from.addingTimeInterval(-1)

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
                while let current = node, !current.isRoot {
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

        func inPeriod(_ transaction: Transaction) -> Bool {
            transaction.datePosted >= from && transaction.datePosted <= to
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

        /// What the parcels held at `date` are worth over what they cost —
        /// zero when nothing is held, `nil` when something is and no price
        /// is known.
        func marked(_ basis: CostBasisResult, of account: Account, on date: Date) -> Decimal? {
            let units = basis.remainingQuantity
            guard units != 0 else { return 0 }
            guard let price = book.securityUnitValue(account.commodity, in: currency, on: date) else {
                return nil
            }
            return currency.round(units * price) - currency.round(basis.remainingCostBasis)
        }

        for account in securityAccounts(book, inPortfolio: portfolioID) {
            let basis = book.costBasis(for: account, asOf: to, method: method, feeTreatment: feeTreatment,
                                       currencyFraction: currency.smallestFraction)
            let units = basis.remainingQuantity
            // Lots are matched in date order, so the disposals before `to` are
            // the same whatever follows; the period's are those dated in it.
            let disposals = basis.realizedGains.filter { $0.disposalDate >= from && $0.disposalDate <= to }
            let realized = currency.round(disposals.reduce(Decimal(0)) { $0 + $1.gain })
            let moneyIn = currency.round(basis.remainingCostBasis
                                         + disposals.reduce(Decimal(0)) { $0 + $1.costBasis })

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
                guard let transaction = split.transaction, inPeriod(transaction),
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
                    guard let transaction = split.transaction, inPeriod(transaction),
                          counted.insert(transaction.guid).inserted else { continue }
                    for other in transaction.splits
                    where other.account.map({ namedIDs.contains(ObjectIdentifier($0)) }) == true {
                        take(other, in: transaction)
                    }
                }
            }
            dividends = currency.round(dividends)
            franking = currency.round(franking)

            // Going in: the parcels held before the period, and their mark.
            let opening = bounded
                ? book.costBasis(for: account, asOf: before, method: method, feeTreatment: feeTreatment,
                                 currencyFraction: currency.smallestFraction)
                : nil
            let heldBefore = opening.map { $0.remainingQuantity != 0 } ?? false

            // A line for a security with any part in the period: held at its
            // end or its start, sold during it, or paying during it.
            let hasHistory = units != 0 || heldBefore || moneyIn != 0 || realized != 0
                || dividends != 0 || franking != 0
            guard includeClosed ? hasHistory : units != 0 else { continue }

            var unrealized: Decimal?
            let closing = marked(basis, of: account, on: to)
            // Going in: a period with no start, or nothing held before this
            // one, opens at nothing over cost; something held is marked, and
            // held with no price is unknown.
            let openingMark: Decimal?
            if let opening {
                openingMark = marked(opening, of: account, on: before)
            } else {
                openingMark = 0
            }
            if let closing, let openingMark {
                unrealized = closing - openingMark
            } else {
                unpriced.append(account.commodity.mnemonic)
            }

            // How long each parcel's money was in, inside the period: a held
            // lot from its purchase (or the period's start, if it was bought
            // before) to the end; a sold one to its sale. A pooled lot is
            // held from the first purchase.
            let first = pooledLots(basis) ? (firstAcquisition(of: account, in: book) ?? to) : to
            let start = bounded ? from : Date.distantPast
            let parcels = basis.openLots.map {
                HeldParcel(cost: $0.costBasis,
                           years: InvestmentYield.years(from: max($0.acquisitionDate ?? first, start), to: to))
            } + disposals.map {
                HeldParcel(cost: $0.costBasis,
                           years: InvestmentYield.years(from: max($0.acquisitionDate ?? first, start),
                                                        to: $0.disposalDate))
            }
            let heldYears = InvestmentYield.weightedYears(parcels)

            let total = realized + (unrealized ?? 0) + dividends + franking
            let fraction: Double? = moneyIn != 0
                ? NSDecimalNumber(decimal: total).doubleValue / NSDecimalNumber(decimal: moneyIn).doubleValue
                : nil
            lines.append(InvestmentReturnLine(
                id: account.guid, accountName: account.name, symbol: account.commodity.mnemonic,
                portfolio: portfolio(of: account),
                units: units, moneyIn: moneyIn, realizedGain: realized, unrealizedGain: unrealized,
                dividends: dividends, frankingCredits: franking, heldYears: heldYears,
                returnFraction: fraction,
                yieldPerAnnum: InvestmentYield.annualised(gain: total, cost: moneyIn, years: heldYears)))

            totalMoneyIn += moneyIn
            totalRealized += realized
            totalUnrealized += unrealized ?? 0
            totalDividends += dividends
            totalFranking += franking
        }

        return InvestmentReturnReport(
            from: from, to: to, currencyCode: currency.mnemonic, method: method,
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
