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

        // The security's own provider first (`FR-INV-22`) — a bond's profile
        // comes from the bond service, and asking Yahoo about an ISIN returns
        // nothing. Then the run's default, but only if it serves fundamentals
        // at all: offering a Refetch that can only fail is worse than saying
        // the section is unavailable.
        let chosen = quoteProvider(for: commodity)
        let provider = (chosen?.servesFundamentals == true ? chosen : nil)
            ?? (preferredProvider.servesFundamentals ? preferredProvider : .yahoo)
        guard provider.servesFundamentals,
              let source = FundamentalsProviderFactory.make(provider, http: quoteHTTP,
                                                            crumbs: yahooCrumbs) else {
            fundamentalsStatus[key(commodity)] = .unavailable(
                String(localized: "No configured provider supplies company data."))
            return
        }

        fundamentalsStatus[key(commodity)] = .fetching
        defer { if fundamentalsStatus[key(commodity)] == .fetching {
            fundamentalsStatus[key(commodity)] = .idle
        } }

        let symbol = provider.providerSymbol(
            for: QuoteService.lookupKey(for: commodity,
                                        override: quoteSymbol(for: commodity), kind: provider))
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
            let source = provider.displayName
            if wanted.contains(.profile), fetched.profile == nil {
                fetched.profile = Stamped(SecurityProfile(), source: source)
            }
            if wanted.contains(.statements), fetched.statements == nil {
                fetched.statements = Stamped([], source: source)
            }
            if wanted.contains(.dividends), fetched.dividends == nil {
                fetched.dividends = Stamped([], source: source)
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
                String(localized: "\(source) has no company data for this security."))
        } catch {
            fundamentalsStatus[key(commodity)] = .unavailable(Self.describeFundamentals(error))
        }
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
