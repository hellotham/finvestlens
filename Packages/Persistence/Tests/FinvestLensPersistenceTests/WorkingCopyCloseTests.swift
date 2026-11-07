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
        // A statement kept alive: `sqlite3_close` refuses, and the connection
        // stays open (GRDB: `SQLITE_BUSY`).
        var statement: Statement? = try staged.store.dbQueue.inDatabase { try $0.makeStatement(sql: "SELECT 1") }

        let error = #expect(throws: DatabaseError.self) { try document.revert() }
        #expect(error?.resultCode == .SQLITE_BUSY, "\(String(describing: error))")
        #expect(document.book.accounts.contains { $0.name == "Keep" })
        #expect(try document.workingCopyHoldsBook(), "the session goes on with its own copy")

        document.discard()
        #expect(FileManager.default.fileExists(atPath: document.workingCopyURL.path),
                "not removed from under a connection that is still open")
        statement = nil
        _ = statement
        try? FileManager.default.removeItem(at: document.workingCopyURL)
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
        // A staged save carries the connection the session had before revert.
        let before = try document.stageSnapshot()
        document.saveFailed(before)

        try document.revert()

        let error = #expect(throws: DatabaseError.self) { try before.store.holds(BookSnapshot(document.book)) }
        #expect(error?.resultCode == .SQLITE_MISUSE, "\(String(describing: error))")
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
