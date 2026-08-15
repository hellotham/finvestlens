//
//  AppModel+Fundamentals.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes

// Phase I5 of the Investments hub (docs/investments-design.md §10): company
// profile, financial statements and declared dividends, fetched on demand and
// cached **outside the book** (decision D2, `FR-INV-35`).
//
// The rule that shapes everything here: prices remain the only fetched thing
// that enters the document, so the two invariants — splits balance to zero,
// GnuCash XML round-trips byte-identically — are untouched by this whole
// feature. The cache is discardable at any time with no data loss.

/// What the detail page knows about a fetch in flight.
public enum FundamentalsStatus: Equatable, Sendable {
    case idle
    case fetching
    /// Nothing could be fetched, with a sentence a person can act on.
    case unavailable(String)
}

@MainActor
extension AppModel {

    /// The sidecar's cached record for a security, if any.
    ///
    /// Read-through only: this never fetches. A page draws what is cached and
    /// offers Refetch, because a network round trip on every scroll into a
    /// section is how a page earns a spinner it does not need.
    public func fundamentals(for commodity: Commodity) -> SecurityFundamentals? {
        fundamentalsCache.load(namespace: "\(commodity.namespace)",
                               mnemonic: commodity.mnemonic)
    }

    /// Fetches whatever is missing or stale, merges it over what is cached, and
    /// writes the result back (`FR-INV-17`, `FR-INV-18`, `FR-INV-19`).
    ///
    /// - Parameter force: refetch every section regardless of its TTL — the
    ///   **Refetch** the design requires to be always available, because a
    ///   figure a user believes is wrong must be re-checkable without waiting
    ///   out a month.
    public func fetchFundamentals(for commodity: Commodity, force: Bool = false) async {
        guard fundamentalsStatus[key(commodity)] != .fetching else { return }

        let cached = fundamentals(for: commodity) ?? SecurityFundamentals()
        let wanted = Set(FundamentalsKind.allCases.filter { force || cached.needsFetch($0) })
        guard !wanted.isEmpty else { return }

        guard let (kind, source) = fundamentalsSource(for: commodity) else {
            fundamentalsStatus[key(commodity)] = .unavailable(
                String(localized: "No configured provider supplies company data."))
            return
        }

        fundamentalsStatus[key(commodity)] = .fetching
        defer { if fundamentalsStatus[key(commodity)] == .fetching {
            fundamentalsStatus[key(commodity)] = .idle
        } }

        let symbol = kind.providerSymbol(
            for: QuoteService.lookupKey(for: commodity,
                                        override: quoteSymbol(for: commodity), kind: kind))
        do {
            var fetched = try await source.fundamentals(symbol: symbol, kinds: wanted)

            // **A "no" is an answer, and it has to be remembered.** Without
            // this, a security the provider has no statements for is asked
            // again every single time its page is opened — the section stays
            // empty, so it stays "never fetched", so it is fetched again,
            // forever. Recording an empty section makes the TTL apply to the
            // absence too. Only in the success path: a request that *failed*
            // records nothing, so a network blip does not suppress retries for
            // a quarter.
            // Named, not shadowed: `source` above is the provider itself and
            // this is its display name, and conflating the two is one edit away
            // from a bug.
            let sourceName = kind.displayName
            if wanted.contains(.profile), fetched.profile == nil {
                fetched.profile = Stamped(SecurityProfile(), source: sourceName)
            }
            if wanted.contains(.statements), fetched.statements == nil {
                fetched.statements = Stamped([], source: sourceName)
            }
            if wanted.contains(.dividends), fetched.dividends == nil {
                fetched.dividends = Stamped([], source: sourceName)
            }

            // Merged, never replaced: a provider that serves a profile but no
            // statements must not erase statements fetched last quarter.
            fundamentalsCache.save(cached.merging(fetched),
                                   namespace: "\(commodity.namespace)",
                                   mnemonic: commodity.mnemonic)
            // The cache is not observed, so nothing would redraw on its own.
            fundamentalsRevision &+= 1

            let gotSomething = fetched.profile?.value.isEmpty == false
                || fetched.statements?.value.isEmpty == false
                || fetched.dividends?.value.isEmpty == false
            fundamentalsStatus[key(commodity)] = gotSomething ? .idle : .unavailable(
                String(localized: "\(sourceName) has no company data for this security."))
        } catch {
            fundamentalsStatus[key(commodity)] = .unavailable(Self.describeFundamentals(error))
        }
    }

    /// Which provider should answer for this security's company data, and the
    /// client that will ask it.
    ///
    /// The order is decision **D5** made concrete:
    ///
    /// 1. **The security's own choice** (`FR-INV-22`), when it serves company
    ///    data — a bond's profile comes from the bond service, and asking Yahoo
    ///    about an ISIN returns nothing.
    /// 2. **A configured keyed provider**, preferred over the keyless default
    ///    because it is a documented API the user signed up to, rather than an
    ///    unofficial endpoint behind a rate-limited handshake.
    /// 3. **Yahoo**, which needs no key and covers equities.
    ///
    /// Returns `nil` only when nothing at all can answer, which on a default
    /// install cannot happen — Yahoo is always available.
    func fundamentalsSource(for commodity: Commodity)
        -> (kind: QuoteProviderKind, provider: FundamentalsProvider)? {

        func build(_ kind: QuoteProviderKind) -> (QuoteProviderKind, FundamentalsProvider)? {
            guard kind.servesFundamentals,
                  let provider = FundamentalsProviderFactory.make(
                    kind, apiKey: kind.requiresAPIKey ? apiKeys.key(for: kind) : nil,
                    http: quoteHTTP, crumbs: yahooCrumbs)
            else { return nil }
            return (kind, provider)
        }

        if let chosen = quoteProvider(for: commodity), let made = build(chosen) { return made }

        // Deterministic order, so the same book asks the same service every
        // time rather than whichever the key store happened to list first.
        for kind in QuoteProviderKind.allCases.sorted(by: { $0.rawValue < $1.rawValue })
        where kind.preferredForFundamentals {
            if let made = build(kind) { return made }
        }
        return build(.yahoo)
    }

    /// Forgets one security's cached data, so the next fetch starts clean.
    public func clearFundamentals(for commodity: Commodity) {
        fundamentalsCache.remove(namespace: "\(commodity.namespace)",
                                 mnemonic: commodity.mnemonic)
        fundamentalsRevision &+= 1
    }

    /// Forgets everything cached. Surfaced in Settings, because a cache the
    /// user cannot clear is a cache they cannot trust — and this one holds
    /// third-party licensed content.
    public func clearAllFundamentals() {
        fundamentalsCache.removeAll()
        fundamentalsRevision &+= 1
    }

    /// How much is cached, for the Settings line that says what clearing frees.
    public func fundamentalsCacheSummary() -> (securities: Int, bytes: Int) {
        (fundamentalsCache.count(), fundamentalsCache.sizeOnDisk())
    }

    /// The status of the most recent fetch for a security.
    public func fundamentalsStatus(for commodity: Commodity) -> FundamentalsStatus {
        fundamentalsStatus[key(commodity)] ?? .idle
    }

    private func key(_ commodity: Commodity) -> String {
        "\(commodity.namespace)|\(commodity.mnemonic)"
    }

    /// A sentence, not an error code. Every one of these is something a person
    /// can either act on or stop worrying about.
    static func describeFundamentals(_ error: Error) -> String {
        guard let quoteError = error as? QuoteError else {
            return String(localized: "Company data could not be fetched.")
        }
        switch quoteError {
        case .missingAPIKey(let kind):
            return String(localized: "\(kind.displayName) needs an API key, set in Settings ▸ Pricing.")
        case .unsupported(let message), .providerError(let message):
            return message
        case .httpStatus(429):
            // Worth its own sentence. Yahoo rate-limits the company-data
            // handshake per address and hard — the same request answers fully
            // one minute and refuses the next — so the useful advice is to wait,
            // not to check a setting. Prices are unaffected: they come from a
            // different endpoint that needs no handshake.
            return String(localized: "The provider is limiting requests just now. Prices are unaffected — try company data again shortly.")
        case .httpStatus(let code):
            return String(localized: "The provider refused the request (HTTP \(code)).")
        case .malformedResponse:
            return String(localized: "The provider's reply was not in the expected form.")
        case .noData:
            return String(localized: "The provider has no company data for this security.")
        }
    }
}

// MARK: - Bulk (`FR-INV-17`…`FR-INV-19`)

@MainActor
extension AppModel {

    /// How a bulk fundamentals run is going, for the progress strip.
    public struct FundamentalsRun: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var current: String
        public var filled: Int
        public var failures: [String]
        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    /// Fetches company profile and financials for **every** security that has a
    /// provider able to supply them.
    ///
    /// There was no way to do this. `fetchFundamentals(for:)` is called from
    /// two buttons on one security's page, so filling a portfolio meant opening
    /// every holding in turn and pressing Fetch — asked about on 15 Aug 2026
    /// ("how do I populate security profile and financials in bulk?"), and the
    /// honest answer was that you could not.
    ///
    /// Bonds are the case that makes this cheap rather than merely convenient:
    /// FIIG's profile comes from the same one-request index the prices come
    /// from, and every bond's `companyDescription` is already in that payload —
    /// so a whole book of bonds costs one round trip per bond only because the
    /// per-security call re-asks, and the TTL then keeps it that way.
    ///
    /// Sequential on purpose. These are the same rate-limited hosts the quote
    /// fetch uses (Yahoo's crumb handshake in particular), and a fan-out over
    /// fifty securities is how a provider starts refusing.
    ///
    /// - Parameter force: refetch every section regardless of its TTL.
    public func fetchAllFundamentals(force: Bool = false) async {
        let securities = pricableSecurities.filter { fundamentalsSource(for: $0) != nil }
        guard !securities.isEmpty else {
            fundamentalsRun = nil
            showToast(.failure, String(localized: "No configured provider supplies company data."))
            return
        }
        var run = FundamentalsRun(done: 0, total: securities.count, current: "",
                                  filled: 0, failures: [])
        fundamentalsRun = run
        for commodity in securities {
            run.current = commodity.mnemonic
            fundamentalsRun = run
            await fetchFundamentals(for: commodity, force: force)
            // What the run achieved, judged by what is now on the security
            // rather than by the call having returned: a provider that answers
            // "no statements for this one" is a completed fetch and an empty
            // security, and reporting it as filled would overstate the run.
            if let facts = fundamentals(for: commodity), facts.profile != nil {
                run.filled += 1
            } else if case let .unavailable(reason)? = fundamentalsStatus[key(commodity)] {
                run.failures.append("\(commodity.mnemonic): \(reason)")
            }
            run.done += 1
            fundamentalsRun = run
        }
        fundamentalsRun = nil
        if run.failures.isEmpty {
            showToast(.success, String(localized: "Company data updated for \(run.filled) securities."))
        } else {
            showToast(.failure, String(localized: "\(run.filled) updated, \(run.failures.count) unavailable."))
        }
    }
}
