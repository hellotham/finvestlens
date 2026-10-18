//
//  AppModel+Reports.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    /// The currency used for single-currency reports — the Engine's one
    /// authoritative derivation (root-account commodity first; `.first` over
    /// the commodity table alone was registration-order dependent).
    var reportCurrency: Commodity {
        book?.baseCurrency ?? .aud
    }

    public func balanceSheet(asOf: Date = Date()) -> BalanceSheet? {
        guard let book else { return nil }
        return cachedReport("bs:\(asOf.timeIntervalSinceReferenceDate)") {
            FinancialReports.balanceSheet(book, asOf: asOf, currency: reportCurrency,
                                          balances: balances(asOf: asOf))
        }
    }

    /// Every account's balance as of a date, memoised: the balance sheet and
    /// the wellbeing score both ask it of the end of today, on every revision
    /// the Overview shows, and walking the book once serves both (R5b).
    func balances(asOf date: Date) -> [ObjectIdentifier: Decimal] {
        guard let book else { return [:] }
        return cachedReport("balances:\(date.timeIntervalSinceReferenceDate)") {
            book.balancesByAccount(from: nil, to: date)
        } ?? [:]
    }

    public func incomeStatement(from: Date, to: Date) -> IncomeStatement? {
        guard let book else { return nil }
        return cachedReport("is:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            FinancialReports.incomeStatement(book, from: from, to: to, currency: reportCurrency)
        }
    }

    /// The postings of every account in scope — each named account with its
    /// subaccounts, every level, or the whole book for `nil` — grouped by
    /// account (`FR-RPT-04`).
    public func transactionReport(accountIDs: Set<GncGUID>?, from: Date, to: Date) -> AccountsTransactionReport? {
        report(transactionsReportRequest(accountIDs: accountIDs, from: from, to: to))
    }

    func transactionsReportRequest(accountIDs: Set<GncGUID>?, from: Date,
                                   to: Date) -> ReportRequest<AccountsTransactionReport> {
        let scope = accountIDs.map { $0.map(\.hexString).sorted().joined(separator: ",") } ?? "all"
        let covered = book.map { book in
            FinancialReports.transactionReportAccounts(book, accountIDs: accountIDs).map(\.guid)
        } ?? []
        return ReportRequest(key: "txrs:\(scope):\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)",
                             work: postings(in: covered)) { book in
            FinancialReports.transactionReport(book, accountIDs: accountIDs, from: from, to: to)
        }
    }

    /// The postings a report over `accountIDs` reads — its
    /// ``ReportRequest/work``. Read from the lookup index, which the build
    /// itself needs.
    func postings(in accountIDs: some Sequence<GncGUID>) -> Int? {
        guard let book else { return nil }
        return accountIDs.reduce(0) { total, id in
            total + (book.account(with: id).map { book.splits(for: $0).count } ?? 0)
        }
    }

    /// An account's postings grouped by reconcile state as of a date
    /// (`FR-RPT-05`).
    public func reconcileReport(accountID: GncGUID, asOf: Date) -> ReconcileReport? {
        report(reconcileReportRequest(accountID: accountID, asOf: asOf))
    }

    func reconcileReportRequest(accountID: GncGUID, asOf: Date) -> ReportRequest<ReconcileReport> {
        ReportRequest(key: "recr:\(accountID.hexString):\(asOf.timeIntervalSinceReferenceDate)",
                      work: postings(in: [accountID])) { book in
            FinancialReports.reconcileReport(book, accountID: accountID, asOf: asOf)
        }
    }

    /// Every account's balance in debit/credit columns (`FR-RPT-01`).
    public func trialBalance(asOf: Date) -> TrialBalanceReport? {
        guard let book else { return nil }
        return cachedReport("tb:\(asOf.timeIntervalSinceReferenceDate)") {
            FinancialReports.trialBalance(book, asOf: asOf, currency: reportCurrency)
        }
    }

    /// The movement of capital over a period (`FR-RPT-01`).
    public func equityStatement(from: Date, to: Date) -> EquityStatement? {
        guard let book else { return nil }
        return cachedReport("eq:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            FinancialReports.equityStatement(book, from: from, to: to, currency: reportCurrency)
        }
    }

    /// How many levels the chart of accounts has beneath the root — the depth
    /// at which a report shows everything, and the Account Summary's default.
    public var accountTreeDepth: Int {
        guard let book else { return 1 }
        // Read by the report bar's body and three times a document build:
        // walked once per book revision, top down, carrying the depth.
        return cachedReport("treeDepth") { () -> Int in
            func deepest(_ account: Account, _ depth: Int) -> Int {
                account.children.reduce(depth) { max($0, deepest($1, depth + 1)) }
            }
            return max(1, book.rootAccount.children.reduce(0) { max($0, deepest($1, 1)) })
        } ?? 1
    }

    /// The chart of accounts with balances, cut at a depth (`FR-RPT-01`).
    public func accountSummary(asOf: Date, depthLimit: Int) -> AccountSummaryReport? {
        guard let book else { return nil }
        return cachedReport("as:\(asOf.timeIntervalSinceReferenceDate):\(depthLimit)") {
            FinancialReports.accountSummary(book, asOf: asOf, currency: reportCurrency,
                                            depthLimit: depthLimit)
        }
    }

    /// Money into and out of a set of accounts over a period (`FR-RPT-01`).
    public func cashFlow(accountIDs: Set<GncGUID>, from: Date, to: Date) -> CashFlowReport? {
        guard let book, !accountIDs.isEmpty else { return nil }
        let ids = accountIDs.map(\.hexString).sorted().joined(separator: ",")
        return cachedReport("cf:\(ids):\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            FinancialReports.cashFlow(book, accountIDs: accountIDs, from: from, to: to,
                                      currency: reportCurrency)
        }
    }

    /// The daily-weighted average balance of a set of accounts over a period,
    /// sliced by interval (`FR-RPT-03`).
    public func averageBalance(accountIDs: Set<GncGUID>, from: Date, to: Date,
                               step: AverageBalanceStep) -> AverageBalanceReport? {
        guard let book, !accountIDs.isEmpty,
              accountIDs.contains(where: { book.account(with: $0) != nil }) else { return nil }
        return report(averageBalanceRequest(accountIDs: accountIDs, from: from, to: to, step: step))
    }

    func averageBalanceRequest(accountIDs: Set<GncGUID>, from: Date, to: Date,
                               step: AverageBalanceStep) -> ReportRequest<AverageBalanceReport> {
        let ids = accountIDs.map(\.hexString).sorted().joined(separator: ",")
        let currency = reportCurrency
        return ReportRequest(key: "avg:\(ids):\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate):\(step)",
                             work: averageBalanceWork(accountIDs: accountIDs, from: from, to: to)) { book in
            // Resolved in the book it is built from: a replica's own accounts.
            let accounts = accountIDs.compactMap { book.account(with: $0) }
            guard !accounts.isEmpty else { return nil }
            return FinancialReports.averageBalance(book, accounts: accounts, currency: currency,
                                                   from: from, to: to, step: step)
        }
    }

    /// What an Average Balance build reads: each account's postings, then a
    /// walk of the period a day at a time that samples every account — so a
    /// month measured quick does not vouch for All Time, years of days, on
    /// the main actor. All Time starts at the book's first entry, as the
    /// report itself does.
    func averageBalanceWork(accountIDs: Set<GncGUID>, from: Date, to: Date) -> Int? {
        guard let postings = postings(in: accountIDs) else { return nil }
        let start = from == .distantPast ? (bookFirstEntryDate ?? to) : from
        let days = max(0, Int(to.timeIntervalSince(start) / 86_400) + 1)
        return postings + days * accountIDs.count
    }

    /// When the book's first entry was posted, once a revision.
    var bookFirstEntryDate: Date? {
        guard let book else { return nil }
        return cachedReport("firstEntry") { book.transactions.lazy.map(\.datePosted).min() }
    }

    /// Income and spending by category and by month (`FR-RPT-03`).
    public func categoryBreakdown(from: Date, to: Date) -> CategoryBreakdown? {
        guard let book else { return nil }
        return cachedReport("cb:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            FinancialReports.categoryBreakdown(book, from: from, to: to, currency: reportCurrency)
        }
    }

    /// A monthly net-worth series across the last `months` months.
    public func netWorthSeries(months: Int = 12, endingAt end: Date = Date()) -> [NetWorthPoint] {
        guard let book else { return [] }
        return cachedReport("nws:\(months):\(end.timeIntervalSinceReferenceDate)") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let dates: [Date] = (0..<max(1, months)).reversed().compactMap {
                calendar.date(byAdding: .month, value: -$0, to: end)
            }
            let series = FinancialReports.netWorthSeries(book, dates: dates, currency: reportCurrency)
            return series.isEmpty ? nil : series
        } ?? []
    }
}
