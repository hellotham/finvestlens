//
//  NewSecuritySheet.swift
//  FinvestLens — FeatureUI
//
//  Adding a security by name (`FR-INV-41`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensQuotes

/// Type a name, pick the listing, done.
///
/// Nobody knows their holdings by identifier. They know "WAM Income Maximiser",
/// and the exchange suffix that turns that into a price is provider trivia —
/// trivia that, got wrong, is not a failure but a *plausible wrong answer*:
/// `WMX` returns a New York index stub at zero, `MG` returns a US
/// industrial-services company whose closes then sat in this book as an
/// Australian super fund's unit price for 836 days.
///
/// So the app asks the provider instead. The person recognises the name and the
/// exchange; the identifier is never typed, and the class of error goes away at
/// the only point it can.
struct NewSecuritySheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SecuritySearchResult] = []
    @State private var chosen: SecuritySearchResult?
    @State private var searching = false
    @State private var filling = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                Divider()
                content
            }
            .navigationTitle("New Security")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(chosen == nil || filling)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Company or ticker", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search for a security")
                    .onSubmit { search() }
                    .onChange(of: query) { _, _ in scheduleSearch() }
                if searching { ProgressView().controlSize(.small) }
            }
            // The prompt is not a label — HIG *Text fields*. And it says what
            // to type, because "search" alone leaves people guessing whether
            // this wants a name or a code. Either works.
            Text("Search a price provider by name or ticker — the exchange and identifier are filled in for you.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView {
                Label("Couldn’t search", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            }
        } else if results.isEmpty {
            ContentUnavailableView {
                Label(query.isEmpty ? "Find a security" : "Nothing found",
                      systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text(query.isEmpty
                     ? "Start typing a company name or ticker."
                     : "No listing matched. Try the company’s full name.")
            }
        } else {
            List(results, selection: Binding<Set<String>>(
                get: { chosen.map { [$0.id] } ?? [] },
                set: { ids in chosen = ids.first.flatMap { id in results.first { $0.id == id } } }
            )) { result in
                row(result).tag(result.id)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ result: SecuritySearchResult) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).lineLimit(1)
                HStack(spacing: 6) {
                    // The identifier is *shown* — so it can be recognised — but
                    // never typed. Seeing `WMX.AX` beside `WMX.XA` is what makes
                    // the choice between two listings of one company possible.
                    Text(result.symbol).monospaced()
                    if !result.exchange.isEmpty { Text(result.exchange) }
                    if !result.kind.isEmpty { Text(result.kind.capitalized) }
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.pricableSecurities.contains(where: {
                $0.mnemonic.caseInsensitiveCompare(result.symbol) == .orderedSame
            }) {
                Text("Already in this book")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Typing is a stream, not a question. Each keystroke cancels the last
    /// search rather than racing it — otherwise a slow early request lands
    /// after a fast later one and the list shows results for a prefix.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            search()
        }
    }

    private func search() {
        let term = query
        searching = true
        error = nil
        Task {
            defer { searching = false }
            do {
                let found = try await model.searchSecurities(matching: term)
                guard term == query else { return }   // a later keystroke won
                results = found
                chosen = found.first
            } catch {
                self.error = error.localizedDescription
                results = []
            }
        }
    }

    private func add() {
        guard let chosen else { return }
        guard let commodity = model.createSecurity(from: chosen) else {
            error = String(localized: "This book already holds that security.")
            return
        }
        filling = true
        Task {
            // Prices and company data, without a second trip to a menu: the
            // security is worth nothing until it has a price, and asking twice
            // for one obvious consequence is the friction this sheet removes.
            await model.fillNewSecurity(commodity)
            filling = false
            dismiss()
        }
    }
}
