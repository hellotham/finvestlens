//
//  AppModel+InlineEdit.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  In-place register editing (GnuCash-style): the selected row's date,
//  description, transfer account and amount edit directly in the table.
//  Money-touching edits are limited to simple two-leg same-currency
//  transactions — anything richer (splits, securities, multi-currency)
//  belongs in the transaction editor, where every leg is visible.
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    /// Whether a row's transaction is simple enough for inline edits that touch
    /// money: exactly two legs, both in the transaction currency.
    public func isSimpleTransfer(splitID: GncGUID) -> Bool {
        guard let book, let split = book.split(with: splitID),
              let txn = split.transaction else { return false }
        return txn.splits.count == 2
            && txn.splits.allSatisfy { $0.account?.commodity == txn.currency }
    }

    // The per-field inline setters that lived here — `inlineSetDate`,
    // `inlineSetDescription`, `inlineSetNotes`, `inlineSetMemo`,
    // `inlineSetLegAccount`, `inlineSetAmount` and `inlineSetTransfer`, each in
    // split- and transaction-keyed spellings — were **deleted**, not moved.
    //
    // They were the register's editing API until the sheet redesign, which
    // commits a whole `TransactionDraft` through `updateTransaction`
    // (`RegisterSheet.swift`). Nothing in the app has called one since; only
    // their own tests did, which is how ten public methods on the app's central
    // model went on looking maintained. The invariants they carried — a
    // money-touching edit only on a two-leg same-currency transaction, the
    // counter leg rebalanced with it — are `updateTransaction`'s now, and are
    // covered there.
    //
    // `isSimpleTransfer(splitID:)` above stays: the register and the bulk-edit
    // sheet both ask it.

    // MARK: Bulk edit

    /// A uniform change to apply across a selection: `nil` fields are left as
    /// they are. Set string fields apply verbatim (empty clears memo/notes; an
    /// empty description is ignored — a transaction needs one).
    public struct BulkTransactionEdit: Sendable, Equatable {
        public var date: Date?
        public var description: String?
        public var notes: String?
        public var memo: String?
        public var reconcile: ReconcileState?
        public var transferAccountID: GncGUID?

        public var isEmpty: Bool {
            date == nil && description == nil && notes == nil && memo == nil
                && reconcile == nil && transferAccountID == nil
        }

        public init() {}
    }

    /// Applies `edit` uniformly to every selected row: transaction fields
    /// (date, description, notes) once per transaction; split fields (memo,
    /// reconcile) to each selected row's leg; transfer by moving the counter
    /// leg of simple two-leg transactions (others are counted, not touched).
    /// One undoable action.
    @discardableResult
    public func applyBulkEdit(_ edit: BulkTransactionEdit,
                              toSplits splitIDs: Set<GncGUID>) -> (edited: Int, transferSkipped: Int) {
        guard let book, !edit.isEmpty else { return (0, 0) }
        let splits = splitIDs.compactMap { book.split(with: $0) }
        var seen = Set<GncGUID>()
        var transactions: [Transaction] = []
        for split in splits {
            if let txn = split.transaction, seen.insert(txn.guid).inserted {
                transactions.append(txn)
            }
        }
        guard !transactions.isEmpty else { return (0, 0) }

        let transferAccount = edit.transferAccountID.flatMap { book.account(with: $0) }
        let description = edit.description?.trimmingCharacters(in: .whitespaces)
        var transferSkipped = 0

        editing(transactions.map(\.guid), named: "Bulk Edit Transactions") {
            for txn in transactions {
                if let date = edit.date { txn.datePosted = date }
                if let description, !description.isEmpty { txn.transactionDescription = description }
                if let notes = edit.notes { txn.notes = notes.trimmingCharacters(in: .whitespaces) }
            }
            for split in splits {
                if let memo = edit.memo { split.memo = memo.trimmingCharacters(in: .whitespaces) }
                if let state = edit.reconcile, split.reconcileState != state {
                    split.reconcileState = state
                    split.reconcileDate = state == .reconciled ? Date() : split.reconcileDate
                }
                if let account = transferAccount {
                    guard let txn = split.transaction, txn.splits.count == 2,
                          txn.splits.allSatisfy({ $0.account?.commodity == txn.currency }),
                          account.commodity == txn.currency,
                          let other = txn.splits.first(where: { $0 !== split })
                    else { transferSkipped += 1; continue }
                    if other.account !== account { other.account = account }
                }
            }
        }
        return (transactions.count, transferSkipped)
    }

}
