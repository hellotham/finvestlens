//
//  ReportPipeline.swift
//  FinvestLens — CLI
//
//  filter → value → group → sort over one `Book`, shared by every command
//  (design ADR-L3). Ledger's conventions are kept where they differ from the
//  app's: `--end` is exclusive, an account matches by its full colon path,
//  and `--related` reports the OTHER postings of matched transactions.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One posting the report will show.
public struct ReportPosting {
    public let split: Split
    public let transaction: Transaction
    /// The amount in the reporting commodity (after valuation), and the
    /// commodity it is stated in.
    public var amount: Decimal
    public var commodity: Commodity
    public var date: Date { transaction.datePosted }
    public var account: Account? { split.account }
}

public struct ReportRequest {
    public var options: CLIOptions
    public var query: ParsedQuery
    public var today: Date

    public init(options: CLIOptions, query: ParsedQuery, today: Date) {
        self.options = options
        self.query = query
        self.today = today
    }
}

public struct ReportPipeline {
    public let book: Book
    public let request: ReportRequest

    public init(book: Book, request: ReportRequest) {
        self.book = book
        self.request = request
    }

    /// The reporting commodity: `-X CODE` wins, else the book's base.
    public var reportCommodity: Commodity {
        if let code = request.options.exchange.first {
            // `-X A:B` converts A into B; the target is the right side.
            let target = code.contains(":") ? String(code.split(separator: ":")[1]) : code
            if let existing = book.commodities.first(where: { $0.mnemonic == target }) {
                return existing
            }
            return Commodity(namespace: .currency, mnemonic: target,
                             fullName: target, smallestFraction: 100)
        }
        return book.baseCurrency
    }

    /// The resolved reporting window; `end` is exclusive (ledger's rule).
    public var window: (begin: Date?, end: Date?) {
        var begin: Date?
        var end: Date?
        if let text = request.options.begin {
            begin = PeriodExpression.date(text, today: request.today)
        }
        if let text = request.options.end {
            end = PeriodExpression.date(text, today: request.today)
        }
        var periodText = request.options.period
        if periodText == nil, !request.query.periodWords.isEmpty {
            periodText = request.query.periodWords.joined(separator: " ")
        }
        if let periodText {
            let period = PeriodExpression.parse(periodText, today: request.today)
            begin = period.begin ?? begin
            end = period.end ?? end
        }
        return (begin, end)
    }

    public var interval: PeriodInterval? {
        var periodText = request.options.period
        if periodText == nil, !request.query.periodWords.isEmpty {
            periodText = request.query.periodWords.joined(separator: " ")
        }
        guard let periodText else { return nil }
        return PeriodExpression.parse(periodText, today: request.today).interval
    }

    /// Every posting that survives filtering, in journal order.
    public func postings() -> [ReportPosting] {
        let bounds = window
        let options = request.options
        let predicate = request.query.predicate
        var result: [ReportPosting] = []

        for transaction in book.transactions.sorted(by: { $0.datePosted < $1.datePosted }) {
            if let begin = bounds.begin, transaction.datePosted < begin { continue }
            if let end = bounds.end, transaction.datePosted >= end { continue }

            // State filters apply per posting (ledger reads a transaction's
            // flag as shorthand for all of its postings).
            func passesState(_ split: Split) -> Bool {
                if options.cleared && split.reconcileState != .reconciled { return false }
                if options.uncleared && split.reconcileState == .reconciled { return false }
                if options.pending && split.reconcileState != .cleared { return false }
                return true
            }

            let matched = transaction.splits.filter {
                predicate.matches(QuerySubject(split: $0, transaction: transaction))
            }
            guard !matched.isEmpty else { continue }

            let shown: [Split]
            if options.related {
                shown = transaction.splits.filter { split in
                    !matched.contains { $0 === split }
                }
            } else {
                shown = matched
            }

            for split in shown where passesState(split) {
                if let display = request.query.display,
                   !display.matches(QuerySubject(split: split, transaction: transaction)) {
                    continue
                }
                result.append(valued(split: split, transaction: transaction))
            }
        }

        result = sorted(result)
        if let head = options.head { result = Array(result.prefix(head)) }
        if let tail = options.tail { result = Array(result.suffix(tail)) }
        return result
    }

    /// Applies the valuation flags to one split.
    func valued(split: Split, transaction: Transaction) -> ReportPosting {
        let options = request.options
        let target = reportCommodity
        let accountCommodity = split.account?.commodity ?? transaction.currency

        // Default (-O): the account's own commodity — quantity for a security
        // leg, value for a cash leg.
        var amount = split.quantity
        var commodity = accountCommodity
        if accountCommodity == transaction.currency {
            amount = split.value
            commodity = transaction.currency
        }

        if options.basis {
            // Cost basis: the value leg as booked.
            amount = split.value
            commodity = transaction.currency
        } else if options.market || !options.exchange.isEmpty || options.historical {
            let asOf = options.historical ? transaction.datePosted : valuationDate
            if commodity == target {
                // Already in the target commodity.
            } else if let converted = book.convert(amount, from: commodity, to: target, on: asOf) {
                amount = converted
                commodity = target
            } else if accountCommodity != transaction.currency,
                      let converted = book.convert(split.value, from: transaction.currency,
                                                   to: target, on: asOf) {
                // A security leg with no price: fall back to its booked value.
                amount = converted
                commodity = target
            }
        }
        return ReportPosting(split: split, transaction: transaction,
                             amount: amount, commodity: commodity)
    }

    var valuationDate: Date {
        if let now = request.options.now,
           let parsed = PeriodExpression.date(now, today: request.today) {
            return parsed
        }
        return window.end ?? request.today
    }

    func sorted(_ postings: [ReportPosting]) -> [ReportPosting] {
        let keys = request.options.sortKeys
        guard !keys.isEmpty else { return postings }
        return postings.sorted { lhs, rhs in
            for key in keys {
                let descending = key.hasPrefix("-")
                let name = descending ? String(key.dropFirst()) : key
                let order: Int
                switch name.lowercased() {
                case "date": order = compare(lhs.date, rhs.date)
                case "amount": order = compare(lhs.amount, rhs.amount)
                case "abs(amount)": order = compare(abs(lhs.amount), abs(rhs.amount))
                case "payee": order = compare(lhs.transaction.transactionDescription,
                                              rhs.transaction.transactionDescription)
                case "account": order = compare(lhs.account?.fullName ?? "",
                                                rhs.account?.fullName ?? "")
                default: order = 0
                }
                if order != 0 { return descending ? order > 0 : order < 0 }
            }
            return false
        }
    }

    func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Int {
        lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
    }

    /// Balances per account full name, summed over the filtered postings.
    /// A parent's subtree total is the sum of its own and its children's.
    public func balances() -> [String: [String: Decimal]] {
        var totals: [String: [String: Decimal]] = [:]
        for posting in postings() {
            guard let account = posting.account else { continue }
            totals[account.fullName, default: [:]][posting.commodity.mnemonic, default: 0] += posting.amount
        }
        return totals
    }
}
