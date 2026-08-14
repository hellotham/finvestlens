//
//  PriceEntrySheets.swift (was PricesView.swift)
//  FinvestLens — FeatureUI
//
//  The Prices & Securities destination lived here until P11/I2. It rendered
//  every price row in the book behind a segmented tab picker; both are gone
//  (`FR-INV-29` — prices are shown per security and exported, never as one
//  book-wide table). What remains is manual entry, which the Investments hub
//  presents from its More menu and its worklist.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// Adds a single price for a security.
struct AddPriceSheet: View {
    @Bindable var model: AppModel
    /// Preselected when the sheet is raised from a security's own page — being
    /// asked which security you meant, on the page about that security, is the
    /// kind of question a hub exists to stop asking.
    var commodity: Commodity?
    @Environment(\.dismiss) private var dismiss

    @State private var commodityKey: String = ""
    @State private var date = Date()
    @State private var valueText = ""

    private var commodities: [Commodity] { model.pricableSecurities }
    private func key(_ c: Commodity) -> String { "\(c.namespace)|\(c.mnemonic)" }

    var body: some View {
        NavigationStack {
            Form {
                if let commodity {
                    LabeledContent("Security", value: commodity.mnemonic)
                } else {
                    Picker("Security", selection: $commodityKey) {
                        Text("—").tag("")
                        ForEach(commodities, id: \.self) { Text($0.mnemonic).tag(key($0)) }
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Price (\(model.reportCurrency.mnemonic))", text: $valueText)
                    .multilineTextAlignment(.trailing)
            }
            .navigationTitle("Add Price")
            .onEscapeCommand { dismiss() }
            .onAppear { if let commodity { commodityKey = key(commodity) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(commodityKey.isEmpty || EditableSplit.strictDecimal(valueText.trimmingCharacters(in: .whitespaces)) == nil)
                }
            }
        }
    }

    private func add() {
        // Resolved from the key rather than from the parameter, so a security
        // that is watched but not held — and so absent from `pricableSecurities`
        // in some books — still cannot be priced into existence by accident.
        guard let commodity = commodities.first(where: { key($0) == commodityKey }),
              let value = EditableSplit.strictDecimal(valueText.trimmingCharacters(in: .whitespaces))
        else { return }
        model.addPrice(commodity: commodity, currency: model.reportCurrency, date: date, value: value)
        dismiss()
    }
}

/// Adds a single exchange rate between two of the book's currencies.
struct AddRateSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var fromCode = ""
    @State private var toCode = ""
    @State private var date = Date()
    @State private var rateText = ""

    private var currencies: [Commodity] { model.currencyCommodities }

    var body: some View {
        NavigationStack {
            Form {
                Picker("From", selection: $fromCode) {
                    Text("—").tag("")
                    ForEach(currencies, id: \.mnemonic) { Text($0.mnemonic).tag($0.mnemonic) }
                }
                Picker("To", selection: $toCode) {
                    Text("—").tag("")
                    ForEach(currencies, id: \.mnemonic) { Text($0.mnemonic).tag($0.mnemonic) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Rate (1 \(fromCode.isEmpty ? "from" : fromCode) = ? \(toCode.isEmpty ? "to" : toCode))",
                          text: $rateText)
                    .multilineTextAlignment(.trailing)
            }
            .navigationTitle("Add Exchange Rate")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !fromCode.isEmpty && !toCode.isEmpty && fromCode != toCode && (EditableSplit.strictDecimal(rateText.trimmingCharacters(in: .whitespaces)) ?? 0) > 0
    }

    private func add() {
        guard let from = currencies.first(where: { $0.mnemonic == fromCode }),
              let to = currencies.first(where: { $0.mnemonic == toCode }),
              let rate = EditableSplit.strictDecimal(rateText.trimmingCharacters(in: .whitespaces)) else { return }
        model.addExchangeRate(from: from, to: to, rate: rate, date: date)
        dismiss()
    }
}
