//
//  LedgerWriter.swift
//  FinvestLens — Interchange
//
//  Canonical Ledger 3 journal output (FR-XIO-10): one deterministic form,
//  shared by the exporter and the CLI's `print` so they cannot drift. The
//  canonical shape follows ledger's own `print`: `%Y/%m/%d` dates (aux as
//  `=DATE`), four-space posting indent, amounts in a padded column, notes
//  and metadata re-emitted as written, virtual brackets and lot annotations
//  preserved. Parse → write → parse is a fixed point (pinned by tests).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct LedgerWriteOptions: Sendable {
    /// Emit `account`/`commodity` directive blocks.
    public var includeDirectives = true
    /// Emit `P` price lines.
    public var includePrices = true
    /// Emit periodic (`~`) and automated (`=`) entries verbatim.
    public var includeRawEntries = true
    /// Minimum width of the posting's account cell (indent excluded); the
    /// amount starts after this many characters plus two spaces.
    public var accountColumn = 34

    public init() {}
}

public enum LedgerWriter {

    /// The whole journal, canonically.
    public static func write(_ journal: LedgerJournal,
                             options: LedgerWriteOptions = LedgerWriteOptions()) -> String {
        var out = ""

        if options.includeDirectives {
            for directive in journal.accountDirectives {
                out += "account \(directive.name)\n"
                if let note = directive.note { out += "    note \(note)\n" }
                for alias in directive.aliases { out += "    alias \(alias)\n" }
                for extra in directive.extraLines { out += "    \(extra)\n" }
            }
            if !journal.accountDirectives.isEmpty { out += "\n" }
            for directive in journal.commodityDirectives {
                let symbol = LedgerAmountSyntax.needsQuoting(directive.symbol)
                    ? "\"\(directive.symbol)\"" : directive.symbol
                out += "commodity \(symbol)\n"
                if let format = directive.format { out += "    format \(format)\n" }
                if let note = directive.note { out += "    note \(note)\n" }
                if directive.noMarket { out += "    nomarket\n" }
                for extra in directive.extraLines { out += "    \(extra)\n" }
            }
            if !journal.commodityDirectives.isEmpty { out += "\n" }
        }

        if options.includePrices, !journal.prices.isEmpty {
            for price in journal.prices {
                out += priceLine(price, styles: journal.styles) + "\n"
            }
            out += "\n"
        }

        if options.includeRawEntries {
            for entry in journal.periodicEntries + journal.automatedEntries {
                out += entry.header + "\n"
                for line in entry.lines { out += line + "\n" }
                out += "\n"
            }
        }

        for (index, transaction) in journal.transactions.enumerated() {
            out += write(transaction, styles: journal.styles, options: options)
            if index < journal.transactions.count - 1 { out += "\n" }
        }
        return out
    }

    /// One `P` line in the re-parseable `pricedb` form.
    public static func priceLine(_ price: LedgerPriceEntry,
                                 styles: LedgerAmountStyles) -> String {
        let symbol = LedgerAmountSyntax.needsQuoting(price.symbol)
            ? "\"\(price.symbol)\"" : price.symbol
        let hasTime = LedgerDateParsing.utc
            .dateComponents([.hour, .minute, .second], from: price.date) != DateComponents(hour: 0, minute: 0, second: 0)
        let stamp = LedgerDateParsing.format(price.date, includeTime: hasTime)
        return "P \(stamp) \(symbol) \(LedgerAmountSyntax.format(price.price, styles: styles))"
    }

    /// One transaction, canonically.
    public static func write(_ transaction: LedgerTransaction,
                             styles: LedgerAmountStyles,
                             options: LedgerWriteOptions = LedgerWriteOptions()) -> String {
        var out = LedgerDateParsing.format(transaction.date)
        if let aux = transaction.auxDate {
            out += "=" + LedgerDateParsing.format(aux)
        }
        switch transaction.state {
        case .cleared: out += " *"
        case .pending: out += " !"
        case .uncleared: break
        }
        if let code = transaction.code { out += " (\(code))" }
        if !transaction.payee.isEmpty { out += " " + transaction.payee }
        out += "\n"
        for note in transaction.noteLines {
            out += "    ; \(note)\n"
        }

        // The account cell width for this transaction: aligned amounts.
        let cells = transaction.postings.map { postingCell($0) }
        let width = max(options.accountColumn, cells.map(\.count).max() ?? 0)

        for (posting, cell) in zip(transaction.postings, cells) {
            var line = "    " + cell
            if let tail = postingTail(posting, styles: styles) {
                line += String(repeating: " ", count: max(2, width + 2 - cell.count))
                line += tail
            }
            if let note = posting.note {
                line += "  ; \(note)"
            }
            out += line + "\n"
            for extra in posting.noteLines where extra != posting.note {
                out += "    ; \(extra)\n"
            }
        }
        return out
    }

    /// The account cell: state flag + virtual brackets + name.
    static func postingCell(_ posting: LedgerPosting) -> String {
        var cell = ""
        switch posting.state {
        case .cleared: cell += "* "
        case .pending: cell += "! "
        default: break
        }
        switch posting.virtualKind {
        case .real: cell += posting.account
        case .balanced: cell += "[\(posting.account)]"
        case .unbalanced: cell += "(\(posting.account))"
        }
        return cell
    }

    /// Everything after the account: amount, lot annotation, cost, assertion.
    /// `nil` when the posting elides its amount and asserts nothing.
    static func postingTail(_ posting: LedgerPosting, styles: LedgerAmountStyles) -> String? {
        var pieces: [String] = []
        if posting.isAssignment, let target = posting.assertion {
            return "= " + LedgerAmountSyntax.format(target, styles: styles)
        }
        if let amount = posting.amount {
            pieces.append(LedgerAmountSyntax.format(amount, styles: styles))
        }
        if let lot = posting.lotAnnotation { pieces.append(lot) }
        if let cost = posting.cost {
            let marker: String
            switch (cost.kind, cost.isVirtual) {
            case (.perUnit, false): marker = "@"
            case (.total, false): marker = "@@"
            case (.perUnit, true): marker = "(@)"
            case (.total, true): marker = "(@@)"
            }
            pieces.append(marker + " " + LedgerAmountSyntax.format(cost.amount, styles: styles))
        }
        if let assertion = posting.assertion {
            pieces.append("= " + LedgerAmountSyntax.format(assertion, styles: styles))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " ")
    }
}
