//
//  AppModel+Audit.swift
//  FinvestLens — FeatureUI
//
//  The audit log (P9, docs/planning-design.md §9): a GnuCash-style append-only
//  sidecar beside the document, one line per edit operation, written on the
//  same code path as undo registration so it can't drift from what actually
//  happened. The log never enters the book file, and rotates at a size cap.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensPersistence

@MainActor
extension AppModel {

    /// The sidecar beside the document, `<Book>.audit`: the book's base name
    /// with the `audit` extension, which the app declares as a related item
    /// so the sandbox lets it be read and appended through the document's
    /// own grant (the same mechanism as the `.lock` file). It was
    /// `<Book>.finvestlens.audit.log` until 11 Oct 2026; that name shares no
    /// base with the book and is unreachable from a sandboxed app, so an old
    /// sidecar stays where it is and a new trail starts beside it.
    var auditSidecar: RelatedSidecar? {
        documentURL.map { RelatedSidecar(documentURL: $0, pathExtension: "audit") }
    }

    var auditLogURL: URL? { auditSidecar?.sidecarURL }

    private static let auditSizeCap = 1 << 20          // rotate past 1 MB…
    private static let auditKeepBytes = 1 << 19        // …keeping the last 512 KB

    /// Appends one operation line: ISO-8601 timestamp, tab, operation name.
    /// Undo/redo replays are labelled as such. Failures are ignored — the log
    /// is an aid, never a reason an edit can't proceed.
    func auditLog(_ operation: String) {
        guard let sidecar = auditSidecar else { return }
        var label = operation
        if undoManager?.isUndoing == true { label = "Undo " + label }
        else if undoManager?.isRedoing == true { label = "Redo " + label }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)\t\(label)\n"
        try? sidecar.append(Data(line.utf8))
        if let size = sidecar.size(), size > Self.auditSizeCap {
            rotateAuditLog(sidecar)
        }
    }

    /// Trims the log to its newest tail, cutting at a line boundary.
    private func rotateAuditLog(_ sidecar: RelatedSidecar) {
        guard let data = sidecar.read(), data.count > Self.auditKeepBytes else { return }
        var tail = data.suffix(Self.auditKeepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? sidecar.write(Data(tail))
    }

    /// The newest entries, most recent first, for the viewer.
    public func auditLogTail(limit: Int = 500) -> [(date: String, operation: String)] {
        guard let data = auditSidecar?.read(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).suffix(limit).reversed().map { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            let date = parts.first.map(String.init) ?? ""
            let operation = parts.count > 1 ? String(parts[1]) : ""
            return (date, operation)
        }
    }
}
