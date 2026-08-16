//
//  AppModel+SecurityLookup.swift
//  FinvestLens — FeatureUI
//
//  Adding a security by looking it up, not by typing its identifier
//  (`FR-INV-41`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes

@MainActor
extension AppModel {

    /// Finds securities matching a few words of name or ticker.
    ///
    /// Through Yahoo, whose search needs no key — so this works in a book that
    /// has configured nothing, which is exactly the book where someone is
    /// adding their first security.
    public func searchSecurities(matching query: String) async throws -> [SecuritySearchResult] {
        let provider = YahooQuoteProvider(http: quoteHTTP)
        return try await provider.searchSecurities(matching: query)
    }

    /// Creates a security from a search result and fills it in.
    ///
    /// **A security is not an account.** Several accounts can hold the same
    /// security — the same shares in two portfolios — so this registers the
    /// commodity and nothing else; opening an account to hold it is a separate
    /// act with a separate sheet. Conflating them is what made "add a security"
    /// mean "add an account" and left no way to do the first without the
    /// second.
    ///
    /// The identifier comes from the **provider**, suffix and all, which is the
    /// point of looking it up: `WMX.AX`, never the `WMX` a person would
    /// reasonably type and which finds a New York index stub priced at zero.
    ///
    /// Returns the commodity, or `nil` if the book already has it — adding a
    /// second copy of a security is never what was meant.
    @discardableResult
    public func createSecurity(from result: SecuritySearchResult) -> Commodity? {
        let namespace = result.exchange.trimmingCharacters(in: .whitespaces)
        let commodity = Commodity(
            namespace: .security(namespace.isEmpty ? "OTHER" : namespace.uppercased()),
            mnemonic: result.symbol.uppercased(),
            fullName: result.name,
            smallestFraction: 10_000)
        guard !(book?.commodities.contains(commodity) ?? false) else { return nil }
        editingWholeBook(named: "Add Security") {
            book?.registerCommodity(commodity)
        }
        return commodity
    }

    /// Fetches everything worth having about a newly added security: its price
    /// history and, where a provider serves them, its profile and financials.
    ///
    /// Separate from ``createSecurity(from:)`` because it awaits, and because a
    /// security is worth having in the book even if the network is not there.
    public func fillNewSecurity(_ commodity: Commodity) async {
        await updatePriceHistory(for: [commodity], using: preferredProvider)
        await fetchFundamentals(for: commodity, force: false)
    }
}
