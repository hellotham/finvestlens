//
//  CategoryBreakdown.swift
//  FinvestLens — Reports
//
//  GnuCash's Expense Piechart, Income Piechart and Income & Expense Barchart
//  (`FR-RPT-03`) — the most-looked-at reports in a personal book, because the
//  question they answer is the everyday one: where does it all go?
//
//  Two shapes from one computation. Slices: the period's income or spending per
//  top-level category, subtrees rolled up, largest first. Months: the same
//  totals cut by calendar month for the bar chart. Both are bound to the
//  income statement — slices sum to its total, and the months sum to the
//  slices — so the three reports can never tell three stories.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One month's income and spending, for the bar chart.
public struct MonthlyFlow: Identifiable, Hashable, Sendable {
    public var id: Date { month }
    /// The first instant of the month.
    public var month: Date
    public var income: Decimal
    public var expenses: Decimal
}

public struct CategoryBreakdown: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    /// Spending per top-level expense category, subtrees rolled, largest first.
    public var expenseSlices: [ReportLine]
    /// Income per top-level income category, likewise.
    public var incomeSlices: [ReportLine]
    /// Each expense account's own spending over the period — converted, not
    /// rolled and **not rounded** — so a category can be broken down into its
    /// subcategories at every level and each node rounded once, from the
    /// exact sum beneath it: a top-level node is then its slice to the cent.
    public var expenseAccounts: [ReportLine] = []
    /// Each income account's own income over the period, likewise.
    public var incomeAccounts: [ReportLine] = []
    public var totalExpenses: Decimal
    public var totalIncome: Decimal
    /// Month-by-month totals across the period, oldest first.
    public var months: [MonthlyFlow]
}

public extension FinancialReports {

    /// Where the period's money came from and went, by category and by month
    /// (`FR-RPT-03`).
    static func categoryBreakdown(_ book: Book, from: Date, to: Date,
                                  currency: Commodity,
                                  calendar: Calendar = .current) -> CategoryBreakdown {
        let map = categoryMap(book, from: from, to: to)
        func slices(_ type: AccountType) -> ([ReportLine], Decimal) {
            categorySlices(type, in: book, map: map, currency: currency, to: to)
        }

        // Months by walking split-wise once: the slice computation converts a
        // whole subtree at the period's closing rate, which is right for "what
        // did the year cost", but a month's bar should be the month's money.
        var monthTotals: [Date: (income: Decimal, expenses: Decimal)] = [:]
        for transaction in book.transactions
        where transaction.datePosted >= from && transaction.datePosted <= to {
            for split in transaction.splits where split.reconcileState != .voided {
                guard let account = split.account else { continue }
                let isIncome = account.type == .income
                let isExpense = account.type == .expense
                guard isIncome || isExpense else { continue }
                guard let amount = convert(split.quantity, of: account, in: book,
                                           to: currency, on: transaction.datePosted)
                else { continue }
                let month = calendar.date(from: calendar.dateComponents(
                    [.year, .month], from: transaction.datePosted)) ?? transaction.datePosted
                var entry = monthTotals[month] ?? (0, 0)
                // Presentation signs: income is credit-normal, spending debit.
                if isIncome { entry.income += -amount } else { entry.expenses += amount }
                monthTotals[month] = entry
            }
        }
        let months = monthTotals
            .map { MonthlyFlow(month: $0.key,
                               income: currency.round($0.value.income),
                               expenses: currency.round($0.value.expenses)) }
            .sorted { $0.month < $1.month }

        let (expenseSlices, totalExpenses) = slices(.expense)
        let (incomeSlices, totalIncome) = slices(.income)
        return CategoryBreakdown(
            from: from, to: to, currencyCode: currency.mnemonic,
            expenseSlices: expenseSlices, incomeSlices: incomeSlices,
            expenseAccounts: categoryAccounts(.expense, in: book, map: map, currency: currency, to: to),
            incomeAccounts: categoryAccounts(.income, in: book, map: map, currency: currency, to: to),
            totalExpenses: totalExpenses, totalIncome: totalIncome,
            months: months)
    }

    /// Every account under a top-level category of `type` with money of its
    /// own in the period: exactly what the slices roll up, before they roll
    /// it — the same tops, the same descendants whatever their own type
    /// (GnuCash lets income and expense accounts sit under each other), the
    /// same map and conversion, unrounded. Chosen by the account's own type
    /// instead, an expense account under Income was listed under Spending
    /// while its money was counted in Total Income, and neither section's
    /// rows added up to the total printed under them.
    private static func categoryAccounts(_ type: AccountType, in book: Book,
                                         map: [ObjectIdentifier: Decimal], currency: Commodity,
                                         to: Date) -> [ReportLine] {
        var lines: [ReportLine] = []
        for top in book.rootAccount.children where top.type == type {
            for account in [top] + top.descendants where !account.isPlaceholder {
                guard let amount = convert(displayBalance(in: map, of: account), of: account,
                                           in: book, to: currency, on: to),
                      amount != 0 else { continue }
                lines.append(ReportLine(id: account.guid, name: account.name,
                                        fullName: account.fullName, amount: amount))
            }
        }
        return lines
    }

    /// ``categoryBreakdown(_:from:to:currency:calendar:)``'s two totals alone
    /// — the same numbers from the same code, without the month-by-month walk
    /// (a calendar computation and a conversion per split) that only the
    /// bar chart reads. The wellbeing score asks for three windows' totals on
    /// every revision, and paid that walk three times over for nothing.
    static func categoryTotals(_ book: Book, from: Date, to: Date,
                               currency: Commodity) -> (income: Decimal, expenses: Decimal) {
        categoryTotals(book, windows: [(from, to)], currency: currency)[0]
    }

    /// ``categoryTotals(_:from:to:currency:)`` for several windows, the book
    /// walked once for all of them.
    static func categoryTotals(_ book: Book, windows: [(from: Date, to: Date)],
                               currency: Commodity) -> [(income: Decimal, expenses: Decimal)] {
        let maps = book.balancesByAccount(windows: windows.map { (from: $0.from, to: $0.to) },
                                          excludingClosing: true)
        return zip(windows, maps).map { window, map in
            let (_, expenses) = categorySlices(.expense, in: book, map: map, currency: currency, to: window.to)
            let (_, income) = categorySlices(.income, in: book, map: map, currency: currency, to: window.to)
            return (income, expenses)
        }
    }

    /// One walk for every category's period total. Closing entries are
    /// excluded — this reports income and expense categories, which Close
    /// Book zeroes, so a closed year otherwise showed no spending at all.
    private static func categoryMap(_ book: Book, from: Date, to: Date) -> [ObjectIdentifier: Decimal] {
        balanceMap(book, from: from, to: to, excludingClosing: true)
    }

    /// The period's top-level categories of `type`, subtrees rolled up and
    /// converted, largest first, and their total.
    private static func categorySlices(_ type: AccountType, in book: Book,
                                       map: [ObjectIdentifier: Decimal], currency: Commodity,
                                       to: Date) -> ([ReportLine], Decimal) {
        /// A subtree's converted, presentation-signed total over the period.
        func rolled(_ account: Account) -> Decimal {
            var total = Decimal(0)
            if !account.isPlaceholder {
                let native = displayBalance(in: map, of: account)
                total = convert(native, of: account, in: book, to: currency, on: to) ?? 0
            }
            return account.children.reduce(total) { $0 + rolled($1) }
        }

        var lines: [ReportLine] = []
        var total = Decimal(0)
        for top in book.rootAccount.children where top.type == type {
            let amount = currency.round(rolled(top))
            guard amount != 0 else { continue }
            lines.append(ReportLine(id: top.guid, name: top.name,
                                    fullName: top.fullName, amount: amount))
            total += amount
        }
        lines.sort { $0.amount == $1.amount ? $0.fullName < $1.fullName
                                            : $0.amount > $1.amount }
        return (lines, currency.round(total))
    }
}
