//
//  ForeignAmount.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// An amount in a currency other than the one a transaction is booked in,
/// as recorded by the bank that converted it.
public struct ForeignAmount: Sendable, Equatable, Hashable {
    public let amount: Decimal
    /// ISO 4217, upper-cased.
    public let currencyCode: String

    public init(amount: Decimal, currencyCode: String) {
        self.amount = amount
        self.currencyCode = currencyCode.uppercased()
    }
}

/// Recovers the original amount of a foreign purchase from the narrative a
/// card issuer writes into it.
///
/// A card charged overseas posts in the cardholder's own currency, so the
/// transaction says `-64.51 AUD` and the receipt in your hand says
/// `NZD 72.11`. Nothing about those two numbers matches, and the rate that
/// connects them is not in the book — which is why a receipt from a trip
/// could never be linked to its purchase by amount.
///
/// It turns out the rate is not needed, because the issuer already wrote the
/// original down. ANZ puts it straight into the description:
///
///     THE SQUARE RESTAURANT     CHRISTCHURCH  72.11  NZD 2.18 AUD
///
/// — merchant, city, **the amount actually charged**, its currency, then the
/// conversion fee. So the receipt's own figure can be matched exactly against
/// the book, with no rate, no tolerance, and nothing for anyone to tag.
///
/// The trailing fee is not trustworthy. Real exports carry `NZD 1.1.56 AUD`,
/// `THB 0.0.29 AUD`, `MYR22.68 AUD` — the fee field arrives mangled and the
/// space before the code is sometimes missing. The *foreign amount before the
/// code* is clean in every sample, so that is the only part read here; the
/// mangled tail is left alone rather than guessed at.
public enum ForeignAmountScanner {

    /// Currency codes as Foundation knows them, so "GST", "TAX" and a bank's
    /// own initials are not mistaken for money.
    private static let currencyCodes: Set<String> = Set(Locale.commonISOCurrencyCodes)

    /// `123.45  NZD` → one amount. Repeated for every occurrence.
    ///
    /// The book's own currency is *not* filtered here — the scanner does not
    /// know it. Callers pass ``scan(_:excluding:)`` instead, because the fee
    /// tail (`… 2.18 AUD`) is itself a well-formed amount-and-code pair and
    /// would otherwise read as a foreign amount of the transaction's own
    /// currency.
    public static func scan(_ text: String) -> [ForeignAmount] {
        guard !text.isEmpty else { return [] }
        // Two or more digits of cents, a required gap, then the code. The gap
        // is what separates a real pairing from a number that merely happens
        // to sit before a word.
        let pattern = #"([0-9][0-9,]*\.[0-9]{2})\s+([A-Za-z]{3})(?![A-Za-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var found: [ForeignAmount] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: whole) {
            guard let amountRange = Range(match.range(at: 1), in: text),
                  let codeRange = Range(match.range(at: 2), in: text) else { continue }
            let code = text[codeRange].uppercased()
            guard currencyCodes.contains(code) else { continue }
            let digits = text[amountRange].replacingOccurrences(of: ",", with: "")
            guard let amount = Decimal(string: digits), amount > 0 else { continue }
            found.append(ForeignAmount(amount: amount, currencyCode: code))
        }
        return found
    }

    /// Foreign amounts in `text`, dropping any stated in `excluding` — pass the
    /// transaction's own currency.
    public static func scan(_ text: String, excluding bookCurrency: String) -> [ForeignAmount] {
        let own = bookCurrency.uppercased()
        return scan(text).filter { $0.currencyCode != own }
    }
}
