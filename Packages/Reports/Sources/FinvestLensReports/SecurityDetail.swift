//
//  SecurityDetail.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

// Phase I3 of the Investments hub (docs/investments-design.md §7): everything
// about **one** security, assembled once.
//
// The page draws eight sections and they share their inputs — the price series
// feeds both the chart and the price table, the movements feed both the chart's
// buy/sell markers and the activity list, and the holding periods feed the
// shading and the gap hatching. Computing them per section would walk the price
// database eight times; the reference book holds ~150k prices.

/// One recorded price, with its provenance (`FR-INV-27`).
///
/// `source` is carried because the detail page is the only place the price
/// table exists, and a price you cannot attribute is a price you cannot judge:
/// on the reference book 68% of rows were hand-entered and nothing on screen
/// ever said so.
public struct SecurityPriceRow: Identifiable, Hashable, Sendable {
    public var id: GncGUID
    public var date: Date
    public var value: Decimal
    public var currencyCode: String
    public var source: String

    public init(id: GncGUID, date: Date, value: Decimal, currencyCode: String, source: String) {
        self.id = id
        self.date = date
        self.value = value
        self.currencyCode = currencyCode
        self.source = source
    }

    /// Whether a provider supplied this row, as opposed to a person typing it.
    ///
    /// GnuCash writes `Finance::Quote` for anything its own fetcher produced
    /// and `user:…` for everything else; this app follows that convention, so
    /// the same test reads a book from either.
    public var isFromProvider: Bool { source.hasPrefix("Finance::Quote") }
}

/// A movement in the book drawn on the price chart and listed under activity
/// (`FR-INV-16`).
///
/// The unfair advantage the whole page is built around: anyone can show a price
/// chart, only this app can draw *your* buys and sells on it.
public struct SecurityEvent: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Units in.
        case buy
        /// Units out.
        case sell
        /// Cash in with no unit movement — a dividend or distribution.
        case income
    }

    /// The transaction's GUID paired with the account's, because one
    /// transaction can move the same commodity in two accounts and a duplicate
    /// identity makes `ForEach` drop a row.
    public var id: String
    public var kind: Kind
    public var date: Date
    /// Signed unit movement — positive for a buy, negative for a sell, zero for
    /// income.
    public var units: Decimal
    /// Cash value of the movement, always positive.
    public var amount: Decimal
    /// `amount ÷ |units|`, or `nil` for income and for unit movements with no
    /// cash leg (a transfer in specie, a stock dividend).
    public var unitPrice: Decimal?
    public var accountName: String
    public var eventDescription: String
}

/// One security's whole story (`FR-INV-15`).
public struct SecurityDetail: Sendable {
    public var commodity: Commodity
    public var currencyCode: String
    public var asOf: Date

    // Header
    /// Units held now.
    public var units: Decimal
    /// The latest recorded price, and when.
    public var latestPrice: Decimal?
    public var latestPriceDate: Date?
    /// The price before that, so the header can show a change. Taken from the
    /// previous *priced day*, not "yesterday": on a Monday the comparison a
    /// person means is Friday's close, and on a thin security it is whenever it
    /// last printed.
    public var previousPrice: Decimal?
    public var previousPriceDate: Date?
    public var marketValue: Decimal?
    public var allocation: Double?
    public var averageCost: Decimal?

    // Performance
    public var costBasis: Decimal
    public var unrealizedGain: Decimal?
    public var realizedGain: Decimal
    public var income: Decimal
    /// Total return since holding — unrealised + realised + income ÷ money in.
    public var returnFraction: Double?
    /// Income ÷ cost basis: what the holding yields on what you paid for it,
    /// which is the only yield figure that is about *your* position rather than
    /// about today's buyer.
    public var yieldOnCost: Double?

    // The chart and the tables
    /// Every recorded price, oldest first.
    public var prices: [SecurityPriceRow]
    /// Buys, sells and income, oldest first.
    public var events: [SecurityEvent]
    /// Periods the security was actually held, for the chart's shading.
    public var holdingPeriods: [HoldingPeriod]
    /// Open tax lots.
    public var lots: [LotDetail]
    /// How many prices came from where, for the provenance line.
    public var sources: [String: Int]
    /// Accounts this commodity is held in.
    public var accountNames: [String]

    /// Whether anything is known about this security beyond its existence.
    public var isEmpty: Bool { prices.isEmpty && events.isEmpty }

    /// The change from ``previousPrice`` to ``latestPrice`` as a fraction.
    public var priceChangeFraction: Double? {
        guard let latest = latestPrice, let previous = previousPrice, previous != 0 else { return nil }
        return NSDecimalNumber(decimal: (latest - previous) / previous).doubleValue
    }
}

public extension FinancialReports {

    /// Assembles the security detail page's whole model in one pass
    /// (`FR-INV-15`).
    ///
    /// - Parameter health: the security's row from ``priceHealth(_:currency:asOf:quotable:ceased:gapLimit:calendar:)``
    ///   when the caller already has it. The app does — it memoises whole-book
    ///   health for the overview — and reusing it avoids recomputing holding
    ///   periods over the entire price database to draw one page. Passing `nil`
    ///   computes this security's periods locally, which is what tests do.
    /// - Parameter holding: the security's rows from
    ///   ``advancedPortfolio(_:currency:asOf:method:feeTreatment:)``, for the
    ///   same reason: return, average cost and allocation are already computed
    ///   there and recomputing them here would be a second answer to the same
    ///   question, free to drift.
    static func securityDetail(_ book: Book, commodity: Commodity, currency: Commodity,
                               asOf: Date = Date(),
                               health: SecurityPriceHealth? = nil,
                               holdings: [AdvancedHolding] = [],
                               lots: [LotDetail] = [],
                               calendar: Calendar = .current) -> SecurityDetail {
        let today = calendar.startOfDay(for: asOf)

        // --- Prices, one pass, oldest first -------------------------------
        var prices: [SecurityPriceRow] = []
        var sources: [String: Int] = [:]
        for price in book.prices where price.commodity == commodity {
            sources[price.source, default: 0] += 1
            prices.append(SecurityPriceRow(id: price.guid, date: price.date, value: price.value,
                                           currencyCode: price.currency.mnemonic,
                                           source: price.source))
        }
        prices.sort { $0.date < $1.date }

        // The latest price and the one before it, by **day**: two rows stamped
        // the same day (a re-fetch over a hand-entered figure) are one
        // observation, and treating them as two reports a 0% change against
        // itself while the real previous close sits a row further back.
        let onOrBefore = prices.filter { calendar.startOfDay(for: $0.date) <= today }
        let latest = onOrBefore.last
        let previous = latest.flatMap { last -> SecurityPriceRow? in
            let lastDay = calendar.startOfDay(for: last.date)
            return onOrBefore.last { calendar.startOfDay(for: $0.date) < lastDay }
        }

        // --- Movements: chart markers and the activity list ----------------
        var events: [SecurityEvent] = []
        var movements: [(date: Date, quantity: Decimal)] = []
        var accountNames: [String] = []
        for account in book.accounts
        where account.type.isSecurityType && account.commodity == commodity {
            accountNames.append(account.fullName)
            for split in book.splits(for: account) {
                guard let transaction = split.transaction else { continue }
                let date = transaction.datePosted
                if split.quantity != 0 {
                    movements.append((date: date, quantity: split.quantity))
                    // `value` is the cash the book moved for those units, signed
                    // the same way as the quantity. Its magnitude is the money;
                    // its sign is already carried by the units.
                    let amount = abs(split.value)
                    let unitPrice = split.quantity == 0 ? nil : amount / abs(split.quantity)
                    events.append(SecurityEvent(
                        id: "\(transaction.guid.hexString)|\(account.guid.hexString)|q",
                        kind: split.quantity > 0 ? .buy : .sell,
                        date: date, units: split.quantity, amount: amount,
                        // A transfer in specie moves units with no cash leg;
                        // reporting a unit price of zero there would draw a
                        // marker at the bottom of the chart and claim the shares
                        // were free.
                        unitPrice: amount == 0 ? nil : unitPrice,
                        accountName: account.fullName,
                        eventDescription: transaction.transactionDescription))
                }
                // Income attributed the way GnuCash's advanced portfolio does:
                // income-account splits in a transaction that touches this
                // security account. Recorded once per transaction even when the
                // dividend is split across several income accounts.
                let cash = transaction.splits
                    .filter { $0.account?.type == .income }
                    .reduce(Decimal(0)) { $0 - $1.value }
                if cash != 0 {
                    events.append(SecurityEvent(
                        id: "\(transaction.guid.hexString)|\(account.guid.hexString)|i",
                        kind: .income, date: date, units: 0, amount: cash, unitPrice: nil,
                        accountName: account.fullName,
                        eventDescription: transaction.transactionDescription))
                }
            }
        }
        events.sort { $0.date < $1.date }
        accountNames.sort()

        // --- Position figures, from the lot engine ------------------------
        //
        // Money-weighted across accounts, matching how the overview's rows are
        // built: a commodity held in two accounts has two returns, and the
        // arithmetic mean of them is not the portfolio's.
        var units = Decimal(0), costBasis = Decimal(0), realized = Decimal(0), income = Decimal(0)
        var marketValue: Decimal?, unrealized: Decimal?
        var allocation = 0.0
        var weightedReturn = 0.0, returnWeight = Decimal(0)
        var weightedCost = Decimal(0), costUnits = Decimal(0)
        for holding in holdings where holding.symbol == commodity.mnemonic {
            units += holding.shares
            costBasis += holding.costBasis
            realized += holding.realizedGain
            income += holding.income
            if let value = holding.marketValue { marketValue = (marketValue ?? 0) + value }
            if let gain = holding.unrealizedGain { unrealized = (unrealized ?? 0) + gain }
            allocation += holding.allocation ?? 0
            let weight = abs(holding.marketValue ?? holding.costBasis)
            if let fraction = holding.returnFraction {
                weightedReturn += fraction * NSDecimalNumber(decimal: weight).doubleValue
                returnWeight += weight
            }
            if let average = holding.averageCost, holding.shares != 0 {
                weightedCost += average * holding.shares
                costUnits += holding.shares
            }
        }

        let periods = health?.holdingPeriods
            ?? holdingPeriods(from: movements, asOf: today)

        return SecurityDetail(
            commodity: commodity,
            currencyCode: currency.mnemonic,
            asOf: asOf,
            units: health?.units ?? units,
            latestPrice: latest?.value,
            latestPriceDate: latest?.date,
            previousPrice: previous?.value,
            previousPriceDate: previous?.date,
            marketValue: marketValue ?? health?.marketValue,
            allocation: allocation == 0 ? nil : allocation,
            averageCost: costUnits == 0 ? nil : weightedCost / costUnits,
            costBasis: costBasis,
            unrealizedGain: unrealized,
            realizedGain: realized,
            income: income,
            returnFraction: returnWeight == 0 ? nil
                : weightedReturn / NSDecimalNumber(decimal: returnWeight).doubleValue,
            // Undefined rather than infinite on a zero cost basis — a fully
            // franked holding acquired for nothing (a demutualisation, a bonus
            // issue) would otherwise report an infinite yield.
            yieldOnCost: costBasis == 0 ? nil
                : NSDecimalNumber(decimal: income / costBasis).doubleValue,
            prices: prices,
            events: events,
            holdingPeriods: periods,
            lots: lots.filter { $0.symbol == commodity.mnemonic },
            sources: sources,
            accountNames: accountNames)
    }

    /// The detail's prices as CSV (`FR-INV-29`).
    ///
    /// Columns match what `CSVPriceImporter` reads back, so an export can be
    /// re-imported — the point of exporting a price table at all is usually to
    /// fix something in a spreadsheet and put it back. `source` rides along as
    /// a trailing column the importer ignores, because a table that hides where
    /// its numbers came from is the defect this page exists to fix.
    ///
    /// Dates are ISO-8601 day strings in the supplied calendar's zone: a price
    /// is a fact about a day, and exporting the stored 10:59Z instant would
    /// make a reader in Sydney think every close happened at nine in the
    /// evening.
    static func priceCSV(_ rows: [SecurityPriceRow], symbol: String,
                         calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var out = "Symbol,Date,Price,Currency,Source\n"
        for row in rows {
            out += [symbol, formatter.string(from: row.date),
                    NSDecimalNumber(decimal: row.value).stringValue,
                    row.currencyCode, csvField(row.source)]
                .joined(separator: ",") + "\n"
        }
        return out
    }

    /// Quotes a field that would otherwise break the row. Sources are
    /// provider-written strings and one of them arriving with a comma would
    /// silently shift every later column.
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
