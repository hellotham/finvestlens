//
//  AppModel+FYPack.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The Financial Year Pack (redesign 6.6b, UC10): the EOFY bundle in one
//  export — P&L, Balance Sheet, Capital Gains, and a Dividend & Franking
//  summary — for the chosen financial year. Everything reuses the existing
//  report builders; the dividend summary is the one new document, shaped for
//  tax time: per security, franked / unfranked / imputation credits.
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    /// A financial year the pack can be built for, newest first: the current
    /// FY and the three before it (bounded by the book's oldest transaction).
    func packFinancialYears() -> [(label: String, from: Date, to: Date)] {
        let calendar = Calendar.current
        let oldest = book?.transactions.map(\.datePosted).min() ?? .distantFuture
        var years: [(String, Date, Date)] = []
        var range = resolve(.currentFinancialYear)
        for _ in 0..<4 {
            let endYear = calendar.component(.year, from: range.to)
            let startYear = calendar.component(.year, from: range.from)
            let label = ReportPeriod.financialYearLabel(fromYear: startYear, toYear: endYear)
            years.append((label, range.from, range.to))
            guard range.to > oldest else { break }
            let from = calendar.date(byAdding: .year, value: -1, to: range.from) ?? range.from
            let to = calendar.date(byAdding: .year, value: -1, to: range.to) ?? range.to
            range = (from, to)
        }
        return years
    }

    /// One page of the pack: an annual-report statement or a tabular report.
    enum FinancialYearPackPage {
        case statement(Statement)
        case document(ReportDocument)

        var title: String {
            switch self {
            case .statement(let statement): statement.title
            case .document(let document): document.title
            }
        }
    }

    /// The pack, in reading order: the three statements (annual-report
    /// presentation, report-redesign §3), then capital gains and the
    /// dividend & franking summary. Reports with nothing to say are skipped
    /// rather than emitted as empty pages.
    func financialYearPackPages(from: Date, to: Date, label: String) -> [FinancialYearPackPage] {
        var pages: [FinancialYearPackPage] = []
        if let income = incomeStatementStatement(from: from, to: to, periodLabel: label) {
            pages.append(.statement(income))
        }
        if let position = financialPositionStatement(asOf: to) {
            pages.append(.statement(position))
        }
        if let changes = changesInNetWorthStatement(from: from, to: to, periodLabel: label) {
            pages.append(.statement(changes))
        }
        if let cg = capitalGainsDocument(from: from, to: to, periodLabel: label) {
            pages.append(.document(cg))
        }
        if let dividends = dividendFrankingDocument(from: from, to: to, periodLabel: label) {
            pages.append(.document(dividends))
        }
        return pages
    }

    /// A period's dividends by security and kind: what the Dividends &
    /// Franking report prints, and what the review decks chart. Computed
    /// once and handed over as figures, so that nothing finds a number by
    /// the wording of a report — the decks used to look the totals up by
    /// the labels "Franked" and "Unfranked" and the sections by a title
    /// ending in "dividends", which the first translated report would have
    /// silently emptied.
    struct DividendBreakdown {
        struct Security {
            var name: String
            var franked = Decimal(0)
            var unfranked = Decimal(0)
            var imputation = Decimal(0)
            /// Under the Dividends tree and not named as any of the three.
            var other = Decimal(0)
        }
        var currencyCode: String
        /// By name.
        var securities: [Security]

        var franked: Decimal { securities.reduce(0) { $0 + $1.franked } }
        /// Unfranked, with what the account names did not classify.
        var unfranked: Decimal { securities.reduce(0) { $0 + $1.unfranked + $1.other } }
        var credits: Decimal { securities.reduce(0) { $0 + $1.imputation } }

        /// Cash received by security — franked, unfranked and unclassified,
        /// without the credits — for the securities that had any line of it.
        var cashBySecurity: [String: Decimal] {
            var cash: [String: Decimal] = [:]
            for security in securities
            where security.franked != 0 || security.unfranked != 0 || security.other != 0 {
                cash[security.name] = security.franked + security.unfranked + security.other
            }
            return cash
        }
    }

    /// Income-statement lines under a Dividends subtree, classified per
    /// security into franked / unfranked / imputation credits by account
    /// name — the same shape the book's own dividend transactions use
    /// (Dividends ▸ TICKER ▸ Franked / Unfranked / Imputation Credit). `nil`
    /// when the book records no dividend income.
    func dividendBreakdown(from: Date, to: Date) -> DividendBreakdown? {
        guard let statement = incomeStatement(from: from, to: to) else { return nil }
        let dividendLines = statement.income.filter {
            $0.fullName.localizedCaseInsensitiveContains("dividend")
        }
        guard !dividendLines.isEmpty else { return nil }

        var bySecurity: [String: DividendBreakdown.Security] = [:]
        for line in dividendLines {
            let name = line.name.lowercased()
            // The security is the path component holding the classified leaf;
            // a flat "Dividends ▸ BHP" line is that account itself.
            let components = line.fullName.components(separatedBy: ":")
            let isLeafClass = name.contains("frank") || name.contains("imputation")
            let security = isLeafClass
                ? components.dropLast().last ?? line.name
                : line.name
            var entry = bySecurity[security] ?? DividendBreakdown.Security(name: security)
            if name.contains("unfranked") { entry.unfranked += line.amount }
            else if name.contains("frank") { entry.franked += line.amount }
            else if name.contains("imputation") { entry.imputation += line.amount }
            else { entry.other += line.amount }
            bySecurity[security] = entry
        }
        return DividendBreakdown(currencyCode: statement.currencyCode,
                                 securities: bySecurity.values.sorted { $0.name < $1.name })
    }

    /// The Dividend & Franking summary, as a report. `nil` when the book
    /// records no dividend income.
    func dividendFrankingDocument(from: Date, to: Date, periodLabel: String) -> ReportDocument? {
        guard let breakdown = dividendBreakdown(from: from, to: to) else { return nil }
        let franked = breakdown.franked
        let unfranked = breakdown.unfranked
        let imputation = breakdown.credits

        func rows(_ keyPath: KeyPath<DividendBreakdown.Security, Decimal>) -> [ReportDocumentRow] {
            breakdown.securities.compactMap { entry in
                let amount = entry[keyPath: keyPath]
                return amount == 0 ? nil : ReportDocumentRow(label: entry.name, amount: amount)
            }
        }

        return ReportDocument(
            title: String(localized: "Dividends & Franking"),
            periodLabel: periodLabel,
            currencyCode: breakdown.currencyCode,
            kpis: [
                ReportKPI(label: String(localized: "Franked"), amount: franked),
                ReportKPI(label: String(localized: "Unfranked"), amount: unfranked),
                ReportKPI(label: String(localized: "Franking credits"), amount: imputation),
            ],
            chart: nil,
            sections: [
                ReportDocumentSection(title: String(localized: "Franked dividends"), rows: rows(\.franked),
                                      total: (String(localized: "Total franked"), franked)),
                ReportDocumentSection(
                    title: String(localized: "Unfranked dividends"),
                    rows: rows(\.unfranked) + rows(\.other),
                    total: (String(localized: "Total unfranked"), unfranked)),
                ReportDocumentSection(title: String(localized: "Franking (imputation) credits"),
                                      rows: rows(\.imputation),
                                      total: (String(localized: "Total credits"), imputation)),
                ReportDocumentSection(
                    title: String(localized: "Grossed-up total"),
                    rows: [],
                    total: (String(localized: "Dividends plus credits"), franked + unfranked + imputation)),
            ].filter { !$0.rows.isEmpty || $0.total != nil },
            notes: [String(localized: "Classified by account name under the Dividends income tree (Franked / Unfranked / Imputation Credit), the same shape the app books dividend statements into.")],
            facts: nil)
    }
}
