//
//  PeriodicEntries.swift
//  FinvestLens — CLI
//
//  Ledger's `~ PERIOD` entries are budget/forecast templates, inert until a
//  flag activates them (docs/ledger-cli-reference.md §8). The parser keeps
//  them raw in `SourceExtras`; this file turns them into concrete postings
//  for `--budget`, `--add-budget`, `--unbudgeted`, `--forecast`, and the
//  `budget` command. A FinvestLens book has no `~` entries, so its Budgets
//  collection (book KVP) is offered as the same shape.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange

/// One template: a period plus the amounts it posts each time it fires.
public struct BudgetTemplate: Sendable {
    public var period: ResolvedPeriod
    /// account full name → amount per occurrence, in that posting's commodity.
    public var postings: [(account: String, amount: Decimal, commodity: String)]

    public init(period: ResolvedPeriod,
                postings: [(account: String, amount: Decimal, commodity: String)]) {
        self.period = period
        self.postings = postings
    }
}

public enum PeriodicEntries {

    /// Reads the `~ PERIOD` entries a journal carried into templates.
    public static func templates(from extras: SourceExtras, today: Date) -> [BudgetTemplate] {
        var result: [BudgetTemplate] = []
        for journal in extras.journals {
            for entry in journal.periodicEntries {
                let header = entry.header.drop(while: { $0 == "~" })
                    .trimmingCharacters(in: .whitespaces)
                let period = PeriodExpression.parse(header, today: today)
                guard period.interval != nil else { continue }

                // Re-parse the body as a transaction so the posting grammar
                // (elision, costs, virtuals) is the codec's, not a second copy.
                let body = ([("2000/01/01 budget")] + entry.lines).joined(separator: "\n")
                let parsed = LedgerParser.parse(text: body, fileName: "periodic", today: today)
                guard let transaction = parsed.journal.transactions.first else { continue }

                var postings: [(String, Decimal, String)] = []
                for posting in transaction.postings {
                    for amount in posting.resolvedAmounts where amount.quantity != 0 {
                        postings.append((posting.account, amount.quantity, amount.commodity))
                    }
                }
                guard !postings.isEmpty else { continue }
                result.append(BudgetTemplate(period: period, postings: postings))
            }
        }
        return result
    }

    /// A FinvestLens book's own budget, as a monthly template — so
    /// `--budget` works on a `.finvestlens` source too. Book budgets are named
    /// *alternatives* (GnuCash's model), so only the first is used: summing
    /// "2025 Budget" and "2026 Budget" would double every line.
    public static func templates(fromBook book: Book, today: Date) -> [BudgetTemplate] {
        guard case let .string(json)? = book.kvp[BookKvpKeys.budgets],
              let data = json.data(using: .utf8),
              let budgets = try? JSONDecoder().decode([Budget].self, from: data),
              let budget = budgets.first
        else { return [] }

        var postings: [(String, Decimal, String)] = []
        for line in budget.lines {
            guard let account = book.account(with: line.accountGUID),
                  line.amount != 0 else { continue }
            postings.append((account.fullName, line.amount, account.commodity.mnemonic))
        }
        guard !postings.isEmpty else { return [] }
        return [BudgetTemplate(period: ResolvedPeriod(interval: .monthly), postings: postings)]
    }

    /// Budgeted amounts per account over `[begin, end)`: one occurrence per
    /// interval bucket the template's own bounds allow.
    public static func budgeted(_ templates: [BudgetTemplate],
                                begin: Date, end: Date)
        -> [String: [String: Decimal]] {
        var totals: [String: [String: Decimal]] = [:]
        for template in templates {
            guard let interval = template.period.interval else { continue }
            let start = max(begin, template.period.begin ?? begin)
            let finish = min(end, template.period.end ?? end)
            guard start < finish else { continue }
            let occurrences = PeriodExpression.buckets(interval: interval,
                                                       from: start, to: finish).count
            guard occurrences > 0 else { continue }
            for posting in template.postings {
                totals[posting.account, default: [:]][posting.commodity, default: 0]
                    += posting.amount * Decimal(occurrences)
            }
        }
        return totals
    }

    /// Forecast postings: keep firing each template past the last real
    /// posting while `while` holds (by date), capped by `years`.
    public static func forecast(_ templates: [BudgetTemplate],
                                from start: Date, limit: Date,
                                today: Date) -> [(date: Date, account: String,
                                                  amount: Decimal, commodity: String)] {
        var generated: [(Date, String, Decimal, String)] = []
        for template in templates {
            guard let interval = template.period.interval else { continue }
            let begin = max(start, template.period.begin ?? start)
            let finish = min(limit, template.period.end ?? limit)
            guard begin < finish else { continue }
            for bucket in PeriodExpression.buckets(interval: interval, from: begin, to: finish) {
                for posting in template.postings {
                    generated.append((bucket.start, posting.account,
                                      posting.amount, posting.commodity))
                }
            }
        }
        return generated.sorted { $0.0 < $1.0 }
    }
}
