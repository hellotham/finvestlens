//
//  StagedTransaction.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// A normalized transaction produced by a bank-file importer, before it is
/// matched and posted into the book.
///
/// `amount` is signed from the perspective of the account being imported into:
/// positive is money in, negative is money out. All importers (CSV/QIF/OFX)
/// emit this shape, which then flows into the shared ``ImportMatcher``
/// (Architecture §5.8a).
public struct StagedTransaction: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var date: Date
    public var amount: Decimal
    public var payee: String
    public var memo: String
    public var reference: String
    /// Whether ``reference`` is a **bank-unique** transaction identifier — an
    /// OFX/HBCI `FITID`, or the bank's own servicer reference in MT940/CAMT —
    /// rather than free text the payer chose.
    ///
    /// This decides two things, and getting it wrong is expensive both ways.
    /// A bank-unique id is definitive duplicate evidence on its own, and is
    /// the only thing that may be written to GnuCash's `online_id` slot. Free
    /// text repeats: a CSV "Reference" column routinely says the same thing
    /// every month ("RENT"), and treating that as an identifier made a later,
    /// larger payment match January's row and be skipped as a duplicate.
    /// Importers that cannot promise uniqueness leave this `false`, and their
    /// references are then only corroborating evidence alongside the amount.
    public var referenceIsBankUnique: Bool
    /// Source category label (QIF `L`, OFX has none) — a hint for matching.
    public var category: String
    /// Investment detail when this row is a security transaction (QIF
    /// `!Type:Invst`, OFX `<INVBUY>`/`<INVSELL>`/…). `nil` for ordinary cash
    /// rows, which flow through the cash ``ImportMatcher`` as before.
    public var investment: InvestmentDetail?
    /// Sub-splits when the record distributes one cash movement across several
    /// categories (QIF `S`/`E`/`$` lines). Empty for a plain two-legged row.
    public var splits: [StagedSplit]
    /// The bank's identifier for the account **this particular row** came from
    /// — MT940 `:25:`, CAMT `<Acct>`, OFX `<ACCTID>`.
    ///
    /// One file may carry several statements: a bank that exports "all my
    /// accounts" writes one `<STMTRS>`/`:25:`/`<Stmt>` block per account into
    /// a single download. The importers flattened those into one list and the
    /// import sheet posted the lot into whichever account the user had picked,
    /// so a joint file silently moved every other account's transactions into
    /// one. Stamping the row lets the sheet see the seam. `nil` for formats
    /// that carry no account id at all (CSV, QIF).
    public var sourceAccountID: String?

    public init(id: UUID = UUID(), date: Date, amount: Decimal, payee: String = "",
                memo: String = "", reference: String = "",
                referenceIsBankUnique: Bool = false, category: String = "",
                investment: InvestmentDetail? = nil, splits: [StagedSplit] = [],
                sourceAccountID: String? = nil) {
        self.id = id
        self.date = date
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.reference = reference
        self.referenceIsBankUnique = referenceIsBankUnique
        self.category = category
        self.investment = investment
        self.splits = splits
        self.sourceAccountID = sourceAccountID
    }

    /// Whether this staged row is a security transaction rather than cash.
    public var isInvestment: Bool { investment != nil }
    /// Whether this row distributes its amount across more than one category.
    public var isSplit: Bool { splits.count > 1 }
}

/// One category leg of a split cash record (QIF `S`/`E`/`$`).
public struct StagedSplit: Hashable, Sendable {
    /// The category / account name this leg books to (QIF `S`).
    public var category: String
    /// The leg's amount, signed like the parent (QIF `$`).
    public var amount: Decimal
    public var memo: String

    public init(category: String, amount: Decimal, memo: String = "") {
        self.category = category
        self.amount = amount
        self.memo = memo
    }
}

/// The security-transaction fields a QIF `!Type:Invst` record or an OFX
/// investment statement carries (`FR-XIO-01`/`FR-XIO-02`).
public struct InvestmentDetail: Hashable, Sendable {

    /// The kinds of security action an import can express, normalised across
    /// QIF action codes and OFX transaction types.
    public enum Action: String, Hashable, Sendable {
        case buy, sell, dividend, reinvestDividend, returnOfCapital, other
    }

    public var action: Action
    /// The security's name or ticker as written in the file (resolved to a
    /// commodity/account at import time).
    public var security: String
    /// Shares transacted (always positive; the action carries direction).
    public var quantity: Decimal
    public var pricePerShare: Decimal
    public var commission: Decimal

    public init(action: Action, security: String = "", quantity: Decimal = 0,
                pricePerShare: Decimal = 0, commission: Decimal = 0) {
        self.action = action
        self.security = security
        self.quantity = quantity
        self.pricePerShare = pricePerShare
        self.commission = commission
    }
}

/// Shared helpers for importers. Public so the Intelligence layer's tolerant
/// extraction parses money with the *same* rules — two drifting copies meant a
/// fix could land in one pipeline and not the other.
public enum ImportParsing {

    /// Decodes import-file bytes as UTF-8, stripping a leading BOM — Excel's
    /// "CSV UTF-8" (and some bank portals) prepend `EF BB BF`, and a preserved
    /// U+FEFF glues itself to the first field or tag, silently failing the
    /// first row's date parse and header autodetection.
    public static func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// Parses a monetary string, tolerating currency symbols, thousands
    /// separators, spaces, parenthesised negatives and `DR`/`CR` markers.
    ///
    /// The implementation lives in `FinvestLensEngine` as
    /// ``MoneyParsing/amount(_:)`` — importers are not the only place a human
    /// or a machine writes an amount as text, and the rule engine comparing
    /// against its own `Decimal(string:)` read "1,000" as **1**. One parser,
    /// one set of rules, wherever money arrives as a string.
    public static func amount(_ raw: String) -> Decimal? {
        MoneyParsing.amount(raw)
    }
}
