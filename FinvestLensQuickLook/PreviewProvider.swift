//
//  PreviewProvider.swift
//  FinvestLens — Quick Look preview extension
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Quick Look preview for a `.finvestlens` book and for GnuCash's own
//  `.gnucash` files (FR-PLT-03). Unlike the widget, this previews an arbitrary
//  file the user selected in Finder — not the last-opened book — so it reads
//  that file directly. It uses the system SQLite3 (read-only, no GRDB / Engine)
//  to pull a few headline counts, keeping the extension light and free of the
//  app's dependency graph.
//
//  Three file shapes reach it, told apart by their first bytes rather than by
//  their extension (GnuCash uses `.gnucash` for two of them):
//
//   * SQLite — ours (`account`, `txn`, …) or GnuCash's own SQL backend
//     (`accounts`, `transactions`, …; names read from GnuCash's source,
//     `libgnucash/backend/sql/gnc-{account,transaction,price,commodity}-sql.cpp`).
//   * gzip — GnuCash's default XML save.
//   * plain XML — GnuCash saved with compression off.
//
//  The XML paths never parse the document. GnuCash writes its own totals into
//  a `<gnc:count-data>` header at the top of the file, so the preview inflates
//  a *prefix* and scans that: a 200 MB book costs the same as a small one.
//

import Foundation
import Compression
import QuickLook
#if canImport(QuickLookUI)
import QuickLookUI   // QLPreviewingController lives here on macOS
#endif
import SwiftUI
import SQLite3

#if os(macOS)
import AppKit
typealias PlatformViewController = NSViewController
typealias PlatformHostingController = NSHostingController
#else
import UIKit
typealias PlatformViewController = UIViewController
typealias PlatformHostingController = UIHostingController
#endif

/// A few cheap headline figures, and what kind of book they came from.
struct BookSummary {
    var accounts = 0
    var transactions = 0
    var prices = 0
    var commodities = 0
    var readable = false
    /// Shown under the file's name — the reader should be able to see at a
    /// glance that this is a GnuCash file the app can import, not one of ours.
    var kind = LocalizedStringResource("FinvestLens Book")

    /// How much of a compressed book to inflate before giving up on finding the
    /// count header. GnuCash writes it within the first few hundred bytes.
    private static let xmlPrefixLimit = 64 * 1024
    /// How much of the file to read. Enough compressed input to yield the
    /// prefix above with room to spare, and small enough to stay cheap.
    private static let filePrefixBytes = 256 * 1024

    static func read(from url: URL) -> BookSummary {
        guard let head = prefix(of: url, bytes: filePrefixBytes) else { return BookSummary() }
        if head.starts(with: [0x1f, 0x8b]) {
            return gnuCash(xml: inflateGzipPrefix(head, limit: xmlPrefixLimit))
        }
        if head.starts(with: Array("SQLite format 3".utf8)) {
            return sqlite(at: url)
        }
        // Uncompressed XML — GnuCash saves this way with compression off.
        return gnuCash(xml: head)
    }

    private static func prefix(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: bytes)
    }

    // MARK: SQLite — ours, or GnuCash's own SQL backend

    private static func sqlite(at url: URL) -> BookSummary {
        var summary = BookSummary()
        var db: OpaquePointer?
        // SQLITE_OPEN_READONLY — never modify the previewed file.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return summary
        }
        defer { sqlite3_close(db) }

        /// `nil` when the table is not in this schema — which is how the two
        /// schemas are told apart, rather than by guessing from the extension.
        func count(_ table: String) -> Int? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \"\(table)\"", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : nil
        }

        if let accounts = count("account") {                     // our own schema
            summary.accounts = accounts
            summary.transactions = count("txn") ?? 0
            summary.prices = count("price") ?? 0
            summary.commodities = count("commodity") ?? 0
            summary.readable = true
        } else if let accounts = count("accounts") {             // GnuCash's
            summary.accounts = accounts
            summary.transactions = count("transactions") ?? 0
            summary.prices = count("prices") ?? 0
            summary.commodities = count("commodities") ?? 0
            summary.readable = true
            summary.kind = LocalizedStringResource("GnuCash Book")
        }
        return summary
    }

    // MARK: GnuCash XML — the file's own count header, not a parse

    private static func gnuCash(xml: Data) -> BookSummary {
        guard let text = String(data: xml, encoding: .utf8)
                ?? String(data: xml, encoding: .isoLatin1),
              text.contains("<gnc") else { return BookSummary() }
        var summary = BookSummary()
        summary.kind = LocalizedStringResource("GnuCash Book")
        summary.accounts = countData(text, type: "account")
        summary.transactions = countData(text, type: "transaction")
        summary.prices = countData(text, type: "price")
        summary.commodities = countData(text, type: "commodity")
        summary.readable = true
        return summary
    }

    /// `<gnc:count-data cd:type="account">42</gnc:count-data>` — the totals
    /// GnuCash writes at the head of every XML book. Scanned rather than parsed
    /// because the prefix we hold is, by construction, not well-formed XML.
    private static func countData(_ text: String, type: String) -> Int {
        let opening = "cd:type=\"\(type)\">"
        guard let start = text.range(of: opening),
              let end = text.range(of: "<", range: start.upperBound..<text.endIndex)
        else { return 0 }
        return Int(text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 0
    }

    // MARK: gzip

    /// Inflates the front of a gzip stream, stopping at `limit` bytes of output.
    ///
    /// Deliberately not `FinvestLensInterchange.Gzip`: linking Interchange would
    /// drag Engine — and the app's whole dependency graph — into an extension
    /// that Quick Look launches on a Finder selection and that otherwise needs
    /// nothing but system SQLite. The header walk below is the same RFC 1952
    /// one, minus the trailer (we hold a prefix, so there is no trailer to
    /// strip) and stopping early rather than inflating the whole book.
    private static func inflateGzipPrefix(_ data: Data, limit: Int) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18 else { return Data() }
        // magic(2) method(1) flags(1) mtime(4) xfl(1) os(1) = 10 bytes
        let flags = bytes[3]
        let fhcrc = 0x02, fextra = 0x04, fname = 0x08, fcomment = 0x10
        var offset = 10
        if flags & UInt8(fextra) != 0 {
            guard offset + 2 <= bytes.count else { return Data() }
            offset += 2 + (Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8))
        }
        for flag in [fname, fcomment] where flags & UInt8(flag) != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & UInt8(fhcrc) != 0 { offset += 2 }
        guard offset < bytes.count else { return Data() }

        let payload = data.subdata(in: (data.startIndex + offset)..<data.endIndex)
        return inflate(payload, limit: limit)
    }

    /// Raw DEFLATE, as much as `payload` yields. `COMPRESSION_ZLIB` is Apple's
    /// name for raw DEFLATE; the stream is never finalized, because a prefix
    /// has no end — running the input dry is the expected way to stop.
    private static func inflate(_ payload: Data, limit: Int) -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return Data() }
        defer { compression_stream_destroy(&stream) }

        let chunk = 32 * 1024
        var out = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }

        return payload.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.src_ptr = base
            stream.src_size = raw.count
            while out.count < limit {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let remaining = stream.src_size
                let status = compression_stream_process(&stream, 0)
                out.append(buffer, count: chunk - stream.dst_size)
                guard status == COMPRESSION_STATUS_OK else { break }
                // Input exhausted with nothing more to give: a prefix ends here.
                if stream.dst_size == chunk, stream.src_size == remaining { break }
            }
            return out
        }
    }
}

struct BookPreview: View {
    let name: String
    let summary: BookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "building.columns")
                    .font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2).fontWeight(.semibold).lineLimit(1)
                    Text(summary.kind).font(.callout).foregroundStyle(.secondary)
                }
            }

            if summary.readable {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    row("Accounts", summary.accounts)
                    row("Transactions", summary.transactions)
                    row("Commodities", summary.commodities)
                    row("Prices", summary.prices)
                }
                .font(.body.monospacedDigit())
            } else {
                Text("Preview unavailable")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted(.number)).gridColumnAlignment(.trailing)
        }
    }
}

/// The Quick Look preview controller. `QLSupportedContentTypes` in Info.plist
/// scopes it to the `.finvestlens` UTI.
class PreviewViewController: PlatformViewController, QLPreviewingController {

    func preparePreviewOfFile(at url: URL) async throws {
        let summary = BookSummary.read(from: url)
        let name = url.deletingPathExtension().lastPathComponent
        let host = PlatformHostingController(rootView: BookPreview(name: name, summary: summary))

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #if !os(macOS)
        host.didMove(toParent: self)
        #endif
    }
}
