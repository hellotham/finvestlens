//
//  BillReminders.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The state of a scheduled bill relative to today (`FR-BILL-01`).
public enum BillStatus: String, Sendable {
    case paid, overdue, dueSoon, upcoming
}

/// A single occurrence of a scheduled bill/deposit on the financial calendar
/// (`FR-PLAN-01`, `FR-BILL-01`).
public struct BillReminder: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var scheduledID: GncGUID
    public var name: String
    public var dueDate: Date
    /// Expected outflow magnitude (positive), in the schedule's currency.
    public var amount: Decimal
    public var status: BillStatus
}

public extension FinancialReports {

    /// Occurrences of scheduled outflows in `[from, to]`, each classified paid /
    /// overdue / due-soon / upcoming relative to `asOf`. "Paid" is inferred from
    /// a posted transaction with the same name within `graceDays` of the due
    /// date (`FR-BILL-01`).
    static func billReminders(
        _ book: Book,
        scheduled: [ScheduledTransaction],
        from: Date, to: Date, asOf: Date,
        dueSoonDays: Int = 7, graceDays: Int = 3
    ) -> [BillReminder] {
        var reminders: [BillReminder] = []
        let grace = TimeInterval(graceDays) * 86_400
        let dueSoon = TimeInterval(dueSoonDays) * 86_400
        let calendar = Calendar.current

        // One pass over the book: transactions bucketed by posting day, so
        // each occurrence's paid-check probes a handful of day buckets instead
        // of scanning every transaction — the dashboard evaluates this report
        // several times per body pass on a 100k-transaction book.
        var byDay: [Date: [Transaction]] = [:]
        let windowLower = from.addingTimeInterval(-grace)
        let windowUpper = to.addingTimeInterval(grace)
        for txn in book.transactions
        where txn.datePosted >= windowLower && txn.datePosted <= windowUpper {
            byDay[calendar.startOfDay(for: txn.datePosted), default: []].append(txn)
        }
        func candidates(near date: Date) -> [Transaction] {
            var result: [Transaction] = []
            var day = calendar.startOfDay(for: date.addingTimeInterval(-grace))
            let end = date.addingTimeInterval(grace)
            while day <= end {
                if let bucket = byDay[day] { result.append(contentsOf: bucket) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return result
        }
        let today = calendar.startOfDay(for: asOf)

        for schedule in scheduled where schedule.isEnabled {
            let amount = outflowAmount(schedule, book: book)
            guard amount > 0 else { continue }
            // Bound the walk with `since:` rather than filtering afterwards.
            // `limit` caps the dates *returned*, so asking for every occurrence
            // since the schedule began and discarding the old ones spent the
            // whole budget on history: a daily bill started more than 5,000
            // days ago returned only its first 5,000 dates, every one of them
            // older than `from`, and the reminder list came back empty. One
            // second before `from`, because `since` is exclusive.
            let dates = schedule.recurrence.occurrences(since: from.addingTimeInterval(-1), through: to)
            for date in dates {
                let status: BillStatus
                if isPaid(name: schedule.name, description: schedule.transactionDescription,
                          billID: schedule.id, expected: amount,
                          near: date, grace: grace, candidates: candidates(near: date)) {
                    status = .paid
                } else if calendar.startOfDay(for: date) < today {
                    // Day granularity: a bill due today is *due*, not overdue.
                    // Occurrences carry the schedule's time-of-day, and an
                    // instant comparison against a live clock flipped them to
                    // a critical "overdue" partway through their own due day.
                    status = .overdue
                } else if date <= asOf.addingTimeInterval(dueSoon) {
                    status = .dueSoon
                } else {
                    status = .upcoming
                }
                reminders.append(BillReminder(
                    id: UUID(), scheduledID: schedule.id, name: schedule.name,
                    dueDate: date, amount: amount, status: status))
            }
        }
        return reminders.sorted { $0.dueDate < $1.dueDate }
    }

    /// Sum of the positive postings to expense/liability accounts (the bill's
    /// cost); falls back to the largest split magnitude.
    private static func outflowAmount(_ schedule: ScheduledTransaction, book: Book) -> Decimal {
        var outflow = Decimal(0)
        for split in schedule.splits {
            guard let type = book.account(with: split.accountGUID)?.type else { continue }
            if (type == .expense || type == .liability || type == .credit), split.value > 0 {
                outflow += split.value
            }
        }
        if outflow > 0 { return outflow }
        return schedule.splits.map(\.value).map(abs).max() ?? 0
    }

    /// The KVP slot a rule's link-to-bill action stamps on a payment
    /// transaction: the settled schedule's GUID. An exact link outranks the
    /// description heuristic below.
    public static let billLinkKey = "finvestlens/bill-id"

    /// How far a payment may drift from the bill's expected amount and still
    /// settle it by name (utilities vary month to month; ±25% covers that
    /// while a $5 transaction named like the rent no longer marks an $800
    /// bill paid — `FR-BILL-01`'s expected-amount matching).
    static let amountTolerance = Decimal(string: "0.25")!

    private static func isPaid(name: String, description: String, billID: GncGUID,
                               expected: Decimal, near date: Date,
                               grace: TimeInterval, candidates: [Transaction]) -> Bool {
        let lower = date.addingTimeInterval(-grace)
        let upper = date.addingTimeInterval(grace)
        let name = name.trimmingCharacters(in: .whitespaces)
        let description = description.trimmingCharacters(in: .whitespaces)
        return candidates.contains { txn in
            guard txn.datePosted >= lower, txn.datePosted <= upper else { return false }
            // Exact: a rule linked this payment to the bill (FR-RULE-01
            // link-to-bill) — no name or amount matching required.
            if case let .guid(linked)? = txn.kvp[billLinkKey], linked == billID {
                return true
            }
            // Heuristic: a NON-EMPTY matching description. Comparing empty
            // against empty returned `.orderedSame`, so a description-less
            // schedule was marked paid by any blank-description bank row in
            // the grace window and never raised overdue.
            let d = txn.transactionDescription
            let nameMatches = (!name.isEmpty && d.caseInsensitiveCompare(name) == .orderedSame)
                || (!description.isEmpty && d.caseInsensitiveCompare(description) == .orderedSame)
            guard nameMatches else { return false }
            // …and agreeing money (skip only when the schedule's expected
            // amount is unknown).
            guard expected > 0 else { return true }
            let magnitude = txn.splits.map { abs($0.value) }.max() ?? 0
            return abs(magnitude - expected) <= expected * Self.amountTolerance
        }
    }
}
