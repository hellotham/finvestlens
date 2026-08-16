//
//  RegisterFXTests.swift
//  FinvestLens — FeatureUI
//
//  Entering a foreign-currency transaction in the register (`FR-CUR-02`,
//  `FR-REG-07`).
//
//  The shape under test is GnuCash's, verified against its source rather than
//  its documentation: a split's `value` is in the **transaction's** currency
//  and its `quantity` in the **account's** commodity (`Split.h:251-265`), so
//  the ratio of the two *is* the exchange rate and there is nothing else to
//  store. Trading accounts (`xaccTransUseTradingAccounts`,
//  `Transaction.cpp:983`) are an optional book flag that make currency
//  gain/loss explicit — they are not how the two amounts are recorded, which
//  is why none of these tests needs one.
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
@Suite("Register FX entry")
struct RegisterFXTests {

    /// An AUD book with a card and an expense category — the shape of the case
    /// this exists for: a purchase abroad on a local card, where *no* account
    /// is foreign and the foreignness belongs to the transaction alone.
    private func book() throws -> (model: AppModel, card: GncGUID,
                                   expense: GncGUID, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let card = try #require(model.addAccount(name: "Card", type: .credit, commodity: .aud))
        let expense = try #require(model.addAccount(name: "Travel", type: .expense, commodity: .aud))
        return (model, card, expense, url)
    }

    private func localDraft(card: GncGUID, expense: GncGUID) -> TransactionDraft {
        var out = EditableSplit()
        out.accountID = card
        out.amountText = "-600"
        var into = EditableSplit()
        into.accountID = expense
        into.amountText = "600"
        return TransactionDraft(transactionID: .random(), date: day(0),
                                description: "Hotel", notes: "", tagsText: "",
                                lines: [out, into], currencyOverride: nil)
    }

    // MARK: The draft

    /// Naming a currency must not silently redenominate the figures already
    /// typed: 600 AUD is what left the card, so it becomes each leg's
    /// *quantity* and the value waits for the foreign amount.
    @Test("Setting a currency moves the local amounts to quantities")
    func settingCurrencyMovesFigures() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        var draft = localDraft(card: card, expense: expense)
        let myr = try #require(model.resolveCurrencyCode("MYR"))
        draft.setCurrency(myr, text: "MYR")

        #expect(draft.lines[0].quantityText == "-600")
        #expect(draft.lines[1].quantityText == "600")
        #expect(draft.lines[0].amountText.isEmpty, "the foreign figure is not yet known")
        #expect(draft.lines[1].amountText.isEmpty)
        #expect(draft.currencyOverride == myr)
    }

    /// And the move is reversible — the way out of a currency chosen by
    /// mistake, without retyping the amounts.
    @Test("Clearing the currency puts the local amounts back")
    func clearingCurrencyRestoresFigures() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        var draft = localDraft(card: card, expense: expense)
        draft.setCurrency(model.resolveCurrencyCode("MYR"), text: "MYR")
        draft.setCurrency(nil, text: "")

        #expect(draft.lines[0].amountText == "-600")
        #expect(draft.lines[1].amountText == "600")
        #expect(draft.lines.allSatisfy { $0.quantityText.isEmpty })
        #expect(draft.currencyOverride == nil)
    }

    /// One number instead of one per leg — GnuCash's `RATE_CELL`.
    @Test("A rate fills every leg's foreign value, signs intact")
    func rateFillsValues() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        var draft = localDraft(card: card, expense: expense)
        let myr = try #require(model.resolveCurrencyCode("MYR"))
        draft.setCurrency(myr, text: "MYR")
        // 1 MYR = 0.3383 AUD, so 600 AUD is 1,773.57 MYR.
        draft.applyRate(dec("0.3383"), rounding: myr)

        #expect(draft.lines[0].amount == dec("-1773.57"))
        #expect(draft.lines[1].amount == dec("1773.57"))
        #expect(draft.imbalance == 0, "an FX transaction still balances in its own currency")
    }

    /// A rate typed after the amounts is a check, not an overwrite — otherwise
    /// entering the true figures then glancing at the rate would destroy them.
    @Test("A rate leaves legs that already carry a value alone")
    func rateDoesNotOverwrite() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        var draft = localDraft(card: card, expense: expense)
        draft.setCurrency(model.resolveCurrencyCode("MYR"), text: "MYR")
        draft.lines[0].amountText = "-1773.84"
        draft.applyRate(dec("0.3383"), rounding: nil)

        #expect(draft.lines[0].amountText == "-1773.84", "the typed figure survived")
        #expect(draft.lines[1].amount != 0, "the untouched leg was still filled")
    }

    /// The rate is derived, never stored — so it cannot disagree with the
    /// amounts it is supposed to describe.
    @Test("The implied rate is quantity over value")
    func impliedRate() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        var draft = localDraft(card: card, expense: expense)
        draft.setCurrency(model.resolveCurrencyCode("MYR"), text: "MYR")
        draft.lines[0].amountText = "-1200"          // 1,200 MYR
        // 600 AUD ÷ 1,200 MYR = 0.5 AUD per MYR.
        #expect(draft.impliedRate == dec("0.5"))
        #expect(localDraft(card: card, expense: expense).impliedRate == nil,
                "a single-currency transaction has no rate to show")
    }

    // MARK: Validation

    @Test("A currency cell accepts blank and ISO codes, and nothing else")
    func currencyValidation() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(model.resolveCurrencyCode("myr")?.mnemonic == "MYR", "case is not the user's problem")
        #expect(model.resolveCurrencyCode("AUD") != nil)
        #expect(model.resolveCurrencyCode("MY") == nil, "two letters is not a currency")
        #expect(model.resolveCurrencyCode("ZZZ") == nil, "a typo must not invent a currency")
        #expect(model.resolveCurrencyCode("12") == nil)

        var draft = localDraft(card: card, expense: expense)
        #expect(draft.currencyIsValid, "blank means: derive it from the accounts")
        draft.setCurrency(nil, text: "ZZZ")
        #expect(!draft.currencyIsValid)
        #expect(!draft.isBalanced, "an unresolvable currency has to block the save")
    }

    // MARK: Round trip through the book

    /// The whole point: what the register writes is the structure GnuCash
    /// reads back — value in the transaction currency, quantity in the
    /// account's — and the register can then say so on the row.
    @Test("A register FX edit round-trips as value and quantity")
    func roundTrip() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let myr = try #require(model.resolveCurrencyCode("MYR"))
        try model.addTransaction(date: day(0), description: "Hotel", currency: myr, splits: [
            SplitInput(accountID: card, value: dec("-1773.57"), quantity: dec("-600")),
            SplitInput(accountID: expense, value: dec("1773.57"), quantity: dec("600")),
        ])
        let id = try #require(model.book?.transactions.last?.guid)

        #expect(model.foreignCurrencyCode(ofTransaction: id) == "MYR")
        let rate = try #require(model.rate(ofTransaction: id))
        // 600 ÷ 1,773.57 ≈ 0.3383 AUD per MYR.
        #expect(rate > dec("0.338") && rate < dec("0.339"))

        // The register shows the account's own money, not the foreign figure:
        // the card really did lose 600 AUD.
        model.selectedAccountID = card
        let row = try #require(model.registerRows.last)
        #expect(row.amount == dec("-600"))
        #expect(row.foreignCurrencyCode == "MYR", "and says which currency it was struck in")

        // A same-currency transaction says nothing, which is what keeps the
        // cell empty on every ordinary row.
        try model.addTransaction(date: day(1), description: "Groceries", currency: .aud, splits: [
            SplitInput(accountID: card, value: dec("-50")),
            SplitInput(accountID: expense, value: dec("50")),
        ])
        #expect(model.registerRows.last?.foreignCurrencyCode == nil)
    }

    /// A rate is a price: recording it is what makes the *next* conversion
    /// need no typing at all.
    @Test("A stored rate is offered for the next transaction")
    func storedRatePrefills() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let myr = try #require(model.resolveCurrencyCode("MYR"))
        model.addExchangeRate(from: myr, to: .aud, rate: dec("0.3383"), date: day(0))
        let stored = try #require(model.storedFxRate(code: "MYR", on: day(0)))
        #expect(stored == dec("0.3383"))

        var draft = localDraft(card: card, expense: expense)
        draft.setCurrency(myr, text: "MYR")
        draft.applyRate(stored, rounding: myr)
        #expect(draft.lines[0].amount == dec("-1773.57"))
    }
}

/// What a document says about its currency, and what the app does when it
/// cannot be sure.
///
/// The rule (15 Aug 2026): **ask, showing the evidence.** Detection used to
/// return one answer and refuse `$` outright, so a US invoice produced nothing
/// and the caller read that as "domestic" — the whole of the reported
/// "sporadic" behaviour.
@MainActor
@Suite("Document currency evidence")
struct DocumentCurrencyTests {

    private func candidates(_ text: String) -> [String] {
        AppModel.currencyCandidates(in: text)
    }

    @Test("A qualified dollar names exactly one currency")
    func qualifiedDollars() {
        #expect(candidates("Total US$1,234.56") == ["USD"])
        #expect(candidates("Total S$980.00") == ["SGD"])
        #expect(candidates("Total NZ$44.10") == ["NZD"])
        #expect(candidates("Total HK$980.00") == ["HKD"])
        // And therefore needs no question.
        #expect(AppModel.currencyHint(in: "Total US$1,234.56") == "USD")
    }

    /// The case that used to yield nothing at all.
    @Test("A bare dollar names its several candidates instead of nothing")
    func bareDollarIsAmbiguous() {
        let found = candidates("Amount due $1,234.56")
        #expect(found.contains("USD"))
        #expect(found.contains("AUD"))
        #expect(found.count > 1, "a bare $ is a question, not an answer")
        #expect(AppModel.currencyHint(in: "Amount due $1,234.56") == nil,
                "and the automatic path must not guess between them")
    }

    @Test("An ISO code or an unambiguous symbol still answers outright")
    func codesAndSymbols() {
        #expect(candidates("Total MYR 1,773.84") == ["MYR"])
        #expect(candidates("Jumlah RM 1,773.84") == ["MYR"])
        #expect(candidates("Totale €89,00") == ["EUR"])
        #expect(candidates("Total ฿2,400") == ["THB"])
    }

    @Test("A document naming no currency yields none")
    func silentDocument() {
        #expect(candidates("Invoice 4471 — thank you for your business").isEmpty)
    }

    /// The boundaries these patterns need, each one a way the detector read a
    /// currency into an ordinary word. `S$` inside `US$` is the one that got
    /// through and turned every American invoice Singaporean.
    @Test("Currency tokens are not read out of the middle of words")
    func wordBoundaries() {
        #expect(!candidates("Total US$1,234.56").contains("SGD"))
        #expect(!candidates("FIRM QUOTE 1,234.56").contains("MYR"), "RM inside FIRM")
        #expect(!candidates("CHFinance Pty Ltd").contains("CHF"))
        #expect(candidates("Paid US$40 and S$60").sorted() == ["SGD", "USD"],
                "both, when the document really names both")
    }

    // MARK: The refusals, now named

    private func book() throws -> (AppModel, GncGUID, GncGUID, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let card = try #require(model.addAccount(name: "Card", type: .credit, commodity: .aud))
        let expense = try #require(model.addAccount(name: "Travel", type: .expense, commodity: .aud))
        return (model, card, expense, url)
    }

    private func simpleTransaction(_ model: AppModel, _ card: GncGUID,
                                   _ expense: GncGUID, local: Decimal) throws -> GncGUID {
        try model.addTransaction(date: day(0), description: "Hotel", currency: .aud, splits: [
            SplitInput(accountID: card, value: -local),
            SplitInput(accountID: expense, value: local),
        ])
        return try #require(model.book?.transactions.last?.guid)
    }

    @Test("A real conversion restructures and says so")
    func restructures() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let id = try simpleTransaction(model, card, expense, local: dec("600"))

        let outcome = model.restructureAsForeign(transactionID: id,
                                                 foreignAmount: dec("1773.57"),
                                                 currencyCode: "MYR")
        #expect(outcome == .restructured)
        #expect(model.foreignCurrencyCode(ofTransaction: id) == "MYR")
    }

    /// Near parity is a surcharge, not a currency — a deliberate refusal that
    /// now announces itself instead of looking like a failure.
    @Test("Near-parity amounts are refused, with the implied rate")
    func nearParityIsNamed() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let id = try simpleTransaction(model, card, expense, local: dec("102"))

        let outcome = model.restructureAsForeign(transactionID: id,
                                                 foreignAmount: dec("100"),
                                                 currencyCode: "USD")
        #expect(outcome == .nearParity(implied: dec("1.02")))
        #expect(!outcome.didRestructure)
        #expect(model.foreignCurrencyCode(ofTransaction: id) == nil)
    }

    @Test("More than two legs is reported as too complex, not as nothing")
    func multiLegIsNamed() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let fees = try #require(model.addAccount(name: "Fees", type: .expense, commodity: .aud))
        try model.addTransaction(date: day(0), description: "Hotel", currency: .aud, splits: [
            SplitInput(accountID: card, value: dec("-610")),
            SplitInput(accountID: expense, value: dec("600")),
            SplitInput(accountID: fees, value: dec("10")),
        ])
        let id = try #require(model.book?.transactions.last?.guid)

        let outcome = model.restructureAsForeign(transactionID: id,
                                                 foreignAmount: dec("1773.57"),
                                                 currencyCode: "MYR")
        #expect(outcome == .tooComplex)
        // And the register can still do it by hand — which is the point of
        // naming this case rather than swallowing it.
        #expect(model.resolveCurrencyCode("MYR") != nil)
    }

    @Test("Matching amounts mean there is nothing to convert")
    func matchingAmounts() throws {
        let (model, card, expense, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let id = try simpleTransaction(model, card, expense, local: dec("600"))
        #expect(model.restructureAsForeign(transactionID: id,
                                           foreignAmount: dec("600"),
                                           currencyCode: "MYR") == .notForeign)
    }
}

/// Adding a security by looking it up (`FR-INV-41`).
///
/// Asked for on 16 Aug 2026: "New security should be as seamless as possible.
/// Rather than asking the user to fill in details, the user should be able to
/// look up a security through any of the pricing providers, and details
/// automatically filled."
@MainActor
@Suite("Security lookup")
struct SecurityLookupTests {

    private func book() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    /// The identifier comes from the provider, suffix and all. Typing `WMX`
    /// finds a New York index stub; the search result says `WMX.AX`, and that
    /// is what the book stores.
    @Test("A found security keeps the provider's own symbol and exchange")
    func keepsProviderSymbol() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let found = SecuritySearchResult(symbol: "WMX.AX", exchange: "ASX",
                                         name: "Wam Income Maximiser Limited", kind: "EQUITY")
        let made = try #require(model.createSecurity(from: found))
        #expect(made.mnemonic == "WMX.AX", "the suffix is the whole point")
        #expect(made.namespace == .security("ASX"))
        #expect(made.fullName == "Wam Income Maximiser Limited")
        #expect(model.book?.commodities.contains(made) == true)
    }

    /// A security is not an account. Adding one creates no account, because
    /// several accounts can hold the same security in different portfolios.
    @Test("Adding a security creates no account")
    func createsNoAccount() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let before = model.book?.accounts.count ?? 0
        _ = model.createSecurity(from: SecuritySearchResult(
            symbol: "CBA.AX", exchange: "ASX", name: "Commonwealth Bank", kind: "EQUITY"))
        #expect(model.book?.accounts.count == before)
    }

    @Test("The same security is never added twice")
    func noDuplicates() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let found = SecuritySearchResult(symbol: "BHP.AX", exchange: "ASX",
                                         name: "BHP Group", kind: "EQUITY")
        #expect(model.createSecurity(from: found) != nil)
        #expect(model.createSecurity(from: found) == nil, "asked again, it declines")
    }

    /// A listing with no exchange still lands somewhere findable rather than
    /// in a namespace called "".
    @Test("A result with no exchange gets a namespace anyway")
    func missingExchange() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let made = try #require(model.createSecurity(from: SecuritySearchResult(
            symbol: "XYZ", exchange: "", name: "Something", kind: "")))
        #expect(made.namespace == .security("OTHER"))
    }

    /// The ticker is recoverable from the symbol for the places that want it
    /// bare (a namespace, a display column) without re-deriving the split.
    @Test("The bare ticker is available beside the full symbol")
    func tickerSplit() {
        #expect(SecuritySearchResult(symbol: "WMX.AX", exchange: "ASX",
                                     name: "", kind: "").ticker == "WMX")
        #expect(SecuritySearchResult(symbol: "AAPL", exchange: "NMS",
                                     name: "", kind: "").ticker == "AAPL")
    }
}
