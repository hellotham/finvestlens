//
//  BudgetRenderers.swift
//  FinvestLens — CLI
//
//  The `budget` command's four-column comparison and the `--budget` family's
//  effect on balance/register (docs/ledger-cli-reference.md §8), plus
//  `--forecast`'s generated postings and the `xact` draft generator.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange

public enum BudgetRenderers {

    /// The templates a source offers: a journal's `~` entries, else the
    /// book's own Budgets collection.
    public static func templates(book: Book, extras: SourceExtras, today: Date) -> [BudgetTemplate] {
        let fromJournal = PeriodicEntries.templates(from: extras, today: today)
        return fromJournal.isEmpty
            ? PeriodicEntries.templates(fromBook: book, today: today)
            : fromJournal
    }

    /// `budget`: actual, budgeted, remaining, and percent used per account.
    public static func budget(_ pipeline: ReportPipeline, book: Book,
                              extras: SourceExtras) -> String {
        let today = pipeline.request.today
        let templates = templates(book: book, extras: extras, today: today)
        guard !templates.isEmpty else {
            return "No periodic transactions or budgets to compare against.\n"
        }
        let bounds = pipeline.window
        let postings = pipeline.postings()
        let begin = bounds.begin ?? postings.first?.date ?? today
        let end = bounds.end ?? PeriodExpression.utc
            .date(byAdding: .day, value: 1, to: postings.last?.date ?? today)!

        let budgeted = PeriodicEntries.budgeted(templates, begin: begin, end: end)
        var actuals: [String: [String: Decimal]] = [:]
        for posting in postings {
            guard let account = posting.account else { continue }
            actuals[account.fullName, default: [:]][posting.commodity.mnemonic, default: 0]
                += posting.amount
        }

        var rows: [(String, Decimal, Decimal, String)] = []
        for account in Set(budgeted.keys).union(actuals.keys).sorted() {
            // Sorted, not `.keys.first`: a dictionary's order is not stable,
            // and the chosen commodity picks the row's whole column.
            let commodity = (budgeted[account]?.keys.sorted().first
                ?? actuals[account]?.keys.sorted().first) ?? book.baseCurrency.mnemonic
            let planned = budgeted[account]?[commodity] ?? 0
            let actual = actuals[account]?[commodity] ?? 0
            // Ledger's three modes: budgeted only (the default), the
            // unbudgeted remainder, or both.
            let options = pipeline.request.options
            if options.unbudgeted {
                guard planned == 0, actual != 0 else { continue }
            } else if options.addBudget {
                guard planned != 0 || actual != 0 else { continue }
            } else {
                guard planned != 0 else { continue }
            }
            rows.append((account, actual, planned, commodity))
        }
        guard !rows.isEmpty else { return "" }

        func commodity(_ mnemonic: String) -> Commodity {
            book.commodities.first { $0.mnemonic == mnemonic }
                ?? Commodity(namespace: .currency, mnemonic: mnemonic,
                             fullName: mnemonic, smallestFraction: 100)
        }

        // Cells are formatted first so the three money columns can share one
        // width wide enough for the widest of them.
        var totalActual = Decimal(0), totalPlanned = Decimal(0)
        var cells: [(actual: String, planned: String, remaining: String,
                     percent: String, account: String)] = []
        for (account, actual, planned, mnemonic) in rows {
            let unit = commodity(mnemonic)
            totalActual += actual
            totalPlanned += planned
            cells.append((Renderers.amount(actual, unit),
                          Renderers.amount(planned, unit),
                          Renderers.amount(planned - actual, unit),
                          planned == 0 ? "" : percentText(actual / planned),
                          account))
        }
        let base = book.baseCurrency
        cells.append((Renderers.amount(totalActual, base),
                      Renderers.amount(totalPlanned, base),
                      Renderers.amount(totalPlanned - totalActual, base),
                      totalPlanned == 0 ? "" : percentText(totalActual / totalPlanned), ""))
        let width = max(12, cells.flatMap { [$0.actual.count, $0.planned.count, $0.remaining.count] }
            .max() ?? 12)

        var lines = ["\(Renderers.pad("Actual", to: width)) \(Renderers.pad("Budgeted", to: width)) "
            + "\(Renderers.pad("Remaining", to: width)) \(Renderers.pad("Used", to: 5))  Account"]
        let separator = [width, width, width, 5]
            .map { String(repeating: "-", count: $0) }.joined(separator: " ")
        lines.append(separator)
        for cell in cells.dropLast() {
            lines.append(Renderers.pad(cell.actual, to: width) + " "
                + Renderers.pad(cell.planned, to: width) + " "
                + Renderers.pad(cell.remaining, to: width) + " "
                + Renderers.pad(cell.percent, to: 5) + "  " + cell.account)
        }
        lines.append(separator)
        if let total = cells.last {
            lines.append(Renderers.pad(total.actual, to: width) + " "
                + Renderers.pad(total.planned, to: width) + " "
                + Renderers.pad(total.remaining, to: width) + " "
                + Renderers.pad(total.percent, to: 5))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func percentText(_ fraction: Decimal) -> String {
        let percent = NSDecimalNumber(decimal: fraction * 100).doubleValue
        return String(format: "%.0f%%", percent.isFinite ? percent : 0)
    }

    /// `xact [DATE] PAYEE [ACCOUNT-REGEX] AMOUNT …`: a draft transaction
    /// modelled on the most recent transaction matching PAYEE, with the given
    /// amounts substituted. The draft is printed, never saved — the CLI does
    /// not write (design NG-L3); paste it into a journal or the app.
    public static func xact(_ arguments: [String], book: Book, today: Date) -> (String, Int32) {
        var terms = arguments
        guard !terms.isEmpty else {
            return ("finlens: xact needs a payee (try 'xact [DATE] PAYEE [ACCOUNT] AMOUNT')\n", 1)
        }

        var date = today
        if terms[0].contains("/") || terms[0].contains("-"),
           let parsed = PeriodExpression.date(terms[0], today: today) {
            date = parsed
            terms.removeFirst()
        }
        guard !terms.isEmpty else { return ("finlens: xact needs a payee\n", 1) }
        let payeePattern = terms.removeFirst()

        let matcher = RegexMatcher(payeePattern)
        guard let template = book.transactions
            .filter({ matcher.matches($0.transactionDescription) })
            .max(by: { $0.datePosted < $1.datePosted }) else {
            return ("finlens: no earlier transaction matches '\(payeePattern)'\n", 1)
        }

        // The rest is a list of amounts, each optionally preceded by an
        // account regex saying which leg it replaces.
        var overrides: [(pattern: String?, amount: Decimal)] = []
        var pendingAccount: String?
        for term in terms {
            if let amount = decimal(term) {
                overrides.append((pendingAccount, amount))
                pendingAccount = nil
            } else {
                pendingAccount = term
            }
        }

        // The legs, in transaction order, minus the one that will balance.
        let legs = template.splits.compactMap { split -> (account: String, value: Decimal)? in
            guard let account = split.account else { return nil }
            return (account.fullName, split.value)
        }
        guard legs.count >= 2 else {
            return ("finlens: '\(template.transactionDescription)' has too few postings to copy\n", 1)
        }
        // The funding leg is the most negative one, as in the template.
        let fundingIndex = legs.indices.min { legs[$0].value < legs[$1].value } ?? legs.count - 1

        var amounts = legs.map(\.value)
        var unmatched: [Decimal] = []
        for override in overrides {
            let target = override.pattern.flatMap { pattern -> Int? in
                let matcher = RegexMatcher(pattern)
                return legs.indices.first { matcher.matches(legs[$0].account) }
            }
            if let target { amounts[target] = override.amount } else { unmatched.append(override.amount) }
        }
        // Bare amounts fill the non-funding legs in order, as ledger does.
        var queue = unmatched[...]
        for index in legs.indices where index != fundingIndex {
            guard let next = queue.first else { break }
            amounts[index] = next
            queue = queue.dropFirst()
        }

        var journal = LedgerJournal()
        journal.styles = LedgerExport.styles(for: book)
        var entry = LedgerTransaction(date: date, payee: template.transactionDescription)
        for index in legs.indices {
            var posting = LedgerPosting(account: legs[index].account)
            // The funding leg is left elided so the draft always balances.
            if index != fundingIndex {
                posting.amount = LedgerAmount(commodity: template.currency.mnemonic,
                                              quantity: amounts[index])
            }
            entry.postings.append(posting)
        }
        journal.transactions = [entry]
        return (LedgerWriter.write(journal), 0)
    }

    static func decimal(_ text: String) -> Decimal? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        guard cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil else {
            return nil
        }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}
