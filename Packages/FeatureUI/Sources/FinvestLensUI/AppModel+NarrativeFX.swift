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
            // Already multi-currency: the fact is recorded, nothing to recover.
            guard txn.splits.allSatisfy({ $0.account?.commodity == txn.currency }) else { continue }
            for split in txn.splits {
                guard let account = split.account else { continue }
                if let accountName, account.name != accountName { continue }
                guard account.commodity == txn.currency else { continue }
                guard let found = Self.parseNarrativeFX(split.memo),
                      found.code != txn.currency.mnemonic else { continue }
                out.append(NarrativeFX(
                    transactionID: txn.guid, date: txn.datePosted,
                    narrative: txn.transactionDescription,
                    foreignAmount: found.amount, currencyCode: found.code,
                    fee: found.fee, localAmount: abs(split.value)))
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
