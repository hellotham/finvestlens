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
        journalCachesFollowSettings()
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
            Self.appendJournalBlock(of: txn, to: &rows, inFocus: inFocus, balances: balances)
        }
        journalRowCache[accountID] = rows
        if accountID == nil { ledgerBlockStarts = nil }
        return rows
    }

    /// A transaction's rows: its heading, then each leg.
    private static func appendJournalBlock(of txn: Transaction, to rows: inout [JournalRow],
                                           inFocus: (Split) -> Bool, balances: [GncGUID: Decimal]) {
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

    // MARK: Following an edit (P7)

    /// The register settings every journal follows; a cache built under
    /// other settings is dropped on the next ask.
    struct JournalSettings: Equatable {
        let sort: RegisterSort
        let reversed: Bool
        let filter: RegisterFilter
        let subaccounts: Bool
    }

    func journalCachesFollowSettings() {
        let current = JournalSettings(sort: registerSort, reversed: registerSortReversed,
                                      filter: registerFilter, subaccounts: registerIncludesSubaccounts)
        if journalSettings != current {
            dropJournalCaches()
            journalSettings = current
        }
    }

    func dropJournalCaches() {
        journalTransactionCache = [:]
        journalRowCache = [:]
        ledgerBlockStarts = nil
    }

    /// The journals after an edit. An account's own journal carries a running
    /// balance the edit may move on every later row, and is the size of one
    /// account: it goes, and is built again when asked for. The general
    /// ledger — every transaction, filtered and sorted, and ~150k rows on the
    /// reference book when they are built — is patched instead: each changed
    /// transaction taken out from where its old fields filed it, and put where
    /// its new ones file it (P7). The order is what every register surface
    /// draws the whole book from; the rows go with it when something built
    /// them. An edit that does not say what it changed, that changed accounts
    /// (rows name them), or that touched more than a few transactions — each
    /// patch moves everything after it — has it built again too.
    func followJournals(_ changes: EditChanges?) {
        journalCachesFollowSettings()
        guard let changes, !changes.accounts, changes.transactions.count <= 8,
              journalTransactionCache[nil] != nil,
              patchGeneralLedger(changes.transactions) else {
            dropJournalCaches()
            return
        }
        journalTransactionCache = journalTransactionCache.filter { $0.key == nil }
        journalRowCache = journalRowCache.filter { $0.key == nil }
    }

    /// `changed` applied to the general ledger's caches; `false` when it
    /// could not be — a transaction not where it was filed — and the caches
    /// must be built again.
    private func patchGeneralLedger(_ changed: [(before: Transaction?, live: Transaction?)]) -> Bool {
        // Out of the dictionaries while they change, so they can change in
        // place rather than be copied first. Until the 18 October review the
        // patch needed the rows as well — which only `journalRows` builds,
        // and nothing on screen asks for — so in the app it never ran: every
        // edit re-sorted the whole book on the next pass of All Transactions.
        guard let book, var order = journalTransactionCache.removeValue(forKey: nil) else { return false }
        let builtRows = journalRowCache.removeValue(forKey: nil)
        let hasRows = builtRows != nil
        var rows = builtRows ?? []
        var starts = hasRows ? (ledgerBlockStarts ?? rows.indices.filter { rows[$0].isHeading }) : []
        ledgerBlockStarts = nil
        guard !hasRows || starts.count == order.count else { return false }
        func blockEnd(_ index: Int) -> Int { index + 1 < starts.count ? starts[index + 1] : rows.count }

        // Out first, every one, found by who it is. A transaction changed in
        // place sits where its old fields filed it but already carries its
        // new ones, so no search by fields can be trusted to find it — or to
        // step over it while looking for another.
        for (before, live) in changed {
            guard let guid = before?.guid ?? live?.guid,
                  let index = order.firstIndex(where: { $0.guid == guid }) else {
                // Not there: fine if it was not shown, or is new.
                if let before, journalTransactionsInclude(before) { return false }
                continue
            }
            if hasRows {
                let range = starts[index]..<blockEnd(index)
                rows.removeSubrange(range)
                starts.remove(at: index)
                for later in index..<starts.count { starts[later] -= range.count }
            }
            order.remove(at: index)
        }
        // Then in, where its new fields file it: after everything that sorts
        // before it, the book's order breaking a tie, as the stable sorts do.
        for (_, live) in changed {
            guard let live, book.transaction(with: live.guid) === live, journalTransactionsInclude(live)
            else { continue }
            var low = 0, high = order.count
            while low < high {
                let mid = (low + high) / 2
                if ledgerPrecedes(order[mid], live) { low = mid + 1 } else { high = mid }
            }
            if hasRows {
                let at = low < starts.count ? starts[low] : rows.count
                var block: [JournalRow] = []
                Self.appendJournalBlock(of: live, to: &block, inFocus: { _ in false }, balances: [:])
                rows.insert(contentsOf: block, at: at)
                starts.insert(at, at: low)
                for later in (low + 1)..<starts.count { starts[later] += block.count }
            }
            order.insert(live, at: low)
        }
        journalTransactionCache[nil] = order
        if hasRows {
            journalRowCache[nil] = rows
            ledgerBlockStarts = starts
        }
        return true
    }

    /// Whether the general ledger shows `txn` under the register's filter.
    private func journalTransactionsInclude(_ txn: Transaction) -> Bool {
        let filter = registerFilter
        guard !filter.isShowingEverything else { return true }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: txn.datePosted)
        if let start = filter.startDate.map({ calendar.startOfDay(for: $0) }), day < start { return false }
        if let end = filter.endDate.map({ calendar.startOfDay(for: $0) }), day > end { return false }
        return txn.splits.contains { filter.statuses.contains($0.reconcileState) }
    }

    /// The general ledger's order without the book-order tie-break: the
    /// register's sort, then the date — what the two stable sorts in
    /// ``journalTransactions(forAccountID:)`` leave — reversed when asked.
    private func ledgerCompare(_ a: Transaction, _ b: Transaction) -> ComparisonResult {
        func compare<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
            x < y ? .orderedAscending : (y < x ? .orderedDescending : .orderedSame)
        }
        func debits(_ txn: Transaction) -> Decimal {
            txn.splits.filter { $0.value > 0 }.reduce(0) { $0 + $1.value }
        }
        var result: ComparisonResult
        switch registerSort {
        case .standard, .date: result = .orderedSame
        case .dateEntered: result = compare(a.dateEntered, b.dateEntered)
        case .number:
            let n = Transaction.numOrString(a.number, b.number)
            result = n < 0 ? .orderedAscending : (n > 0 ? .orderedDescending : .orderedSame)
        case .amount: result = compare(debits(a), debits(b))
        case .description: result = a.transactionDescription.localizedCaseInsensitiveCompare(b.transactionDescription)
        case .memo: result = (a.splits.first?.memo ?? "").localizedCaseInsensitiveCompare(b.splits.first?.memo ?? "")
        }
        if result == .orderedSame { result = compare(a.datePosted, b.datePosted) }
        guard registerSortReversed else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    /// Whether `a` comes before `b` in the general ledger, the book's order
    /// deciding a tie.
    private func ledgerPrecedes(_ a: Transaction, _ b: Transaction) -> Bool {
        switch ledgerCompare(a, b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            let earlier = a.bookOrder < b.bookOrder
            return registerSortReversed ? !earlier && a !== b : earlier
        }
    }

    /// Whether the general ledger's caches, followed edit by edit, are what
    /// building them again gives. For tests and the verification switch.
    func generalLedgerMatchesRebuild() -> Bool {
        guard let order = journalTransactionCache[nil] else { return true }
        let rows = journalRowCache[nil]
        let keptStarts = ledgerBlockStarts
        let keptTransactions = journalTransactionCache
        let keptRows = journalRowCache
        let keptSettings = journalSettings
        dropJournalCaches()
        journalSettings = keptSettings
        let freshOrder = journalTransactions(forAccountID: nil)
        let freshRows = rows == nil ? nil : journalRows(forAccountID: nil)
        journalTransactionCache = keptTransactions
        journalRowCache = keptRows
        ledgerBlockStarts = keptStarts
        return freshOrder.map(ObjectIdentifier.init) == order.map(ObjectIdentifier.init) && freshRows == rows
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
    ///
    /// Memoised per transaction until ``transactionRevision`` moves: every
    /// leg carries its account's `fullName`, a recursive string build, and
    /// Journal style asks for every row's legs on each geometry pass.
    public func legRows(ofTransaction id: GncGUID) -> [AutoSplitRow] {
        if legRowsRevision != transactionRevision {
            legRowsCache.removeAll(keepingCapacity: true)
            legRowsRevision = transactionRevision
        }
        if let hit = legRowsCache[id] { return hit }
        guard let book, let txn = book.transaction(with: id) else { return [] }
        let rows = txn.splits.map { split in
            AutoSplitRow(legID: split.guid,
                         account: split.account?.fullName ?? "—",
                         memo: split.memo,
                         action: split.action,
                         reconcile: split.reconcileState.rawValue,
                         amount: split.value,
                         currencyCode: txn.currency.mnemonic)
        }
        legRowsCache[id] = rows
        return rows
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
    /// Both honour the register's Subaccounts, Filter and Sort settings,
    /// applied per *transaction*: a transaction is shown when any of its
    /// relevant legs passes the filter, and sorts by its own fields.
    ///
    /// **The whole book used to honour neither.** Filtering and sorting sat
    /// inside an `if !focusSet.isEmpty` block, and the general ledger's focus
    /// set is empty by definition — so All Transactions ignored the Filter
    /// sheet entirely and came back oldest-first however its column headers
    /// were clicked. Worse, those headers still wrote `registerSort`, which is
    /// one shared setting: sorting All Transactions by Amount did nothing here
    /// and silently re-sorted every single-account register instead.
    ///
    /// A leg is "relevant" when it is in focus, or — with no anchoring account
    /// — always. That is the only change the general ledger needs: GnuCash is
    /// explicit that the general journal has no anchoring split
    /// (`gnc-split-reg.c:894`), so "the focus legs" becomes "the legs".
    func journalTransactions(forAccountID accountID: GncGUID?) -> [Transaction] {
        journalCachesFollowSettings()
        if let cached = journalTransactionCache[accountID] { return cached }
        guard let book else { return [] }
        let focusSet = journalFocusSet(forAccountID: accountID)

        func inFocus(_ split: Split) -> Bool {
            split.account.map { focusSet.contains(ObjectIdentifier($0)) } ?? false
        }
        func relevant(_ split: Split) -> Bool { focusSet.isEmpty || inFocus(split) }

        let inScope = focusSet.isEmpty ? book.transactions
            : book.transactions.filter { txn in txn.splits.contains(where: inFocus) }
        // By date, stably — on keys taken once, with the book position as the
        // tie-break, rather than two object reads a comparison: the general
        // ledger's first build sorts the whole book, and comparing `Date`s
        // through the transactions was the largest of what entering Accounts
        // still cost the first time (build 4). Same order, as a stable sort
        // by date gives.
        let keyed = inScope.indices.map { (key: inScope[$0].datePosted.timeIntervalSinceReferenceDate, at: $0) }
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.at < $1.at }
        var transactions = keyed.map { inScope[$0.at] }

        let filter = registerFilter
        if !filter.isShowingEverything {
            let calendar = Calendar.current
            let start = filter.startDate.map { calendar.startOfDay(for: $0) }
            let end = filter.endDate.map { calendar.startOfDay(for: $0) }
            transactions = transactions.filter { txn in
                let day = calendar.startOfDay(for: txn.datePosted)
                if let start, day < start { return false }
                if let end, day > end { return false }
                return txn.splits.contains { relevant($0) && filter.statuses.contains($0.reconcileState) }
            }
        }

        /// What the Amount column shows, so it sorts by what it displays.
        ///
        /// With no anchor there is no leg whose value is "the" amount, and
        /// summing every leg would give zero on a balanced transaction. GnuCash
        /// fills the general journal's total from the debit side
        /// (`split-register-model.c:1650-1657`), which is also what
        /// ``wholeBookRowSummary(ofTransaction:)`` puts in the cell.
        func focusValue(_ txn: Transaction) -> Decimal {
            focusSet.isEmpty
                ? txn.splits.filter { $0.value > 0 }.reduce(0) { $0 + $1.value }
                : txn.splits.reduce(Decimal(0)) { $0 + (inFocus($1) ? $1.value : 0) }
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
                txn.splits.first(where: relevant)?.memo ?? ""
            }
            transactions.sort { memo($0).localizedCaseInsensitiveCompare(memo($1)) == .orderedAscending }
        }
        if registerSortReversed { transactions.reverse() }

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

    /// What the All Transactions summary bar can honestly say.
    ///
    /// Not a balance: the book has none, because every account nets against
    /// the others. The count moves with the Filter sheet — which is the point
    /// of showing it, now that All Transactions honours that filter at all —
    /// and the debit total is what the Amount column adds up, on the same
    /// definition the rows use.
    public func wholeBookRegisterSummary() -> (count: Int, debits: Decimal) {
        // Memoised per transaction revision and filter — not in the report
        // memo, which a price edit empties though no transaction moved — and
        // summed without an array per transaction: on the reference book this
        // was 17% of entering Accounts (build 4), on every visit after a quote
        // refresh. The journal honours the register filter, so the key does.
        let key = WholeBookSummaryKey(revision: transactionRevision, filter: registerFilter)
        if let memo = wholeBookSummaryMemo, memo.key == key { return memo.value }
        let value = Self.debitSummary(journalTransactions(forAccountID: nil))
        wholeBookSummaryMemo = (key, value)
        return value
    }

    /// How many transactions, and their debit total — the whole-book bar's two
    /// facts, of any run of transactions.
    static func debitSummary(_ transactions: [Transaction]) -> (count: Int, debits: Decimal) {
        var debits = Decimal(0)
        for txn in transactions {
            for split in txn.splits where split.value > 0 { debits += split.value }
        }
        return (transactions.count, debits)
    }

    public func wholeBookRowSummary(ofTransaction id: GncGUID) -> WholeBookRowSummary {
        guard let txn = book?.transaction(with: id) else {
            return WholeBookRowSummary(reconcile: "", accounts: "", total: 0)
        }
        return Self.wholeBookRowSummary(of: txn)
    }

    /// ``wholeBookRowSummary(ofTransaction:)`` of a transaction in hand: one
    /// pass over its legs and no array made. The whole-book registers ask it of
    /// every transaction in the book — 46k on the reference book — and the
    /// lookups, sets and filtered arrays it used to make were most of their
    /// base build, paid on entering Accounts (build 4).
    static func wholeBookRowSummary(of txn: Transaction) -> WholeBookRowSummary {
        let splits = txn.splits
        var reconcile = splits.first?.reconcileState
        var agreed = true
        // Debits first, so a two-legged row reads in the direction the money
        // moved rather than in storage order. Legs with no account are not counted,
        // as they were not when these were arrays of names.
        var debitName: String?, creditName: String?
        var debitLegs = 0, creditLegs = 0
        var total = Decimal(0)
        for split in splits {
            if agreed, split.reconcileState != reconcile { agreed = false; reconcile = nil }
            if split.value > 0 {
                total += split.value
                if let name = split.account?.name { debitLegs += 1; debitName = debitName ?? name }
            } else if split.value < 0, let name = split.account?.name {
                creditLegs += 1
                creditName = creditName ?? name
            }
        }
        let accounts: String
        if debitLegs == 1, creditLegs == 1, let debitName, let creditName {
            accounts = "\(creditName) → \(debitName)"
        } else if splits.count == 1 {
            // Not reachable through the app — `addTransaction` refuses
            // `.tooFewSplits` — but an imported GnuCash book can carry an
            // orphan split, and a row for one should name where it posted
            // rather than claim to be a split transaction.
            accounts = splits[0].account?.name ?? ""
        } else {
            // The same marker the single-account register already uses for a
            // transaction with more than one other side.
            accounts = splitMarker
        }
        return WholeBookRowSummary(reconcile: reconcile?.rawValue ?? "", accounts: accounts, total: total)
    }

    /// "— Split —", looked up once rather than once a row.
    private static let splitMarker = String(localized: "— Split —")
}
