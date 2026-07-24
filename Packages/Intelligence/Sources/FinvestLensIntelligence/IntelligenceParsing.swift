//
//  IntelligenceParsing.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensInterchange

/// Tolerant parsing of model-generated values.
///
/// Guided generation constrains *shape*, not *content*: amounts arrive as
/// strings that may carry currency symbols, thousands separators, or
/// parenthesised negatives, and dates arrive as `yyyy-MM-dd` (requested in
/// every prompt) but occasionally degrade to other unambiguous forms.
public enum IntelligenceParsing {

    /// Parses a monetary string: `"$1,234.56"`, `"(45.20)"`, `"-45.20"`, `"CR 12.00"`.
    ///
    /// Delegates the numeric core to `ImportParsing.amount` — the bank-file
    /// importers' parser — after handling the DR/CR markers statements print.
    /// Two drifted copies meant the EU separator disambiguation ("1.234,56",
    /// "45,20") lived only in the import pipeline while AI-extracted amounts
    /// silently misparsed 100×.
    public static func amount(_ raw: String) -> Decimal? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A debit marker is its own token ("500 DR", "DR 500") — a bare
        // suffix test would read the currency code in "500 IDR" as one.
        var debit = false
        let upper = text.uppercased()
        if upper == "DR" { return nil }   // a marker with no number
        if upper.hasSuffix(" DR") {
            debit = true
            text = String(text.dropLast(3))
        } else if upper.hasPrefix("DR ") {
            debit = true
            text = String(text.dropFirst(3))
        }
        guard let value = ImportParsing.amount(text) else { return nil }
        return debit && value > 0 ? -value : value
    }

    /// Parses a model-generated date, preferring ISO `yyyy-MM-dd`.
    public static func date(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "d MMMM yyyy", "MMMM d, yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(text.prefix(24))) {
                return date
            }
        }
        return nil
    }
}
