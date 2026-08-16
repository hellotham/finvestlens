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

    /// The provider both unattended paths use: ⌘⇧U and the six-hourly
    /// auto-refresh (`FR-INV-22`).
    ///
    /// Both used to name Yahoo outright — `availableProviders.contains(.yahoo)
    /// ? .yahoo : …`, and Yahoo needs no key so that branch always won. A book
    /// configured for EODHD was therefore priced by Yahoo every six hours
    /// regardless, and on 12 Aug 2026 the reference book's daily coverage fell
    /// from 30 securities to 21 without a word: the provider had changed under
    /// it. Configuring a key has to be enough; asking someone to also pick the
    /// provider on every run is the same instruction twice.
    ///
    /// So: whatever the book was told to prefer, else a keyed provider if one
    /// is configured — going to the trouble of storing a key *is* the
    /// preference — and Yahoo only when nothing else is set up.
    /// One name for it, used by every caller that does not name a provider
    /// itself. There were **three** hardcoded copies of
    /// `contains(.yahoo) ? .yahoo : …` — in ⌘⇧U, in the six-hourly refresh, and
    /// as `preferredProvider` for the security pages — so "the default
    /// provider" meant Yahoo in three places and was configurable in none.
    public var preferredProvider: QuoteProviderKind { preferredQuoteProvider }

    public var preferredQuoteProvider: QuoteProviderKind {
        get {
            if case let .string(raw)? = book?.kvp["finvestlens/quoteProvider"],
               let stored = QuoteProviderKind(rawValue: raw),
               availableProviders.contains(stored) {
                return stored
            }
            return availableProviders.first { $0.requiresAPIKey } ?? .yahoo
        }
        set {
            editingBookKvp(named: "Change Price Provider") {
                book?.kvp["finvestlens/quoteProvider"] = .string(newValue.rawValue)
            }
        }
    }

    /// Removes price rows a provider wrote in a currency other than the one
    /// asked for (`FR-INV-40`).
    ///
    /// Those rows carry the provider's number stamped with the wrong currency —
    /// the mismatch was only ever noted in the `source` string, so nothing
    /// downstream could tell. `QuoteService` refuses to write them now; this
    /// clears the ones already in a book. Destructive, so it is explicit about
    /// scope and returns what it removed.
    @discardableResult
    public func pruneWrongCurrencyPrices(for commodities: [Commodity]) -> Int {
        let doomed = Set(commodities)
        var removed = 0
        editingPrices(named: "Remove Wrong-Currency Prices") {
            removed = book?.removePrices { price in
                doomed.contains(price.commodity)
                    && price.source.contains("Finance::Quote")
                    && price.source.contains("(")
            } ?? 0
        }
        return removed
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

    // MARK: Per-security provider (`FR-INV-22`)

    /// The provider chosen for this security, if any.
    public func quoteProvider(for commodity: Commodity) -> QuoteProviderKind? {
        quoteProviders[symbolKey(commodity)].flatMap(QuoteProviderKind.init(rawValue:))
    }

    /// Chooses a provider for one security, or clears the choice so the run's
    /// provider is used.
    public func setQuoteProvider(_ kind: QuoteProviderKind?, for commodity: Commodity) {
        quoteProviders[symbolKey(commodity)] = kind?.rawValue
        commitKvpCollections(named: "Set Quote Provider")
    }

    /// The provider a fetch should actually ask about `commodity` in a run
    /// nominally using `kind`: the security's own choice when it has one.
    ///
    /// A per-security choice outranks the run because it encodes something the
    /// run cannot know — that this particular security is a bond only FIIG
    /// prices. Without it, "Update Prices" would send eleven ISINs to Yahoo and
    /// report eleven failures, every time, forever.
    func effectiveProvider(for commodity: Commodity, in kind: QuoteProviderKind) -> QuoteProviderKind {
        guard let chosen = quoteProvider(for: commodity) else { return kind }
        // …unless the user has not configured it. A keyed provider with no key
        // cannot serve anything, and silently falling back beats failing the
        // security outright with an error about a key it does not have to have.
        return availableProviders.contains(chosen) ? chosen : kind
    }

    /// Securities FIIG could price but has not been asked to: they carry an
    /// ISIN-shaped identifier and no provider choice (`FR-INV-31`).
    ///
    /// Offered, never applied silently. An identifier that *looks* like an ISIN
    /// is not proof the bond is in FIIG's index, and quietly re-pointing a
    /// security's provider is the kind of change that is invisible until a
    /// price goes wrong.
    public var fiigCandidates: [Commodity] {
        pricableSecurities.filter { commodity in
            guard quoteProvider(for: commodity) == nil else { return false }
            return Self.looksLikeISIN(commodity.exchangeCode)
        }
    }

    /// Whether a code has an ISIN's shape: two country letters, nine
    /// alphanumeric characters of national number, and a check digit
    /// (ISO 6166).
    ///
    /// Shape only — the check digit is not verified, because the answer is used
    /// to *offer* FIIG rather than to assert the security is listed there. The
    /// index itself is the authority on that, and it is one request away.
    static func looksLikeISIN(_ code: String?) -> Bool {
        let trimmed = (code ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.count == 12 else { return false }
        let characters = Array(trimmed)
        return characters[0...1].allSatisfy(\.isLetter)
            && characters[2...10].allSatisfy { $0.isLetter || $0.isNumber }
            && characters[11].isNumber
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

    /// Fetches the latest prices now, if auto-refresh is on and there are
    /// securities to price — through the book's own provider, not Yahoo by
    /// assumption. This runs unattended every six hours, so a provider it
    /// picks for itself is a provider nobody chose.
    public func refreshQuotesNow() async {
        guard autoRefreshQuotes, !pricableSecurities.isEmpty,
              !availableProviders.isEmpty else { return }
        await fetchLatestQuotes(using: preferredQuoteProvider)
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

    /// The ticker overrides for `commodities`, in the shape the batch path
    /// wants.
    private func overrides(for commodities: [Commodity]) -> [Commodity: String] {
        var out: [Commodity: String] = [:]
        for commodity in commodities {
            if let symbol = quoteSymbol(for: commodity), !symbol.isEmpty {
                out[commodity] = symbol
            }
        }
        return out
    }

    /// Fetches the latest quote for every held security using `kind` and adds a
    /// price for each success. Failures for individual symbols are collected but
    /// do not abort the run (`FR-INV-03`).
    public func fetchLatestQuotes(using kind: QuoteProviderKind) async {
        let commodities = fetchableSecurities
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

        // Grouped by the provider each security actually goes to, so a book
        // holding both shares and bonds serves each from the service that can
        // price it (`FR-INV-22`, `FR-INV-31`). Batch providers then cost one
        // request for their whole group instead of one per security.
        var byProvider: [QuoteProviderKind: [Commodity]] = [:]
        for commodity in commodities {
            byProvider[effectiveProvider(for: commodity, in: kind), default: []].append(commodity)
        }
        var done = 0
        for (provider, group) in byProvider.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if provider.isBatch {
                quoteStatus = .fetching("\(provider.displayName) (\(group.count))")
                do {
                    let prices = try await service.latestPrices(
                        for: group, in: reportCurrency, using: provider,
                        symbolOverrides: overrides(for: group))
                    // A bond price arrives as percent of par; which unit that
                    // becomes is a fact about the security, not the provider.
                    fetched.append(contentsOf: normalisedParPercent(Array(prices.values),
                                                                    from: provider))
                    // A batch reports absences by omission, so the securities
                    // it did not cover are named here rather than lost — being
                    // absent from an index is the one thing a person can fix,
                    // by correcting the identifier.
                    for commodity in group where prices[commodity] == nil {
                        failures.append("\(commodity.mnemonic): not in \(provider.displayName)")
                    }
                } catch {
                    // One failed request is the whole group; say which.
                    failures.append("\(provider.displayName): \(Self.describe(error))")
                }
                done += group.count
                quoteProgress = Double(done) / Double(commodities.count)
                continue
            }
            for commodity in group {
                do {
                    let price = try await service.latestPrice(
                        for: commodity, in: reportCurrency, using: provider,
                        symbolOverride: quoteSymbol(for: commodity))
                    fetched.append(contentsOf: normalisedParPercent([price], from: provider))
                } catch {
                    failures.append("\(commodity.mnemonic): \(Self.describe(error))")
                }
                done += 1
                quoteProgress = Double(done) / Double(commodities.count)
            }
        }
        // **The sweep that makes coverage provider-independent.**
        //
        // Until now a security the chosen provider could not serve was simply
        // reported and left unpriced, so which securities got prices depended
        // on which provider happened to run. Measured on the reference book:
        // EODHD priced 30 securities a day to 11 Aug, Yahoo took over on the
        // 12th and priced 21, and eleven holdings quietly stopped being valued
        // — AMP, COL, IAG, LLC, PL8, PPT, VAP, VDHG, YMAX, MG, WMX. Nothing was
        // wrong with those securities; the run had changed underneath them.
        //
        // So anything still unpriced is offered to every *other* configured
        // provider before being called a failure. The priced set becomes the
        // union of what the book's providers can do between them, which is the
        // same set whichever one leads — and `Price.source` still records who
        // actually served each row, so the book never loses that.
        let servedSoFar = Set(fetched.map(\.commodity))
        let stillMissing = commodities.filter { !servedSoFar.contains($0) }
        if !stillMissing.isEmpty {
            var recovered: Set<Commodity> = []
            for commodity in stillMissing {
                let tried = effectiveProvider(for: commodity, in: kind)
                for alternate in availableProviders.sorted(by: { $0.rawValue < $1.rawValue })
                where alternate != tried && !alternate.matchesByIdentifier {
                    quoteStatus = .fetching("\(commodity.mnemonic) via \(alternate.displayName)")
                    if let price = try? await service.latestPrice(
                        for: commodity, in: reportCurrency, using: alternate,
                        symbolOverride: quoteSymbol(for: commodity)) {
                        fetched.append(contentsOf: normalisedParPercent([price], from: alternate))
                        recovered.insert(commodity)
                        break
                    }
                }
            }
            // A security recovered elsewhere is not a failure, so its first
            // provider's complaint comes off the list — otherwise every run
            // would report problems it had already solved.
            if !recovered.isEmpty {
                let names = Set(recovered.map(\.mnemonic))
                failures.removeAll { line in
                    names.contains(where: { line.hasPrefix("\($0):") })
                }
            }
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
        await fetchHistory(for: fetchableSecurities, using: kind, replacing: false,
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
        guard !fetchableSecurities.isEmpty else {
            showToast(.info, "No securities to price.")
            return
        }
        guard quoteProgress == nil else { return }   // one run at a time
        await updatePriceHistory(using: preferredQuoteProvider)
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

            // The security's own provider when it has one (`FR-INV-22`): a
            // bond's history request must reach FIIG, not the run's Yahoo.
            let provider = effectiveProvider(for: commodity, in: kind)

            do {
                let raw: [Price]
                if provider.supportsHistory {
                    raw = try await service.historicalPrices(
                        for: commodity, in: reportCurrency, from: start, to: today, using: provider,
                        symbolOverride: quoteSymbol(for: commodity))
                } else {
                    // No history endpoint: at least bring the latest price current.
                    raw = [try await service.latestPrice(
                        for: commodity, in: reportCurrency, using: provider,
                        symbolOverride: quoteSymbol(for: commodity))]
                }
                // Bond history arrives as percent of par, exactly like the
                // latest price, so it takes the same scaling — otherwise a
                // rebuilt series would sit a hundredfold away from the row the
                // daily fetch writes for the same bond.
                let fetched = normalisedParPercent(raw, from: provider)
                // Refetch only overwrites when the fetch actually returned data.
                // Never in the no-history case: replacing a series with the one
                // price a latest-only provider can give would delete a whole
                // history to install a single point, which is what "rebuild"
                // must never mean.
                if replacing && !fetched.isEmpty && provider.supportsHistory {
                    toReplace.insert(commodity)
                }
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
