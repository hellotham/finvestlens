//
//  SourceGrounding.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Checks a model's answer against the document it was supposed to read.
///
/// Every extractor here asks the model for figures "exactly as printed", and
/// every one of them sometimes gets a figure that is not printed anywhere —
/// either padding an array up to its ceiling with plausible rows, or reading
/// the wrong part of the page. Both are silent: the answer is well-formed,
/// well-typed, and wrong.
///
/// So the answers are checked against the source. This is deliberately not
/// clever — it is containment on a folded string, which cannot express
/// "roughly right" and cannot be talked into an exception. It never *repairs*
/// an answer, only refuses one, and refusing leaves the row for a person.
enum SourceGrounding {

    /// Folds to letters and digits: case, spacing, punctuation and currency
    /// symbols all stop mattering, so `$1,700.00` and `1700.00` are the same
    /// haystack.
    static func folded(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whether an amount the model reported is actually printed in `source`
    /// (which must already be ``folded(_:)``).
    ///
    /// Compared on digits alone, so the differences that carry no information
    /// fall away: a minus sign the statement writes as a trailing `CR`, a
    /// thousands separator the model drops, a currency symbol either side.
    static func isAmountPrinted(_ amount: String, in source: String) -> Bool {
        printedCount(amount, in: source) != 0
    }

    /// How many times an amount is printed in `source`, or ``unbounded`` when
    /// the figure is too short to count on.
    ///
    /// A transaction cannot occur on a page more often than its amount does,
    /// which makes this the ceiling on how many times an extractor may report
    /// it. That matters because the model sometimes restates a row it has
    /// already given, with the payee worded differently each time — enough to
    /// defeat a dedupe key that holds the payee verbatim. On one real ANZ
    /// statement three transactions came back four and five times each, ten
    /// surplus rows out of ninety; the same month's neighbours had none.
    static func printedCount(_ amount: String, in source: String) -> Int {
        let digits = amount.filter(\.isNumber)
        // Under $10.00 an amount folds to three digits or fewer, which is short
        // enough to hit by chance in a page of card numbers and dates — so the
        // check abstains rather than rejecting a real row on a weak test.
        guard digits.count >= 4 else { return unbounded }
        var count = 0
        var searched = source[...]
        while let hit = searched.range(of: digits) {
            count += 1
            searched = searched[hit.upperBound...]
        }
        return count
    }

    /// Returned by ``printedCount(_:in:)`` when the figure carries too little
    /// information to be counted — never a limit.
    static let unbounded = Int.max

    /// Whether a name the model reported occurs in `source` (already folded).
    ///
    /// Prompts ask for names "cleaned up", so an exact match is the wrong test:
    /// `WOOLWORTHS 3421 SYDNEY NS` legitimately comes back as `Woolworths`.
    /// Folded, the cleaned name is still a substring of the printed one — while
    /// an invented merchant is not.
    ///
    /// Short names are exempt: below four folded characters containment stops
    /// discriminating (`BP`, `Aldi`) and would start accepting anything.
    static func isNamePrinted(_ name: String, in source: String) -> Bool {
        let needle = folded(name)
        guard needle.count >= 4 else { return !needle.isEmpty }
        if source.contains(needle) { return true }
        // A multi-word name may be cleaned by dropping a word rather than
        // punctuation ("Transport for NSW Travel" → "Transport NSW"), so accept
        // it when every word of four or more characters is present.
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { folded(String($0)) }
            .filter { $0.count >= 4 }
        return !words.isEmpty && words.allSatisfy { source.contains($0) }
    }
}
