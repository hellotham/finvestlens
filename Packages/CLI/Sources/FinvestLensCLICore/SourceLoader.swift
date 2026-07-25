//
//  SourceLoader.swift
//  FinvestLens — CLI
//
//  Turns every `-f` source into one Engine `Book` plus the journal-only
//  extras the pipeline can't model (design ADR-L3): `.finvestlens` books open
//  through a READ-ONLY store connection — no lock, no working copy, no writes
//  (ADR-L2) — while `.ledger` journals and `.gnucash` files come through the
//  existing interchange codecs.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensPersistence
import FinvestLensInterchange

public enum SourceKind: Sendable, Equatable {
    case book, journal, gnucash
}

/// What a journal carries that a `Book` cannot.
public struct SourceExtras: Sendable {
    public var journals: [LedgerJournal] = []
    public var diagnostics: [LedgerDiagnostic] = []
    public var unbalancedVirtualsSkipped = 0
}

public struct LoadedSource {
    public let book: Book
    public let extras: SourceExtras
    public let descriptions: [String]
}

public enum SourceLoadError: Error, CustomStringConvertible {
    case noFile
    case unreadable(String, String)
    case multipleBooks
    case journalErrors([LedgerDiagnostic])

    public var description: String {
        switch self {
        case .noFile:
            "no source file given (use -f FILE or set FINLENS_FILE)"
        case .unreadable(let path, let reason):
            "cannot read '\(path)': \(reason)"
        case .multipleBooks:
            "only one .finvestlens book can be read at a time"
        case .journalErrors(let diagnostics):
            diagnostics.prefix(10).map(\.description).joined(separator: "\n")
        }
    }
}

public enum SourceLoader {

    public static func kind(of path: String) -> SourceKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "finvestlens": return .book
        case "gnucash": return .gnucash
        case "ledger", "journal", "dat", "txt": return .journal
        default: break
        }
        // Content sniff: gzip magic or a `<gnc-v2` root means GnuCash.
        guard let handle = FileHandle(forReadingAtPath: path),
              let head = try? handle.read(upToCount: 512) else { return .journal }
        try? handle.close()
        if head.starts(with: [0x1f, 0x8b]) { return .gnucash }
        let text = String(decoding: head, as: UTF8.self)
        if text.contains("<gnc-v2") || text.contains("<?xml") { return .gnucash }
        return .journal
    }

    /// Loads and merges every source. Journal sources merge into one book;
    /// a book source must stand alone.
    public static func load(paths: [String], today: Date = Date()) throws -> LoadedSource {
        guard !paths.isEmpty else { throw SourceLoadError.noFile }

        let kinds = paths.map(kind(of:))
        if kinds.contains(.book) {
            guard paths.count == 1 else { throw SourceLoadError.multipleBooks }
            let path = paths[0]
            do {
                let store = try SQLiteDocumentStore(readOnlyPath: path)
                let book = try store.read()
                return LoadedSource(book: book, extras: SourceExtras(),
                                    descriptions: [(path as NSString).lastPathComponent])
            } catch {
                throw SourceLoadError.unreadable(path, error.localizedDescription)
            }
        }

        if kinds.contains(.gnucash), paths.count == 1 {
            let path = paths[0]
            do {
                let result = try GnuCashXMLImporter.importBook(from: URL(fileURLWithPath: path))
                return LoadedSource(book: result.book, extras: SourceExtras(),
                                    descriptions: [(path as NSString).lastPathComponent])
            } catch {
                throw SourceLoadError.unreadable(path, error.localizedDescription)
            }
        }

        // One or more journals: parse each, merge the text, then map once so
        // account identity is shared across files.
        var merged = ""
        var descriptions: [String] = []
        for path in paths {
            let text: String
            if path == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                text = String(decoding: data, as: UTF8.self)
                descriptions.append("<stdin>")
            } else {
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw SourceLoadError.unreadable(path, "not readable as UTF-8 text")
                }
                text = contents
                descriptions.append((path as NSString).lastPathComponent)
            }
            merged += text
            if !merged.hasSuffix("\n") { merged += "\n" }
        }

        let parsed = LedgerParser.parse(text: merged,
                                        fileName: descriptions.joined(separator: "+"),
                                        today: today)
        let errors = parsed.diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else { throw SourceLoadError.journalErrors(errors) }

        let result = LedgerImport.importBook(parsed: parsed)
        var extras = SourceExtras()
        extras.journals = [parsed.journal]
        extras.diagnostics = parsed.diagnostics
        extras.unbalancedVirtualsSkipped = result.summary.unbalancedVirtualsSkipped
        return LoadedSource(book: result.book, extras: extras, descriptions: descriptions)
    }

    /// `-f` files, else `$FINLENS_FILE`. We deliberately do NOT read
    /// `LEDGER_FILE` (design §5.1): pointing another tool's environment at a
    /// different engine invites silent confusion.
    public static func resolvePaths(_ files: [String],
                                    environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [String] {
        if !files.isEmpty { return files }
        if let fromEnvironment = environment["FINLENS_FILE"], !fromEnvironment.isEmpty {
            return [fromEnvironment]
        }
        return []
    }
}
