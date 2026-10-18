//
//  CompactRegisterView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The register at phone width: a list of postings, newest first, and the
//  editor as a sheet (PRD §8 "iOS": "optimized for quick transaction entry
//  and review"). The seven-column table needs a regular width; here the row
//  carries what a glance wants — who, from where, how much, when — and a tap
//  opens the editor on that transaction. A long press offers the same
//  actions the table's context menu does.
//

#if os(iOS)
import SwiftUI
import FinvestLensEngine

struct CompactRegisterView: View {
    @Bindable var model: AppModel
    /// The account this register was pushed for; `nil` for the journal.
    var accountID: GncGUID?
    /// The journal narrowed to the search's matches — GnuCash's search ledger
    /// (``AppModel/searchLedgerTransactions()``). Only with no `accountID`.
    var searchScoped = false
    @Environment(\.appDateFormat) private var dateFormat
    @State private var editing: GncGUID?
    @State private var adding = false
    /// The journal's rows, built once per transaction revision — the table
    /// memoises the same derivation, and a 46k-posting book cannot afford it
    /// per body pass.
    @State private var journalRows: [RegisterRow] = []
    /// The account's rows as last seen while it was the model's selection. A
    /// pop moves the selection on at once, and a register drawing straight
    /// from the model would empty itself for the length of the animation.
    @State private var accountRows: [RegisterRow] = []
    @State private var currencyCode = ""

    private var wholeBook: Bool { accountID == nil }

    /// Already newest first (`newestFirst`), so the body only reads them.
    private var rows: [RegisterRow] { wholeBook ? journalRows : accountRows }

    /// Newest first: the phone is for review, and the latest posting is the
    /// one most often looked for. By date, not by simply reversing what the
    /// model hands over — an iPad may have left this register sorted by
    /// amount or description before its window was narrowed, and the phone
    /// has no control that would say so. Same-day postings keep the model's
    /// order, reversed.
    private static func newestFirst(_ rows: [RegisterRow]) -> [RegisterRow] {
        rows.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date > b.element.date : a.offset > b.offset
        }.map(\.element)
    }

    /// Whether this register is the one in front. A stack can hold two —
    /// after Go to Other Account — and a request addressed to "the register"
    /// is for the visible one.
    private var isInFront: Bool {
        if searchScoped { return model.isSearching }
        return wholeBook ? model.sidebarSelection == .generalLedger : model.selectedAccountID == accountID
    }

    var body: some View {
        let rows = rows
        let code = currencyCode.isEmpty ? model.reportCurrency.mnemonic : currencyCode
        Group {
            // The search results are empty only when the search found nothing
            // — not for the frame before their rows are built.
            if searchScoped ? model.searchMatchCount == 0 : rows.isEmpty && (wholeBook || model.registerFilter == .showAll) {
                ContentUnavailableView {
                    Label("No transactions", systemImage: "tray")
                } description: {
                    if searchScoped {
                        Text("No transactions match.")
                    } else if wholeBook {
                        Text("This book has no postings yet.")
                    } else {
                        Text("This account has no postings yet.")
                    }
                } actions: {
                    Button("Add a Transaction") { adding = true }
                        .disabled(model.postableAccounts.count < 2)
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        if !wholeBook, model.registerFilter != .showAll {
                            // A filter set on the iPad or Mac still applies;
                            // the phone says so, and offers the way out.
                            HStack {
                                Label("Filtered", systemImage: "line.3.horizontal.decrease.circle")
                                    .scaledFont(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Show All") { model.registerFilter = .showAll }
                                    .scaledFont(.callout)
                            }
                        }
                        ForEach(rows) { row in
                            Button {
                                editing = transactionID(of: row)
                            } label: {
                                CompactRegisterRow(row: row, code: code,
                                                   showsBalance: !wholeBook, dateFormat: dateFormat)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the transaction")
                            .contextMenu {
                                if searchScoped {
                                    // To the account the search was about.
                                    Button("Show in Register", systemImage: "arrow.right.circle") {
                                        model.showInRegister(row.id)
                                    }
                                    Divider()
                                }
                                if let splitID = splitID(of: row) {
                                    TransactionActions(model: model, splitID: splitID,
                                                       selectionSplitIDs: [splitID])
                                }
                            }
                            .id(row.id)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear { showPending(proxy, rows: rows) }
                }
            }
        }
        .task(id: journalKey) { if wholeBook { journalRows = Self.newestFirst(buildJournalRows()) } }
        .onChange(of: accountKey, initial: true) { refreshAccountRows() }
        .sheet(item: $editing) { id in
            CompactTransactionEditor(model: model, editingID: id)
        }
        // The row menu's Edit Transaction… — and ⌘E on a hardware keyboard —
        // ask through the model, as they do of the table.
        .onChange(of: model.editingTransactionID) { _, id in
            guard let id, isInFront else { return }
            editing = id
            model.editingTransactionID = nil
        }
        .sheet(isPresented: $adding) {
            CompactTransactionEditor(model: model, editingID: nil)
        }
        .toolbar {
            // What can be *done* to this register: the regular shell's
            // Actions menu, from the one definition both shells draw
            // (`RegisterActions`). The phone leaves out importing, which
            // `FR-PLT-06` keeps off it, and Bulk Edit and Match Attachments,
            // which work on a multiple selection and a file picker's batch
            // that this list does not offer. Until 12 Oct 2026 a
            // reconciliation could be started on the phone only from the
            // dashboard's Up Next card, never from the account itself.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    RegisterActions(model: model, scope: .phone(account: !wholeBook))
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("Actions")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Transaction", systemImage: "plus") { adding = true }
                    .disabled(model.postableAccounts.count < 2)
            }
        }
    }

    // MARK: Rows

    /// Account rows are one split each; the journal's are one transaction.
    private func transactionID(of row: RegisterRow) -> GncGUID? {
        wholeBook ? row.id : model.transactionID(ofSplit: row.id)
    }

    private func splitID(of row: RegisterRow) -> GncGUID? {
        wholeBook ? model.legRows(ofTransaction: row.id).first?.id : row.id
    }

    private struct AccountKey: Equatable {
        let selected: GncGUID?
        let revision: Int
    }

    private var accountKey: AccountKey {
        AccountKey(selected: model.selectedAccountID, revision: model.registerRevision)
    }

    private func refreshAccountRows() {
        guard let accountID, model.selectedAccountID == accountID else { return }
        accountRows = Self.newestFirst(model.registerRows)
        currencyCode = model.postableAccounts.first { $0.id == accountID }?.currencyCode
            ?? model.reportCurrency.mnemonic
    }

    private struct JournalKey: Equatable {
        let wholeBook: Bool
        let revision: Int
        let search: Int?
    }

    private var journalKey: JournalKey {
        JournalKey(wholeBook: wholeBook, revision: model.transactionRevision,
                   search: searchScoped ? model.searchRevision : nil)
    }

    /// The journal with the two-account summary the table shows.
    private func buildJournalRows() -> [RegisterRow] {
        let ledger = searchScoped ? model.searchLedgerTransactions()
                                  : model.journalTransactions(forAccountID: nil)
        return ledger.map { txn in
            let summary = AppModel.wholeBookRowSummary(of: txn)
            return RegisterRow(id: txn.guid, date: txn.datePosted, dateEntered: txn.dateEntered,
                               number: txn.number, description: txn.transactionDescription,
                               transfer: summary.accounts, reconcile: summary.reconcile,
                               memo: "", notes: txn.notes, action: "",
                               amount: summary.total, runningBalance: nil)
        }
    }

    /// "Show in Register", Go to Date and a quick entry name a split to land
    /// on; the table scrolls to it, and so does this list — consumed here so
    /// the one-shot target is not left for an unrelated register later.
    private func showPending(_ proxy: ScrollViewProxy, rows: [RegisterRow]) {
        guard let target = model.consumePendingRegisterSelection() else { return }
        let id = wholeBook ? model.transactionID(ofSplit: target) : target
        if let id, rows.contains(where: { $0.id == id }) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// One posting: description over its other account, the amount over the
/// date, a running balance beneath when the register has one. The reconcile
/// mark is the table's glyph, in the table's colour, and the spoken row says
/// the amount's sign and the state in words.
struct CompactRegisterRow: View {
    let row: RegisterRow
    let code: String
    let showsBalance: Bool
    let dateFormat: AppDateFormat

    private var description: String {
        row.description.isEmpty ? String(localized: "(No description)") : row.description
    }

    /// At the accessibility text sizes two columns leave the description an
    /// ellipsis beside a full-width amount, so the row stacks instead and the
    /// description gets a second line.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    names(descriptionLines: 2)
                    figures(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    names(descriptionLines: 1)
                    Spacer(minLength: 8)
                    figures(alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func names(descriptionLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(description)
                .scaledFont(.body)
                .lineLimit(descriptionLines)
            if !row.transfer.isEmpty {
                Text(row.transfer)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func figures(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(AmountFormat.string(row.amount, code: code))
                .scaledFont(.body)
                .monospacedDigit()
                .foregroundStyle(row.amount < 0 ? Color.negativeAmount : .primary)
            HStack(spacing: 4) {
                if !row.reconcile.isEmpty, row.reconcile != "n" {
                    Image(systemName: ReconcileBadge.symbol(row.reconcile))
                        .scaledFont(.caption2)
                        .foregroundStyle(ReconcileBadge.color(row.reconcile))
                        .accessibilityHidden(true)
                }
                Text(dateFormat.short(row.date))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsBalance, let balance = row.runningBalance {
                Text(AmountFormat.string(balance, code: code))
                    .scaledFont(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var spoken: String {
        var parts = [dateFormat.short(row.date), description]
        if !row.transfer.isEmpty { parts.append(row.transfer) }
        parts.append(AmountFormat.spoken(row.amount, code: code))
        if showsBalance, let balance = row.runningBalance {
            parts.append(String(localized: "balance \(AmountFormat.spoken(balance, code: code))"))
        }
        if !row.reconcile.isEmpty, row.reconcile != "n" {
            parts.append(ReconcileBadge.word(row.reconcile))
        }
        if row.hasDocument { parts.append(String(localized: "has attachment")) }
        return parts.joined(separator: ", ")
    }
}
#endif
