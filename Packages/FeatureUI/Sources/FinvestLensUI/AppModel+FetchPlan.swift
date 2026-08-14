//
//  AppModel+FetchPlan.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes
import FinvestLensReports

// Phase I7 of the Investments hub (docs/investments-design.md §6): choosing what
// a refresh covers, and being able to see what it will do before it does it.
//
// The default has always been "everything", and on the reference book that
// meant asking a provider about 87 securities, 48 of which are no longer held
// and 22 of which no service has ever priced. The scope makes the common case
// small and the uncommon case possible; the preview makes both legible.

/// What a refresh covers (`FR-INV-25`).
public enum FetchScope: String, CaseIterable, Identifiable, Sendable {
    /// Everything held that a provider can price. The everyday case.
    case holdings
    /// Only holdings that are actually behind. The cheapest useful run.
    case stale
    /// Holdings, plus **closed positions whose held period has a hole**.
    ///
    /// D4 in one sentence: a closed position is not worth today's price, but a
    /// gap inside the period it *was* held silently corrupts historical net
    /// worth and every past valuation — so it is worth fetching once, not
    /// daily.
    case withClosedGaps

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .holdings: String(localized: "All holdings")
        case .stale: String(localized: "Only what's behind")
        case .withClosedGaps: String(localized: "Include closed positions with gaps")
        }
    }
}

/// What a run will do, before it does it (`FR-INV-34`).
public struct FetchPlan: Sendable {
    /// Securities that will be asked about, in the order they will be asked.
    public var securities: [Commodity]
    /// How many will go to each provider — a batch provider's whole group is
    /// one request, which is the point of showing this at all.
    public var byProvider: [QuoteProviderKind: Int]
    /// Requests the run will actually make.
    public var requests: Int
    /// Securities with a hole inside a period they were held.
    public var withGaps: Int
    /// Held securities the scope leaves out, so an empty plan is explicable.
    public var skipped: Int

    public var isEmpty: Bool { securities.isEmpty }
}

@MainActor
extension AppModel {

    /// The chosen scope for a refresh. A book preference: which securities are
    /// worth chasing is a property of this book's holdings.
    public var fetchScope: FetchScope {
        get {
            if case let .string(raw)? = book?.kvp["finvestlens/fetchScope"],
               let scope = FetchScope(rawValue: raw) { return scope }
            return .holdings
        }
        set {
            editingBookKvp(named: "Change Update Scope") {
                book?.kvp["finvestlens/fetchScope"] = .string(newValue.rawValue)
            }
        }
    }

    /// The securities a run under `scope` will ask about (`FR-INV-25`).
    public func securities(in scope: FetchScope) -> [Commodity] {
        let fetchable = fetchableSecurities
        guard let health = priceHealth() else { return fetchable }
        let byCommodity = Dictionary(uniqueKeysWithValues:
            health.securities.map { ($0.commodity, $0) })

        return fetchable.filter { commodity in
            guard let row = byCommodity[commodity] else {
                // Unknown to the health report means no prices and no
                // movements — a watch-list entry. Worth asking about: that is
                // what watching it means.
                return true
            }
            switch scope {
            case .holdings:
                return row.isHeld
            case .stale:
                // A holding that is already current costs a request to be told
                // what the book already knows.
                return row.isHeld && row.freshness.needsAttention
            case .withClosedGaps:
                // Held, or closed with a hole inside the period it was held.
                return row.isHeld || row.missingWhileHeld > 0
            }
        }
    }

    /// What a run under `scope` will do, without doing it (`FR-INV-34`).
    ///
    /// The number that matters is **requests, not securities**: a batch
    /// provider's whole group is one request, so eleven bonds and one share is
    /// two requests, not twelve. Showing securities alone would make the
    /// cheapest scope look like the most expensive.
    public func fetchPlan(scope: FetchScope? = nil,
                          using kind: QuoteProviderKind? = nil) -> FetchPlan {
        let scope = scope ?? fetchScope
        let run = kind ?? preferredProvider
        let chosen = securities(in: scope)

        var byProvider: [QuoteProviderKind: Int] = [:]
        for commodity in chosen {
            byProvider[effectiveProvider(for: commodity, in: run), default: 0] += 1
        }
        let requests = byProvider.reduce(0) { total, entry in
            total + (entry.key.isBatch ? 1 : entry.value)
        }

        let gapped = priceHealth()?.securities
            .filter { chosen.contains($0.commodity) && $0.missingWhileHeld > 0 }
            .count ?? 0

        return FetchPlan(securities: chosen, byProvider: byProvider, requests: requests,
                         withGaps: gapped, skipped: fetchableSecurities.count - chosen.count)
    }

    /// Updates prices under the current scope — what ⌘⇧U now means.
    public func updatePrices(scope: FetchScope? = nil,
                             using kind: QuoteProviderKind? = nil) async {
        let chosen = securities(in: scope ?? fetchScope)
        guard !chosen.isEmpty else {
            quoteStatus = .failure(String(localized: "Nothing to update in this scope."))
            return
        }
        await updatePriceHistory(for: chosen, using: kind ?? preferredProvider)
    }

    // MARK: Manual valuation (`FR-INV-30`)

    /// How often a hand-valued security is expected to be revalued.
    ///
    /// A super fund posts a unit price monthly or quarterly; a private holding
    /// may only be revalued once a year. Without an expected cadence, every
    /// hand-valued security is permanently "old" and the worklist tells the
    /// user off for something that is not late — which is how a worklist stops
    /// being read.
    public enum ValuationCadence: String, CaseIterable, Identifiable, Sendable {
        case monthly, quarterly, halfYearly, yearly, never

        public var id: String { rawValue }

        public var days: Int? {
            switch self {
            case .monthly: 31
            case .quarterly: 92
            case .halfYearly: 184
            case .yearly: 366
            // Not a cadence: a holding valued once and never again — a
            // collectable, a private company — is not overdue, ever.
            case .never: nil
            }
        }

        public var label: String {
            switch self {
            case .monthly: String(localized: "Monthly")
            case .quarterly: String(localized: "Quarterly")
            case .halfYearly: String(localized: "Every six months")
            case .yearly: String(localized: "Yearly")
            case .never: String(localized: "Only when I say")
            }
        }
    }

    /// The cadence set for a hand-valued security, defaulting to quarterly —
    /// what an Australian super fund typically publishes.
    public func valuationCadence(for commodity: Commodity) -> ValuationCadence {
        valuationCadences["\(commodity.namespace)|\(commodity.mnemonic)"]
            .flatMap(ValuationCadence.init(rawValue:)) ?? .quarterly
    }

    public func setValuationCadence(_ cadence: ValuationCadence, for commodity: Commodity) {
        valuationCadences["\(commodity.namespace)|\(commodity.mnemonic)"] = cadence.rawValue
        commitKvpCollections(named: "Set Valuation Cadence")
    }

    /// Whether a hand-valued security is genuinely overdue for a new figure.
    ///
    /// Judged against its own cadence, not against the trading calendar: a
    /// super fund is not stale on a Tuesday because the ASX traded.
    public func isValuationOverdue(_ commodity: Commodity, asOf: Date = Date()) -> Bool {
        guard let days = valuationCadence(for: commodity).days else { return false }
        guard let last = book?.latestPrice(of: commodity, in: reportCurrency)?.date else {
            // Never valued at all is overdue by definition — there is no figure
            // to trust.
            return true
        }
        let elapsed = asOf.timeIntervalSince(last) / 86_400
        return elapsed > Double(days)
    }
}
