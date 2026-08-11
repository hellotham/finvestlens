//
//  SecurityEditSheets.swift (was SecuritiesView.swift)
//  FinvestLens — FeatureUI
//
//  The securities list lived here until P11/I2 and is superseded by the
//  Investments holdings table, which can say what this list never could:
//  freshness, history, value and return. These per-security editors survive
//  and are presented from the hub.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensReports

/// Edits a security's display name and fraction across all holdings.
struct EditSecuritySheet: View {
    @Bindable var model: AppModel
    let commodity: Commodity
    @Environment(\.dismiss) private var dismiss
    @State private var fullName = ""

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Ticker", value: commodity.mnemonic)
                LabeledContent("Exchange", value: namespaceLabel)
                TextField("Full name", text: $fullName)
            }
            .navigationTitle("Edit Security")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.renameSecurity(commodity, fullName: fullName); dismiss() }
                        .disabled(fullName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { fullName = commodity.fullName }
        }
        .frame(minWidth: 360, minHeight: 180)
    }

    private var namespaceLabel: String {
        if case let .security(exchange) = commodity.namespace { return exchange }
        return "—"
    }
}

/// Sets (or clears) a price target that raises a dashboard alert when the
/// latest quote crosses it (`FR-PLAN-05`).
struct PriceTargetSheet: View {
    @Bindable var model: AppModel
    let commodity: Commodity
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var direction: PriceTarget.Direction = .atOrAbove

    private var hasExisting: Bool { model.priceTarget(for: commodity) != nil }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Security", value: commodity.mnemonic)
                if let price = model.book?.latestPrice(of: commodity, in: model.reportCurrency)?.value {
                    LabeledContent("Latest price",
                                   value: AmountFormat.string(price, code: model.reportCurrency.mnemonic))
                }
                Picker("Alert when price is", selection: $direction) {
                    Text("Above").tag(PriceTarget.Direction.atOrAbove)
                    Text("Below").tag(PriceTarget.Direction.atOrBelow)
                }
                .pickerStyle(.segmented)
                TextField("Target price", text: $amount)
                    .multilineTextAlignment(.trailing)
                Text("You’ll see an alert on the dashboard when the latest quote crosses this target.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Price Target")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                if hasExisting {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Remove Target", role: .destructive) {
                            model.removePriceTarget(commodity)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Target") {
                        if let value = EditableSplit.strictDecimal(amount.trimmingCharacters(in: .whitespaces)), value > 0 {
                            model.setPriceTarget(commodity, target: value, direction: direction)
                        }
                        dismiss()
                    }
                    .disabled(EditableSplit.strictDecimal(amount.trimmingCharacters(in: .whitespaces)).map { $0 <= 0 } ?? true)
                }
            }
            .onAppear {
                if let existing = model.priceTarget(for: commodity) {
                    amount = NSDecimalNumber(decimal: existing.target).stringValue
                    direction = existing.direction
                }
            }
        }
        .frame(minWidth: 380, minHeight: 260)
    }
}

/// Adds a security to the watch list (no holding).
struct AddWatchSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var exchange = ""
    @State private var ticker = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Exchange (e.g. NASDAQ)", text: $exchange)
                TextField("Ticker (e.g. AAPL)", text: $ticker)
                TextField("Full name (optional)", text: $name)
            }
            .navigationTitle("Watch Security")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addWatchSecurity(exchange: exchange, ticker: ticker, name: name)
                        dismiss()
                    }
                    .disabled(ticker.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 200)
    }
}
