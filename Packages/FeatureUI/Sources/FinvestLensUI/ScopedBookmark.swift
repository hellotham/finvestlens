//
//  ScopedBookmark.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Bookmarks that give a sandboxed app its access back.
///
/// A plain `bookmarkData()` remembers *where* a file is; only a
/// security-scoped bookmark remembers that the person *granted* it, and on
/// macOS that scope has to be asked for at creation and again at resolution
/// (`.withSecurityScope`). iOS bookmarks carry the scope implicitly, so the
/// options are a macOS-only difference. Every bookmark the app keeps —
/// recent books, the session's last book, the document folders — goes
/// through here, because one made without the scope is a path the sandboxed
/// app can see and not open, which is exactly how the first sandboxed build
/// came up on an empty window instead of the last book.
enum ScopedBookmark {
    static func make(_ url: URL) -> Data? {
        #if os(macOS)
        try? url.bookmarkData(options: .withSecurityScope,
                              includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try? url.bookmarkData()
        #endif
    }

    static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        #if os(macOS)
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        #else
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            return nil
        }
        #endif
        return (url, stale)
    }
}
