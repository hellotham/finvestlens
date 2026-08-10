//
//  ImportCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensPersistence

/// `finlab import` — GnuCash XML in, a `.finvestlens` document out, with the
/// phase timings NFR-02 asks for and nothing else has ever measured.
///
/// Two modes, because the difference between them is the one architecture
/// question left open (architecture.md §10, deferred.md):
///
/// - `document` (default) is exactly what the app does — the four calls of
///   `AppModel.performGnuCashImport`: parse, `FinvestLensDocument.create`,
///   `replaceBook`, `save`. Lock file, local working copy, coordinated atomic
///   write-back.
/// - `direct` points `SQLiteDocumentStore` straight at the destination and
///   writes there. On a network share that is the thing ADR-8 forbids; the
///   point of running it is to find out what the safety is *costing*, which
///   you cannot argue about without a number.
enum ImportCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let source = try options.existingURL("from")
        let destination = try options.requiredURL("to")
        let direct = options.string("mode") == "direct"

        try prepareDestination(destination, force: options.flag("force"), log: log)

        let sourceSize = fileSize(at: source)
        log("Importing \(source.lastPathComponent) (\(Fmt.bytes(sourceSize)))")
        log("        → \(destination.path)")
        log("  mode: \(direct ? "direct (SQLite written in place)" : "document (lock + working copy + write-back)")")
        log("  destination volume: \(isOnLocalVolume(destination) ? "local" : "network share")")
        log("")

        // Phase 1 — parse. No progress closure: building one costs four extra
        // linear scans of the decompressed XML just to pre-count the elements
        // (GnuCashImportProgress.swift:81-84), which would be measured as
        // parse time and is not part of an unattended import.
        let (result, parseSeconds) = try Stopwatch.measure {
            try GnuCashXMLImporter.importBook(from: source)
        }
        let summary = result.summary
        log(Fmt.row("parse XML", Fmt.time(parseSeconds)))

        // Phase 2 — write.
        let writeSeconds: Double
        if direct {
            let (_, seconds) = try Stopwatch.measure { () -> Void in
                let store = try SQLiteDocumentStore(path: destination.path)
                try store.write(result.book)
            }
            writeSeconds = seconds
            log(Fmt.row("write SQLite in place", Fmt.time(seconds)))
        } else {
            let (_, seconds) = try Stopwatch.measure { () -> Void in
                let document = try FinvestLensDocument.create(
                    at: destination,
                    baseCurrency: result.book.commodities.first ?? .aud,
                    breakStaleLock: options.flag("break-lock"))
                // Release the lock and drop the working copy on *every* exit,
                // including a throw from `save()`. Written as a trailing
                // statement this leaked the lock on a freshly created file, so
                // the retry was refused by the destination the failed run had
                // just made.
                defer { document.discard() }
                document.replaceBook(result.book)
                try document.save()
            }
            writeSeconds = seconds
            log(Fmt.row("create + write + write-back", Fmt.time(seconds)))
        }

        log(Fmt.row("total", Fmt.time(parseSeconds + writeSeconds)))
        log("")
        log("  \(Fmt.count(summary.accountCount)) accounts, "
            + "\(Fmt.count(summary.transactionCount)) transactions, "
            + "\(Fmt.count(summary.splitCount)) splits, "
            + "\(Fmt.count(summary.priceCount)) prices")
        log("  document \(Fmt.bytes(fileSize(at: destination))) "
            + "(\(String(format: "%.1f×", Double(fileSize(at: destination)) / Double(max(sourceSize, 1)))) the gzipped source)")

        if !summary.isClean {
            log("")
            log("  Scrub found \(summary.scrubIssues.count) issue(s) — the book is imported, "
                + "but these are worth a look in the app:")
            for issue in summary.scrubIssues.prefix(10) { log("    • \(issue)") }
            if summary.scrubIssues.count > 10 { log("    … and \(summary.scrubIssues.count - 10) more") }
        }
        for warning in summary.warnings { log("  note: \(warning)") }
    }

    /// Refuses to clobber an existing book; with `--force`, moves it aside.
    ///
    /// Never deletes. A book is the only copy of someone's financial history,
    /// and "I replaced it and it turned out to be the wrong one" has no undo —
    /// so the old file keeps its bytes under a dated name and the person
    /// decides later whether to bin it.
    @MainActor
    private static func prepareDestination(_ destination: URL, force: Bool, log: LabLog) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return }
        guard force else { throw LabError.destinationExists(destination) }

        // Local time, not UTC: a file set aside on the morning of the 10th
        // should not be named for the 9th because Sydney is ahead of GMT.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var aside = destination.deletingLastPathComponent()
            .appendingPathComponent("\(base) (superseded \(stamp.string(from: Date()))).\(ext)")
        var attempt = 2
        while manager.fileExists(atPath: aside.path) {
            aside = destination.deletingLastPathComponent()
                .appendingPathComponent("\(base) (superseded \(stamp.string(from: Date())) \(attempt)).\(ext)")
            attempt += 1
        }
        try manager.moveItem(at: destination, to: aside)
        log("  existing book moved aside → \(aside.lastPathComponent)")

        // The sibling lock belongs to the file that just moved; leaving it
        // behind makes the new book look locked by a process that has been
        // gone for days.
        let lock = destination.deletingPathExtension().appendingPathExtension("lock")
        if manager.fileExists(atPath: lock.path) {
            try? manager.removeItem(at: lock)
            log("  stale \(lock.lastPathComponent) removed")
        }
    }
}
