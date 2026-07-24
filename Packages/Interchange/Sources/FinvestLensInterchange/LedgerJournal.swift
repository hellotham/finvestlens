//
//  LedgerJournal.swift
//  FinvestLens — Interchange
//
//  The parsed model of a Ledger 3 plain-text journal (FR-XIO-09/10).
//  Grammar per docs/ledger-format-reference.md — the manual-and-parser-
//  verified spec this codec is written against. The model keeps everything
//  the writer needs to re-emit a journal canonically (raw note lines, lot
//  annotations, virtual markers), plus resolution results (elision,
//  assignments) and the extras a strict double-entry engine cannot ingest
//  (periodic/automated entries), so nothing is silently lost.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Transaction/posting state flag: none, `!`, or `*`.
public enum LedgerState: String, Sendable, Equatable {
    case uncleared, pending, cleared
}

/// A commodity-tagged quantity. `commodity` is the ledger symbol as written
/// (unquoted form); empty means an uncommoditized number.
public struct LedgerAmount: Hashable, Sendable {
    public var commodity: String
    public var quantity: Decimal

    public init(commodity: String = "", quantity: Decimal) {
        self.commodity = commodity
        self.quantity = quantity
    }
}

/// A posting's cost annotation: `@ AMOUNT` (per unit) or `@@ AMOUNT` (total).
/// `(@)`/`(@@)` parse as the same with `isVirtual` — the exchange rate is
/// not to be recorded in a price history.
public struct LedgerCost: Hashable, Sendable {
    public enum Kind: Sendable { case perUnit, total }
    public var kind: Kind
    public var amount: LedgerAmount
    public var isVirtual: Bool

    public init(kind: Kind, amount: LedgerAmount, isVirtual: Bool = false) {
        self.kind = kind
        self.amount = amount
        self.isVirtual = isVirtual
    }
}

/// `(Account)` bypasses balancing entirely; `[Account]` must balance among
/// the bracketed postings of its transaction.
public enum LedgerVirtualKind: Sendable, Equatable {
    case real, balanced, unbalanced
}

/// One `; Key: Value` (or typed `; Key:: value-expr`) metadata entry.
public struct LedgerMetadata: Hashable, Sendable {
    public var key: String
    public var value: String
    /// `Key:: value` — the value is a value-expression, stored raw.
    public var isTyped: Bool

    public init(key: String, value: String, isTyped: Bool = false) {
        self.key = key
        self.value = value
        self.isTyped = isTyped
    }
}

public struct LedgerPosting: Sendable {
    public var account: String
    public var virtualKind: LedgerVirtualKind = .real
    /// Per-posting override of the transaction's state, if flagged.
    public var state: LedgerState?
    /// The amount as written; `nil` when elided or a balance assignment.
    public var amount: LedgerAmount?
    /// After resolution: the concrete amounts this posting contributes (an
    /// elided posting can absorb one amount per commodity).
    public var resolvedAmounts: [LedgerAmount] = []
    public var cost: LedgerCost?
    /// Raw lot-annotation text (`{…}`, `[…]`, `(…)` after the amount),
    /// preserved verbatim so print/export never destroy it. It does not
    /// affect balancing here (documented divergence, design §4).
    public var lotAnnotation: String?
    /// `= AMOUNT` after the amount/cost: a balance assertion — or, when the
    /// posting has no written amount, a balance **assignment**.
    public var assertion: LedgerAmount?
    public var isAssignment: Bool = false
    /// Synthesized by the `bucket` directive to absorb an imbalance.
    public var isSynthesized: Bool = false
    /// The same-line `; …` note, and any indented note lines below (raw,
    /// including their tag/metadata text — the writer re-emits them).
    public var note: String?
    public var noteLines: [String] = []
    public var tags: [String] = []
    public var metadata: [LedgerMetadata] = []
    /// `; [DATE]` / `; [=EDATE]` / `; [DATE=EDATE]` overrides.
    public var dateOverride: Date?
    public var auxDateOverride: Date?
    public var line: Int = 0

    public init(account: String) {
        self.account = account
    }

    /// The date this posting is effective on, given its transaction.
    public func effectiveDate(transactionDate: Date) -> Date {
        dateOverride ?? transactionDate
    }
}

public struct LedgerTransaction: Sendable {
    public var date: Date
    public var auxDate: Date?
    public var state: LedgerState = .uncleared
    public var code: String?
    public var payee: String
    /// Raw indented note lines (tags/metadata included as written).
    public var noteLines: [String] = []
    public var tags: [String] = []
    public var metadata: [LedgerMetadata] = []
    public var postings: [LedgerPosting] = []
    public var line: Int = 0

    public init(date: Date, payee: String) {
        self.date = date
        self.payee = payee
    }
}

/// A `P DATE [TIME] SYMBOL PRICE` price-history line.
public struct LedgerPriceEntry: Sendable {
    public var date: Date
    public var symbol: String
    public var price: LedgerAmount
    public var line: Int = 0

    public init(date: Date, symbol: String, price: LedgerAmount) {
        self.date = date
        self.symbol = symbol
        self.price = price
    }
}

/// An `account NAME` block with the sub-directives this codec understands;
/// unrecognised sub-lines are preserved raw.
public struct LedgerAccountDirective: Sendable {
    public var name: String
    public var note: String?
    public var aliases: [String] = []
    public var extraLines: [String] = []
    public var line: Int = 0

    public init(name: String) { self.name = name }
}

/// A `commodity SYM` block.
public struct LedgerCommodityDirective: Sendable {
    public var symbol: String
    public var note: String?
    /// The `format` sub-directive's sample amount, as written.
    public var format: String?
    public var noMarket: Bool = false
    public var extraLines: [String] = []
    public var line: Int = 0

    public init(symbol: String) { self.symbol = symbol }
}

/// A periodic (`~ PERIOD`) or automated (`= EXPR`) entry, preserved raw —
/// a strict engine neither applies nor loses them (design §4, NG-L2).
public struct LedgerRawEntry: Sendable {
    public var header: String
    public var lines: [String]
    public var line: Int = 0

    public init(header: String, lines: [String]) {
        self.header = header
        self.lines = lines
    }
}

/// A parse/resolution message anchored to file:line.
public struct LedgerDiagnostic: Sendable, CustomStringConvertible {
    public enum Severity: Sendable, Equatable { case warning, error }
    public var severity: Severity
    public var file: String
    public var line: Int
    public var message: String

    public init(_ severity: Severity, file: String, line: Int, message: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
    }

    public var description: String {
        "\(file):\(line): \(severity == .error ? "error" : "warning"): \(message)"
    }
}

/// The parsed journal: everything needed to report on it, map it to a
/// `Book`, or write it back out.
public struct LedgerJournal: Sendable {
    public var transactions: [LedgerTransaction] = []
    public var prices: [LedgerPriceEntry] = []
    public var accountDirectives: [LedgerAccountDirective] = []
    public var commodityDirectives: [LedgerCommodityDirective] = []
    public var periodicEntries: [LedgerRawEntry] = []
    public var automatedEntries: [LedgerRawEntry] = []
    /// Per-commodity display styles learned from observed amounts.
    public var styles = LedgerAmountStyles()
    /// How many balance assertions the resolver checked (failures are error
    /// diagnostics) and how many assignments it materialised — the import
    /// summary reports both.
    public var assertionsChecked = 0
    public var assignmentsResolved = 0

    public init() {}
}

public struct LedgerParseResult: Sendable {
    public var journal: LedgerJournal
    public var diagnostics: [LedgerDiagnostic]

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}
