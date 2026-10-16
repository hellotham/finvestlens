//
//  BookLoadProgress.swift
//  FinvestLens — Persistence
//
//  How far through materialising a book we are.
//
//  The weights below are measured, not guessed. On the Ashley Bears book
//  (46,553 transactions / 103,332 splits / 102,706 prices) a debug read splits
//  almost exactly in half between transactions and prices:
//
//      commodities (90)           0.002s    0.0%
//      accounts (560) + tree      0.014s    0.3%
//      split rows → grouping      0.358s    6.3%
//      transactions + splits      2.521s   44.7%
//      prices                     2.712s   48.1%
//                                 -----
//                                 5.640s
//
//  Fetching every row from every table is only 0.43s of that, so ~90% of a load
//  is building objects, and the per-row cost is what the bar has to track:
//  ~24µs a split, ~26µs a price, ~9µs a transaction. A split and a price cost
//  about the same; a transaction is cheap next to the splits hanging off it.
//  Weighting by those figures keeps the bar honest on books shaped differently
//  from this one — a price-heavy book spends its time in prices, and the bar
//  says so, where a naive rows-processed count would run ~8% fast and then
//  stall.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A point in a book load, in the user's terms and as a fraction.
public struct BookLoadProgress: Sendable, Equatable {

    /// The phases worth naming. Commodities and accounts are folded into
    /// ``accounts`` — together they are 0.3% of a load, so giving them their own
    /// caption would flash past unread.
    public enum Stage: Sendable, Equatable, CaseIterable {
        case accounts
        case transactions
        case prices
        /// The read is done and the app is building what you see — balances, the
        /// account tree, the dashboard. Not reported by the store: it is the
        /// caller's own work, and the caller sets it. It exists because that
        /// work runs on the main actor and cannot repaint while it runs, so the
        /// last frame painted before it needs to say what is happening rather
        /// than leave a bar sitting under "Reading prices" for seconds.
        case finishing
    }

    /// What the operation reporting is doing. A GnuCash import writes a
    /// freshly parsed book through this same bar, and "Reading transactions"
    /// would be backwards while it does.
    public enum Operation: Sendable, Equatable {
        /// A store read — opening a book.
        case reading
        /// A write-back.
        case writing
        /// The GnuCash XML pass an import makes before it writes.
        case parsing
    }

    public var stage: Stage
    /// Rows finished in this stage.
    public var completed: Int
    /// Rows in this stage. Zero for a stage this book has none of.
    public var total: Int
    /// Overall progress, 0...1, across every stage — what the bar shows.
    public var fraction: Double
    public var operation: Operation

    public init(stage: Stage, completed: Int, total: Int, fraction: Double,
                operation: Operation = .reading) {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.fraction = fraction
        self.operation = operation
    }

    /// Shown under the bar, e.g. "Writing transactions" — each pair a phrase
    /// of its own. It was a verb and a noun put side by side, which is a
    /// sentence in English and nowhere else, and neither word was translated.
    public var label: String {
        switch (operation, stage) {
        case (_, .finishing): String(localized: "Preparing your accounts")
        case (.reading, .accounts): String(localized: "Reading accounts")
        case (.reading, .transactions): String(localized: "Reading transactions")
        case (.reading, .prices): String(localized: "Reading prices")
        case (.writing, .accounts): String(localized: "Writing accounts")
        case (.writing, .transactions): String(localized: "Writing transactions")
        case (.writing, .prices): String(localized: "Writing prices")
        case (.parsing, .accounts): String(localized: "Parsing accounts")
        case (.parsing, .transactions): String(localized: "Parsing transactions")
        case (.parsing, .prices): String(localized: "Parsing prices")
        }
    }
}

/// The measured cost of each row type, relative to each other. Used to size the
/// stages so the bar advances at a steady rate rather than per-row.
///
/// These are ratios, not absolute times: only their proportions matter, so they
/// hold as long as release scales the stages evenly (all three are the same kind
/// of work — Decimal parsing and object construction).
enum LoadWeight {
    static let perSplit = 24.0
    static let perPrice = 26.0
    static let perTransaction = 9.0
}
