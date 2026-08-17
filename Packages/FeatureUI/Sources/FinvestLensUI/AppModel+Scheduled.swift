//
//  AppModel+Scheduled.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    public func addScheduledTransaction(_ scheduled: ScheduledTransaction) {
        scheduledTransactions.append(scheduled)
        commitKvpCollections(named: "Add Scheduled Transaction")
    }

    /// Creates a scheduled transaction from one that already exists (GnuCash's
    /// Transaction ▸ Schedule…), and returns its id (`FR-SCH-01`).
    ///
    /// Most recurring transactions are noticed *after* the first one has been
    /// entered — you pay the rent, and then think to schedule it. So the source
    /// is the template: its description, currency, accounts, amounts and per-
    /// split memos, which is the whole of what makes the next one the same.
    ///
    /// The load-bearing part is `lastPosted`. It is seeded with the source's own
    /// posting date, so the schedule's first occurrence is the *next* one.
    /// Leaving it nil would make the transaction you copied immediately due, and
    /// the schedule's first act would be to post a duplicate of it.
    @discardableResult
    public func scheduleTransaction(_ id: GncGUID, period: RecurrencePeriod,
                                    interval: Int = 1, name: String? = nil,
                                    advanceCreateDays: Int = 0, advanceRemindDays: Int = 0) -> GncGUID? {
        guard let book, let txn = book.transaction(with: id) else { return nil }

        // Every leg needs an account, or the template cannot post: `post` bails
        // on a missing one and would leave a schedule that silently never fires.
        var splits: [ScheduledSplit] = []
        for split in txn.splits {
            guard let accountGUID = split.account?.guid else { return nil }
            splits.append(ScheduledSplit(accountGUID: accountGUID, value: split.value,
                                         memo: split.memo))
        }
        guard !splits.isEmpty else { return nil }

        let scheduled = ScheduledTransaction(
            name: name?.isEmpty == false ? name! : defaultScheduleName(for: txn),
            currency: txn.currency,
            description: txn.transactionDescription,
            recurrence: Recurrence(period: period, interval: interval,
                                   startDate: txn.datePosted),
            splits: splits,
            lastPosted: txn.datePosted,
            advanceCreateDays: advanceCreateDays,
            advanceRemindDays: advanceRemindDays)
        addScheduledTransaction(scheduled)
        return scheduled.id
    }

    /// A name for a schedule made from `txn` — its description, or something
    /// rather than nothing when it has none.
    private func defaultScheduleName(for txn: Transaction) -> String {
        let description = txn.transactionDescription.trimmingCharacters(in: .whitespaces)
        return description.isEmpty ? "Scheduled transaction" : description
    }

    public func deleteScheduledTransaction(_ id: GncGUID) {
        scheduledTransactions.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Scheduled Transaction")
    }

    /// Instances due to be entered up to `through` ("since last run").
    public func pendingScheduled(through: Date = Date()) -> [ScheduledTransactionService.PendingInstance] {
        ScheduledTransactionService.pending(scheduledTransactions, through: through)
    }

    /// Formula-variable names any *due* schedule needs values for before it can
    /// be posted (`FR-SCH-02`), sorted. Empty when no due template uses a
    /// variable formula — the common case.
    public func dueVariableNames(through: Date = Date()) -> [String] {
        var names = Set<String>()
        for sx in scheduledTransactions where !sx.dueDates(through: through).isEmpty {
            names.formUnion(sx.variableNames)
        }
        return names.sorted()
    }

    /// Posts every due instance up to `through`, advancing each schedule's
    /// `lastPosted`. `variables` binds any formula variables (`FR-SCH-02`).
    /// Returns the number of transactions created (`FR-SCH-03`).
    @discardableResult
    public func postDueScheduled(through: Date = Date(), variables: [String: Decimal] = [:]) -> Int {
        guard let book else { return 0 }
        var list = scheduledTransactions
        guard list.contains(where: { $0.isEnabled && !$0.dueDates(through: through).isEmpty })
        else { return 0 }
        var created = 0
        /// Schedules that refused to post — an unbalanced instance, typically a
        /// template whose formula this parser cannot evaluate.
        var blocked: [String] = []
        // ONE whole-book undoable action: the posted transactions and the
        // schedules' advanced `lastPosted` must rewind together. Registering
        // only the kvp restore left the transactions in the book — ⌘Z made
        // the same dates due again and the next post created duplicates.
        editingWholeBook(named: "Post Scheduled Transactions") {
            for index in list.indices {
                let dueDates = list[index].dueDates(through: through)
                // Post in chronological order and advance `lastPosted` only across the
                // contiguous prefix that actually posted. Stopping at the first failure
                // (e.g. an unbound formula variable) leaves that instance and the ones
                // after it to be retried, rather than silently skipping them.
                var postedThrough: Date?
                for date in dueDates {
                    guard ScheduledTransactionService.post(list[index], date: date, into: book, variables: variables) != nil
                    else {
                        // A refusal is permanent until the template is fixed:
                        // `lastPosted` does not advance, so this same date is
                        // due again next time and the schedule never moves. It
                        // used to fail here in total silence — the bill simply
                        // stopped appearing — which is the same invisible-stop
                        // failure the recurrence-horizon fix was written to
                        // remove. Name the schedule so it can be repaired.
                        blocked.append(list[index].name)
                        break
                    }
                    created += 1
                    postedThrough = date
                }
                if let postedThrough, (list[index].lastPosted ?? .distantPast) < postedThrough {
                    list[index].lastPosted = postedThrough
                }
            }
            if created > 0 {
                scheduledTransactions = list
                persistKvpCollections()   // lastPosted rides the same undo snapshot
            }
        }
        if !blocked.isEmpty {
            let names = Set(blocked).sorted().joined(separator: ", ")
            showToast(.failure, "Could not post \(names): the transaction does not balance. "
                      + "Check its amounts or formulas — it will stay due until it is fixed.")
        }
        return created
    }
}
