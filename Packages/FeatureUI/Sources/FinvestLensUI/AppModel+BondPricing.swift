//
//  AppModel+BondPricing.swift
//  FinvestLens — FeatureUI
//
//  Bond prices are quoted per 100 of face value; books do not agree on what a
//  "unit" of a bond is. This turns the market's number into the book's.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes

@MainActor
extension AppModel {

    /// Rescales prices from providers that publish a **percentage of par** into
    /// the unit each security's own records are kept in (`FR-INV-31`).
    ///
    /// Two conventions are in live use, and one book can hold both. Measured on
    /// the reference book, 15 Aug 2026, from the purchases themselves — value ÷
    /// quantity, which is what was actually paid and therefore cannot be an
    /// opinion:
    ///
    /// | Security | Units bought | Paid per unit | Meaning |
    /// |---|---|---|---|
    /// | ten of the eleven | 500 or 1,000 | ~100.5 | a unit is $100 of face, priced per $100 |
    /// | `AU300JEMF025` | 60,000 | 0.8268 | a unit is $1 of face, priced par-relative |
    ///
    /// So neither "always divide by 100" nor "never" is right. The provider
    /// reports what the market says (98.345) and this picks the scale that puts
    /// it beside the security's own history — which keeps a series internally
    /// consistent even where the two conventions sit side by side.
    ///
    /// A security with no purchase to learn from is left par-relative: that is
    /// the GnuCash default for a commodity whose quantity is denominated in
    /// currency units, and it is the reading under which a wrong guess is
    /// *small* rather than a hundredfold.
    func normalisedParPercent(_ prices: [Price], from kind: QuoteProviderKind) -> [Price] {
        guard kind.reportsParPercent else { return prices }
        return prices.map { price in
            var out = price
            out.value = parPercentScaled(price.value, for: price.commodity)
            return out
        }
    }

    /// One published par-percent figure, in this security's unit.
    func parPercentScaled(_ published: Decimal, for commodity: Commodity) -> Decimal {
        let perHundred = published
        let parRelative = published / 100
        guard let established = establishedUnitPrice(for: commodity) else {
            return parRelative
        }
        // Whichever reading sits closer to what this security has always cost.
        // Ratios, not differences: 100.5 against 0.8268 must not be judged on a
        // scale where every candidate near zero looks close.
        func distance(_ candidate: Decimal) -> Decimal {
            guard candidate > 0, established > 0 else { return .greatestFiniteMagnitude }
            return candidate > established ? candidate / established : established / candidate
        }
        return distance(perHundred) <= distance(parRelative) ? perHundred : parRelative
    }

    /// What one unit of this security has actually cost, from its own postings.
    ///
    /// The median of value ÷ quantity over every acquiring split — median, not
    /// mean, because one fat-fingered row should not move it, and acquiring
    /// only because a disposal's proceeds carry the same ratio anyway while a
    /// zero-value corporate-action leg does not.
    func establishedUnitPrice(for commodity: Commodity) -> Decimal? {
        guard let book else { return nil }
        var ratios: [Decimal] = []
        for account in book.accounts where account.commodity == commodity {
            for split in book.splits(for: account) where split.quantity > 0 && split.value > 0 {
                ratios.append(split.value / split.quantity)
            }
        }
        guard !ratios.isEmpty else { return nil }
        ratios.sort(by: <)
        return ratios[ratios.count / 2]
    }
}

@MainActor
extension AppModel {

    /// One price row whose unit disagrees with its own security's.
    public struct MisscaledPrice: Sendable {
        public let mnemonic: String
        public let date: Date
        public let from: Decimal
        public let to: Decimal
    }

    /// Brings every bond price onto the one scale its security is kept in.
    ///
    /// A book that has been priced by more than one route ends up holding both
    /// readings of "98.345": the hand-entered rows and the FIIG fetches that
    /// divided by 100 sit a hundredfold below the rows written since. A chart
    /// then draws a cliff, and a valuation is right or wrong depending on which
    /// row it lands on.
    ///
    /// The scale is not guessed: it is the security's own established unit
    /// price (``establishedUnitPrice(for:)``, from what was paid), falling back
    /// to the median of the rows themselves where nothing was ever bought. A
    /// row more than tenfold away from that is off by the factor of 100 and is
    /// multiplied or divided onto it; anything closer is a price movement and
    /// is left alone.
    @discardableResult
    public func rescaleBondPrices(apply: Bool) -> [MisscaledPrice] {
        guard let book else { return [] }
        var found: [MisscaledPrice] = []
        var corrections: [(Price, Decimal)] = []

        let bonds = Set(book.prices.map(\.commodity).filter {
            if case let .security(name) = $0.namespace {
                return name.localizedCaseInsensitiveContains("bond")
                    || name.localizedCaseInsensitiveContains("fiig")
            }
            return false
        })

        for commodity in bonds {
            let rows = book.prices.filter { $0.commodity == commodity }
            guard !rows.isEmpty else { continue }
            let anchor: Decimal
            if let paid = establishedUnitPrice(for: commodity) {
                // What was paid settles it however few rows there are — which
                // is the case that matters for a bond priced once by hand and
                // never fetched. Requiring two rows skipped exactly those.
                anchor = paid
            } else {
                // Nothing bought: the rows can only be judged against each
                // other, so a lone row has nothing to disagree with.
                guard rows.count > 1 else { continue }
                let values = rows.map(\.value).filter { $0 > 0 }.sorted(by: <)
                guard !values.isEmpty else { continue }
                anchor = values[values.count / 2]
            }
            guard anchor > 0 else { continue }

            for row in rows where row.value > 0 {
                let ratio = row.value > anchor ? row.value / anchor : anchor / row.value
                guard ratio > 10 else { continue }
                let corrected = row.value < anchor ? row.value * 100 : row.value / 100
                found.append(MisscaledPrice(mnemonic: commodity.mnemonic, date: row.date,
                                            from: row.value, to: corrected))
                corrections.append((row, corrected))
            }
        }

        guard apply, !corrections.isEmpty else { return found }
        editingPrices(named: "Rescale Bond Prices") {
            for (row, corrected) in corrections {
                var replacement = row
                replacement.value = corrected
                book.removePrices { $0.guid == row.guid }
                book.addPrice(replacement)
            }
        }
        return found
    }
}
