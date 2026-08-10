//
//  DocumentLinkTests.swift
//  FinvestLens — FeatureUI
//
//  Transaction document links (`FR-AI-08`): storing PDFs in the document
//  folder, relative-link resolution against the setting (or the book's
//  folder), name collisions, and identical-file reuse.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Document links", .serialized)
struct DocumentLinkTests {

    /// Runs `body` with a clean document-folder setting, restoring it after.
    private func withCleanSetting(_ body: (AppModel) throws -> Void) throws {
        let saved = UserDefaults.standard.string(forKey: AppModel.documentFolderDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppModel.documentFolderDefaultsKey)
        defer {
            UserDefaults.standard.set(saved ?? "", forKey: AppModel.documentFolderDefaultsKey)
        }
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        try body(model)
    }

    private func makeTransaction(_ model: AppModel) throws -> GncGUID {
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let shopping = try #require(model.addAccount(name: "Shopping", type: .expense))
        return try model.addTransaction(
            date: Date(), description: "SHOP", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -50),
                     SplitInput(accountID: shopping, value: 50)]
        )
    }

    @Test("Attaching stores the file next to the book and links it relatively")
    func attachDefaultFolder() throws {
        try withCleanSetting { model in
            let id = try makeTransaction(model)
            let data = Data("INVOICE".utf8)
            let link = try model.attachDocument(named: "invoice.pdf", data: data, to: id)
            #expect(link == "invoice.pdf")

            // Stored next to the book, resolvable, and on the transaction.
            let resolved = try #require(model.linkedDocumentURL(for: id))
            #expect(resolved.deletingLastPathComponent().path
                    == model.documentURL?.deletingLastPathComponent().path)
            #expect(try Data(contentsOf: resolved) == data)
            #expect(model.hasLinkedDocument(id))
            #expect(model.book?.transaction(with: id)?.documentLink == "invoice.pdf")

            // Same name + same content → reused, not duplicated.
            #expect(try model.attachDocument(named: "invoice.pdf", data: data, to: id) == "invoice.pdf")
            // Same name + different content → uniqued.
            let other = try model.attachDocument(named: "invoice.pdf",
                                                 data: Data("OTHER".utf8), to: id)
            #expect(other == "invoice 2.pdf")
        }
    }

    @Test("A configured folder overrides the book folder")
    func configuredFolder() throws {
        try withCleanSetting { model in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("finvestlens-docs-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            model.configuredDocumentFolder = folder

            let id = try makeTransaction(model)
            let link = try model.attachDocument(named: "statement.pdf",
                                                data: Data("S".utf8), to: id)
            #expect(link == "statement.pdf")
            let resolved = try #require(model.linkedDocumentURL(for: id))
            #expect(resolved.deletingLastPathComponent().path == folder.path)
        }
    }

    @Test("Absolute and file:// links resolve as-is")
    func absoluteLinks() throws {
        try withCleanSetting { model in
            let id = try makeTransaction(model)
            let book = try #require(model.book)
            let transaction = try #require(book.transaction(with: id))

            transaction.documentLink = "/tmp/somewhere/doc.pdf"
            #expect(model.linkedDocumentURL(for: id)?.path == "/tmp/somewhere/doc.pdf")

            transaction.documentLink = "file:///tmp/other/doc.pdf"
            #expect(model.linkedDocumentURL(for: id)?.path == "/tmp/other/doc.pdf")

            transaction.documentLink = nil
            #expect(!model.hasLinkedDocument(id))
            #expect(model.linkedDocumentURL(for: id) == nil)
        }
    }

    @Test("Linking never copies, and relativises against either configured root")
    func linkInPlaceIsRelativeToEitherRoot() throws {
        let saved = UserDefaults.standard.string(forKey: AppModel.secondaryDocumentFolderDefaultsKey)
        defer {
            UserDefaults.standard.set(saved ?? "", forKey: AppModel.secondaryDocumentFolderDefaultsKey)
        }
        try withCleanSetting { model in
            let invoices = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let finance = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            for folder in [invoices, finance] {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent("2026-04"), withIntermediateDirectories: true)
            }
            defer { for f in [invoices, finance] { try? FileManager.default.removeItem(at: f) } }
            model.configuredDocumentFolder = invoices
            model.secondaryDocumentFolder = finance

            // Under the PRIMARY root, in a subfolder: the subpath is kept, so
            // the archive's own shape survives in the link.
            let receipt = invoices.appendingPathComponent("2026-04/Coles.png")
            try Data("R".utf8).write(to: receipt)
            let first = try makeTransaction(model)
            model.linkDocument(at: receipt, to: first)
            #expect(model.documentLink(for: first) == "2026-04/Coles.png")

            // Under the SECONDARY root. This is the case that regressed: only
            // the primary was checked, so every document filed in the second
            // folder had the user's full home path written into the book.
            let advice = finance.appendingPathComponent("2026-04/Dividend.pdf")
            try Data("D".utf8).write(to: advice)
            let second = try makeTransaction(model)
            model.linkDocument(at: advice, to: second)
            #expect(model.documentLink(for: second) == "2026-04/Dividend.pdf")
            #expect(model.linkedDocumentURL(for: second)?.path == advice.path)

            // Under neither: absolute, because there is no base to be relative to.
            let loose = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).png")
            try Data("L".utf8).write(to: loose)
            defer { try? FileManager.default.removeItem(at: loose) }
            let third = try makeTransaction(model)
            model.linkDocument(at: loose, to: third)
            #expect(model.documentLink(for: third) == loose.standardizedFileURL.path)

            // Nothing was copied into either root: linking leaves the archive
            // exactly as it found it.
            for folder in [invoices, finance] {
                let files = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil)
                #expect(files.map(\.lastPathComponent) == ["2026-04"])
            }
        }
    }
}
