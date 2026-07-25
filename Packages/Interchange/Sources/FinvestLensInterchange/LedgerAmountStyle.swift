//
//  LedgerAmountStyle.swift
//  FinvestLens — Interchange
//
//  Ledger amount lexing and per-commodity display-style learning
//  (docs/ledger-format-reference.md §2/§9): commodity position and spacing,
//  thousands marks, decimal-comma handling, and display precision are all
//  learned from *observed* posting amounts and reused for every amount of
//  that commodity on output — costs and `P` lines contribute value only.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// How one commodity's amounts are written.
public struct LedgerCommodityStyle: Hashable, Sendable {
    public var isPrefix = false        // `$20.00` vs `20.00 AUD`
    public var spaced = true           // space between symbol and quantity
    public var thousands = false       // 1,519.95
    public var decimalComma = false    // European: 1.000,00
    public var precision = 0           // max observed decimal places
    public var quoted = false          // symbol needs double quotes

    public init() {}
}

/// The styles learned across a journal (or seeded by an exporter).
public struct LedgerAmountStyles: Sendable {
    public private(set) var byCommodity: [String: LedgerCommodityStyle] = [:]

    public init() {}

    public func style(for commodity: String) -> LedgerCommodityStyle {
        byCommodity[commodity] ?? LedgerCommodityStyle()
    }

    /// Records an observation: position/spacing/quoting stick from the first
    /// sighting; thousands/decimal-comma latch on; precision is the maximum.
    public mutating func observe(_ commodity: String, sample: LedgerCommodityStyle) {
        guard !commodity.isEmpty else { return }
        if var existing = byCommodity[commodity] {
            existing.thousands = existing.thousands || sample.thousands
            existing.decimalComma = existing.decimalComma || sample.decimalComma
            existing.precision = max(existing.precision, sample.precision)
            byCommodity[commodity] = existing
        } else {
            byCommodity[commodity] = sample
        }
    }

    /// Exporter seeding: declare a commodity's style outright.
    public mutating func declare(_ commodity: String, style: LedgerCommodityStyle) {
        byCommodity[commodity] = style
    }
}

/// Amount lexing/formatting shared by the parser and the writer.
public enum LedgerAmountSyntax {

    /// Characters legal in an unquoted commodity symbol: everything except
    /// whitespace, digits, and ledger's punctuation set (format ref §9).
    static func isSymbolCharacter(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNumber { return false }
        return !"-+*/^&|=<>[](){}@.,;:?!\"".contains(character)
    }

    public static func needsQuoting(_ symbol: String) -> Bool {
        symbol.isEmpty || !symbol.allSatisfy(isSymbolCharacter)
    }

    /// Parses one amount token (e.g. `$20.00`, `-15.50 CAD`, `100 "crab
    /// apples"`, `10,5 EUR`). Returns nil (no diagnostics) when the text is
    /// not an amount — the caller decides whether that is an error.
    ///
    /// - Parameters:
    ///   - decimalCommaDefault: the journal-wide `--decimal-comma` state.
    ///   - styles: consulted for the commodity's learned decimal style and,
    ///     when `observe` is true, updated with this sighting.
    public static func parse(_ text: String,
                             decimalCommaDefault: Bool,
                             styles: inout LedgerAmountStyles,
                             observe: Bool) -> LedgerAmount? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        guard !s.isEmpty else { return nil }

        var negative = false
        if s.first == "-" { negative = true; s = s.dropFirst() }
        s = s.drop(while: { $0 == " " })
        guard let first = s.first else { return nil }

        var symbol = ""
        var quoted = false
        var isPrefix = false
        var spacedBeforeNumber = false
        var numberToken = ""

        func takeSymbol() -> Bool {
            if s.first == "\"" {
                quoted = true
                s = s.dropFirst()
                guard let close = s.firstIndex(of: "\"") else { return false }
                symbol = String(s[..<close])
                s = s[s.index(after: close)...]
                return true
            }
            let run = s.prefix(while: isSymbolCharacter)
            guard !run.isEmpty else { return false }
            symbol = String(run)
            s = s.dropFirst(run.count)
            return true
        }

        func takeNumber() -> Bool {
            let run = s.prefix(while: { $0.isNumber || $0 == "." || $0 == "," })
            guard !run.isEmpty, run.contains(where: \.isNumber) else { return false }
            numberToken = String(run)
            s = s.dropFirst(run.count)
            return true
        }

        if first.isNumber || first == "." || first == "," {
            // NUMBER [SYMBOL]  (suffix style)
            guard takeNumber() else { return nil }
            let spaces = s.prefix(while: { $0 == " " })
            s = s.dropFirst(spaces.count)
            if !s.isEmpty {
                let hadSpace = !spaces.isEmpty
                guard takeSymbol(), s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                spacedBeforeNumber = hadSpace
                isPrefix = false
            } else {
                symbol = ""
            }
        } else {
            // SYMBOL [-] NUMBER  (prefix style)
            guard takeSymbol() else { return nil }
            let spaces = s.prefix(while: { $0 == " " })
            s = s.dropFirst(spaces.count)
            spacedBeforeNumber = !spaces.isEmpty
            if s.first == "-" {
                guard !negative else { return nil }
                negative = true
                s = s.dropFirst()
            }
            guard takeNumber(), s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            isPrefix = true
        }

        let commodityDecimalComma = styles.byCommodity[symbol]?.decimalComma ?? decimalCommaDefault
        guard let interpreted = interpretNumber(numberToken, decimalComma: commodityDecimalComma)
        else { return nil }

        if observe, !symbol.isEmpty {
            var sample = LedgerCommodityStyle()
            sample.isPrefix = isPrefix
            sample.spaced = spacedBeforeNumber
            sample.thousands = interpreted.usedThousands
            sample.decimalComma = interpreted.decimalComma
            sample.precision = interpreted.precision
            sample.quoted = quoted
            styles.observe(symbol, sample: sample)
        }

        let quantity = negative ? -interpreted.value : interpreted.value
        return LedgerAmount(commodity: symbol, quantity: quantity)
    }

    /// Applies the `.`/`,` disambiguation rules (format ref §9): with both
    /// marks the rightmost is the decimal point; a lone comma is a decimal
    /// comma when the trailing group isn't three digits (or the style says
    /// so), else a thousands mark.
    static func interpretNumber(_ token: String, decimalComma: Bool)
        -> (value: Decimal, precision: Int, usedThousands: Bool, decimalComma: Bool)? {
        let lastDot = token.lastIndex(of: ".")
        let lastComma = token.lastIndex(of: ",")

        var decimalMark: Character?
        var effectiveDecimalComma = decimalComma
        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            decimalMark = comma > dot ? "," : "."
            effectiveDecimalComma = comma > dot
        case (.some, nil):
            if decimalComma {
                // European style: '.' groups thousands — trailing group must
                // be three digits or the number is malformed.
                let trailing = token.suffix(from: token.index(after: lastDot!))
                guard trailing.count == 3, trailing.allSatisfy(\.isNumber),
                      token.filter({ $0 == "." }).count >= 1 else { return nil }
                decimalMark = nil
            } else {
                guard token.filter({ $0 == "." }).count == 1 else { return nil }
                decimalMark = "."
            }
        case (nil, .some):
            let trailing = token.suffix(from: token.index(after: lastComma!))
            if decimalComma || trailing.count != 3 {
                guard token.filter({ $0 == "," }).count == 1 else { return nil }
                decimalMark = ","
                effectiveDecimalComma = true
            } else {
                decimalMark = nil
            }
        case (nil, nil):
            decimalMark = nil
        }

        var integerPart = ""
        var fractionPart = ""
        var inFraction = false
        var usedThousands = false
        for character in token {
            if let mark = decimalMark, character == mark, !inFraction {
                inFraction = true
                continue
            }
            if character == "." || character == "," {
                guard !inFraction else { return nil }   // grouping after the point
                usedThousands = true
                continue
            }
            if inFraction { fractionPart.append(character) } else { integerPart.append(character) }
        }
        guard !integerPart.isEmpty || !fractionPart.isEmpty else { return nil }
        let plain = (integerPart.isEmpty ? "0" : integerPart)
            + (fractionPart.isEmpty ? "" : "." + fractionPart)
        guard let value = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return (value, fractionPart.count, usedThousands, effectiveDecimalComma)
    }

    /// Renders an amount in its commodity's learned/declared style.
    public static func format(_ amount: LedgerAmount, styles: LedgerAmountStyles) -> String {
        let style = styles.style(for: amount.commodity)
        let number = formatQuantity(amount.quantity, style: style)
        guard !amount.commodity.isEmpty else { return number }
        let symbol = style.quoted || needsQuoting(amount.commodity)
            ? "\"\(amount.commodity)\"" : amount.commodity
        let gap = style.spaced ? " " : ""
        if style.isPrefix {
            // Keep the sign outside a prefixed symbol: `-$20.00`.
            if number.hasPrefix("-") {
                return "-" + symbol + gap + number.dropFirst()
            }
            return symbol + gap + number
        }
        return number + gap + symbol
    }

    static func formatQuantity(_ value: Decimal, style: LedgerCommodityStyle) -> String {
        var plain = NSDecimalNumber(decimal: value).stringValue   // "-1234.5"
        var negative = false
        if plain.hasPrefix("-") { negative = true; plain.removeFirst() }
        let parts = plain.split(separator: ".", maxSplits: 1).map(String.init)
        var integerPart = parts.first ?? "0"
        var fractionPart = parts.count > 1 ? parts[1] : ""
        // Pad to the display precision, never truncate real digits.
        while fractionPart.count < style.precision { fractionPart.append("0") }

        if style.thousands, integerPart.count > 3 {
            var grouped = ""
            for (offset, character) in integerPart.reversed().enumerated() {
                if offset > 0, offset % 3 == 0 {
                    grouped.append(style.decimalComma ? "." : ",")
                }
                grouped.append(character)
            }
            integerPart = String(grouped.reversed())
        }
        let mark = style.decimalComma ? "," : "."
        var out = integerPart
        if !fractionPart.isEmpty { out += mark + fractionPart }
        if negative { out = "-" + out }
        return out
    }
}
