//
//  AppModel+NarrativeFX.swift
//  FinvestLens — FeatureUI
//
//  Recovering the foreign amount a card issuer wrote into the narrative
//  (`FR-CUR-02`, `FR-REG-07`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One transaction the bank recorded in another currency, as read from its own
/// narrative.
public struct NarrativeFX: Sendable, Equatable {
    public let transactionID: GncGUID
    public let date: Date
    public let narrative: String
    /// What was actually spent, in the currency it was spent in.
    public let foreignAmount: Decimal
    public let currencyCode: String
    /// The card's international transaction fee, where the bank stated one.
    /// Parsed and reported; never posted, because which expense account it
    /// belongs in is the book owner's decision.
    public let fee: Decimal?
    /// What left the account, in the account's own currency.
    public let localAmount: Decimal
    /// Whether the book already holds this as a multi-currency transaction.
    ///
    /// Converted rows stay in the list rather than being filtered out, because
    /// the fee still has to be separated and that pass needs the rate the
    /// conversion established. Excluding them meant a second run over an
    /// already-converted book found nothing at all to do.
    public let alreadyForeign: Bool

    public var impliedRate: Decimal {
        foreignAmount == 0 ? 0 : localAmount / foreignAmount
    }

    /// The stated fee, but only where it can be believed.
    ///
    /// A card's international transaction fee is a small percentage — every
    /// clean row in the reference book sat at 3.3–3.8%. Anything outside a
    /// generous band came from the parser running into the merchant's own text
    /// (a dry run produced "390.39" against an 11.51 charge), and a wrong
    /// figure reported confidently is worse than none.
    public var plausibleFee: Decimal? {
        guard let fee, fee > 0, localAmount > 0 else { return nil }
        let share = fee / localAmount
        return share <= Decimal(string: "0.10")! ? fee : nil
    }
}

@MainActor
extension AppModel {

    /// Every transaction whose money leg carries a foreign amount in its memo
    /// but which the book still holds as single-currency.
    ///
    /// A card issuer writes the original amount into the narrative and charges
    /// the account in local currency, so the book ends up with half the fact:
    /// the AUD that left, and the MYR that was spent sitting in a memo where no
    /// report can reach it.
    public func narrativeForeignCandidates(accountName: String? = nil,
                                           since: Date? = nil) -> [NarrativeFX] {
        guard let book else { return [] }
        var out: [NarrativeFX] = []
        for txn in book.transactions {
            if let since, txn.datePosted < since { continue }
            let isForeign = txn.splits.contains { $0.account?.commodity != txn.currency }
            for split in txn.splits {
                guard let account = split.account else { continue }
                if let accountName, account.name != accountName { continue }
                guard let found = Self.parseNarrativeFX(split.memo) else { continue }
                // A narrative naming the account's own currency is a domestic
                // purchase whose address happened to end in a figure.
                guard found.code != account.commodity.mnemonic else { continue }
                out.append(NarrativeFX(
                    transactionID: txn.guid, date: txn.datePosted,
                    narrative: txn.transactionDescription,
                    foreignAmount: found.amount, currencyCode: found.code,
                    fee: found.fee,
                    // The account's own money is always the **quantity**: on a
                    // converted transaction `value` has become the foreign
                    // figure, and reading it here made the fee's rate a
                    // hundredfold out on the second run.
                    localAmount: abs(split.quantity),
                    alreadyForeign: isForeign))
                break
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Reads a card narrative's foreign amount, its currency, and the fee the
    /// bank stated beside it.
    ///
    /// ANZ's format, decoded from the reference book on 15 Aug 2026 and checked
    /// against the posted amounts:
    ///
    /// ```
    /// RCP-Booking               George Town  1773.84  MYR22.68 AUD
    ///                                        ───┬───  ─┬─ ──┬── ─┬─
    ///                                       amount  currency │  the fee's
    ///                                                       fee  currency
    /// ```
    ///
    /// `1773.84 MYR` against the posted `670.59 AUD` is 0.37804, and `22.68` is
    /// 3.38% of the charge — the international transaction fee, not the
    /// conversion. Every sampled row agreed, in both currencies the book holds
    /// (MYR ~0.37, NZD ~0.89).
    ///
    /// **Two spaces before the amount is the anchor.** That gap is what
    /// separates the bank's fixed-width merchant-and-city field from the
    /// figures; without it a street number parses as a purchase.
    public static func parseNarrativeFX(_ memo: String)
        -> (amount: Decimal, code: String, fee: Decimal?)? {

        let pattern = #"\s{2}([0-9][0-9,]*\.[0-9]{2})\s{1,2}([A-Z]{3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: memo, range: NSRange(memo.startIndex..., in: memo)),
              let amountRange = Range(match.range(at: 1), in: memo),
              let codeRange = Range(match.range(at: 2), in: memo)
        else { return nil }
        let code = String(memo[codeRange])
        let digits = memo[amountRange].replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(string: digits), amount > 0 else { return nil }

        // The fee tail is not always cleanly written — "2.2.94 AUD" and
        // "0.0.16 AUD" both appear, and on some rows the merchant's own text
        // runs into it. The last well-formed number before a trailing currency
        // letter is taken, and then **sanity-checked by the caller**: a dry run
        // over the reference book produced a "fee" of 390.39 on an 11.51 charge
        // from exactly this kind of run-on. A fee that cannot be read is better
        // missing than invented, so `plausibleFee(_:against:)` discards it.
        var fee: Decimal?
        let tail = String(memo[codeRange.upperBound...])
        if let feeRegex = try? NSRegularExpression(pattern: #"([0-9]+\.[0-9]{2})\s*A"#),
           let feeMatch = feeRegex.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
           let feeRange = Range(feeMatch.range(at: 1), in: tail) {
            fee = Decimal(string: String(tail[feeRange]))
        }
        return (amount, code, fee)
    }
}

@MainActor
extension AppModel {

    /// Why a fee could not be moved to its own leg.
    public enum FeeSplitOutcome: Equatable, Sendable {
        case split(foreign: Decimal, local: Decimal)
        /// Already has more than the two legs a card charge starts with — the
        /// fee may well be out already, and guessing would double it.
        case notSimple
        /// No fee stated, or one too large to believe.
        case noFee
        /// The transaction is not foreign-denominated, so there is no rate to
        /// convert the fee at.
        case notForeign

        public var didSplit: Bool { if case .split = self { return true }; return false }
    }

    /// Moves a card's international transaction fee onto its own expense leg.
    ///
    /// The bank charges one amount and states the fee inside it, so a foreign
    /// purchase arrives as a single figure that is really two: the goods, and
    /// roughly 3.4% for having bought them abroad. Left merged, every foreign
    /// purchase overstates its category and the year's card fees are
    /// unreportable.
    ///
    /// The fee is quoted in the **account's** currency while the transaction is
    /// denominated in the foreign one, so the new leg needs both figures, like
    /// every other split here: `quantity` is the fee as charged, and `value` is
    /// that fee at this transaction's own rate. The goods leg gives up exactly
    /// what the fee leg takes, in both units, so the transaction still balances
    /// in the currency it was struck in and each account still moves by what
    /// really moved it.
    /// - Parameter apply: `false` answers what *would* happen and writes
    ///   nothing. One code path for both, so a dry run cannot promise more than
    ///   the real thing delivers — the first version counted every candidate
    ///   with a readable fee and said "62 would move" when 54 could.
    @discardableResult
    public func splitCardFee(transactionID: GncGUID, feeLocal: Decimal,
                             feeAccountID: GncGUID, apply: Bool = true) -> FeeSplitOutcome {
        guard let book, let txn = book.transaction(with: transactionID),
              let feeAccount = book.account(with: feeAccountID)
        else { return .notForeign }
        guard feeLocal > 0 else { return .noFee }
        guard txn.splits.count == 2 else { return .notSimple }
        // Foreign-denominated: no split's account is in the transaction's own
        // currency, which is what gives us a rate to convert the fee at.
        guard txn.splits.allSatisfy({ $0.account?.commodity != txn.currency })
        else { return .notForeign }

        // The leg the fee comes out of is the one the money went *to* — the
        // card leg is what was charged and must keep its full amount, because
        // that is what the statement says left the account.
        guard let goods = txn.splits.first(where: { $0.value > 0 }),
              let anchor = txn.splits.first(where: { $0.value != 0 && $0.quantity != 0 }),
              anchor.value != 0
        else { return .notSimple }
        let rate = abs(anchor.quantity) / abs(anchor.value)   // local per foreign
        guard rate > 0 else { return .notForeign }
        guard feeLocal < abs(goods.quantity) else { return .noFee }

        let feeForeign = txn.currency.round(feeLocal / rate)
        guard feeForeign > 0, feeForeign < goods.value else { return .noFee }

        guard apply else { return .split(foreign: feeForeign, local: feeLocal) }
        editing([transactionID], named: "Separate Card Fee") {
            goods.value -= feeForeign
            goods.quantity -= feeLocal
            txn.addSplit(account: feeAccount, value: feeForeign, quantity: feeLocal,
                         memo: String(localized: "International transaction fee"))
        }
        return .split(foreign: feeForeign, local: feeLocal)
    }
}

@MainActor
extension AppModel {

    /// Corrects a transfer into an account that is *already* denominated in the
    /// narrative's currency.
    ///
    /// Not every foreign row on a card is a purchase. Eight of the reference
    /// book's were cash moved into a MYR account, and they arrived with the AUD
    /// figure copied into both fields — so the MYR account was credited 21.91
    /// MYR when 59.50 MYR had actually landed in it, and its balance was a
    /// third of the truth.
    ///
    /// The fix is not to redenominate the transaction: the card was charged in
    /// AUD and the transaction's currency is right. What is wrong is one
    /// `quantity`. GnuCash's split already says how to hold this — `value` in
    /// the transaction's currency, `quantity` in the account's own
    /// (`Split.h:251-265`) — so the AUD leg keeps its value and the MYR leg's
    /// quantity becomes the money that reached it.
    @discardableResult
    public func alignForeignAccountQuantity(transactionID: GncGUID,
                                            foreignAmount: Decimal,
                                            currencyCode: String,
                                            apply: Bool = true) -> Bool {
        guard let book, let txn = book.transaction(with: transactionID),
              foreignAmount > 0
        else { return false }
        // The leg whose account is held in the narrative's currency.
        guard let leg = txn.splits.first(where: {
            $0.account?.commodity.mnemonic == currencyCode
                && $0.account?.commodity != txn.currency
        }) else { return false }
        let signed = leg.value < 0 ? -foreignAmount : foreignAmount
        guard leg.quantity != signed else { return false }
        guard apply else { return true }
        editing([transactionID], named: "Correct Foreign Quantity") {
            leg.quantity = signed
        }
        // The rate this proves is worth keeping: it is a real conversion the
        // bank performed, dated.
        if leg.value != 0 {
            recordFxRate(code: currencyCode, rate: abs(leg.value) / foreignAmount,
                         date: txn.datePosted, in: txn.currency)
        }
        return true
    }
}
