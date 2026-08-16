//
//  AppModel+FX.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Foreign-amount conversion for the transaction editor (`FR-CUR-01…04`).
//
//  GnuCash's data model is kept — rates are ordinary price-DB records, splits
//  carry value/quantity — but the workflow is automated: the rate auto-fills
//  from the book, can be fetched live (Yahoo `MYRAUD=X`, keyless), and when
//  the user knows both amounts the implied rate is derived and stored, so
//  every conversion teaches the price DB.
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes

@MainActor
extension AppModel {

    /// Currency codes offered by the converter: the book's currencies first,
    /// then common ISO codes.
    public var fxCurrencyCodes: [String] {
        let inBook = (book?.commodities ?? [])
            .filter { $0.namespace == .currency }
            .map(\.mnemonic)
        let common = ["USD", "EUR", "GBP", "JPY", "NZD", "SGD", "MYR", "HKD",
                      "CNY", "THB", "IDR", "INR", "CHF", "CAD", "KRW", "VND"]
        var seen = Set<String>()
        return (inBook + common).filter { $0 != reportCurrency.mnemonic && seen.insert($0).inserted }
    }

    /// The book's commodity for `code`, or a fresh currency commodity. Reusing
    /// the stored instance matters: `Commodity` equality spans all fields, and
    /// price-index buckets key on it.
    func currencyCommodity(_ code: String) -> Commodity {
        book?.commodities.first { $0.namespace == .currency && $0.mnemonic == code }
            ?? Commodity(namespace: .currency, mnemonic: code, fullName: code, smallestFraction: 100)
    }

    /// Resolves a typed currency code to a commodity, or `nil` if it names no
    /// currency — what the register's Currency cell validates against.
    ///
    /// Deliberately **not** `currencyCommodity(_:)`: that one invents a
    /// commodity for any string it is handed, which is right when the caller
    /// already knows the code is real and wrong for a cell someone is still
    /// typing into. "MY" would silently become a currency named MY.
    func resolveCurrencyCode(_ text: String) -> Commodity? {
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3, code.allSatisfy(\.isLetter) else { return nil }
        if let known = book?.commodities.first(where: {
            $0.namespace == .currency && $0.mnemonic == code
        }) { return known }
        // A currency the book has never seen is still a currency — this is how
        // the first foreign transaction in a book gets entered at all. The ISO
        // list is the gate, so a typo cannot invent one.
        guard Locale.commonISOCurrencyCodes.contains(code) else { return nil }
        return Commodity(namespace: .currency, mnemonic: code,
                         fullName: code, smallestFraction: 100)
    }

    /// A transaction's exchange rate: local units per one unit of its own
    /// currency, read straight off the splits.
    ///
    /// GnuCash stores no rate — `value` is in the transaction's currency and
    /// `quantity` in the account's (`Split.h:251-265`), so their ratio *is* the
    /// rate and cannot fall out of step with the amounts. `nil` when the
    /// transaction is single-currency or a leg is missing one of the two.
    public func rate(ofTransaction id: GncGUID) -> Decimal? {
        guard let txn = book?.transaction(with: id) else { return nil }
        for split in txn.splits where split.account?.commodity != txn.currency {
            guard split.value != 0, split.quantity != 0 else { continue }
            return split.quantity / split.value
        }
        return nil
    }

    /// The currency a transaction was struck in, when that is not the currency
    /// its accounts imply. `nil` for the ordinary single-currency transaction.
    ///
    /// The whole-book register has no anchoring account to compare against, so
    /// it asks the transaction directly.
    public func foreignCurrencyCode(ofTransaction id: GncGUID) -> String? {
        guard let txn = book?.transaction(with: id) else { return nil }
        let derived = transactionCurrency(for: txn.splits.compactMap { $0.account?.guid })
        return txn.currency == derived ? nil : txn.currency.mnemonic
    }

    /// The stored rate: one unit of `code` in the report currency, nearest to
    /// `date` (price DB — direct, inverse, or one indirect hop).
    public func storedFxRate(code: String, on date: Date? = nil) -> Decimal? {
        guard let book else { return nil }
        return book.exchangeRate(from: currencyCommodity(code), to: reportCurrency, on: date)
    }

    /// Fetches a live rate for one unit of `code` in the report currency and
    /// stores it in the price DB so future lookups — and reports — can use it.
    /// Throws with the provider's reason so the UI can say why a fetch failed
    /// rather than doing nothing.
    ///
    /// Routed through the book's configured provider like every other fetch
    /// (`FR-INV-22`). It used to name Yahoo outright, which is the same
    /// hardcoding that had ⌘⇧U and the six-hourly refresh ignoring a
    /// configured provider — a book set up for EODHD still had its rates
    /// fetched by Yahoo, with nothing on screen saying so.
    ///
    /// The preferred provider is used only when its FX spelling is known
    /// (``QuoteProviderKind/fxSymbol(from:to:)``); otherwise this falls back to
    /// Yahoo, which is keyless and always available. Falling back is right
    /// here: an unverified symbol would return "no data", and reporting "there
    /// is no MYR/AUD rate" would be worse than fetching a correct one from a
    /// provider whose name the row still records.
    @discardableResult
    public func fetchLiveFxRate(code: String) async throws -> Decimal {
        let foreign = currencyCommodity(code)
        let preferred = preferredQuoteProvider
        let kind = preferred.fxSymbol(from: code, to: reportCurrency.mnemonic) == nil
            ? .yahoo : preferred
        guard let symbol = kind.fxSymbol(from: code, to: reportCurrency.mnemonic) else {
            throw QuoteError.unsupported("No exchange-rate source is configured.")
        }
        let service = QuoteService(keys: apiKeys, http: quoteHTTP)
        // Every plausibility check a security price gets — a zero, a 1970 date,
        // a currency that is not the one asked for — applies to a rate too, and
        // they all live in `QuoteService.price(from:)`, so this needs no
        // guard of its own beyond what that throws.
        let price = try await service.latestPrice(
            for: foreign, in: reportCurrency, using: kind, symbolOverride: symbol)
        editingPrices(named: "Fetch Exchange Rate") {
            // Deduplicated like every other price write: this used to append
            // unconditionally, so pressing the button twice in a day left two
            // identical rows and `latestPrice` picked between them.
            book?.addPrices(deduplicating: [price])
        }
        return price.value
    }

    /// Restructures a simple local transaction into proper multi-currency form
    /// for a document denominated in `currencyCode` with foreign total
    /// `foreignAmount`: the transaction currency becomes the foreign one, split
    /// `value`s carry ±foreign (balancing the transaction), and each split's
    /// `quantity` keeps the local amount that moves its account. The implied
    /// rate is recorded in the price DB. One undoable action.
    ///
    /// Only the simple shape is restructured — two legs, both in the (current)
    /// transaction currency; anything richer is left for the editor. Returns
    /// whether the restructure happened.
    /// Why an automatic restructure did not happen.
    ///
    /// A `Bool` was not enough: every one of these refusals is a case where
    /// the document plainly *is* foreign and the user is entitled to know the
    /// app looked and declined. Silence here is what made the feature read as
    /// working "sporadically" — it was working exactly as written, and never
    /// saying when it hadn't.
    public enum ForeignRestructureOutcome: Equatable, Sendable {
        case restructured
        /// Nothing to do: the amounts agree, or the currency is already right.
        case notForeign
        /// Real, but too rich for the automatic path: more than two legs, or a
        /// leg already in another currency. The editor can still do it.
        case tooComplex
        /// Within a few percent of parity — a surcharge or fee, not a currency.
        case nearParity(implied: Decimal)

        public var didRestructure: Bool { self == .restructured }
    }

    @discardableResult
    public func restructureAsForeign(transactionID: GncGUID,
                                     foreignAmount: Decimal,
                                     currencyCode: String) -> ForeignRestructureOutcome {
        guard let book, foreignAmount > 0,
              let txn = book.transaction(with: transactionID)
        else { return .notForeign }
        guard currencyCode != txn.currency.mnemonic else { return .notForeign }
        guard txn.splits.count == 2,
              txn.splits.allSatisfy({ $0.account?.commodity == txn.currency })
        else { return .tooComplex }
        let local = txn.splits.map { abs($0.value) }.max() ?? 0
        guard local > 0, local != foreignAmount else { return .notForeign }
        // A near-parity "rate" is a surcharge or fee difference, not a foreign
        // currency: a card FX margin or booking fee sits within a few percent,
        // while real currency pairs (even NZD/AUD ≈ 0.92) sit outside this
        // band. Refusing here keeps a deposit-with-surcharge local.
        let implied = local / foreignAmount
        guard implied < Decimal(string: "0.95")! || implied > Decimal(string: "1.05")!
        else { return .nearParity(implied: implied) }

        let foreign = currencyCommodity(currencyCode)
        let rounded = foreign.round(foreignAmount)
        // The implied rate's local side is the TRANSACTION's currency —
        // captured before the restructure rewrites it. Recording it against
        // the report currency wrote a quantitatively wrong rate for the wrong
        // pair whenever the legs sat in a foreign-denominated account (a
        // USD-account EUR invoice stored EUR→AUD ≈ 1.08 where truth ≈ 1.65).
        let localCurrency = txn.currency
        editing([transactionID], named: "Record Foreign Amount") {
            txn.currency = foreign
            for split in txn.splits {
                let localValue = split.value
                split.value = localValue > 0 ? rounded : -rounded
                split.quantity = localValue   // what moves the account, unchanged
            }
        }
        recordFxRate(code: currencyCode, rate: local / rounded,
                     date: txn.datePosted, in: localCurrency)
        return .restructured
    }

    /// Records a user-confirmed rate (e.g. the implied rate of a purchase whose
    /// foreign and local amounts are both known) into the price DB. The rate is
    /// local-per-foreign, so the pair recorded is foreign → `localCurrency`
    /// (defaulting to the report currency for report-level callers).
    public func recordFxRate(code: String, rate: Decimal, date: Date,
                             in localCurrency: Commodity? = nil) {
        // One rate-recording implementation app-wide.
        addExchangeRate(from: currencyCommodity(code), to: localCurrency ?? reportCurrency,
                        rate: rate, date: date)
    }
}
