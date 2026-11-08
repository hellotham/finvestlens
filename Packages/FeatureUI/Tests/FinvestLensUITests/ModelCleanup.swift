//
//  ModelCleanup.swift
//  FinvestLens — FeatureUI
//
//  Closes a test's model and removes its book, with what the app keeps beside
//  it. A test that only made a model over a temporary book left that book's
//  working copy, the book and its lock in the temporary folder — 27 working
//  copies from every run of the suite — and one that removed only the book
//  left its audit trail, `<Book>.audit`: several hundred a run, 5,261 in the
//  temporary folder on 8 Nov 2026.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import FinvestLensUI

@MainActor
func closeAndRemove(_ model: AppModel) {
    let url = model.documentURL
    model.close()
    if let url { removeBook(at: url) }
}

/// Removes a test's book and the files the app keeps beside it: its audit
/// trail and its lock (`RelatedSidecar`: the book's name, another extension).
/// Harmless for a file that is not a book: there is nothing beside it to go.
func removeBook(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    for sidecar in ["audit", "lock"] {
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension(sidecar))
    }
}
