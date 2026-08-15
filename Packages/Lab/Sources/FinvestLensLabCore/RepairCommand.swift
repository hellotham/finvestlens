//
//  RepairCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensUI

/// `finlab repair` — corrections for data this tool itself got wrong.
///
/// One repair so far: **posting days**. A transaction entered from a receipt
/// took its date from the filename, which is midnight *local*; the book stores
/// a posting day as midnight UTC, so those rows sat a day early to anything
/// reading in UTC and would have exported to GnuCash on the wrong day.
///
/// Nothing is written without `--apply`, and only document-linked transactions
/// whose posted date carries a stray time-of-day are considered — a date
/// already at midnight UTC is never touched.
enum RepairCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let file = try options.existingURL("file")
        let apply = options.flag("apply")

        let model = AppModel()
        let (_, openSeconds) = try await Stopwatch.measure {
            try await model.open(at: file, breakStaleLock: true)
        }
        defer { model.close() }
        log(Fmt.row("open \(file.lastPathComponent)", Fmt.time(openSeconds)))
        guard !model.isReadOnly else { throw LabError.message("book opened read-only") }

        // Bond price scale first: it is independent of the day repair, and a
        // book can need one, the other, both or neither.
        let rescaled = model.rescaleBondPrices(apply: apply)
        if rescaled.isEmpty {
            log("  every bond price is on its security's own scale.")
        } else {
            log("  \(rescaled.count) bond price(s) a hundredfold off their security's scale:")
            let byBond = Dictionary(grouping: rescaled, by: \.mnemonic)
            for mnemonic in byBond.keys.sorted() {
                let rows = byBond[mnemonic]!
                let sample = rows[0]
                log("    \(mnemonic): \(rows.count) row(s), e.g. "
                    + "\(NSDecimalNumber(decimal: sample.from).stringValue) → "
                    + "\(NSDecimalNumber(decimal: sample.to).stringValue)")
            }
            if apply {
                try model.save()
                log("  bond prices rescaled and saved.")
            }
        }

        let moved = model.repostLinkedTransactionDays(apply: apply)
        guard !moved.isEmpty else {
            log("  every linked transaction already posts on a clean day — nothing to do.")
            return
        }

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "UTC")
        day.locale = Locale(identifier: "en_US_POSIX")

        log("  \(moved.count) transaction(s) posted with a stray time of day:")
        for row in moved {
            log("    \(day.string(from: row.from)) → \(day.string(from: row.to))  \(row.description)")
        }
        if apply {
            let (_, saveSeconds) = try Stopwatch.measure { try model.save() }
            log(Fmt.row("save", Fmt.time(saveSeconds)))
        } else {
            log("  (dry run — pass --apply to correct them)")
        }
    }
}
