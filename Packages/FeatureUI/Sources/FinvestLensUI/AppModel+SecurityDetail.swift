//
//  AppModel+SecurityDetail.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes
import FinvestLensReports

// Phase I3 of the Investments hub (docs/investments-design.md §7): the bridge
// between the detail page and the report that assembles it, plus the
// per-security edits the page collects in one place — ticker override, ISIN,
// price entry and deletion, CSV export.

@MainActor
extension AppModel {

    /// Everything about one security (`FR-INV-15`), memoised on the book
    /// revision.
    ///
    /// The whole-book analyses it feeds on — price health and the advanced
    /// portfolio — are memoised too, so opening a detail page costs one pass
    /// over the price database for this security rather than the ~1.1s the
    /// overview's health scan takes.
    public func securityDetail(for commodity: Commodity) -> SecurityDetail? {
        guard let book else { return nil }
        let asOf = Self.endOfToday()
        let key = "secdetail:\(commodity.namespace)|\(commodity.mnemonic)"
            + ":\(asOf.timeIntervalSinceReferenceDate):\(costBasisMethod.rawValue):\(feeTreatment.rawValue)"
        return cachedReport(key) { [self] in
            FinancialReports.securityDetail(
                book, commodity: commodity, currency: reportCurrency, asOf: asOf,
                health: priceHealth()?.securities.first { $0.commodity == commodity },
                holdings: advancedPortfolio(asOf: asOf)?.holdings ?? [],
                lots: investmentLots(asOf: asOf))
        }
    }

    // MARK: Identifiers (`FR-INV-32`)

    /// The security's exchange code — an ISIN for a bond, an exchange ticker
    /// for a share (GnuCash `cmdty:xcode`).
    ///
    /// Read from the book's own commodity table rather than from the passed-in
    /// value, so the field reflects an edit made moments ago: the `Commodity`
    /// a view holds is a value type captured when the row was built.
    public func exchangeCode(for commodity: Commodity) -> String {
        book?.commodities.first { $0 == commodity }?.exchangeCode ?? commodity.exchangeCode ?? ""
    }

    /// Sets or clears the exchange code across every account, price and the
    /// commodity table.
    ///
    /// Whitespace-trimmed and upper-cased: an ISIN is defined upper-case, and a
    /// trailing space pasted from a statement is the difference between FIIG
    /// matching a bond and reporting it unknown.
    public func setExchangeCode(_ code: String, for commodity: Commodity) {
        guard let book else { return }
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned != exchangeCode(for: commodity) else { return }
        editingWholeBook(named: "Set Identifier") {
            book.updateCommodityMetadata(commodity, fullName: nil, smallestFraction: nil,
                                         exchangeCode: cleaned)
        }
    }

    // MARK: The price table (`FR-INV-27`)

    /// Replaces one price row's value, keeping its date, currency identity and
    /// GUID.
    ///
    /// The source is rewritten to `user:price-editor`, matching GnuCash's own
    /// convention: a figure a person typed over a fetched one is no longer the
    /// provider's, and leaving the old attribution in place would make the
    /// provenance column lie about exactly the row most likely to be wrong.
    public func updatePriceValue(_ id: GncGUID, to value: Decimal) {
        guard let book, let existing = book.prices.first(where: { $0.guid == id }),
              existing.value != value else { return }
        editingPrices(named: "Edit Price") {
            book.removePrice(id)
            // `preservingTime` because the stored instant is already the
            // book's one convention (10:59:00Z of its day); re-normalising it
            // would restamp a row an importer deliberately opted out of.
            book.addPrice(Price(guid: existing.guid, commodity: existing.commodity,
                                currency: existing.currency, date: existing.date,
                                value: value, source: "user:price-editor",
                                type: existing.type, preservingTime: true))
        }
    }

    /// This security's prices as CSV (`FR-INV-29`).
    public func priceCSV(for commodity: Commodity) -> String {
        FinancialReports.priceCSV(securityDetail(for: commodity)?.prices ?? [],
                                  symbol: commodity.mnemonic)
    }

    /// A filename a person will recognise a week later, and which sorts by
    /// security then by export date in a downloads folder.
    public func priceCSVFilename(for commodity: Commodity) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(commodity.mnemonic)-prices-\(formatter.string(from: Date())).csv"
    }

    // MARK: One security's fetch (`FR-INV-23`)

    /// Fills in missing history for one security, leaving what is already there.
    public func updatePrices(for commodity: Commodity, using kind: QuoteProviderKind? = nil) async {
        await updatePriceHistory(for: [commodity], using: kind ?? preferredProvider)
    }

    /// Rebuilds one security's history from scratch — but only if the fetch
    /// returns data, so a failed run can never wipe good prices.
    public func refetchPrices(for commodity: Commodity, using kind: QuoteProviderKind? = nil) async {
        await refetchPriceHistory(for: [commodity], using: kind ?? preferredProvider)
    }

    /// The provider a fetch uses when the caller does not name one: Yahoo when
    /// it is available (keyless, best ASX coverage — D5), otherwise whatever is
    /// configured.
    public var preferredProvider: QuoteProviderKind {
        availableProviders.contains(.yahoo) ? .yahoo : (availableProviders.first ?? .yahoo)
    }
}
