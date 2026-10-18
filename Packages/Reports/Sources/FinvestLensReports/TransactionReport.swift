//
//  TransactionReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One posting to the reported account (`FR-RPT-04`).
public struct TransactionReportRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var date: Date
    public var description: String
    /// The account(s) on the other side of the transaction.
    public var transfer: String
    /// Signed amount posted to the reported account (in its commodity).
    public var amount: Decimal
    /// Running balance of the reported account after this posting.
    public var balance: Decimal
}

/// A Transaction Report: an account's postings over a period with a running
/// balance and a period total (`FR-RPT-04`).
public struct TransactionReport: Sendable {
    public var accountName: String
    public var from: Date
    public var to: Date
    public var currencyCode: String
    public var rows: [TransactionReportRow]
    /// Net change over the period.
    public var total: Decimal
    /// Opening balance carried into the period.
    public var opening: Decimal
    /// Closing balance at the end of the period.
    public var closing: Decimal
}

/// One account's postings in a Transaction Report over several accounts: its
/// rows in date order, its opening and closing balance, and its net change —
/// GnuCash's primary subtotal on the account (`trep-engine.scm`: primary key
/// `'account-name`, subtotal on, secondary key register order).
public struct TransactionReportGroup: Identifiable, Sendable {
    public var id: GncGUID
    /// The account's full name, which is what the groups are ordered by.
    public var accountName: String
    public var currencyCode: String
    public var rows: [TransactionReportRow]
    public var total: Decimal
    public var opening: Decimal
    public var closing: Decimal
}

/// A Transaction Report over a set of accounts — every account when none is
/// named — each with its subaccounts, every level (`FR-RPT-04`).
public struct AccountsTransactionReport: Sendable {
    public var from: Date
    public var to: Date
    /// Accounts with postings in the period, by full name.
    public var groups: [TransactionReportGroup]
    public var postingCount: Int { groups.reduce(0) { $0 + $1.rows.count } }
}

public extension FinancialReports {

    /// The accounts a report scoped to `accountIDs` covers: each named account
    /// and everything beneath it, every level; or every account, for `nil`.
    ///
    /// Asked for on build 4: the report "needs to show transactions belong to
    /// all accounts … The filter function needs to also filter by subaccount
    /// (recursively)." GnuCash opens this report on **no** accounts, and says
    /// why — "Selecting all accounts will always imply an insanely long waiting
    /// time upon opening" (`trep-engine.scm`); here the build runs off the main
    /// actor and reads each account's postings from the book's index, so all
    /// of them is the default it was asked to be.
    static func transactionReportAccounts(_ book: Book, accountIDs: Set<GncGUID>?) -> [Account] {
        guard let accountIDs else {
            return book.accounts.filter { $0 !== book.rootAccount }
        }
        var seen = Set<ObjectIdentifier>()
        var out: [Account] = []
        for id in accountIDs {
            guard let account = book.account(with: id) else { continue }
            for member in [account] + account.descendants
            where seen.insert(ObjectIdentifier(member)).inserted {
                out.append(member)
            }
        }
        return out
    }

    /// The postings of every account in scope within `[from, to]`, grouped by
    /// account, each group with a running balance seeded by its opening
    /// balance (`FR-RPT-04`).
    static func transactionReport(_ book: Book, accountIDs: Set<GncGUID>?,
                                  from: Date, to: Date) -> AccountsTransactionReport {
        var groups: [TransactionReportGroup] = []
        let scope = transactionReportAccounts(book, accountIDs: accountIDs)
        // One account chosen, with nothing beneath it: its group stays even
        // over a quiet period, for the opening and closing it reports.
        let keepEmpty = accountIDs?.count == 1 && scope.count == 1
        for account in scope {
            guard let group = postings(of: account, in: book, from: from, to: to,
                                       keepEmpty: keepEmpty) else { continue }
            groups.append(group)
        }
        groups.sort { $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending }
        return AccountsTransactionReport(from: from, to: to, groups: groups)
    }

    /// One account's group: its own postings, read from the book's index, in
    /// the register's order — by date, then GnuCash's canonical order for a
    /// day (`Transaction.canonicalOrder`: closing entries last, number and
    /// action, entered date, description) — so the running Balance on a row
    /// is the balance the register shows on it. `keepEmpty` keeps an account
    /// with nothing in the period, for its opening and closing balance.
    static func postings(of account: Account, in book: Book, from: Date, to: Date,
                         keepEmpty: Bool = false) -> TransactionReportGroup? {
        var opening = Decimal(0)
        var inPeriod: [(split: Split, transaction: Transaction)] = []
        for split in book.splits(for: account) where split.reconcileState != .voided {
            guard let transaction = split.transaction else { continue }
            if transaction.datePosted < from {
                opening += split.quantity
            } else if transaction.datePosted <= to {
                inPeriod.append((split, transaction))
            }
        }
        guard keepEmpty || !inPeriod.isEmpty else { return nil }
        inPeriod.sort {
            Transaction.canonicalOrder($0.transaction, action: $0.split.action,
                                       $1.transaction, action: $1.split.action) < 0
        }

        let commodity = account.commodity
        var running = opening
        var total = Decimal(0)
        var rows: [TransactionReportRow] = []
        rows.reserveCapacity(inPeriod.count)
        for (split, transaction) in inPeriod {
            running += split.quantity
            total += split.quantity
            rows.append(TransactionReportRow(
                id: split.guid, date: transaction.datePosted,
                description: transaction.transactionDescription,
                transfer: transferText(of: split, in: transaction),
                amount: commodity.round(split.quantity),
                balance: commodity.round(running)))
        }
        return TransactionReportGroup(
            id: account.guid, accountName: account.fullName, currencyCode: commodity.mnemonic,
            rows: rows, total: commodity.round(total),
            opening: commodity.round(opening), closing: commodity.round(running))
    }

    /// The account(s) on the other side of `split`: the one other leg's name
    /// as it is, or the distinct names, sorted, of several.
    private static func transferText(of split: Split, in transaction: Transaction) -> String {
        var only: String?
        var names: Set<String> = []
        var count = 0
        for other in transaction.splits where other !== split {
            guard let name = other.account?.name else { continue }
            count += 1
            if count == 1 { only = name } else { names.insert(name) }
        }
        switch count {
        case 0: return "—"
        case 1: return only ?? "—"
        default:
            if let only { names.insert(only) }
            return names.sorted().joined(separator: ", ")
        }
    }

    /// Lists the postings of `accountID` within `[from, to]`, with a running
    /// balance seeded by the opening balance up to `from` (`FR-RPT-04`) —
    /// the many-account report's group for one account, kept even when the
    /// period has nothing in it.
    static func transactionReport(_ book: Book, accountID: GncGUID,
                                  from: Date, to: Date) -> TransactionReport? {
        guard let account = book.account(with: accountID),
              let group = postings(of: account, in: book, from: from, to: to, keepEmpty: true)
        else { return nil }
        return TransactionReport(
            accountName: account.name, from: from, to: to, currencyCode: group.currencyCode,
            rows: group.rows, total: group.total, opening: group.opening, closing: group.closing)
    }
}
