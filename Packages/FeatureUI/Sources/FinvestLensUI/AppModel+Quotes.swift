//
//  AppModel+Quotes.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes

/// Progress/result of a quote fetch, surfaced to the Quotes UI.
public enum QuoteFetchStatus: Equatable, Sendable {
    case idle
    /// A fetch is in progress; the string describes what.
    case fetching(String)
    /// A fetch finished, adding `count` prices.
    case success(Int)
    /// A fetch failed with a user-facing message.
    case failure(String)
}

@MainActor
extension AppModel {

    // MARK: API keys

    /// Providers that are ready to use: Yahoo always, keyed providers once a
    /// key is stored. (Key read/write goes straight to the store —
    /// `DocumentSettingsView` uses `apiKeys.key(for:)`/`setKey` directly.)
    public var availableProviders: [QuoteProviderKind] {
        QuoteProviderKind.allCases.filter { !$0.requiresAPIKey || (apiKeys.key(for: $0)?.isEmpty == false) }
    }

    // MARK: Symbol overrides

    private func symbolKey(_ commodity: Commodity) -> String {
        "\(commodity.namespace)|\(commodity.mnemonic)"
    }

    /// The quote ticker override for `commodity`, if set.
    public func quoteSymbol(for commodity: Commodity) -> String? {
        quoteSymbols[symbolKey(commodity)]
    }

    /// Sets or clears the quote ticker override for `commodity`.
    public func setQuoteSymbol(_ symbol: String?, for commodity: Commodity) {
        let key = symbolKey(commodity)
        if let symbol, !symbol.trimmingCharacters(in: .whitespaces).isEmpty {
            quoteSymbols[key] = symbol.trimmingCharacters(in: .whitespaces)
        } else {
            quoteSymbols[key] = nil
        }
        commitKvpCollections(named: "Set Quote Symbol")
    }

    // MARK: Auto-refresh (`FR-INV-03`)

    /// Whether quotes refresh on open and periodically (book preference).
    public var autoRefreshQuotes: Bool {
        get {
            if case let .int64(v)? = book?.kvp["finvestlens/autoRefreshQuotes"] { return v != 0 }
            return false
        }
        set {
            editingBookKvp(named: "Change Quote Auto-Refresh Setting") {
                book?.kvp["finvestlens/autoRefreshQuotes"] = .int64(newValue ? 1 : 0)
            }
            startQuoteAutoRefresh()
        }
    }

    /// Fetches the latest prices now, if auto-refresh is on and Yahoo (keyless)
    /// is available and there are securities to price.
    public func refreshQuotesNow() async {
        guard autoRefreshQuotes, !pricableSecurities.isEmpty,
              availableProviders.contains(.yahoo) else { return }
        await fetchLatestQuotes(using: .yahoo)
    }

    /// (Re)starts the periodic refresh loop: refreshes immediately, then every
    /// six hours while the document is open. Cancelled on close.
    public func startQuoteAutoRefresh() {
        quoteRefreshTask?.cancel()
        guard autoRefreshQuotes else { quoteRefreshTask = nil; return }
        quoteRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshQuotesNow()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Stops the periodic refresh loop.
    public func stopQuoteAutoRefresh() {
        quoteRefreshTask?.cancel()
        quoteRefreshTask = nil
    }

    // MARK: Fetching

    private func service() -> QuoteService {
        QuoteService(keys: apiKeys, http: quoteHTTP)
    }

    /// Fetches the latest quote for every held security using `kind` and adds a
    /// price for each success. Failures for individual symbols are collected but
    /// do not abort the run (`FR-INV-03`).
    public func fetchLatestQuotes(using kind: QuoteProviderKind) async {
        let commodities = pricableSecurities
        guard !commodities.isEmpty else {
            quoteStatus = .failure("No securities to price.")
            return
        }
        guard quoteProgress == nil else { return }   // one fetch run at a time
        quoteProgress = 0
        defer { quoteProgress = nil }
        quoteStatus = .fetching("latest quotes")
        let service = service()
        var fetched: [Price] = []
        var failures: [String] = []
        for (index, commodity) in commodities.enumerated() {
            do {
                fetched.append(try await service.latestPrice(
                    for: commodity, in: reportCurrency, using: kind,
                    symbolOverride: quoteSymbol(for: commodity)))
            } catch {
                failures.append("\(commodity.mnemonic): \(Self.describe(error))")
            }
            quoteProgress = Double(index + 1) / Double(commodities.count)
        }
        // Collected first, then applied in one go: the fetches await, and an
        // edit has to snapshot and mutate without suspending in between.
        // Identical same-day rows are skipped: the auto-refresh runs on every
        // book open, and over a closed-market weekend each run returned the
        // same Friday close — plain appends accumulated duplicate price rows
        // forever (and made the "already current" toast unreachable).
        let calendar = Calendar.current
        func rowKey(_ price: Price) -> String {
            let day = calendar.startOfDay(for: price.date).timeIntervalSinceReferenceDate
            return "\(price.commodity.namespace):\(price.commodity.mnemonic):\(day):\(price.value)"
        }
        var seen = Set((book?.prices ?? []).map(rowKey))
        let novel = fetched.filter { seen.insert(rowKey($0)).inserted }
        let added = novel.count
        if added > 0 {
            editingPrices(named: "Fetch Quotes") {
                for price in novel { book?.addPrice(price) }
            }
        }
        quoteStatus = failures.isEmpty
            ? .success(added)
            : .failure(String(localized: "Added \(added). Failed — \(failures.joined(separator: "; "))"))
        if failures.isEmpty {
            showToast(.success, added > 0
                ? String(localized: "Quotes fetched — \(added) prices added.")
                : String(localized: "Quotes are already current."))
        } else {
            showToast(.failure, String(localized: "Quote fetch: \(failures.count) symbols failed — see Prices for details."))
        }
    }

    /// Brings **every** held security's price history up to date (`FR-INV-03e`),
    /// filling gaps anywhere in the series — not just the trailing gap. For each
    /// security it fetches daily history spanning from the earliest date it cares
    /// about (the first holding date, or the earliest stored price if that is
    /// earlier) through today, then adds only the dates it does not already hold.
    /// That closes interior holes (a missing week mid-series) as well as the gap
    /// from the last price to today. Non-trading days (weekends/holidays) simply
    /// have no observation and are not treated as gaps. Providers without a
    /// history endpoint (Finnhub) fall back to a single latest quote.
    public func updatePriceHistory(using kind: QuoteProviderKind) async {
        await fetchHistory(for: pricableSecurities, using: kind, replacing: false,
                           label: "Update Price History")
    }

    /// The same gap-filling update, scoped to chosen securities (`FR-INV-23`).
    ///
    /// The distinction from ``refetchPriceHistory(for:using:)`` is the one that
    /// matters when a single holding has fallen behind: this **merges**, adding
    /// only dates the book does not already hold, while refetch replaces the
    /// series outright. A security whose early history was imported from
    /// GnuCash and whose recent years a provider stopped serving needs the
    /// former — the replacing form would discard the good years to fix the bad
    /// ones.
    public func updatePriceHistory(for commodities: [Commodity],
                                   using kind: QuoteProviderKind) async {
        await fetchHistory(for: commodities, using: kind, replacing: false,
                           label: "Update Price History")
    }

    /// The one-click path (redesign 6.4, ⌘⇧U): update every security's price
    /// history with the default provider and toast the outcome. The journey's
    /// most frequent task, callable from the menu, the Up Next card, and the
    /// Prices toolbar — no sheet, no provider picker.
    public func updateAllPrices() async {
        guard !pricableSecurities.isEmpty else {
            showToast(.info, "No securities to price.")
            return
        }
        guard quoteProgress == nil else { return }   // one run at a time
        let provider: QuoteProviderKind = availableProviders.contains(.yahoo)
            ? .yahoo : (availableProviders.first ?? .yahoo)
        await updatePriceHistory(using: provider)
    }

    /// When the newest security price landed, if any — "last updated" for the
    /// Prices header and the Up Next card.
    public var lastPriceUpdate: Date? {
        book?.prices.lazy
            .filter { $0.commodity.namespace != .currency }
            .map(\.date).max()
    }

    /// Rebuilds price history for `commodities` from scratch (`FR-INV-03e`): for
    /// each, fetches the full daily series from its first holding date through
    /// today and, **only if that fetch returns data**, replaces the security's
    /// existing prices with the fresh set. A failed or empty fetch leaves the
    /// existing prices untouched, so a bad network run can never wipe good data.
    public func refetchPriceHistory(for commodities: [Commodity],
                                    using kind: QuoteProviderKind) async {
        await fetchHistory(for: commodities, using: kind, replacing: true,
                           label: "Refetch Price History")
    }

    /// Shared engine for both update (merge) and refetch (replace). Fetches per
    /// security into a staging buffer first; the single book edit at the end only
    /// touches securities whose fetch succeeded, so failures never mutate the book.
    private func fetchHistory(for commodities: [Commodity], using kind: QuoteProviderKind,
                              replacing: Bool, label: String) async {
        guard !commodities.isEmpty else {
            quoteStatus = .failure(replacing ? "No securities selected." : "No securities to price.")
            return
        }
        // One run at a time — the guard used to live only on the ⌘⇧U wrapper,
        // so the Quotes sheet's buttons could start a second concurrent run
        // that snapshotted `existing` before the first committed and re-added
        // every price it fetched (and the first finisher's deferred
        // `quoteProgress = nil` killed the shared progress overlay).
        guard quoteProgress == nil else { return }
        let service = service()
        let calendar = Calendar.current
        let today = Date()

        // Dates already held per commodity — built once, so a big price database
        // is not rescanned per security.
        var existing: [Commodity: Set<Date>] = [:]
        for price in book?.prices ?? [] {
            existing[price.commodity, default: []].insert(calendar.startOfDay(for: price.date))
        }

        // Staged edits: commodities to wipe first (replace mode), and prices to add.
        var toReplace: Set<Commodity> = []
        var toAdd: [Price] = []
        var failures: [String] = []

        quoteProgress = 0
        defer { quoteProgress = nil }

        for (index, commodity) in commodities.enumerated() {
            quoteStatus = .fetching("\(commodity.mnemonic) (\(index + 1) of \(commodities.count))")
            let have = replacing ? [] : (existing[commodity] ?? [])

            // Span the whole holding period so interior gaps get filled, not just
            // the tail. In replace mode we always rebuild from the first holding.
            let anchors = [replacing ? nil : existing[commodity]?.min(),
                           firstHoldingDate(for: commodity)].compactMap { $0 }
            let start = anchors.min()
                ?? calendar.date(byAdding: .year, value: -5, to: today) ?? today

            do {
                let fetched: [Price]
                if kind.supportsHistory {
                    fetched = try await service.historicalPrices(
                        for: commodity, in: reportCurrency, from: start, to: today, using: kind,
                        symbolOverride: quoteSymbol(for: commodity))
                } else {
                    // No history endpoint: at least bring the latest price current.
                    fetched = [try await service.latestPrice(
                        for: commodity, in: reportCurrency, using: kind,
                        symbolOverride: quoteSymbol(for: commodity))]
                }
                // Refetch only overwrites when the fetch actually returned data.
                if replacing && !fetched.isEmpty { toReplace.insert(commodity) }
                let novel = fetched.filter { !have.contains(calendar.startOfDay(for: $0.date)) }
                toAdd.append(contentsOf: novel)
            } catch {
                failures.append("\(commodity.mnemonic): \(Self.describe(error))")
            }
            quoteProgress = Double(index + 1) / Double(commodities.count)
        }

        let added = toAdd.count
        if !toReplace.isEmpty || added > 0 {
            editingPrices(named: label) {
                if !toReplace.isEmpty {
                    book?.removePrices { toReplace.contains($0.commodity) }
                }
                for price in toAdd { book?.addPrice(price) }
            }
        }
        if failures.isEmpty {
            quoteStatus = .success(added)
            showToast(.success, added > 0
                ? String(localized: "Prices updated — \(added) new prices.")
                : String(localized: "Prices are already up to date."))
        } else {
            let detail = failures.joined(separator: "; ")
            quoteStatus = .failure(String(localized: "Added \(added). Failed — \(detail)"))
            showToast(.failure, String(localized: "Price update: added \(added), \(failures.count) failed — see Prices for details."))
        }
    }

    /// The earliest date any account denominated in `commodity` was posted to —
    /// where a security with no prices yet should start its history.
    private func firstHoldingDate(for commodity: Commodity) -> Date? {
        guard let book else { return nil }
        return book.accounts
            .filter { $0.commodity == commodity }
            .flatMap { book.splits(for: $0) }
            .compactMap { $0.transaction?.datePosted }
            .min()
    }

    private static func describe(_ error: Error) -> String {
        if let quoteError = error as? QuoteError {
            switch quoteError {
            case .missingAPIKey(let kind): return "\(kind.displayName) API key not set"
            case .unsupported(let message): return message
            case .httpStatus(let code): return "HTTP \(code)"
            case .malformedResponse(let detail): return "bad response (\(detail))"
            case .providerError(let message): return message
            case .noData: return "no data"
            }
        }
        return error.localizedDescription
    }
}
