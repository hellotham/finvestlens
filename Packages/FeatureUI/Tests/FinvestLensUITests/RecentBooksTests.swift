//
//  RecentBooksTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

@Suite("Recent books that have moved")
struct RecentBooksTests {

    /// The plain kind: this test process is not sandboxed, so it neither
    /// makes nor needs a security-scoped bookmark.
    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @Test("A recent whose folder moved is found where its bookmark says, not dropped")
    func movedRecentIsFound() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let before = base.appendingPathComponent("Container-A", isDirectory: true)
        let after = base.appendingPathComponent("Container-B", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let book = before.appendingPathComponent("Household.finvestlens")
        try Data("a book".utf8).write(to: book)
        let mark = try book.bookmarkData()
        // The app's container moves, and the book with it.
        try FileManager.default.moveItem(at: before, to: after)
        let gone = base.appendingPathComponent("Deleted.finvestlens").path

        let result = AppModel.relocated(paths: [book.path, gone], bookmarks: [book.path: mark],
                                        resolve: Self.resolve, bookmark: { try? $0.bookmarkData() })
        #expect(result.moved)
        #expect(result.paths.count == 2)
        #expect(Self.canonical(result.paths[0]) == Self.canonical(after.appendingPathComponent("Household.finvestlens").path),
                "\(result.paths)")
        #expect(result.paths[1] == gone, "a dead path with no bookmark is left for the list to drop")
        #expect(result.bookmarks[book.path] == nil)
        #expect(result.bookmarks[result.paths[0]] != nil, "its bookmark goes with it")
    }

    @Test("A recent that is where it was is left alone")
    func unmovedRecentStays() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("recents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let book = base.appendingPathComponent("Household.finvestlens")
        try Data("a book".utf8).write(to: book)
        let mark = try book.bookmarkData()

        let result = AppModel.relocated(paths: [book.path], bookmarks: [book.path: mark],
                                        resolve: Self.resolve, bookmark: { try? $0.bookmarkData() })
        #expect(!result.moved)
        #expect(result.paths == [book.path])
        #expect(result.bookmarks == [book.path: mark])
    }
}
