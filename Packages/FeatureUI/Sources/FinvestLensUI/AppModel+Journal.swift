//
//  AppModel+Journal.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One line of a journal register: either a transaction's heading or one of
/// its legs. A journal is a register with several rows per transaction (as in
/// GnuCash), so it is a flat list of uniform rows rather than nested sections —
/// which is what lets it be a `Table`, and lets a jump to either end be
/// instant no matter how far away it is.
public struct JournalRow: Identifiable, Hashable, Sendable {
    /// The transaction's GUID for a heading, the split's for a leg.
    public let id: GncGUID
    public var transactionID: GncGUID
    public var isHeading: Bool
    /// Set on headings only.
    public var date: Date?
    /// The description on a heading, the account name on a leg.
    public var text: String
    /// Set on legs only.
    public var amount: Decimal?
    public var currencyCode: String
    /// `true` when this leg posts to the register's focused account.
    public var isFocusAccount: Bool
    /// The transaction's notes (headings only) — shown under the description in
    /// the journal styles.
    public var notes: String = ""
    /// The split's memo (legs only) — shown under the account name.
    public var memo: String = ""
    /// The split's action (legs only) — GnuCash's per-leg Action field.
    public var action: String = ""
    /// The split's reconcile glyph (legs only): n/c/y/f/v, as in the Basic
    /// register — empty on headings.
    public var reconcile: String = ""
    /// Whether the transaction carries a document link (headings only).
    public var hasDocument = false
    /// The focused account's balance as of this leg (single-account journals
    /// only; `nil` on headings, other accounts' legs, and the general ledger).
    /// Gives the journal styles the same Balance column as Basic, so switching
    /// styles doesn't reflow the trailing columns.
    public var runningBalance: Decimal?
}

/// One row of the Basic / Auto-Split register table: a transaction row (the
/// focus account's split, exactly as Basic shows it), or — in Auto-Split — one
/// leg of the expanded transaction shown beneath it.
public struct AutoSplitRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    /// The Basic register row; `nil` for an expanded leg.
    public let main: RegisterRow?
    /// Leg fields (empty on main rows).
    public let legAccount: String
    public let legMemo: String
    public let legAction: String
    public let legReconcile: String
    public let legAmount: Decimal
    public let legCurrencyCode: String

    init(main: RegisterRow) {
        id = main.id
        self.main = main
        legAccount = ""
        legMemo = ""
        legAction = ""
        legReconcile = ""
        legAmount = 0
        legCurrencyCode = ""
    }

    init(legID: GncGUID, account: String, memo: String, action: String,
         reconcile: String, amount: Decimal, currencyCode: String) {
        id = legID
        main = nil
        legAccount = account
        legMemo = memo
        legAction = action
        legReconcile = reconcile
        legAmount = amount
        legCurrencyCode = currencyCode
    }

    // Sort handles for the table's sortable headers. Never applied to reorder
    // rows — the model sorts; see `tableSortOrder` in RegisterView.
    public var date: Date { main?.date ?? .distantFuture }
    public var description: String { main?.description ?? legAccount }
    public var amount: Decimal { main?.amount ?? legAmount }
}

@MainActor
extension AppModel {

    /// Every row of the journal for `accountID` (the general ledger when it is
    /// `nil`), oldest first: a heading per transaction followed by its legs.
    ///
    /// Cached until the book changes. Building ~140k rows for the whole book is
    /// a fraction of a second once, but doing it per body pass is not — and the
    /// rows are uniform, so the whole journal can be a `Table` and no longer
    /// needs to be windowed to stay responsive.
    public func journalRows(forAccountID accountID: GncGUID?) -> [JournalRow] {
        if let cached = journalRowCache[accountID] { return cached }
        guard let book else { return [] }
        let focusSet = journalFocusSet(forAccountID: accountID)
        func inFocus(_ split: Split) -> Bool {
            split.account.map { focusSet.contains(ObjectIdentifier($0)) } ?? false
        }

        // Balances accumulate in canonical date order over *every* focus split —
        // before the filter hides transactions and before any sort rearranges
        // them, exactly the Basic register's rule (a hidden or reordered split
        // still moved the account). Dropped for a mixed-commodity subtree, where
        // the sum would be a number of nothing.
        let trackBalance: Bool = {
            guard !focusSet.isEmpty, let accountID,
                  let account = book.account(with: accountID) else { return false }
            guard registerIncludesSubaccounts else { return true }
            return Set(([account] + account.descendants).map(\.commodity)).count == 1
        }()
        var balances: [GncGUID: Decimal] = [:]
        if trackBalance {
            var running = Decimal(0)
            let dated = book.transactions.sorted {
                Transaction.canonicalOrder($0, action: "", $1, action: "") < 0
            }
            for txn in dated {
                for split in txn.splits where inFocus(split) {
                    if split.reconcileState != .voided { running += split.quantity }
                    balances[split.guid] = running
                }
            }
        }

        var rows: [JournalRow] = []
        rows.reserveCapacity(journalTransactions(forAccountID: accountID).count * 3)
        for txn in journalTransactions(forAccountID: accountID) {
            rows.append(JournalRow(
                id: txn.guid, transactionID: txn.guid, isHeading: true,
                date: txn.datePosted, text: txn.transactionDescription,
                amount: nil, currencyCode: txn.currency.mnemonic, isFocusAccount: false,
                notes: txn.notes, hasDocument: txn.documentLink != nil))
            for split in txn.splits {
                let isFocus = inFocus(split)
                rows.append(JournalRow(
                    id: split.guid, transactionID: txn.guid, isHeading: false,
                    date: nil, text: split.account?.name ?? "—",
                    amount: split.value, currencyCode: txn.currency.mnemonic,
                    isFocusAccount: isFocus,
                    memo: split.memo, action: split.action,
                    reconcile: split.reconcileState.rawValue,
                    runningBalance: isFocus ? balances[split.guid] : nil))
            }
        }
        journalRowCache[accountID] = rows
        return rows
    }

    /// The leg rows of one transaction — what an opened-out line draws beneath
    /// itself.
    ///
    /// Per transaction, on demand, rather than building every register row's
    /// legs up front: only the handful of rows actually on screen ask, and a
    /// transaction has a handful of splits. Building them for the whole
    /// register cost an O(rows) pass on every single view update, which on a
    /// 140,000-row register is what made selecting a row feel slow.
    ///
    /// Every leg is returned, the focus account's included — an opened-out line
    /// is the transaction journal's view of the transaction, and hiding the leg
    /// you are looking from makes a two-split transaction look one-sided.
    public func legRows(ofTransaction id: GncGUID) -> [AutoSplitRow] {
        guard let book, let txn = book.transaction(with: id) else { return [] }
        return txn.splits.map { split in
            AutoSplitRow(legID: split.guid,
                         account: split.account?.fullName ?? "—",
                         memo: split.memo,
                         action: split.action,
                         reconcile: split.reconcileState.rawValue,
                         amount: split.value,
                         currencyCode: txn.currency.mnemonic)
        }
    }

    /// GnuCash's Auto-Split Ledger (`FR-REG-03`): exactly the Basic register —
    /// same rows, columns and running balance — with the transaction you are
    /// looking at opened out into its legs beneath its row.
    ///
    /// A main row is a ``RegisterRow`` (the focus account's split); a leg row is
    /// one split of the expanded transaction. Legs posting to accounts already
    /// shown as main rows are skipped — they are on screen, and a split GUID
    /// can only appear once in the table.
    public func autoSplitRows(expanding transactionID: GncGUID?,
                              expandAll: Bool = false) -> [AutoSplitRow] {
        cachedAutoSplitRows(expanding: transactionID, all: expandAll) {
            let rows = registerRows
            let mainIDs = Set(rows.map(\.id))

            func legs(of txn: Transaction) -> [AutoSplitRow] {
                txn.splits.compactMap { split in
                    guard !mainIDs.contains(split.guid) else { return nil }
                    return AutoSplitRow(
                        legID: split.guid,
                        account: split.account?.fullName ?? "—",
                        memo: split.memo,
                        action: split.action,
                        reconcile: split.reconcileState.rawValue,
                        amount: split.value,
                        currencyCode: txn.currency.mnemonic)
                }
            }

            // Show All Splits: every transaction opened out, once — the
            // journal read, in the same table. A transaction with several
            // focus legs (a subtree register) expands under its first row.
            if expandAll, let book {
                var expanded = Set<GncGUID>()
                var out: [AutoSplitRow] = []
                out.reserveCapacity(rows.count * 3)
                for row in rows {
                    out.append(AutoSplitRow(main: row))
                    guard let txn = book.split(with: row.id)?.transaction,
                          expanded.insert(txn.guid).inserted else { continue }
                    out.append(contentsOf: legs(of: txn))
                }
                return out
            }

            guard let transactionID, let txn = book?.transaction(with: transactionID) else {
                return rows.map(AutoSplitRow.init(main:))
            }
            let expandedIDs = Set(txn.splits.map(\.guid))
            var out: [AutoSplitRow] = []
            out.reserveCapacity(rows.count + txn.splits.count)
            var inserted = false
            for row in rows {
                out.append(AutoSplitRow(main: row))
                if !inserted, expandedIDs.contains(row.id) {
                    inserted = true
                    out.append(contentsOf: legs(of: txn))
                }
            }
            return out
        }
    }

    /// The set of accounts a single-account journal is *about*: the account,
    /// plus its subtree when Subaccounts is on. Empty for the general ledger.
    private func journalFocusSet(forAccountID accountID: GncGUID?) -> Set<ObjectIdentifier> {
        guard let accountID, let book, let account = book.account(with: accountID) else { return [] }
        let accounts = registerIncludesSubaccounts ? [account] + account.descendants : [account]
        return Set(accounts.map(ObjectIdentifier.init))
    }

    /// Transactions for `accountID` (its postings), or every transaction when
    /// `accountID` is `nil` (general ledger). Cached until the book — or a
    /// register view setting — changes: filtering and sorting the whole book on
    /// every body pass is what made the general ledger unusable.
    ///
    /// A single-account journal honours the register's Subaccounts, Filter and
    /// Sort settings, applied per *transaction*: a transaction is shown when any
    /// of its focus-account legs passes the filter, and sorts by its own fields
    /// (amount/memo meaning the focus legs' net value / first memo). The general
    /// ledger is always the whole book, oldest first.
    func journalTransactions(forAccountID accountID: GncGUID?) -> [Transaction] {
        if let cached = journalTransactionCache[accountID] { return cached }
        guard let book else { return [] }
        let focusSet = journalFocusSet(forAccountID: accountID)

        func inFocus(_ split: Split) -> Bool {
            split.account.map { focusSet.contains(ObjectIdentifier($0)) } ?? false
        }

        var transactions = book.transactions
            .filter { txn in
                focusSet.isEmpty || txn.splits.contains(where: inFocus)
            }
            .sorted { $0.datePosted < $1.datePosted }

        if !focusSet.isEmpty {
            let filter = registerFilter
            if !filter.isShowingEverything {
                let calendar = Calendar.current
                let start = filter.startDate.map { calendar.startOfDay(for: $0) }
                let end = filter.endDate.map { calendar.startOfDay(for: $0) }
                transactions = transactions.filter { txn in
                    let day = calendar.startOfDay(for: txn.datePosted)
                    if let start, day < start { return false }
                    if let end, day > end { return false }
                    return txn.splits.contains { inFocus($0) && filter.statuses.contains($0.reconcileState) }
                }
            }

            func focusValue(_ txn: Transaction) -> Decimal {
                txn.splits.reduce(Decimal(0)) { $0 + (inFocus($1) ? $1.value : 0) }
            }
            switch registerSort {
            case .standard, .date:
                break   // already oldest first
            case .dateEntered:
                transactions.sort { $0.dateEntered < $1.dateEntered }
            case .number:
                transactions.sort { Transaction.numOrString($0.number, $1.number) < 0 }
            case .amount:
                transactions.sort { focusValue($0) < focusValue($1) }
            case .description:
                transactions.sort {
                    $0.transactionDescription.localizedCaseInsensitiveCompare($1.transactionDescription) == .orderedAscending
                }
            case .memo:
                func memo(_ txn: Transaction) -> String {
                    txn.splits.first(where: inFocus)?.memo ?? ""
                }
                transactions.sort { memo($0).localizedCaseInsensitiveCompare(memo($1)) == .orderedAscending }
            }
            if registerSortReversed { transactions.reverse() }
        }

        journalTransactionCache[accountID] = transactions
        return transactions
    }

}

// MARK: - Whole-book rows (P12/N6)

/// What a whole-book register row can say about a transaction.
///
/// The whole book is GnuCash's `GENERAL_JOURNAL`, and GnuCash is explicit that
/// it has **no anchoring split** — `gnc-split-reg.c:894`, in that comment
/// exactly. So the three things a single-account row takes from *its* split
/// have to come from the transaction instead:
///
/// - **Reconcile** — the flag every leg agrees on, or nothing where they
///   differ. A single-account row reads one split's state; here there is no
///   "one split", and a state the legs disagree about is not a fact.
/// - **Accounts** — where a single-account row names the *other* side
///   (`gnc_split_register_get_mxfrm_entry` takes `xaccSplitGetOtherSplit`),
///   with no anchor there is no other side. It names both, or falls back to the
///   register's existing "— Split —" for anything wider.
/// - **Total** — GnuCash fills the general journal's total cell from
///   `get_trans_total_value_subaccounts` rather than one split's amount
///   (`split-register-model.c:1650-1657`). The debit total is that number.
public struct WholeBookRowSummary: Sendable {
    public let reconcile: String
    public let accounts: String
    public let total: Decimal
}

@MainActor
extension AppModel {

    public func wholeBookRowSummary(ofTransaction id: GncGUID) -> WholeBookRowSummary {
        guard let txn = book?.transaction(with: id) else {
            return WholeBookRowSummary(reconcile: "", accounts: "", total: 0)
        }
        let splits = txn.splits

        let states = Set(splits.map(\.reconcileState))
        let reconcile = states.count == 1 ? (states.first?.rawValue ?? "") : ""

        // Debits first, so a two-legged row reads in the direction the money
        // moved rather than in storage order.
        let debits = splits.filter { $0.value > 0 }.compactMap { $0.account?.name }
        let credits = splits.filter { $0.value < 0 }.compactMap { $0.account?.name }
        let accounts: String
        if debits.count == 1, credits.count == 1 {
            accounts = "\(credits[0]) → \(debits[0])"
        } else if splits.count == 1 {
            // Not reachable through the app — `addTransaction` refuses
            // `.tooFewSplits` — but an imported GnuCash book can carry an
            // orphan split, and a row for one should name where it posted
            // rather than claim to be a split transaction.
            accounts = splits[0].account?.name ?? ""
        } else {
            // The same marker the single-account register already uses for a
            // transaction with more than one other side.
            accounts = "— Split —"
        }

        return WholeBookRowSummary(
            reconcile: reconcile,
            accounts: accounts,
            total: splits.filter { $0.value > 0 }.reduce(0) { $0 + $1.value })
    }
}
