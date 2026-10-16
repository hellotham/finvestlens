//
//  LocalizedNames.swift
//  FinvestLens — FeatureUI
//
//  The reader's names for things the lower packages identify by a raw value.
//
//  Each of these was drawn on screen as its identifier — `rawValue`, or
//  `rawValue.capitalized` — so the account-type picker said "Mutual", the
//  rule editor "startsWith", and a schedule "Every 2 weeks" by gluing an `s`
//  onto an English noun, in every language. The identifiers stay what they
//  are: they are written into books and compared by code. What is shown is
//  spelled out here, case by case, where the compiler can see each phrase.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensRules

extension AccountType {
    /// GnuCash's names for the types, as its account dialog shows them.
    var localizedName: String {
        switch self {
        case .root: String(localized: "Root")
        case .asset: String(localized: "Asset")
        case .bank: String(localized: "Bank")
        case .cash: String(localized: "Cash")
        case .credit: String(localized: "Credit Card")
        case .liability: String(localized: "Liability")
        case .equity: String(localized: "Equity")
        case .income: String(localized: "Income")
        case .expense: String(localized: "Expense")
        case .receivable: String(localized: "A/Receivable")
        case .payable: String(localized: "A/Payable")
        case .stock: String(localized: "Stock")
        case .mutualFund: String(localized: "Mutual Fund")
        case .trading: String(localized: "Trading")
        }
    }
}

extension RuleField {
    var localizedName: String {
        switch self {
        case .description: String(localized: "Description")
        case .memo: String(localized: "Memo")
        case .amount: String(localized: "Amount")
        case .account: String(localized: "Account")
        }
    }
}

extension RuleOperator {
    var localizedName: String {
        switch self {
        case .contains: String(localized: "contains")
        case .equals: String(localized: "equals")
        case .startsWith: String(localized: "starts with")
        case .endsWith: String(localized: "ends with")
        case .greaterThan: String(localized: "is greater than")
        case .lessThan: String(localized: "is less than")
        }
    }
}

extension RegisterSort {
    var title: String {
        switch self {
        case .standard: String(localized: "Standard Order")
        case .date: String(localized: "Date")
        case .dateEntered: String(localized: "Date of Entry")
        case .number: String(localized: "Number")
        case .amount: String(localized: "Amount")
        case .description: String(localized: "Description")
        case .memo: String(localized: "Memo")
        }
    }
}

extension BillableEntry.Kind {
    var localizedName: String {
        switch self {
        case .time: String(localized: "Time")
        case .mileage: String(localized: "Mileage")
        }
    }
}

extension InvestmentDetail.Action {
    var localizedName: String {
        switch self {
        case .buy: String(localized: "Buy")
        case .sell: String(localized: "Sell")
        case .dividend: String(localized: "Dividend")
        case .reinvestDividend: String(localized: "Reinvest Dividend")
        case .returnOfCapital: String(localized: "Return of Capital")
        case .other: String(localized: "Other")
        }
    }
}

extension RecurrencePeriod {
    /// "Every 2 weeks" — a phrase for each unit, each with its own plural.
    /// It was "Every \(n) \(noun)" and an `s` when `n` was not one.
    func every(_ interval: Int) -> String {
        switch self {
        case .daily: String(localized: "Every \(interval) days")
        case .weekly: String(localized: "Every \(interval) weeks")
        case .monthly, .endOfMonth, .nthWeekday, .lastWeekday: String(localized: "Every \(interval) months")
        case .yearly: String(localized: "Every \(interval) years")
        case .once: String(localized: "Once")
        }
    }

    /// A schedule as a sentence: "Every 2 months (last day), from 1 March 2026".
    func summary(interval: Int, from start: String) -> String {
        switch self {
        case .once: String(localized: "Once, on \(start)")
        case .daily: String(localized: "Every \(interval) days, from \(start)")
        case .weekly: String(localized: "Every \(interval) weeks, from \(start)")
        case .monthly: String(localized: "Every \(interval) months, from \(start)")
        case .yearly: String(localized: "Every \(interval) years, from \(start)")
        case .endOfMonth: String(localized: "Every \(interval) months (last day), from \(start)")
        case .nthWeekday: String(localized: "Every \(interval) months (same weekday), from \(start)")
        case .lastWeekday: String(localized: "Every \(interval) months (last weekday), from \(start)")
        }
    }
}

extension Commodity {
    /// A currency by the reader's name for it — "Australischer Dollar" — and
    /// anything else by its own. A currency's stored name is ISO's English
    /// one, as GnuCash's table writes it into a book; shown as it was, a
    /// German statement read "Alle Beträge in Australian Dollar (AUD)".
    var localizedName: String {
        if namespace == .currency,
           let name = Locale.current.localizedString(forCurrencyCode: mnemonic) {
            return name
        }
        return fullName.isEmpty ? mnemonic : fullName
    }
}

/// What a security search result is, by the provider's own type code.
/// Yahoo's codes drawn as they came read "Etf" and "Mutualfund"; a code this
/// does not know is shown as it came.
enum SecurityKindName {
    static func name(_ code: String) -> String {
        switch code.uppercased() {
        case "EQUITY": String(localized: "Share")
        case "ETF": String(localized: "ETF")
        case "MUTUALFUND": String(localized: "Fund")
        case "INDEX": String(localized: "Index")
        case "CURRENCY": String(localized: "Currency")
        case "CRYPTOCURRENCY": String(localized: "Cryptocurrency")
        case "FUTURE": String(localized: "Future")
        case "OPTION": String(localized: "Option")
        case "BOND": String(localized: "Bond")
        default: code
        }
    }
}
