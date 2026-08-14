//
//  FetchPreviewSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensQuotes

/// What a refresh will do, before it does it (`FR-INV-34`) —
/// docs/investments-design.md §6.
///
/// The old destination's Update button was a leap of faith: it asked a provider
/// about 87 securities, 48 of them no longer held and 22 of them things no
/// service has ever priced, and said nothing about any of that until it was
/// over. This is the same run, described first.
struct FetchPreviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: FetchScope = .holdings
    @State private var provider: QuoteProviderKind?

    private var plan: FetchPlan {
        model.fetchPlan(scope: scope, using: provider)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What to update") {
                    Picker("Scope", selection: $scope) {
                        ForEach(FetchScope.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Picker("Provider", selection: $provider) {
                        Text("Each security's own choice").tag(QuoteProviderKind?.none)
                        ForEach(model.availableProviders) { kind in
                            Text(kind.displayName).tag(QuoteProviderKind?.some(kind))
                        }
                    }
                }

                Section("What will happen") {
                    let plan = plan
                    LabeledContent("Securities", value: "\(plan.securities.count)")
                    // The number that actually costs anything. A batch
                    // provider's whole group is one request, so eleven bonds
                    // and one share is two requests — showing securities alone
                    // makes the cheapest scope look like the dearest.
                    LabeledContent("Requests", value: "\(plan.requests)")
                    if plan.withGaps > 0 {
                        LabeledContent("With gaps while held", value: "\(plan.withGaps)")
                    }
                    if plan.skipped > 0 {
                        LabeledContent("Left out by this scope", value: "\(plan.skipped)")
                    }
                    ForEach(plan.byProvider.sorted(by: { $0.key.rawValue < $1.key.rawValue }),
                            id: \.key) { provider, count in
                        LabeledContent(provider.displayName) {
                            Text(provider.isBatch
                                 ? String(localized: "\(count) securities in one request")
                                 : String(localized: "\(count) requests"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !plan.isEmpty {
                    Section("Securities") {
                        // Named, not counted. "48 securities" is a number; the
                        // list is what lets someone notice the one that should
                        // not be there.
                        Text(plan.securities.map(\.mnemonic).sorted().joined(separator: ", "))
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Update Prices")
            .onEscapeCommand { dismiss() }
            .onAppear { scope = model.fetchScope }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") {
                        // Remembered, because the next run almost always wants
                        // the same scope.
                        model.fetchScope = scope
                        let chosen = scope, kind = provider
                        dismiss()
                        Task { await model.updatePrices(scope: chosen, using: kind) }
                    }
                    .disabled(plan.isEmpty || model.quoteProgress != nil)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}

/// Sets how often a hand-valued security is expected to be revalued
/// (`FR-INV-30`).
///
/// Manual valuation is a category, not a failure: a super fund posts a unit
/// price monthly, a private holding may be revalued once a year, and without an
/// expected cadence both read as permanently overdue — which is how a worklist
/// stops being read.
struct ValuationCadenceSheet: View {
    @Bindable var model: AppModel
    let commodity: Commodity
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDateFormat) private var dateFormat
    @State private var cadence: AppModel.ValuationCadence = .quarterly

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Security", value: commodity.mnemonic)
                if let latest = model.book?.latestPrice(of: commodity, in: model.reportCurrency) {
                    LabeledContent("Last valued", value: dateFormat.long(latest.date))
                }
                Picker("Expect a new valuation", selection: $cadence) {
                    ForEach(AppModel.ValuationCadence.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Text("This security is valued by hand, so nothing fetches it. The cadence decides when Investments asks you for a new figure — it is never a deadline.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Valuation Cadence")
            .onEscapeCommand { dismiss() }
            .onAppear { cadence = model.valuationCadence(for: commodity) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setValuationCadence(cadence, for: commodity)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}
