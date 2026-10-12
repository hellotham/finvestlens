//
//  TokenBudget.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  How much text fits in a model's context window.
//
//  This package used to budget in *characters*: `prefix(6000)` for an invoice,
//  `prefix(1500)` for a classification, sized by hand for a 4,096-token
//  window. Both halves of that were wrong by October 2026. The window is not
//  4,096: asked directly, the on-device model on a Mac running macOS 27
//  reports 8,192 (`SystemLanguageModel.contextSize`), Apple's own article
//  still says 4,096, and Private Cloud Compute has 32,768 — so the size is a
//  thing to ask for, never a thing to remember. And a character is not a
//  quarter of a token in the text this app reads.
//
//  **Financial text is the expensive kind.** Measured with the macOS 27
//  model's own `tokenCount(for:)` on 12 October 2026, synthetic text:
//
//      English prose          5.8 characters a token
//      German prose           4.4
//      Japanese               1.9
//      Chinese                1.6
//      invoice lines          2.0
//      bank-statement rows    1.5
//      rows of digits         1.1
//
//  Every digit is a token and so is nearly every mark of punctuation. The
//  first estimate written here charged all Latin-script text 3.2 characters
//  a token and called that running high; on a statement it came to less than
//  half the model's count, and `LanguageModels.fit` — which trusted it for
//  the first cut — sent the model an invoice 1,350 tokens over its budget
//  and reported nothing cut.
//
//  So the model's count is the authority wherever a model will count
//  (`LanguageModels.fit` measures, cuts in proportion, and measures again),
//  and this estimate is what stands in where none will: Private Cloud
//  Compute and a model the person supplies have a window and no counter.
//  Its weights are fitted to the measurements above so that it is never
//  under the model's count on any of them — by 8% on rows of digits, by a
//  third on Chinese, by two thirds on English prose, which is the price of
//  one set of weights for every script.
//

import Foundation

enum TokenBudget {

    /// A token count for `text` that is not under the model's own.
    ///
    /// Weights per character: a digit 1.15; ASCII punctuation and symbols 1;
    /// a capital 0.75 (bank narratives are capitals, and "WOOLWORTHS" is
    /// several tokens where "woolworths" is two); any other Latin letter
    /// 0.3; a line break 1; a run of two or more spaces 1 (a column gap is a
    /// token; the single space between words is nearly free, at 0.1); a CJK
    /// ideograph or Hangul syllable 0.85; kana 0.65; anything else 0.5.
    static func estimate(_ text: String) -> Int {
        var tokens = 0.0
        var spaces = 0
        func closeSpaces() {
            if spaces == 1 { tokens += 0.1 } else if spaces > 1 { tokens += 1 }
            spaces = 0
        }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x20 || value == 0x09 || value == 0xA0 {
                spaces += 1
                continue
            }
            closeSpaces()
            switch value {
            case 0x0A, 0x0D:
                tokens += 1
            case 0x30...0x39:
                tokens += 1.15
            case 0x41...0x5A:
                tokens += 0.75
            case 0x61...0x7A:
                tokens += 0.3
            case 0x00...0x7F:
                tokens += 1                    // ASCII punctuation, symbols
            case 0x80...0x24F:
                // Latin-1 and Latin Extended: accented letters, and the
                // punctuation that lives among them.
                tokens += scalar.properties.isAlphabetic
                    ? (scalar.properties.isUppercase ? 0.75 : 0.3) : 1
            case 0x3040...0x30FF:              // Hiragana, Katakana
                tokens += 0.65
            case 0x3000...0x303F,              // CJK punctuation
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,   // ideographs
                 0xAC00...0xD7AF,              // Hangul syllables
                 0xFF00...0xFFEF,              // half- and full-width forms
                 0x20000...0x2FA1F:            // ideograph extensions
                tokens += 0.85
            case 0x1F000...0x1FAFF:            // emoji: several tokens each
                tokens += 2
            default:
                tokens += 0.5
            }
        }
        closeSpaces()
        return Int(tokens.rounded(.up))
    }

    /// What neither a count nor the estimate sees — role markers, the
    /// framework's own framing around a schema — as a flat 64 tokens plus 5%
    /// of the window.
    static func margin(context: Int) -> Int { 64 + context / 20 }

    /// Tokens left for input once the fixed parts and the reply are paid for.
    static func inputTokens(context: Int, fixed: Int, reply: Int) -> Int {
        max(0, context - fixed - reply - margin(context: context))
    }

    /// The longest leading part of `text` of at most `characters`, and
    /// whether anything was cut.
    ///
    /// Cut where the text itself breaks: at the last line break inside the
    /// limit, or failing that the last sentence end, or the last space — as
    /// long as that costs no more than a fifth of what was allowed. A
    /// statement row is a line, and a row cut from its amount is worse than
    /// a slightly shorter piece; a break further back than a fifth would
    /// throw away more than it saves, so the cut is then made mid-run.
    ///
    /// Works in `Character`s, so a Windows line ending is one break and
    /// never split ("\r\n" is a single `Character` in Swift, and equal to
    /// neither of its halves).
    static func leading(_ text: String, characters: Int) -> (text: String, truncated: Bool) {
        guard characters > 0 else { return ("", !text.isEmpty) }
        let window = Array(text.prefix(characters + 1))
        guard window.count > characters else { return (text, false) }
        let limit = characters
        let floor = limit - limit / 5
        func lastBoundary(_ isBoundary: (Character) -> Bool) -> Int? {
            var index = limit - 1
            while index >= floor {
                if isBoundary(window[index]) { return index + 1 }
                index -= 1
            }
            return nil
        }
        let end = lastBoundary(\.isNewline)
            ?? lastBoundary { ".。！？!?".contains($0) }
            ?? lastBoundary(\.isWhitespace)
            ?? limit
        return (String(window[..<end]), true)
    }
}
