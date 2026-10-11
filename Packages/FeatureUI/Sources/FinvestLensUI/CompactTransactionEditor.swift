//
//  CompactTransactionEditor.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The transaction editor at phone width: a form. The regular editor hosts
//  the register's own row, which folds its account cells away below 640
//  points — on a phone there would be no way to pick an account. Here every
//  split is an account and an amount, plus a quantity where the account is
//  held in something other than the transaction's currency.
//
//  The rule it is built to: **what it does not show, it does not change.**
//  A transaction's currency is the one it was recorded in, never re-derived
//  from its accounts (a purchase entered through the FX converter would
//  otherwise be re-saved in the wrong unit). Tags and the number go back as
//  they came. A split's memo, action, reconcile state and identity ride
//  along untouched. And a split is removed only by removing it — a blank
//  amount stops the save instead of quietly dropping the line.
//

#if os(iOS)
import SwiftUI
import FinvestLensEngine

struct CompactTransactionEditor: View {
    @Bindable var model: AppModel
    var editingID: GncGUID?
    var documentPrefill: TransactionEditorSheet.DocumentPrefill?
    @Environment(\.dismiss) private var dismiss

    private struct Leg: Identifiable {
        let id = UUID()
        var splitID: GncGUID?
        var accountID: GncGUID?
        var amountText = ""
        var quantityText = ""
        var memo = ""
        var action = ""
        /// As loaded, for a split whose quantity differs from its value on
        /// an account that would not normally need one — kept if untouched.
        var loadedAmountText: String?
        var loadedQuantity: Decimal?

        var amount: Decimal? { CompactTransactionEditor.parse(amountText) }
        var quantity: Decimal? { CompactTransactionEditor.parse(quantityText) }

        /// A line nobody has started: ignored rather than incomplete.
        var isBlank: Bool {
            splitID == nil && accountID == nil
                && amountText.trimmingCharacters(in: .whitespaces).isEmpty
                && quantityText.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @State private var loaded = false
    @State private var date = Date()
    @State private var description = ""
    @State private var notes = ""
    @State private var legs: [Leg] = [Leg(), Leg()]
    /// The currency the transaction was recorded in, where that is not the
    /// one its accounts would give it. Carried, never re-derived.
    @State private var recordedCurrency: Commodity?
    /// The amount last written into the second line on the first's behalf.
    @State private var mirrored: String?
    @State private var commitError: String?
    @State private var confirmingDelete = false

    private var isEditing: Bool { editingID != nil }
    private var accounts: [AccountNode] { model.postableAccounts }

    private var currency: Commodity {
        recordedCurrency ?? model.transactionCurrency(for: legs.compactMap(\.accountID))
    }

    fileprivate static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : AmountExpression.evaluate(trimmed)
    }

    /// A value as the field shows it: plain digits, the way the regular
    /// editor prefills an amount.
    private static func editText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// `FR-REG-07`: a split on an account held in another commodity — a
    /// security, a foreign currency — carries its own quantity.
    private func needsQuantity(_ leg: Leg) -> Bool {
        guard let id = leg.accountID, let node = accounts.first(where: { $0.id == id }) else { return false }
        return node.currencyCode != currency.mnemonic
    }

    private func commodityCode(_ leg: Leg) -> String {
        accounts.first { $0.id == leg.accountID }?.currencyCode ?? ""
    }

    private var entered: [Leg] { legs.filter { !$0.isBlank } }

    /// Every line that has been started is finished: an account, an amount,
    /// and a quantity where one is needed.
    private var linesComplete: Bool {
        entered.allSatisfy { leg in
            leg.accountID != nil && leg.amount != nil && (!needsQuantity(leg) || leg.quantity != nil)
        }
    }

    /// What the splits add up to; a balanced transaction sums to zero.
    private var imbalance: Decimal { entered.compactMap(\.amount).reduce(0, +) }

    private var canSave: Bool { entered.count >= 2 && linesComplete && imbalance == 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Description", text: $description)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    ForEach($legs) { $leg in
                        legRow($leg)
                    }
                    .onDelete { offsets in
                        legs.remove(atOffsets: offsets)
                        while legs.count < 2 { legs.append(Leg()) }
                    }
                    Button("Add Split", systemImage: "plus.circle") { legs.append(Leg()) }
                } header: {
                    Text("Splits")
                } footer: {
                    if imbalance != 0 {
                        Text("Out of balance by \(AmountFormat.string(imbalance, code: currency.mnemonic)).")
                            .foregroundStyle(Color.negativeAmount)
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
                if isEditing {
                    Section {
                        Button("Delete Transaction", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Transaction" : "New Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { commit() }
                        .disabled(!canSave)
                }
            }
            .alert("Couldn’t save the transaction", isPresented: Binding(
                get: { commitError != nil },
                set: { if !$0 { commitError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(commitError ?? "")
            }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete Transaction", role: .destructive) {
                    if let editingID { model.deleteTransaction(editingID) }
                    dismiss()
                }
            }
            .onAppear(perform: loadIfNeeded)
            // The two-line entry the phone is for: type what was spent and
            // the other line takes the opposite, until it is given its own.
            .onChange(of: legs.first?.amountText) { _, text in
                guard !isEditing, legs.count == 2, let text, let amount = Self.parse(text) else { return }
                guard legs[1].amountText.isEmpty || legs[1].amountText == mirrored else { return }
                let opposite = Self.editText(-amount)
                legs[1].amountText = opposite
                mirrored = opposite
            }
        }
    }

    private func legRow(_ leg: Binding<Leg>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AccountField(prompt: "Account", nodes: accounts, selection: leg.accountID)
            HStack {
                Text("Amount")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("0.00", text: leg.amountText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityLabel("Amount")
            }
            if needsQuantity(leg.wrappedValue) {
                HStack {
                    Text("Quantity")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Quantity", text: leg.quantityText,
                              prompt: Text(verbatim: commodityCode(leg.wrappedValue)))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .accessibilityLabel("Quantity")
                        .accessibilityValue(leg.wrappedValue.quantityText)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Model

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let editingID, let edit = model.editData(forTransaction: editingID) {
            date = edit.date
            description = edit.description
            notes = edit.notes
            let derived = model.transactionCurrency(for: edit.splits.compactMap(\.accountID))
            if edit.currency != derived { recordedCurrency = edit.currency }
            legs = edit.splits.map { split in
                let text = Self.editText(split.value)
                return Leg(splitID: split.splitID, accountID: split.accountID,
                           amountText: text,
                           quantityText: split.quantity.map(Self.editText) ?? "",
                           memo: split.memo, action: split.action,
                           loadedAmountText: text, loadedQuantity: split.quantity)
            }
            // A split that needs a quantity and was stored at one-to-one has
            // none recorded separately; the field shows what it holds.
            for index in legs.indices where legs[index].quantityText.isEmpty && needsQuantity(legs[index]) {
                legs[index].quantityText = legs[index].amountText
            }
            while legs.count < 2 { legs.append(Leg()) }
        } else if let prefill = documentPrefill {
            if let prefilled = prefill.date { date = prefilled }
            if let text = prefill.description, !text.isEmpty { description = text }
            if let amount = prefill.amount, amount != 0 {
                legs = [Leg(amountText: Self.editText(-amount)), Leg(amountText: Self.editText(amount))]
            }
        }
    }

    /// The quantity a split goes back with. Where the form shows one, that;
    /// where it does not and the split came with one that the amount has not
    /// moved from, the one it came with; otherwise none, and the engine takes
    /// the quantity from the value as it does for any same-currency posting.
    private func quantity(for leg: Leg) -> Decimal? {
        if needsQuantity(leg) { return leg.quantity }
        if leg.loadedQuantity != nil, leg.amountText == leg.loadedAmountText { return leg.loadedQuantity }
        return nil
    }

    private func commit() {
        guard canSave else { return }
        let inputs = entered.compactMap { leg -> SplitInput? in
            guard let accountID = leg.accountID, let amount = leg.amount else { return nil }
            return SplitInput(splitID: leg.splitID, accountID: accountID, value: amount,
                              quantity: quantity(for: leg), memo: leg.memo, action: leg.action)
        }
        do {
            if let editingID {
                // Tags and the number are not on this form: `nil` leaves them.
                _ = try model.updateTransaction(id: editingID, date: date, description: description,
                                                currency: currency, splits: inputs, notes: notes)
            } else {
                let newID = try model.addTransaction(date: date, description: description,
                                                     currency: currency, splits: inputs, notes: notes)
                if let prefill = documentPrefill, let data = try? Data(contentsOf: prefill.url) {
                    model.attachDocumentReporting(named: prefill.url.lastPathComponent,
                                                  data: data, to: newID)
                }
            }
            dismiss()
        } catch {
            commitError = error.localizedDescription
        }
    }
}
#endif
