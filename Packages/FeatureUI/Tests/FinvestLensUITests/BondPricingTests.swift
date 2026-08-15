//
//  BondPricingTests.swift
//  FinvestLens — FeatureUI
//
//  Bond prices are quoted per 100 of face value (`FR-INV-31`).
//
//  The reference book holds both live conventions at once, measured from its
//  own purchases on 15 Aug 2026 — ten bonds bought at 500 or 1,000 units and
//  ~100.5 per unit, one at 60,000 units and 0.8268. A provider cannot know
//  which a security uses, so the scale is chosen against what was paid.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensQuotes
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@MainActor
@Suite("Bond price scale")
struct BondPricingTests {

    private func book() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    private func bond(_ mnemonic: String) -> Commodity {
        Commodity(namespace: .security("Bond"), mnemonic: mnemonic,
                  fullName: mnemonic, smallestFraction: 10_000)
    }

    /// Buys `units` at `perUnit`, which is what teaches the book the scale.
    private func buy(_ model: AppModel, _ commodity: Commodity,
                     units: Decimal, perUnit: Decimal) throws {
        let holding = try #require(model.addAccount(name: commodity.mnemonic, type: .stock,
                                                    commodity: commodity))
        let cash = try #require(model.addAccount(name: "Cash \(commodity.mnemonic)",
                                                 type: .bank, commodity: .aud))
        let cost = units * perUnit
        try model.addTransaction(date: day(0), description: "Buy", currency: .aud, splits: [
            SplitInput(accountID: holding, value: cost, quantity: units),
            SplitInput(accountID: cash, value: -cost),
        ])
    }

    /// The ten-of-eleven case: $100 parcels, priced per $100. Dividing by 100
    /// here valued them at a hundredth of their worth — the defect reported on
    /// 15 Aug 2026 ("bond prices are not correct").
    @Test("A bond bought in $100 parcels keeps the market's per-100 figure")
    func perHundredConvention() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bnp = bond("AU3CB0327641")
        try buy(model, bnp, units: 500, perUnit: dec("100.6"))
        #expect(model.establishedUnitPrice(for: bnp) == dec("100.6"))
        // FIIG publishes 96.325 — and 500 × 96.325 = $48,163, which is the
        // right order of magnitude for a $50,000 face holding.
        #expect(model.parPercentScaled(dec("96.325"), for: bnp) == dec("96.325"))
    }

    /// And the one that genuinely is par-relative must not be multiplied.
    @Test("A bond held in dollars of face stays par-relative")
    func parRelativeConvention() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let jem = bond("AU300JEMF025")
        try buy(model, jem, units: 60_000, perUnit: dec("0.8268"))
        #expect(model.establishedUnitPrice(for: jem) == dec("0.8268"))
        #expect(model.parPercentScaled(dec("72.201"), for: jem) == dec("0.72201"))
    }

    /// Both, in one book, from one fetch — which is the case that makes a
    /// fixed divisor wrong whichever way it is set.
    @Test("One book can hold both conventions")
    func bothAtOnce() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let parcels = bond("AU3CB0328482")
        let face = bond("AU300JEMF025")
        try buy(model, parcels, units: 500, perUnit: dec("100.5"))
        try buy(model, face, units: 55_000, perUnit: dec("0.83"))

        let published = [
            Price(commodity: parcels, currency: .aud, date: day(1),
                  value: dec("97.639"), source: "Finance::Quote:fiig", type: "last"),
            Price(commodity: face, currency: .aud, date: day(1),
                  value: dec("72.201"), source: "Finance::Quote:fiig", type: "last"),
        ]
        let scaled = model.normalisedParPercent(published, from: .fiig)
        let byMnemonic = Dictionary(uniqueKeysWithValues:
            scaled.map { ($0.commodity.mnemonic, $0.value) })
        #expect(byMnemonic["AU3CB0328482"] == dec("97.639"))
        #expect(byMnemonic["AU300JEMF025"] == dec("0.72201"))
    }

    /// A ticker provider's prices are already per unit and must pass through
    /// untouched — the scaling is FIIG's alone.
    @Test("Only a par-percent provider is rescaled")
    func onlyParPercentProviders() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let share = Commodity(namespace: .security("ASX"), mnemonic: "BHP.AX",
                              fullName: "BHP", smallestFraction: 10_000)
        let price = Price(commodity: share, currency: .aud, date: day(1),
                          value: dec("41.55"), source: "Finance::Quote:yahoo", type: "last")
        #expect(model.normalisedParPercent([price], from: .yahoo).first?.value == dec("41.55"))
        #expect(QuoteProviderKind.fiig.reportsParPercent)
        #expect(!QuoteProviderKind.yahoo.reportsParPercent)
    }

    /// Nothing to learn from: par-relative, because a wrong guess that way is
    /// small rather than hundredfold.
    @Test("An unbought security falls back to par-relative")
    func noHistory() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let unknown = bond("XS9999999999")
        #expect(model.establishedUnitPrice(for: unknown) == nil)
        #expect(model.parPercentScaled(dec("99.5"), for: unknown) == dec("0.995"))
    }
}
