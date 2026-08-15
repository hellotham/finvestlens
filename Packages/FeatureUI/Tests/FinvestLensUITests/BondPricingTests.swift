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
                                     fee: dec("22.68"), localAmount: dec("670.59"), alreadyForeign: false)
        #expect(believable.plausibleFee == dec("22.68"))

        let nonsense = NarrativeFX(transactionID: .random(), date: day(0), narrative: "",
                                   foreignAmount: dec("12.90"), currencyCode: "NZD",
                                   fee: dec("390.39"), localAmount: dec("11.51"), alreadyForeign: false)
        #expect(nonsense.plausibleFee == nil)
    }

    @Test("The implied rate is the local amount over the foreign")
    func impliedRate() {
        let row = NarrativeFX(transactionID: .random(), date: day(0), narrative: "",
                              foreignAmount: dec("1773.84"), currencyCode: "MYR",
                              fee: nil, localAmount: dec("670.59"), alreadyForeign: false)
        #expect(row.impliedRate > dec("0.378") && row.impliedRate < dec("0.379"))
    }

    /// A converted transaction stays in the list, **flagged** rather than
    /// filtered.
    ///
    /// Dropping it was the first design and it was wrong: the card fee still
    /// has to come out, and that pass needs the rate the conversion
    /// established — so a second run over an already-converted book found
    /// nothing at all to do, and the fees stayed merged.
    @Test("A converted transaction stays in the list, marked as converted")
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
        let after = try #require(model.narrativeForeignCandidates(accountName: "Card").first)
        #expect(after.alreadyForeign, "still listed, and known to be done")
        #expect(after.localAmount == dec("670.59"),
                "read from the quantity — `value` is the foreign figure now")
        // Asked to convert again, it declines rather than double-converting.
        #expect(model.restructureAsForeign(transactionID: id, foreignAmount: dec("1773.84"),
                                           currencyCode: "MYR") != .restructured)
    }
}

/// Separating a card's international transaction fee, and correcting a
/// transfer into an account already held in the foreign currency.
@MainActor
@Suite("Card fees and foreign accounts")
struct CardFeeTests {

    private func book() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    /// The Kuala Lumpur hotel, to the cent: 1,773.84 MYR charged as 670.59 AUD
    /// of which 22.68 was the fee.
    @Test("The fee leaves the goods leg and lands on its own, in both units")
    func feeSplit() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let card = try #require(model.addAccount(name: "Card", type: .credit, commodity: .aud))
        let lodging = try #require(model.addAccount(name: "Lodging", type: .expense, commodity: .aud))
        let fees = try #require(model.addAccount(name: "Bank", type: .expense, commodity: .aud))
        let myr = try #require(model.resolveCurrencyCode("MYR"))
        try model.addTransaction(date: day(0), description: "Hotel", currency: myr, splits: [
            SplitInput(accountID: card, value: dec("-1773.84"), quantity: dec("-670.59")),
            SplitInput(accountID: lodging, value: dec("1773.84"), quantity: dec("670.59")),
        ])
        let id = try #require(model.book?.transactions.last?.guid)

        let outcome = model.splitCardFee(transactionID: id, feeLocal: dec("22.68"),
                                         feeAccountID: fees)
        #expect(outcome.didSplit)

        let txn = try #require(model.book?.transaction(with: id))
        #expect(txn.splits.count == 3)
        #expect(txn.isBalanced, "the values still sum to zero in MYR")

        let feeLeg = try #require(txn.splits.first { $0.account?.name == "Bank" })
        #expect(feeLeg.quantity == dec("22.68"), "charged in AUD")
        // 22.68 AUD at 0.378042 is 59.99 MYR.
        #expect(feeLeg.value > dec("59") && feeLeg.value < dec("61"))

        let goods = try #require(txn.splits.first { $0.account?.name == "Lodging" })
        #expect(goods.quantity == dec("647.91"), "670.59 less the fee")
        // The card keeps the whole charge: that is what the statement says.
        let cardLeg = try #require(txn.splits.first { $0.account?.name == "Card" })
        #expect(cardLeg.quantity == dec("-670.59"))
    }

    /// Running twice must not charge the fee twice.
    @Test("A transaction that already has its fee out is left alone")
    func idempotent() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let card = try #require(model.addAccount(name: "Card", type: .credit, commodity: .aud))
        let lodging = try #require(model.addAccount(name: "Lodging", type: .expense, commodity: .aud))
        let fees = try #require(model.addAccount(name: "Bank", type: .expense, commodity: .aud))
        let myr = try #require(model.resolveCurrencyCode("MYR"))
        try model.addTransaction(date: day(0), description: "Hotel", currency: myr, splits: [
            SplitInput(accountID: card, value: dec("-1773.84"), quantity: dec("-670.59")),
            SplitInput(accountID: lodging, value: dec("1773.84"), quantity: dec("670.59")),
        ])
        let id = try #require(model.book?.transactions.last?.guid)

        #expect(model.splitCardFee(transactionID: id, feeLocal: dec("22.68"), feeAccountID: fees).didSplit)
        #expect(model.splitCardFee(transactionID: id, feeLocal: dec("22.68"), feeAccountID: fees)
                == .notSimple)
        #expect(model.book?.transaction(with: id)?.splits.count == 3)
    }

    /// A dry run may not promise more than the write delivers.
    @Test("Asking without applying writes nothing")
    func dryRunWritesNothing() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let card = try #require(model.addAccount(name: "Card", type: .credit, commodity: .aud))
        let lodging = try #require(model.addAccount(name: "Lodging", type: .expense, commodity: .aud))
        let fees = try #require(model.addAccount(name: "Bank", type: .expense, commodity: .aud))
        let myr = try #require(model.resolveCurrencyCode("MYR"))
        try model.addTransaction(date: day(0), description: "Hotel", currency: myr, splits: [
            SplitInput(accountID: card, value: dec("-1773.84"), quantity: dec("-670.59")),
            SplitInput(accountID: lodging, value: dec("1773.84"), quantity: dec("670.59")),
        ])
        let id = try #require(model.book?.transactions.last?.guid)

        #expect(model.splitCardFee(transactionID: id, feeLocal: dec("22.68"),
                                   feeAccountID: fees, apply: false).didSplit)
        #expect(model.book?.transaction(with: id)?.splits.count == 2, "still two legs")
    }

    /// Not every foreign row is a purchase. Eight of the reference book's were
    /// cash into a MYR account, credited with the **AUD** figure — so a 249.30
    /// MYR deposit read as 91.69 MYR and the account's balance was a third of
    /// the truth.
    @Test("A transfer into a foreign account is credited in that currency")
    func foreignAccountQuantity() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let card = try #require(model.addAccount(name: "Card", type: .credit, commodity: .aud))
        let myr = try #require(model.resolveCurrencyCode("MYR"))
        let wallet = try #require(model.addAccount(name: "MYR", type: .cash, commodity: myr))
        // As imported: the AUD figure copied into both fields.
        try model.addTransaction(date: day(0), description: "Cash", currency: .aud, splits: [
            SplitInput(accountID: card, value: dec("-91.69")),
            SplitInput(accountID: wallet, value: dec("91.69"), quantity: dec("91.69")),
        ])
        let id = try #require(model.book?.transactions.last?.guid)

        #expect(model.alignForeignAccountQuantity(transactionID: id,
                                                  foreignAmount: dec("249.30"),
                                                  currencyCode: "MYR"))
        let txn = try #require(model.book?.transaction(with: id))
        let leg = try #require(txn.splits.first { $0.account?.name == "MYR" })
        #expect(leg.value == dec("91.69"), "the card was charged in AUD, and still is")
        #expect(leg.quantity == dec("249.30"), "and that many ringgit arrived")
        #expect(txn.currency == .aud, "the transaction's own currency was never wrong")
        // The conversion the bank performed is a rate worth keeping.
        #expect(model.storedFxRate(code: "MYR", on: day(0)) != nil)

        // Idempotent: asked again, there is nothing left to correct.
        #expect(!model.alignForeignAccountQuantity(transactionID: id,
                                                   foreignAmount: dec("249.30"),
                                                   currencyCode: "MYR"))
    }
}

/// Where a security's company text is fetched from.
@MainActor
@Suite("Fundamentals routing")
struct FundamentalsRoutingTests {

    private func book() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    /// A bond is described only by the service that indexes bonds. Falling
    /// through to a ticker provider with an ISIN is why a bulk run over the
    /// reference book left all fifteen bonds without a word of company text.
    @Test("A security identified by ISIN asks FIIG for its profile")
    func bondsGoToFIIG() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        var bond = Commodity(namespace: .security("Bond"), mnemonic: "BNP-7.00%-02Jun31c",
                             fullName: "BNP", smallestFraction: 10_000)
        bond.exchangeCode = "FR0014014MD4"
        #expect(model.fundamentalsSource(for: bond)?.kind == .fiig)
    }

    /// And a share still goes to a ticker provider.
    @Test("A share is not sent to the bond index")
    func sharesDoNot() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let share = Commodity(namespace: .security("ASX"), mnemonic: "BHP.AX",
                              fullName: "BHP", smallestFraction: 10_000)
        #expect(model.fundamentalsSource(for: share)?.kind != .fiig)
    }

    /// An explicit per-security choice still wins over both.
    @Test("The user's own choice outranks the ISIN shortcut")
    func explicitChoiceWins() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        var bond = Commodity(namespace: .security("Bond"), mnemonic: "SOMEBOND",
                             fullName: "Some Bond", smallestFraction: 10_000)
        bond.exchangeCode = "AU3CB0327641"
        model.setQuoteProvider(.yahoo, for: bond)
        #expect(model.fundamentalsSource(for: bond)?.kind == .yahoo)
    }
}

/// Telling "ask again later" apart from "there is nothing here".
///
/// A bulk run over 85 securities provoked Yahoo into refusing — `getcrumb`
/// itself answered "Too Many Requests" — and the securities it refused were
/// recorded as having no company data. Those are opposite facts: one is a
/// wall to wait out, the other is a security nobody publishes on.
@MainActor
@Suite("Throttle detection")
struct ThrottleDetectionTests {

    @Test("A refusal is recognised however the provider words it")
    func recognised() {
        #expect(AppModel.looksRateLimited(.unavailable("Too Many Requests")))
        #expect(AppModel.looksRateLimited(.unavailable("HTTP 429")))
        #expect(AppModel.looksRateLimited(.unavailable("rate limit exceeded")))
        #expect(AppModel.looksRateLimited(.unavailable("Throttled, retry later")))
    }

    /// The distinction that matters: a security no provider covers must not be
    /// retried forever, and a throttled one must not be filed as empty.
    @Test("A genuine absence is not mistaken for a throttle")
    func absenceIsNotAThrottle() {
        #expect(!AppModel.looksRateLimited(.unavailable("Yahoo has no company data for this security.")))
        #expect(!AppModel.looksRateLimited(.unavailable("No configured provider supplies company data.")))
        #expect(!AppModel.looksRateLimited(.idle))
        #expect(!AppModel.looksRateLimited(.fetching))
        #expect(!AppModel.looksRateLimited(nil))
    }
}
