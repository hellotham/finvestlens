//
//  TransactionEditRow.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  One register line, laid out on GnuCash's own column contract.
//
//  From `gnucash/register/ledger-core/split-register-layout.c`: the register is
//  a fixed grid, and *every* cursor type drops its cells into the same column
//  indices — which is why nothing moves as you go from a transaction line to
//  its splits, or from reading to editing.
//
//      col  transaction line   double line   split line
//      0    Date               —             —
//      1    Num                Action        Action
//      2    Description        Notes         Memo
//      3    Transfer (MXFRM)   Void notes    Account (XFRM)
//      4    Reconcile          Doc link      Reconcile
//      5/6  Debit / Credit     —             Debit / Credit
//      7    Balance            —             —
//      8    Rate               —             —
//
//  So on a split line **Memo sits in the Description column and Account in the
//  Transfer column** — the reverse of the obvious guess. We have no Num column,
//  so Action takes the Date column, which is blank on a split line for exactly
//  the same reason. FX has a cell of its own (RATE_CELL); our grid has no ninth
//  column, so a split line's foreign quantity takes the Balance cell, blank on
//  split lines and right beside the leg it belongs to.
//
//  Every cell is a live field that looks like text until focused — see
//  ``RegisterCell``. Clicking a cell edits it because it *is* a field. There is
//  no gesture code anywhere in this file, which is the point: a list row
//  swallows clicks aimed at buttons and gestures inside it, and that is what
//  defeated every earlier attempt to make static text clickable.
//

import SwiftUI
import FinvestLensEngine

struct TransactionRowView: View, @MainActor Equatable {
    @Bindable var model: AppModel
    let row: AutoSplitRow
    let metrics: RegisterMetrics
    /// The accounts pickers offer. Passed in, not read per cell: it is hundreds
    /// of nodes, and reading it per cell per update is what made this slow.
    let accounts: [AccountNode]
    let currencyCode: String
    let showsAccountColumn: Bool
    let showsBalanceColumn: Bool
    /// Opened out into its splits — Show All Splits, or opened for editing.
    let isExpanded: Bool
    let isSelected: Bool
    /// The splits to draw when expanded and not editing.
    let restSplits: [AutoSplitRow]
    let showsSecondLine: Bool
    let dateText: (Date) -> String
    let parseDate: (String) -> Date?
    @Binding var draft: TransactionDraft?
    /// The register's shared cursor: one `FocusState` enum decides which cell
    /// holds focus (see ``RegisterCell``).
    var cursor: FocusState<TransactionEditField?>.Binding
    let focusAccountID: GncGUID?
    let cycleReconcile: (GncGUID) -> Void
    /// Promotes this row to the edit draft. Called when any cell takes focus,
    /// before a keystroke lands.
    let beginEdit: () -> Void
    /// Opens the row out into every field (the handle, ⌘E, Edit Transaction…).
    let expandEdit: () -> Void
    let save: () -> Void
    let cancel: () -> Void

    @Environment(\.appFontScale) private var appFontScale

    /// The semantic inputs, and nothing else. Rows receive fresh closure and
    /// binding identities on every register pass; without this comparison
    /// SwiftUI re-rendered every visible row continuously (`_draft changed`),
    /// which is what made clicks laggy and intermittent. Closures carry no
    /// state; the values below are the row's entire appearance.
    static func == (lhs: TransactionRowView, rhs: TransactionRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.metrics == rhs.metrics
            && lhs.currencyCode == rhs.currencyCode
            && lhs.showsAccountColumn == rhs.showsAccountColumn
            && lhs.showsBalanceColumn == rhs.showsBalanceColumn
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isSelected == rhs.isSelected
            && lhs.restSplits == rhs.restSplits
            && lhs.showsSecondLine == rhs.showsSecondLine
            && lhs.draft == rhs.draft
            && lhs.cursor.wrappedValue == rhs.cursor.wrappedValue
            && lhs.focusAccountID == rhs.focusAccountID
            && lhs.accounts.count == rhs.accounts.count
    }

    private var isEditing: Bool { draft != nil }
    private var main: RegisterRow? { row.main }

    /// A cell is a live field only on the selected row. That is your spec —
    /// "selecting a field within an already selected transaction makes it
    /// editable" — and it is also what keeps the register inert on open: with
    /// nothing selected there are no text fields at all, so nothing can take
    /// first responder and quietly start an edit nobody asked for.
    private var cellsAreLive: Bool { isSelected || isEditing }

    // MARK: Cursor traversal


    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            transactionLine
            // HIG, Text fields: "Ensure that tabbing between multiple fields
            // flows as people expect… The system attempts to achieve this
            // result automatically" — automatically, that is, when the view
            // order *is* the visual order. These lines are siblings of the
            // transaction line, not nested inside its Description column, so
            // Tab finishes the line it is on before descending.
            if isExpanded || showsSecondLine { notesLine }
            if isExpanded {
                splitColumnLabels
                splitLines
            }
        }
        .padding(.horizontal, metrics.rowInset)
        .padding(.vertical, 1)
        // Height fixed to content: stabilises measurement so the geometry
        // callback settles instead of flapping (its removal was a bisect
        // casualty, and flapping heights fed the click-eating churn loop).
        .fixedSize(horizontal: false, vertical: true)
        // ⏎ saves the transaction. There is no Save button.
        .onSubmit(of: .text) { save() }
        #if os(macOS)
        .onExitCommand { cancel() }
        #endif
    }

    // MARK: Transaction line

    private var transactionLine: some View {
        HStack(spacing: 0) {
            if metrics.showsDate {
                // `field` only on the live row: the six transaction-level
                // cursor cases carry no row identity, so a resting row must
                // not bind them — two fields claiming the same focus value is
                // undefined. The field still exists *before* the activating
                // click (it appears with selection), which is the invariant
                // the RegisterLab harness proved necessary.
                RegisterCell(value: dateString,
                             field: cellsAreLive ? .date : nil, cursor: cursor,
                             metrics: metrics,
                             onFocus: beginEdit,
                             onEdit: { if let parsed = parseDate($0) { draft?.date = parsed } })
                    .frame(width: metrics.date)
            }
            editHandle.frame(width: metrics.handle)
            descriptionColumn.frame(maxWidth: .infinity)
            if metrics.showsSide, showsAccountColumn {
                RegisterCell(value: main?.accountName ?? "", muted: true,
                             isEditable: false, metrics: metrics)
                    .frame(width: metrics.account)
            }
            if metrics.showsSide {
                transferColumn.frame(width: metrics.transfer)
            }
            ReconcileBadge(glyph: main?.reconcile ?? "") { cycleReconcile(row.id) }
                .allowsHitTesting(false)   // the line map cycles it
                .frame(width: metrics.reconcile)
            amountColumn.frame(width: metrics.amount)
            if showsBalanceColumn {
                balanceColumn.frame(width: metrics.balance)
            }
        }
        // The row at rest is one VoiceOver element that reads like a ledger
        // line; its cells are drawn text, not controls, so exposing them
        // individually would be a soup of fragments (the `Table` this replaced
        // announced whole rows too). Once the cells are live the container
        // steps back and each field is reachable on its own.
        .accessibilityElement(children: cellsAreLive ? .contain : .combine)
        .accessibilityLabel(cellsAreLive ? Text("") : Text(rowSummary))
        .accessibilityAction(named: "Edit Transaction") { expandEdit() }
        .accessibilityAction(named: "Cycle Reconcile State") { cycleReconcile(row.id) }
    }

    /// The row as VoiceOver reads it: date, description, counterparty, amount,
    /// balance, reconcile state.
    private var rowSummary: String {
        guard let main else { return "" }
        var parts = [dateText(main.date), main.description]
        if !main.transfer.isEmpty { parts.append(main.transfer) }
        parts.append(AmountFormat.string(main.amount, code: currencyCode))
        if main.hasDocument { parts.append(String(localized: "has attachment")) }
        if let balance = main.runningBalance {
            parts.append(String(localized: "balance \(AmountFormat.string(balance, code: currencyCode))"))
        }
        parts.append(ReconcileBadge.word(main.reconcile))
        return parts.joined(separator: ", ")
    }

    private var dateString: String {
        if let draft { return dateText(draft.date) }
        return main.map { dateText($0.date) } ?? ""
    }

    /// The handle a selected row exposes — the same act as right-click ▸ Edit
    /// Transaction… and ⌘E. Its column is always laid out and it fills the row
    /// height, so showing it moves nothing and it is an easy target.
    private var editHandle: some View {
        Button(action: expandEdit) {
            Image(systemName: isExpanded ? "chevron.down" : "square.and.pencil")
                .imageScale(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .allowsHitTesting(false)   // the line map triggers expandEdit
        .foregroundStyle(.secondary)
        .accessibilityLabel(isExpanded ? "Collapse transaction" : "Edit transaction")
        .opacity(isSelected || isEditing ? 1 : 0)
        .disabled(!isSelected && !isEditing)
        .accessibilityHidden(!isSelected && !isEditing)
    }

    private var descriptionColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if main?.hasDocument == true {
                    // Decorative: the row's VoiceOver summary says "has
                    // attachment"; announcing a bare "paperclip" as well is
                    // noise.
                    Image(systemName: "paperclip")
                        .imageScale(.small).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                RegisterCell(value: draft?.description ?? main?.description ?? "",
                             placeholder: "Description",
                             isEditable: cellsAreLive,
                             field: cellsAreLive ? .description : nil, cursor: cursor,
                             metrics: metrics,
                             onFocus: beginEdit,
                             onEdit: { draft?.description = $0 })
            }
            // Folded columns surface as caption lines instead of vanishing.
            if let main {
                if !metrics.showsDate {
                    Text(dateText(main.date)).scaledFont(.caption).foregroundStyle(.secondary)
                }
                if !metrics.showsSide, !main.transfer.isEmpty {
                    Text("→ \(main.transfer)").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// HIG, Lists and tables: "Use descriptive column headings in a
    /// multicolumn table." A split line reuses the transaction line's columns
    /// for different fields — Action under Date, Memo under Description,
    /// Account under Transfer — so the register's own headings do not describe
    /// it. These do. Drawn whenever the row is opened out, in both states, so
    /// they cost no layout shift when editing begins.
    private var splitColumnLabels: some View {
        HStack(spacing: 0) {
            if metrics.showsDate {
                label("Action").frame(width: metrics.date)
            }
            Spacer().frame(width: metrics.handle)
            label("Memo").padding(.leading, metrics.splitIndent)
                .frame(maxWidth: .infinity, alignment: .leading)
            if metrics.showsSide, showsAccountColumn {
                Spacer().frame(width: metrics.account)
            }
            if metrics.showsSide {
                label("Account").frame(width: metrics.transfer)
            }
            Spacer().frame(width: metrics.reconcile)
            label("Amount", trailing: true).frame(width: metrics.amount)
            if showsBalanceColumn {
                label(hasForeignLeg ? "Quantity" : "", trailing: true)
                    .frame(width: metrics.balance)
            }
        }
    }

    private func label(_ text: LocalizedStringKey, trailing: Bool = false) -> some View {
        Text(text)
            .scaledFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, metrics.cellPaddingH)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    /// Whether any leg posts to another commodity — the only case in which the
    /// Quantity cell is anything but blank.
    private var hasForeignLeg: Bool {
        guard let draft else { return false }
        return draft.lines.contains { line in
            guard let id = line.accountID,
                  let node = accounts.first(where: { $0.id == id }) else { return false }
            return node.currencyCode != currencyCode
        }
    }

    private var notesLine: some View {
        HStack(spacing: 0) {
            if metrics.showsDate { label("Notes").frame(width: metrics.date) }
            Spacer().frame(width: metrics.handle)
            RegisterCell(value: draft?.notes ?? main?.notes ?? "",
                         placeholder: "Notes about this transaction",
                         muted: true, isEditable: cellsAreLive,
                         field: cellsAreLive ? .notes : nil, cursor: cursor, metrics: metrics,
                         onFocus: beginEdit, onEdit: { draft?.notes = $0 })
            label("Tags").fixedSize()
            RegisterCell(value: draft?.tagsText ?? "", placeholder: "Comma-separated",
                         muted: true, isEditable: cellsAreLive,
                         field: cellsAreLive ? .tags : nil, cursor: cursor, metrics: metrics,
                         onFocus: beginEdit, onEdit: { draft?.tagsText = $0 })
                .frame(maxWidth: 160 * appFontScale)
        }
        .scaledFont(.caption)
    }

    /// The Transfer cell — GnuCash's MXFRM combo. Live like any other cell:
    /// click it (or ⇥ onto it) and type; a `Button` that opened a popover was
    /// the one cell that broke the cursor model, which is why it could never
    /// be tabbed to (HIG finding P1.8).
    @ViewBuilder
    private var transferColumn: some View {
        if let draft, let index = draft.counterpartyIndex(account: focusAccountID) {
            AccountComboCell(accountID: draft.lines[index].accountID,
                             placeholder: "Transfer",
                             nodes: accounts,
                             isEditable: cellsAreLive,
                             field: .transfer, cursor: cursor,
                             metrics: metrics,
                             onFocus: beginEdit,
                             onPick: { self.draft?.lines[index].accountID = $0 },
                             onReturn: save)
        } else {
            RegisterCell(value: isEditing ? String(localized: "— Split —")
                                          : (main?.transfer ?? ""),
                         muted: true, isEditable: false, metrics: metrics)
        }
    }

    @ViewBuilder
    private var amountColumn: some View {
        if let draft, let index = draft.focusIndex(account: focusAccountID) {
            RegisterCell(value: draft.lines[safe: index]?.amountText ?? "",
                         alignment: .trailing, monospaced: true,
                         isEditable: cellsAreLive,
                         field: cellsAreLive ? .amount : nil, cursor: cursor,
                         metrics: metrics, onFocus: beginEdit,
                         onEdit: { self.draft?.setAmountText($0, at: index) })
        } else {
            RegisterCell(value: main.map { AmountFormat.string($0.amount, code: currencyCode) } ?? "",
                         alignment: .trailing, monospaced: true,
                         isEditable: cellsAreLive,
                         field: cellsAreLive ? .amount : nil, cursor: cursor,
                         metrics: metrics, onFocus: beginEdit,
                         onEdit: { text in
                             guard let index = draft?.focusIndex(account: focusAccountID)
                             else { return }
                             draft?.setAmountText(text, at: index)
                         })
        }
    }

    /// Balance at rest; the out-of-balance figure while editing. Editing never
    /// adds a line for it — it takes a cell that is already there.
    @ViewBuilder
    private var balanceColumn: some View {
        if let draft, draft.imbalance != 0 {
            Label(AmountFormat.string(draft.imbalance, code: currencyCode),
                  systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .scaledFont(.caption).monospacedDigit()
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, metrics.cellPaddingH)
                .padding(.vertical, metrics.cellPaddingV)
        } else {
            RegisterCell(value: main?.runningBalance
                            .map { AmountFormat.string($0, code: currencyCode) } ?? "",
                         alignment: .trailing, monospaced: true,
                         isEditable: false, metrics: metrics)
        }
    }

    // MARK: Split lines

    @ViewBuilder
    private var splitLines: some View {
        if let draft {
            ForEach(Array(draft.lines.enumerated()), id: \.element.id) { index, _ in
                editableSplitLine(index)
            }
            addSplitLine
        } else {
            ForEach(restSplits) { restSplitLine($0) }
        }
    }

    private func restSplitLine(_ split: AutoSplitRow) -> some View {
        HStack(spacing: 0) {
            if metrics.showsDate {
                RegisterCell(value: split.legAction, muted: true,
                             isEditable: false, metrics: metrics)
                    .frame(width: metrics.date)
            }
            Spacer().frame(width: metrics.handle)
            RegisterCell(value: split.legMemo, muted: true, isEditable: false, metrics: metrics)
                .padding(.leading, metrics.splitIndent)
                .frame(maxWidth: .infinity)
            if metrics.showsSide, showsAccountColumn {
                Spacer().frame(width: metrics.account)
            }
            if metrics.showsSide {
                RegisterCell(value: split.legAccount, muted: true,
                             isEditable: false, metrics: metrics)
                    .frame(width: metrics.transfer)
            }
            ReconcileBadge(glyph: split.legReconcile) { cycleReconcile(split.id) }
                .frame(width: metrics.reconcile)
            RegisterCell(value: AmountFormat.string(split.legAmount, code: split.legCurrencyCode),
                         alignment: .trailing, monospaced: true, muted: true,
                         isEditable: false, metrics: metrics)
                .frame(width: metrics.amount)
            if showsBalanceColumn { Spacer().frame(width: metrics.balance) }
        }
    }

    /// A split line's cells are cursor cells like any other — each names its
    /// `TransactionEditField`, so clicking one moves the cursor there and ⇥
    /// continues through it. The first build of this file constructed none of
    /// the `split…` field cases: the cells rendered as buttons whose action
    /// was `{}`, and clicking a split's memo did nothing at all.
    private func editableSplitLine(_ index: Int) -> some View {
        let lineID = draft?.lines[safe: index]?.id ?? UUID()
        return HStack(spacing: 0) {
            if metrics.showsDate {
                RegisterCell(value: draft?.lines[safe: index]?.action ?? "",
                             placeholder: "Action",
                             muted: true,
                             field: .splitAction(lineID), cursor: cursor,
                             metrics: metrics,
                             onFocus: beginEdit,
                             onEdit: { draft?.lines[index].action = $0 })
                    .frame(width: metrics.date)
            }
            Spacer().frame(width: metrics.handle)
            RegisterCell(value: draft?.lines[safe: index]?.memo ?? "",
                         placeholder: "Memo",
                         muted: true,
                         field: .splitMemo(lineID), cursor: cursor,
                         metrics: metrics,
                         onFocus: beginEdit,
                         onEdit: { draft?.lines[index].memo = $0 })
                .padding(.leading, metrics.splitIndent)
                .frame(maxWidth: .infinity)
            if metrics.showsSide, showsAccountColumn {
                Spacer().frame(width: metrics.account)
            }
            if metrics.showsSide {
                AccountComboCell(accountID: draft?.lines[safe: index]?.accountID,
                                 nodes: accounts,
                                 field: .splitAccount(lineID), cursor: cursor,
                                 metrics: metrics,
                                 onFocus: beginEdit,
                                 onPick: { draft?.lines[index].accountID = $0 },
                                 onReturn: save)
                    .frame(width: metrics.transfer)
            }
            splitRemoveButton(index).frame(width: metrics.reconcile)
            RegisterCell(value: draft?.lines[safe: index]?.amountText ?? "",
                         alignment: .trailing, monospaced: true,
                         field: .splitAmount(lineID), cursor: cursor,
                         metrics: metrics,
                         onFocus: beginEdit,
                         onEdit: { draft?.setAmountText($0, at: index) })
                .frame(width: metrics.amount)
            if showsBalanceColumn {
                rateCell(index, lineID: lineID).frame(width: metrics.balance)
            }
        }
    }

    /// GnuCash's RATE_CELL, on the leg it belongs to. A leg posting to another
    /// commodity carries two numbers — the value in the transaction's currency,
    /// and the quantity in the account's own. Blank, and inert, for a leg in the
    /// transaction's own currency.
    @ViewBuilder
    private func rateCell(_ index: Int, lineID: UUID) -> some View {
        if let line = draft?.lines[safe: index], let id = line.accountID,
           let node = accounts.first(where: { $0.id == id }),
           node.currencyCode != currencyCode {
            RegisterCell(value: line.quantityText,
                         placeholder: LocalizedStringKey(node.currencyCode),
                         alignment: .trailing, monospaced: true,
                         field: .splitQuantity(lineID), cursor: cursor,
                         metrics: metrics,
                         onFocus: beginEdit,
                         onEdit: { draft?.lines[index].quantityText = $0 })
        } else {
            Spacer()
        }
    }

    private func splitRemoveButton(_ index: Int) -> some View {
        Button {
            draft?.lines.remove(at: index)
        } label: {
            Image(systemName: "minus.circle").imageScale(.small)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .allowsHitTesting(false)   // the split-line map removes it
        .foregroundStyle(.secondary)
        .accessibilityLabel("Remove split")
        .disabled((draft?.lines.count ?? 0) <= 2)
    }

    /// The blank line GnuCash keeps at the foot of an opened-out transaction:
    /// this is how you add a split. It opens pre-balanced against the residual,
    /// so a new leg starts by making the transaction whole.
    private var addSplitLine: some View {
        HStack(spacing: 0) {
            if metrics.showsDate { Spacer().frame(width: metrics.date) }
            Spacer().frame(width: metrics.handle)
            Button {
                var line = EditableSplit()
                let residual = -(draft?.imbalance ?? 0)
                if residual != 0 {
                    line.amountText = NSDecimalNumber(decimal: residual).stringValue
                }
                draft?.lines.append(line)
            } label: {
                Label("Add Split", systemImage: "plus.circle")
                    .scaledFont(.caption)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.leading, metrics.splitIndent)
            .padding(.horizontal, metrics.cellPaddingH)
            .padding(.vertical, metrics.cellPaddingV)
            Spacer(minLength: 0)
        }
    }
}

extension Array {
    /// Index access that tolerates a draft line being removed while a binding
    /// still points at it — the remove button does exactly that.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
