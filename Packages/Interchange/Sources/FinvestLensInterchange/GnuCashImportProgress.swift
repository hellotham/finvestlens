//
//  GnuCashImportProgress.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  How far through parsing a GnuCash XML file we are. A SAX parse of a large
//  export is comparable in cost to reading the native store (Persistence's
//  `BookLoadProgress`/`LoadReporter`), so it gets the same treatment — but
//  Interchange cannot depend on Persistence (they are peers under Engine), so
//  this is its own small, equivalent type. FeatureUI, which depends on both,
//  maps this onto `BookLoadProgress` for display.
//

import Foundation

/// Which kind of element was most recently finished — shown as the caption.
public enum GnuCashImportStage: Sendable, Equatable {
    case accounts
    case transactions
    case prices
}

/// A point in a GnuCash XML parse, in the same terms as `BookLoadProgress`.
public struct GnuCashImportProgress: Sendable, Equatable {
    public var stage: GnuCashImportStage
    /// Elements of `stage`'s kind finished so far.
    public var completed: Int
    /// Elements of `stage`'s kind in the file. Zero if none were found.
    public var total: Int
    /// Overall progress, 0...1, across every stage.
    public var fraction: Double

    public init(stage: GnuCashImportStage, completed: Int, total: Int, fraction: Double) {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.fraction = fraction
    }
}

/// The measured cost of each row type, relative to each other — the same
/// ratios as Persistence's `LoadWeight` (building an object from XML text is
/// roughly the same shape of work as building one from a database row), kept
/// as a separate copy since the two modules don't depend on each other.
enum ParseWeight {
    static let perSplit = 24.0
    static let perPrice = 26.0
    static let perTransaction = 9.0
}

/// Sizes a GnuCash XML parse and emits throttled progress through it.
///
/// The row counts are found by a fast byte-level scan of the raw XML for each
/// element's opening tag — much cheaper than the SAX parse itself (no
/// decoding, no object construction), so pre-sizing the bar this way costs
/// little next to the parse it is sizing.
///
/// GnuCash's own element order is commodities → prices → accounts →
/// transactions, not the accounts-first order Persistence reads/writes in, so
/// progress here is *not* tracked stage-by-stage in sequence; it is a running
/// weighted total across whatever has been finished so far, however the file
/// interleaves them.
struct ParseReporter {

    private let emit: @Sendable (GnuCashImportProgress) -> Void

    private let accountTotal: Int
    private let txnTotal: Int
    private let priceTotal: Int
    private let totalWork: Double

    private var splitsDone = 0
    private var txnsDone = 0
    private var pricesDone = 0
    private var lastPercent = -1

    init(xml: Data, emit: @escaping @Sendable (GnuCashImportProgress) -> Void) {
        self.emit = emit
        accountTotal = Self.occurrenceCount(of: "<gnc:account", in: xml)
        txnTotal = Self.occurrenceCount(of: "<gnc:transaction", in: xml)
        priceTotal = Self.occurrenceCount(of: "<price>", in: xml)
        let splitTotal = Self.occurrenceCount(of: "<trn:split", in: xml)

        let work = Double(splitTotal) * ParseWeight.perSplit
            + Double(txnTotal) * ParseWeight.perTransaction
            + Double(priceTotal) * ParseWeight.perPrice
        totalWork = max(work, 1)
    }

    mutating func accountFinished() {
        // Not weighted (0.3% of a load on the reference book) — reported only
        // so the caption can say "Reading accounts" during the file's account
        // section, same as a store read.
        report(.init(stage: .accounts, completed: 0, total: accountTotal, fraction: doneFraction))
    }

    mutating func transactionFinished(splitsInThisTransaction: Int) {
        txnsDone += 1
        splitsDone += splitsInThisTransaction
        report(.init(stage: .transactions, completed: txnsDone, total: txnTotal, fraction: doneFraction))
    }

    mutating func priceFinished() {
        pricesDone += 1
        report(.init(stage: .prices, completed: pricesDone, total: priceTotal, fraction: doneFraction))
    }

    mutating func finished() {
        report(.init(stage: .prices, completed: priceTotal, total: priceTotal, fraction: 1), force: true)
    }

    private var doneFraction: Double {
        let done = Double(splitsDone) * ParseWeight.perSplit
            + Double(txnsDone) * ParseWeight.perTransaction
            + Double(pricesDone) * ParseWeight.perPrice
        return min(done / totalWork, 1)
    }

    /// Emits at most once per whole percent — same rationale as `LoadReporter`.
    private mutating func report(_ progress: GnuCashImportProgress, force: Bool = false) {
        let percent = Int((progress.fraction * 100).rounded(.down))
        guard force || percent > lastPercent else { return }
        lastPercent = percent
        emit(progress)
    }

    private static func occurrenceCount(of needle: String, in haystack: Data) -> Int {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack[searchStart...].firstRange(of: pattern) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
