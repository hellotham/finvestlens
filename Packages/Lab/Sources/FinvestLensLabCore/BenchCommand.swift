//
//  BenchCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensPersistence

/// `finlab bench` — where the time goes when a large book is opened and saved
/// from wherever it lives.
///
/// The open path already had a harness (`LiveOpenPerfTests`); the **save** path
/// never had one, and on a network share the save is the expensive half. Each
/// save costs two full-file SHA-256 reads of the destination (the conflict
/// fingerprint before, the new baseline after), a whole-file temp copy written
/// into the destination directory, and the atomic replace — four traversals of
/// the file across the wire, not one.
enum BenchCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let file = try options.existingURL("file")
        let repeats = max(1, options.int("repeat") ?? 1)
        let alsoSave = options.flag("save")
        let size = fileSize(at: file)

        log("Benchmarking \(file.lastPathComponent) (\(Fmt.bytes(size)))")
        log("  volume: \(isOnLocalVolume(file) ? "local" : "network share")")
        log("")

        for pass in 1...repeats {
            if repeats > 1 { log("  pass \(pass)") }

            // Read-only open: no lock, but still a working copy + full read.
            let (readOnly, readOnlySeconds) = try Stopwatch.measure {
                try FinvestLensDocument.openReadOnly(at: file)
            }
            let book = readOnly.book
            log(Fmt.row("open read-only (copy + read)", Fmt.time(readOnlySeconds)))

            // The split the open-path harness reports, measured here against
            // whatever volume the book is actually on.
            let workingCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent("finlab-bench-\(UUID().uuidString).finvestlens")
            let (_, copySeconds) = try Stopwatch.measure { () -> Void in
                try FileManager.default.copyItem(at: file, to: workingCopy)
            }
            log(Fmt.row("  ├ copy to local working copy", Fmt.time(copySeconds)))

            let (store, openSeconds) = try Stopwatch.measure {
                try SQLiteDocumentStore(path: workingCopy.path)
            }
            log(Fmt.row("  ├ open SQLite + migrate", Fmt.time(openSeconds)))

            let (_, readSeconds) = try Stopwatch.measure { try store.read() }
            log(Fmt.row("  └ materialise the book", Fmt.time(readSeconds)))

            // The write half, local only — this is the cost the network then
            // has to carry on top.
            let (_, writeSeconds) = try Stopwatch.measure { () -> Void in
                try store.write(book)
            }
            log(Fmt.row("write book → local SQLite", Fmt.time(writeSeconds)))

            try? FileManager.default.removeItem(at: workingCopy)

            if alsoSave {
                // A real save, against the real destination, with the lock and
                // the fingerprints. This is the number a person feels when
                // they press ⌘S on a book that lives on the NAS.
                let (document, openForSaveSeconds) = try Stopwatch.measure {
                    try FinvestLensDocument.open(at: file, breakStaleLock: true)
                }
                log(Fmt.row("open read-write (lock + copy + read)", Fmt.time(openForSaveSeconds)))

                // `defer`, not a trailing statement: a throw from `save()` —
                // a full disk, a dropped share — used to skip the discard and
                // strand the lock. Under a lock that syncs, that stranded file
                // propagates to every other machine and locks them out too.
                defer { document.discard() }

                let (_, saveSeconds) = try Stopwatch.measure { () -> Void in
                    try document.save()
                }
                log(Fmt.row("save (fingerprint ×2 + write-back)", Fmt.time(saveSeconds)))
            }

            if pass == 1 {
                log("")
                log("  \(Fmt.count(book.accounts.count)) accounts, "
                    + "\(Fmt.count(book.transactions.count)) transactions, "
                    + "\(Fmt.count(book.prices.count)) prices")
            }
            log("")
        }
    }
}
