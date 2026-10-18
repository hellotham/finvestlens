//
//  ReportRequest.swift
//  FinvestLens — FeatureUI
//
//  A report as a value: its memo key and how to build it from a book, in one
//  place. The main actor reads it through the memo (`AppModel.report(_:)`);
//  a view about to show a slow one first has it built on a replica, off the
//  main actor (`AppModel.warm(_:)`, P3.3). One request serves both, so the
//  two can never ask for different reports under the same key.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

struct ReportRequest<Value: Sendable>: Sendable {
    /// The memo key — every parameter the build reads.
    let key: String
    /// How much of the book the build reads: the postings of the accounts it
    /// covers, or `nil` for a report over the whole book. A build time is how
    /// long *that much* took, and says nothing about a request that reads far
    /// more — a quiet account's report is no guide to the busiest one's.
    var work: Int? = nil
    /// Which report this is, whatever its parameters: the key up to its
    /// first parameter. Build times are kept per kind.
    var kind: String { String(key.prefix { $0 != ":" }) }
    /// Reads nothing but `book` and what it captured: it runs on the main
    /// actor against the book, or anywhere against a replica.
    let build: @Sendable (Book) -> Value?
}

/// How long a build of one kind of report took, and how much it read
/// (``AppModel/warm(_:)``).
struct ReportBuildTime: Equatable {
    var took: Duration
    /// The request's ``ReportRequest/work``.
    var work: Int?

    /// Whether a build reading `work` would finish inside `threshold` at this
    /// one's rate: the time itself for a report over the whole book, scaled by
    /// the postings for one over some accounts.
    func isFast(for work: Int?, under threshold: Duration) -> Bool {
        guard let work, let measured = self.work else { return took < threshold }
        return took / threshold * (Double(work) / Double(max(measured, 1))) < 1
    }
}
