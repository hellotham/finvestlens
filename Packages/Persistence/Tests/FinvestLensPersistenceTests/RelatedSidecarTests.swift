//
//  RelatedSidecarTests.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensPersistence

@Suite("Related sidecar")
struct RelatedSidecarTests {

    private func tempDocument() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc = dir.appendingPathComponent("Book.finvestlens")
        FileManager.default.createFile(atPath: doc.path, contents: Data("book".utf8))
        return doc
    }

    @Test("The sidecar takes the document's base name and the given extension")
    func naming() {
        let doc = tempDocument()
        defer { try? FileManager.default.removeItem(at: doc.deletingLastPathComponent()) }
        let sidecar = RelatedSidecar(documentURL: doc, pathExtension: "audit")
        #expect(sidecar.sidecarURL.lastPathComponent == "Book.audit")
        #expect(sidecar.sidecarURL.deletingLastPathComponent() == doc.deletingLastPathComponent())
        #expect(!sidecar.exists())
        #expect(sidecar.read() == nil)
        #expect(sidecar.size() == nil)
    }

    @Test("Append creates, appends, and the whole is read back; write replaces")
    func appendWriteRead() throws {
        let doc = tempDocument()
        defer { try? FileManager.default.removeItem(at: doc.deletingLastPathComponent()) }
        let sidecar = RelatedSidecar(documentURL: doc, pathExtension: "audit")
        try sidecar.append(Data("one\n".utf8))
        try sidecar.append(Data("two\n".utf8))
        #expect(sidecar.exists())
        #expect(sidecar.read() == Data("one\ntwo\n".utf8))
        #expect(sidecar.size() == 8)
        try sidecar.write(Data("three\n".utf8))
        #expect(sidecar.read() == Data("three\n".utf8))
        try sidecar.remove()
        #expect(!sidecar.exists())
    }

    @Test("Moving alongside a moved document carries the sidecar and leaves nothing behind")
    func moveAlongside() throws {
        let doc = tempDocument()
        defer { try? FileManager.default.removeItem(at: doc.deletingLastPathComponent()) }
        let sidecar = RelatedSidecar(documentURL: doc, pathExtension: "audit")
        try sidecar.append(Data("trail\n".utf8))
        let renamed = doc.deletingLastPathComponent().appendingPathComponent("Ledger.finvestlens")
        try FileManager.default.moveItem(at: doc, to: renamed)
        try sidecar.move(alongside: renamed)
        #expect(!sidecar.exists())
        let moved = RelatedSidecar(documentURL: renamed, pathExtension: "audit")
        #expect(moved.sidecarURL.lastPathComponent == "Ledger.audit")
        #expect(moved.read() == Data("trail\n".utf8))
        // Moving an absent sidecar is a no-op, not an error.
        try sidecar.move(alongside: renamed)
    }
}
