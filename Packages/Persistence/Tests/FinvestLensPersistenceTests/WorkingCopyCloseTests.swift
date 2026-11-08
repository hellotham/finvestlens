//
//  WorkingCopyCloseTests.swift
//  FinvestLens — Persistence
//
//  A working copy's SQLite connection is closed before its file is removed or
//  replaced. Removing a database file a connection still holds is what SQLite
//  logged as "vnode unlinked while in use" on every close of a book and every
//  revert (4 Nov 2026). Asking the old connection for something fails either
//  way — Apple's SQLite invalidates a descriptor whose file was unlinked — so
//  each test asks how it failed: closed (`SQLITE_MISUSE`, "Connection is
//  closed"), not cut off.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import GRDB
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@Suite("A working copy is closed before it is removed or replaced")
struct WorkingCopyCloseTests {

    @Test("Discard closes the connection, then removes the working copy")
    func discardCloses() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        let workingCopy = document.workingCopyURL
        #expect(FileManager.default.fileExists(atPath: workingCopy.path))

        document.discard()

        #expect(!FileManager.default.fileExists(atPath: workingCopy.path))
        let error = #expect(throws: DatabaseError.self) { try document.workingCopyHoldsBook() }
        #expect(error?.resultCode == .SQLITE_MISUSE, "\(String(describing: error))")
    }

    @Test("A connection that will not close keeps its file: revert says so and changes nothing, discard leaves it")
    func busyConnection() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        document.book.addAccount(Account(name: "Keep", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()
        let staged = try document.stageSnapshot()
        document.saveFailed(staged)
        do {
            // A statement kept alive: `sqlite3_close` refuses, and the
            // connection stays open (GRDB: `SQLITE_BUSY`).
            let statement = try staged.store.dbQueue.inDatabase { try $0.makeStatement(sql: "SELECT 1") }
            try withExtendedLifetime(statement) { () throws -> Void in
                let error = #expect(throws: DatabaseError.self) { try document.revert() }
                #expect(error?.resultCode == .SQLITE_BUSY, "\(String(describing: error))")
                #expect(document.book.accounts.contains { $0.name == "Keep" })
                #expect(try document.workingCopyHoldsBook(), "the session goes on with its own copy")

                document.discard()
                #expect(FileManager.default.fileExists(atPath: document.workingCopyURL.path),
                        "not removed from under a connection that is still open")
            }
        }
        // The statement went with its scope; now the connection closes, and
        // its file can go.
        try staged.store.close()
        try FileManager.default.removeItem(at: document.workingCopyURL)
    }

    @Test("A working copy swept away while the book is open: revert puts the shared file in its place")
    func revertWithoutWorkingCopy() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        document.book.addAccount(Account(name: "Keep", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()
        document.book.addAccount(Account(name: "Temp", type: .asset, commodity: .aud))
        document.markDirty()
        // What a sweep of the temporary folder does, connection and all.
        try FileManager.default.removeItem(at: document.workingCopyURL)

        try document.revert()

        #expect(document.book.accounts.contains { $0.name == "Keep" })
        #expect(!document.book.accounts.contains { $0.name == "Temp" })
        #expect(try document.workingCopyHoldsBook())
        document.book.addAccount(Account(name: "After", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()
        let reopened = try FinvestLensDocument.openReadOnly(at: url)
        defer { reopened.discard() }
        #expect(reopened.book.accounts.contains { $0.name == "Keep" },
                "the save wrote what changed into a whole book, not an empty one")
        #expect(reopened.book.accounts.contains { $0.name == "After" })
    }

    @Test("A shared file that is not a book stops revert before anything is closed or replaced, and leaves no copy")
    func revertOfDamagedFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        document.book.addAccount(Account(name: "Keep", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()
        document.book.addAccount(Account(name: "Unsaved", type: .asset, commodity: .aud))
        document.markDirty()
        // A sync that wrote something else over the shared file. Unique, so a
        // copy of it left in the shared working folder can be told from
        // anything another test put there.
        let damaged = Data("not a book \(UUID().uuidString)".utf8)
        try damaged.write(to: url)

        #expect(throws: (any Error).self) { try document.revert() }

        #expect(document.book.accounts.contains { $0.name == "Unsaved" }, "the session is as it was")
        #expect(document.hasUnsavedChanges)
        #expect(FileManager.default.fileExists(atPath: document.workingCopyURL.path))
        _ = try document.workingCopyHoldsBook()     // still open: this would throw if closed
        let folder = document.workingCopyURL.deletingLastPathComponent()
        let left = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { (try? Data(contentsOf: $0)) == damaged }
        #expect(left.isEmpty, "a copy of the damaged file was left in the working folder: \(left)")
    }

    @Test("A file that will not open as a book leaves no working copy and no lock")
    func failedOpenLeavesNothing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // An SQLite file with someone else's tables: past the header check,
        // refused once copied and opened.
        do {
            let foreign = try DatabaseQueue(path: url.path)
            try foreign.write { try $0.execute(sql: "CREATE TABLE gnclock (hostname TEXT)") }
            try foreign.close()
        }
        let destination = tempURL()
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(throws: FinvestLensDocument.DocumentError.notAFinvestLensBook(.gnuCashSQLite)) {
            _ = try FinvestLensDocument.readWorkingCopy(of: url, to: destination, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        #expect(throws: FinvestLensDocument.DocumentError.notAFinvestLensBook(.gnuCashSQLite)) {
            _ = try FinvestLensDocument.open(at: url)
        }
        // "Book.finvestlens" → "Book.lock" (FileLock).
        let lockFile = url.deletingPathExtension().appendingPathExtension("lock")
        #expect(!FileManager.default.fileExists(atPath: lockFile.path), "the lock taken for the open is released")
    }

    @Test("Revert closes the old connection, replaces the working copy, and goes on saving")
    func revertCloses() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        document.book.addAccount(Account(name: "Keep", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()

        document.book.addAccount(Account(name: "Temp", type: .asset, commodity: .aud))
        document.markDirty()
        // The connection the session had before revert, and a save staged then.
        let before = try document.stageSnapshot()
        document.saveFailed(before)
        let old = before.store

        try document.revert()

        let error = #expect(throws: DatabaseError.self) { try old.holds(BookSnapshot(document.book)) }
        #expect(error?.resultCode == .SQLITE_MISUSE, "\(String(describing: error))")
        // The staged save reaches the store revert opened, not the closed one.
        #expect(try before.store.holds(BookSnapshot(document.book)))
        #expect(document.book.accounts.contains { $0.name == "Keep" })
        #expect(!document.book.accounts.contains { $0.name == "Temp" })
        #expect(try document.workingCopyHoldsBook())

        document.book.addAccount(Account(name: "After", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()
        let reopened = try FinvestLensDocument.openReadOnly(at: url)
        defer { reopened.discard() }
        #expect(reopened.book.accounts.contains { $0.name == "After" })
        #expect(!reopened.book.accounts.contains { $0.name == "Temp" })
    }
}

/// The book's own lock stays with the signal reaper while something else in
/// the same process reads the book. A read-only open builds a lock object it
/// never takes, and that object, going, used to take the holder's entry with
/// it: the next SIGTERM left the open book's lock behind, to sync to every
/// other Mac (found in review, 8 Nov 2026).
@Suite("A lock that was never held leaves the holder's reaper entry alone")
struct LockReaperEntryTests {

    @Test("A read-only open of the open book, and its lock object going, keep the holder registered")
    func readOnlyOpenKeepsHoldersEntry() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        let lockURL = url.deletingPathExtension().appendingPathExtension("lock")
        let holder = try #require(LockReaper.registeredInstance(for: lockURL), "the open book's lock is registered")

        do {
            let reader = try FinvestLensDocument.openReadOnly(at: url)
            reader.discard()
        }
        do { _ = FileLock(documentURL: url) }

        #expect(LockReaper.registeredInstance(for: lockURL) == holder)
    }
}

@Suite("Revert reads the whole shared book before it changes anything")
struct RevertReadsFirstTests {

    /// A book with enough rows that its tables run past the first pages.
    private func savedBook(at url: URL) throws -> FinvestLensDocument {
        let document = try FinvestLensDocument.create(at: url)
        for index in 0..<400 {
            document.book.addAccount(Account(name: "Account \(index)", type: .asset, commodity: .aud))
        }
        document.markDirty()
        try document.save()
        document.book.addAccount(Account(name: "Unsaved", type: .asset, commodity: .aud))
        document.markDirty()
        return document
    }

    private func sha256(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    @Test("A shared file torn by a sync — it opens, then fails as it is read — leaves the session as it was")
    func tornFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try savedBook(at: url)
        defer { document.discard() }
        // The first pages — the schema, the migrations, `meta` — are whole;
        // the rest is gone, as from a sync that stopped half way.
        var bytes = try Data(contentsOf: url)
        let pageSize = 4096
        #expect(bytes.count > 4 * pageSize, "the book runs past its first pages: \(bytes.count) bytes")
        bytes.replaceSubrange((bytes.count / 2)..., with: Data(count: bytes.count - bytes.count / 2))
        try bytes.write(to: url)
        let before = try sha256(document.workingCopyURL)

        #expect(throws: (any Error).self) { try document.revert() }

        #expect(try sha256(document.workingCopyURL) == before, "the working copy was not replaced")
        #expect(document.book.accounts.contains { $0.name == "Unsaved" }, "the book on screen is the session's")
        #expect(document.hasUnsavedChanges)
        _ = try document.workingCopyHoldsBook()     // still open: this would throw if closed
    }

    @Test("A shared file of no bytes is no book: revert refuses it and changes nothing")
    func emptyFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try savedBook(at: url)
        defer { document.discard() }
        try Data().write(to: url)

        #expect(throws: FinvestLensDocument.DocumentError.notAFinvestLensBook(.unrecognized)) {
            try document.revert()
        }
        #expect(document.book.accounts.contains { $0.name == "Unsaved" })
        #expect(document.book.accounts.count > 400)
    }
}

/// The whole working folder swept away, as the system's cleaner can from a
/// book left untouched for days: revert makes the folder again and the session
/// saves. The document gets a working folder of its own, so removing it touches
/// nothing else — not the shared one every other test and process uses.
@Suite("Revert after the working folder itself was swept away")
struct SweptWorkingFolderTests {

    @Test("Revert makes the folder again, and the session goes on saving")
    func folderSwept() throws {
        let url = tempURL()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinvestLens-sweep-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: folder)
        }
        let document = try FinvestLensDocument.create(at: url, workingDirectory: folder)
        defer { document.discard() }
        #expect(document.workingCopyURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        document.book.addAccount(Account(name: "Keep", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()
        try FileManager.default.removeItem(at: folder)

        try document.revert()

        #expect(FileManager.default.fileExists(atPath: document.workingCopyURL.path))
        document.book.addAccount(Account(name: "After", type: .asset, commodity: .aud))
        document.markDirty()
        try document.save()
        let reopened = try FinvestLensDocument.openReadOnly(at: url)
        defer { reopened.discard() }
        #expect(reopened.book.accounts.contains { $0.name == "Keep" })
        #expect(reopened.book.accounts.contains { $0.name == "After" })
    }
}
