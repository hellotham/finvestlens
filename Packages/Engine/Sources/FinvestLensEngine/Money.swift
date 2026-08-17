//
//  Money.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// An exact monetary amount in a specific ``Commodity``.
///
/// FinvestLens uses Swift-native `Foundation.Decimal` for money (Architecture
/// ADR-1): base-10, 38 significant digits, free of binary floating-point error.
/// Bit-for-bit parity with GnuCash's rational `gnc_numeric` is a non-goal —
/// small rounding differences are acceptable.
///
/// Arithmetic is only defined between amounts of the **same commodity**; mixing
/// commodities is a programmer error and traps. Cross-currency conversion is a
/// higher-level concern (prices / exchange rates), not an operator.
public struct Money: Hashable, Codable, Sendable {

    /// The raw (un-rounded) amount.
    public var amount: Decimal
    /// The commodity this amount is denominated in.
    public var commodity: Commodity

    public init(_ amount: Decimal, _ commodity: Commodity) {
        self.amount = amount
        self.commodity = commodity
    }

    /// Zero in the given commodity.
    public static func zero(_ commodity: Commodity) -> Money {
        Money(0, commodity)
    }

    /// The amount rounded to the commodity's smallest fraction.
    public var rounded: Money {
        Money(commodity.round(amount), commodity)
    }

    /// `true` if the amount rounds to zero at the commodity's fraction.
    ///
    /// Uses the rounded value so residuals smaller than one minor unit count
    /// as zero — the tolerance the double-entry balance check relies on.
    public var isZero: Bool {
        commodity.round(amount) == 0
    }

    public var isNegative: Bool { rounded.amount < 0 }
    public var isPositive: Bool { rounded.amount > 0 }

    /// A locale-aware currency string (best-effort; presentation may override).
    public func formatted(locale: Locale = .current) -> String {
        var style = Decimal.FormatStyle.Currency(code: commodity.mnemonic, locale: locale)
        if let digits = commodity.fractionDigits {
            style = style.precision(.fractionLength(digits))
        }
        return rounded.amount.formatted(style)
    }
}

// MARK: - Arithmetic (same-commodity only)

public extension Money {

    static prefix func - (value: Money) -> Money {
        Money(-value.amount, value.commodity)
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(
            lhs.commodity == rhs.commodity,
            "Cannot add \(lhs.commodity.mnemonic) and \(rhs.commodity.mnemonic)"
        )
        return Money(lhs.amount + rhs.amount, lhs.commodity)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        precondition(
            lhs.commodity == rhs.commodity,
            "Cannot subtract \(rhs.commodity.mnemonic) from \(lhs.commodity.mnemonic)"
        )
        return Money(lhs.amount - rhs.amount, lhs.commodity)
    }

    static func += (lhs: inout Money, rhs: Money) { lhs = lhs + rhs }
    static func -= (lhs: inout Money, rhs: Money) { lhs = lhs - rhs }

    /// Scales the amount by a plain decimal factor (e.g. a share price or rate),
    /// keeping the same commodity. The result is **not** auto-rounded.
    static func * (lhs: Money, factor: Decimal) -> Money {
        Money(lhs.amount * factor, lhs.commodity)
    }

    /// Adds two amounts if they share a commodity, else returns `nil`.
    /// A non-trapping alternative to `+` for mixed-commodity contexts.
    func adding(_ other: Money) -> Money? {
        guard commodity == other.commodity else { return nil }
        return Money(amount + other.amount, commodity)
    }
}

// MARK: - Comparison (same-commodity only)

extension Money: Comparable {
    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(
            lhs.commodity == rhs.commodity,
            "Cannot compare \(lhs.commodity.mnemonic) and \(rhs.commodity.mnemonic)"
        )
        return lhs.amount < rhs.amount
    }
}

/// Reads money written as text.
///
/// Amounts reach this app as strings from several directions — bank exports,
/// PDF extraction, and a person typing a threshold into a rule — and every one
/// of them writes them the way people write them: with a currency symbol,
/// grouped thousands, a parenthesised or trailing negative, or an accounting
/// `DR`/`CR` marker. `Decimal(string:)` handles none of that and fails
/// *quietly*: it parses greedily and stops at the first character it does not
/// understand, so `"1,000"` is **1**, not one thousand. A rule reading
/// "amount greater than 1,000" therefore fired on everything over a dollar,
/// and looked perfectly correct in the editor while doing it.
///
/// This lives in Engine rather than in the importers so there is one set of
/// rules for the whole app; `ImportParsing.amount` forwards to it.
public enum MoneyParsing {

    /// Accounting side markers and whether each means *debit*, in probe order:
    /// the dotted form of a token before its bare form, so "Cr." is not read as
    /// "Cr" with a stray dot left behind to be taken for a decimal point.
    private static let sideMarkers: [(form: String, debit: Bool)] = [
        ("DR.", true), ("DR", true),
        ("DB.", true), ("DB", true),
        ("CR.", false), ("CR", false),
    ]

    /// `text` with `form` removed from whichever end carries it as a standalone
    /// token, or `nil` if neither end does.
    ///
    /// The token must be bounded by a non-letter, or a currency code is
    /// mistaken for a marker — "500.00 IDR" ends in "DR", "DRAWINGS 500"
    /// begins with one — and what remains must still contain a digit.
    /// `upper` is the caller's already-folded copy, so this allocates nothing
    /// for the overwhelmingly common no-marker case.
    private static func strippingMarker(_ form: String, from text: String,
                                        upper: String) -> String? {
        if upper.hasSuffix(form) {
            let head = String(text.dropLast(form.count))
            if head.last.map({ !$0.isLetter }) ?? false {
                let body = head.trimmingCharacters(in: .whitespaces)
                if body.contains(where: \.isNumber) { return body }
            }
        }
        if upper.hasPrefix(form) {
            let tail = String(text.dropFirst(form.count))
            if tail.first.map({ !$0.isLetter }) ?? false {
                let body = tail.trimmingCharacters(in: .whitespaces)
                if body.contains(where: \.isNumber) { return body }
            }
        }
        return nil
    }

    /// The amount `raw` denotes, or `nil` if it holds no number.
    public static func amount(_ raw: String) -> Decimal? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        // A trailing minus ("500.00-") denotes a debit in many accounting/German
        // exports; `Decimal(string:)` only honours a *leading* sign and would
        // silently read it as +500, flipping a debit into a credit.
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("-") {
            negative = true
            text = String(text.dropLast())
        }
        // Accounting exports mark the side with a `DR`/`CR` (or `DB`) token
        // rather than a sign. The character filter near the end of this
        // function strips letters, so "500.00 DR" — a debit — parsed as +500
        // and every withdrawal in the file imported as a deposit.
        //
        // The token has to be bounded by a non-letter, or a trailing currency
        // code swallows it: "500.00 IDR" ends in "DR", and "DRAWINGS 500"
        // starts with one. `true` means debit.
        //
        // One pass over a flat table, with the side of each marker stated
        // rather than derived, and `uppercased()` taken once: this runs per
        // imported row *and* per rule per transaction, and folding the whole
        // string six times to discover the overwhelmingly common "no marker"
        // answer was six allocations thrown away every time.
        var side: Bool?
        let upper = text.uppercased()
        for (form, debit) in Self.sideMarkers {
            // The two ends are tried independently. Written as `if suffix …
            // else if prefix …`, a suffix that matched and was then *rejected*
            // by the boundary guard consumed the iteration, so the prefix was
            // never examined: "DR 500 IDR" ends in "DR" via the currency code,
            // the guard correctly refused it, and the leading DR that really
            // does name the side went unseen — the debit parsed as +500.
            guard let body = Self.strippingMarker(form, from: text, upper: upper) else { continue }
            text = body
            side = debit
            break
        }
        // When both separators appear, the rightmost is the decimal point — this
        // disambiguates US "1,234.56" from European "1.234,56"; the other groups
        // thousands.
        if let dot = text.lastIndex(of: "."), let comma = text.lastIndex(of: ",") {
            if comma > dot {   // European: comma is the decimal separator
                text = text.replacingOccurrences(of: ".", with: "")
                              .replacingOccurrences(of: ",", with: ".")
            } else {           // US: comma groups thousands
                text = text.replacingOccurrences(of: ",", with: "")
            }
        } else if text.contains(",") {
            // A lone comma: thousands grouping needs exactly 3 digits per
            // group, so a comma followed by 1–2 trailing digits ("4,99") can
            // only be a decimal comma — stripping it read the amount 100×
            // too large. Groups of 3 keep the en/US reading (ambiguous).
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            let trailingDigits = parts.last.map { $0.filter(\.isNumber).count } ?? 0
            if parts.count == 2, trailingDigits >= 1, trailingDigits <= 2 {
                text = text.replacingOccurrences(of: ",", with: ".")
            }
        }
        text = text.filter { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let value = Decimal(string: text) else { return nil }
        // A DR/CR marker names the side outright, so it outranks every other
        // notation in the string rather than combining with one.
        if let side {
            let magnitude = value < 0 ? -value : value
            return side ? -magnitude : magnitude
        }
        // The sign may already be explicit ("(-5)" / "-500.00-"): only apply
        // the wrapper-derived negation to a positive magnitude, or the two
        // notations cancel and a debit flips positive.
        if negative { return value > 0 ? -value : value }
        return value
    }
}
