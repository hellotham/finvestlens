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

/// Reading the foreign amount a card issuer wrote into the narrative.
///
/// Every string below is a real ANZ memo shape from the reference book,
/// including the malformed tails the bank actually writes ("2.2.94 AUD").
@MainActor
@Suite("Card narrative FX")
struct NarrativeFXTests {

    private func parse(_ memo: String) -> (amount: Decimal, code: String, fee: Decimal?)? {
        AppModel.parseNarrativeFX(memo)
    }

    @Test("The foreign amount and its currency are read")
    func amountAndCurrency() throws {
        let found = try #require(parse("RCP-Booking               George Town  1773.84  MYR22.68 AUD"))
        #expect(found.amount == dec("1773.84"))
        #expect(found.code == "MYR")
        #expect(found.fee == dec("22.68"))
    }

    @Test("Both currencies the book carries are read the same way")
    func bothCurrencies() throws {
        #expect(parse("SOFITEL KUALA LUMPUR DAMA KUALA LUMPUR  60.00  MYR 0.75 AUD")?.amount == dec("60"))
        #expect(parse("THE COFFEE CLUB           AUCKLAND  48.50  NZD 1.46 AUD")?.code == "NZD")
    }

    /// Two spaces before the figure is the anchor. Without it a street number
    /// in the merchant's address parses as a purchase.
    @Test("A domestic row with numbers in its address is not a purchase abroad")
    func domesticRow() {
        #expect(parse("MOTTOSOUTHBNE PTY LTD     MACQUARIE PAR") == nil)
        #expect(parse("SHELL COLES EXPRESS 1234  BRISBANE") == nil)
        // A narrative naming a currency is read whatever that currency is —
        // deciding it is *foreign* needs the transaction, and belongs to the
        // scan (`narrativeForeignCandidates`), not to the reader. AUD is not
        // special in a book that might be kept in something else.
        #expect(parse("SOMEWHERE                 SYDNEY  40.00  AUD")?.code == "AUD")
    }

    /// The bank's fee tail is not always well formed; a fee that cannot be read
    /// is better absent than invented.
    @Test("A malformed fee tail does not corrupt the amount")
    func malformedTail() throws {
        let found = try #require(parse("KTMB GO TICKETING         CYBERJAYA  228.00  MYR 2.2.94 AUD"))
        #expect(found.amount == dec("228"))
        #expect(found.code == "MYR")
    }

    /// A dry run over the real book produced a "fee" of 390.39 against an 11.51
    /// charge, from the parser running into the merchant's own text. A card fee
    /// is a small percentage; anything else is discarded rather than reported.
    @Test("An implausible fee is discarded, not reported")
    func implausibleFee() {
        let believable = NarrativeFX(transactionID: .random(), date: day(0), narrative: "",
                                     foreignAmount: dec("1773.84"), currencyCode: "MYR",
                                     fee: dec("22.68"), localAmount: dec("670.59"))
        #expect(believable.plausibleFee == dec("22.68"))

        let nonsense = NarrativeFX(transactionID: .random(), date: day(0), narrative: "",
                                   foreignAmount: dec("12.90"), currencyCode: "NZD",
                                   fee: dec("390.39"), localAmount: dec("11.51"))
        #expect(nonsense.plausibleFee == nil)
    }

    @Test("The implied rate is the local amount over the foreign")
    func impliedRate() {
        let row = NarrativeFX(transactionID: .random(), date: day(0), narrative: "",
                              foreignAmount: dec("1773.84"), currencyCode: "MYR",
                              fee: nil, localAmount: dec("670.59"))
        #expect(row.impliedRate > dec("0.378") && row.impliedRate < dec("0.379"))
    }

    /// The whole point of the scan: a transaction the book already holds as
    /// multi-currency has nothing left to recover.
    @Test("A transaction already in its own currency is not a candidate")
    func alreadyForeign() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let card = try #require(model.addAccount(name: "Card", type: .credit, commodity: .aud))
        let spend = try #require(model.addAccount(name: "Lodging", type: .expense, commodity: .aud))
        let memo = "RCP-Booking               George Town  1773.84  MYR22.68 AUD"
        try model.addTransaction(date: day(0), description: "Hotel", currency: .aud, splits: [
            SplitInput(accountID: card, value: dec("-670.59"), memo: memo),
            SplitInput(accountID: spend, value: dec("670.59")),
        ])
        #expect(model.narrativeForeignCandidates(accountName: "Card").count == 1)
        // Captured before anything else is posted: `.last` is the newest
        // transaction, and the next block adds one.
        let id = try #require(model.book?.transactions.last?.guid)

        // The scan is where a same-currency narrative is rejected.
        let domestic = try #require(model.addAccount(name: "Cash", type: .bank, commodity: .aud))
        try model.addTransaction(date: day(1), description: "Fuel", currency: .aud, splits: [
            SplitInput(accountID: domestic, value: dec("-40"),
                       memo: "SOMEWHERE                 SYDNEY  40.00  AUD"),
            SplitInput(accountID: spend, value: dec("40")),
        ])
        #expect(model.narrativeForeignCandidates(accountName: "Cash").isEmpty,
                "a narrative naming the account's own currency is not a conversion")
        #expect(model.restructureAsForeign(transactionID: id, foreignAmount: dec("1773.84"),
                                           currencyCode: "MYR") == .restructured)
        #expect(model.narrativeForeignCandidates(accountName: "Card").isEmpty,
                "recovered once, and not offered again")
    }
}
