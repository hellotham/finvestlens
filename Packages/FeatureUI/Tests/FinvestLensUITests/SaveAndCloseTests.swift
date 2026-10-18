//
//  SaveAndCloseTests.swift
//  FinvestLens — FeatureUI
//
//  `saveAndClose()` — Close Book, switching books and quitting — writes on a
//  background thread instead of the main actor (P10). Closing must still
//  never drop an edit: not one an autosave is writing when it starts, not one
//  that lands while its own write is under way.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Save and close")
struct SaveAndCloseTests {

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The account names a saved book holds, read by opening it again.
    private func savedAccounts(at url: URL) async throws -> Set<String> {
        let reader = AppModel()
        try await reader.open(at: url)
        defer { reader.close() }
        return Set(reader.book?.accounts.map(\.name) ?? [])
    }

    @Test("The edit is on disk, the book is closed, and its lock is gone")
    func savesAndCloses() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Book.finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        _ = model.addAccount(name: "Bank", type: .bank)
        #expect(model.hasUnsavedChanges)

        #expect(await model.saveAndClose())
        #expect(!model.isOpen)
        #expect(model.documentError == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Book.lock").path))
        #expect(try await savedAccounts(at: url).contains("Bank"))
    }

    @Test("An autosave already writing is waited for, not raced")
    func waitsForAutosave() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Book.finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        _ = model.addAccount(name: "Bank", type: .bank)

        let autosave = Task { await model.saveWithStatus(interactive: false) }
        for _ in 0..<1_000 where !model.isSaving { await Task.yield() }
        #expect(model.isSaving)                 // the autosave is mid-write…
        #expect(await model.saveAndClose())     // …and closing waits for it
        await autosave.value
        #expect(!model.isOpen)
        #expect(model.documentError == nil)
        #expect(try await savedAccounts(at: url).contains("Bank"))
    }

    @Test("Edits that land while the file is being written are saved before it closes")
    func editsDuringTheWriteAreKept() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Book.finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        _ = model.addAccount(name: "Bank", type: .bank)

        // Someone keeps working while Close Book writes: every account this
        // manages to add before the book closes must be in the file.
        let editing = Task { @MainActor in
            var added: [String] = []
            for index in 0..<400 {
                guard model.isOpen else { break }
                if model.addAccount(name: "Account \(index)", type: .asset) != nil {
                    added.append("Account \(index)")
                }
                await Task.yield()
            }
            return added
        }
        #expect(await model.saveAndClose())
        let added = await editing.value
        #expect(!model.isOpen)
        #expect(!added.isEmpty)
        let saved = try await savedAccounts(at: url)
        #expect(Set(added).isSubset(of: saved))
    }

    @Test("A save that fails leaves the book open and says so")
    func failureKeepsTheBookOpen() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("Book.finvestlens")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        _ = model.addAccount(name: "Bank", type: .bank)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        #expect(await model.saveAndClose() == false)
        #expect(model.isOpen)
        #expect(model.hasUnsavedChanges)
        #expect(model.documentError != nil)
    }

    @Test("With nothing open there is nothing to do")
    func nothingOpen() async {
        let model = AppModel()
        #expect(await model.saveAndClose())
    }

    /// The two halves of a book replacement that must not overlap: the first
    /// is caught mid-close, the second is asked for then.
    enum Replacement: String, CaseIterable, Sendable {
        case openThenNew, openThenLedger, readOnlyThenOpen, newThenOpen
    }

    @Test("While one book is closing for another, a second replacement is refused — not landed over the first",
          arguments: Replacement.allCases)
    func oneReplacementAtATime(_ order: Replacement) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appendingPathComponent("Other.finvestlens")
        let third = dir.appendingPathComponent("Third.finvestlens")
        for (url, name) in [(other, "Other"), (third, "Third")] {
            let writer = AppModel()
            try writer.newDocument(at: url)
            _ = writer.addAccount(name: name, type: .bank)
            #expect(await writer.saveAndClose())
        }
        let journal = dir.appendingPathComponent("Journal.ledger")
        try "2026-01-02 Shop\n    Expenses:Food  AUD 5\n    Assets:Bank\n".write(to: journal, atomically: true, encoding: .utf8)
        let created = dir.appendingPathComponent("Created.finvestlens")

        let model = AppModel()
        try model.newDocument(at: dir.appendingPathComponent("Current.finvestlens"))
        _ = model.addAccount(name: "Bank", type: .bank)   // dirty: the close writes off the main actor

        let first: Task<Void, Never>
        switch order {
        case .openThenNew, .openThenLedger: first = Task { await model.openBook(at: other) }
        case .readOnlyThenOpen: first = Task { await model.openReadOnly(at: other) }
        case .newThenOpen: first = Task { await model.newBook(at: created) }
        }
        for _ in 0..<1_000 where !model.isSaving { await Task.yield() }
        #expect(model.isSaving, "the first replacement is mid-close")
        switch order {
        case .openThenNew: await model.newBook(at: created)
        case .openThenLedger: await model.importLedgerBook(from: journal, saveAs: created)
        case .readOnlyThenOpen, .newThenOpen: await model.openBook(at: third)
        }
        await first.value
        defer { model.close() }

        let expected = order == .newThenOpen ? created : other
        #expect(model.documentURL?.standardizedFileURL == expected.standardizedFileURL)
        if order == .openThenNew || order == .openThenLedger {
            #expect(!FileManager.default.fileExists(atPath: created.path), "the refused book was never made")
        }
        // Nothing was left holding a lock nobody can see.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Third.lock").path))
        #expect(model.documentError == nil)
    }
}
