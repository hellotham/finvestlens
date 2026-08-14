//
//  FundamentalsCache.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The sidecar where fetched fundamentals live — **never the book**
/// (`FR-INV-35`, decision D2).
///
/// ```
/// ~/Library/Application Support/<app>/Fundamentals/
///     <namespace>|<mnemonic>.json
/// ```
///
/// Four properties, each of which is the reason it is not in the document:
///
/// - **Prices stay the only fetched thing in the book**, so the two invariants
///   (splits balance to zero, GnuCash XML round-trips byte-identically) are
///   untouched by any of this. That alone settles it.
/// - **Keyed by commodity identity**, so it survives a rename and follows a
///   book copy only if the user copies it — which is correct, because it is a
///   cache and not data.
/// - **Discardable at any time with no data loss**, and never written during a
///   save.
/// - **It holds third-party licensed content.** It is not exported, not
///   included in a report, and not in any published artifact.
public struct FundamentalsCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `FileManager.default` rather than an injected one: it is not `Sendable`,
    /// and storing it would make this cache un-`Sendable` too. Tests inject a
    /// temporary **directory** instead, which exercises the real filesystem —
    /// a better test than a fake that cannot reproduce a permission failure.
    private var fileManager: FileManager { .default }

    /// The default location under Application Support.
    ///
    /// Falls back to a temporary directory rather than failing: a cache that
    /// cannot be written is a page that refetches, not a page that breaks.
    public static func standard(appName: String = "FinvestLens") -> FundamentalsCache {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return FundamentalsCache(
            directory: base.appendingPathComponent(appName, isDirectory: true)
                .appendingPathComponent("Fundamentals", isDirectory: true))
    }

    /// The file for a commodity identity.
    ///
    /// `|` is the separator the rest of the app already uses for this key, and
    /// it is legal in a POSIX filename. Everything else that is not is
    /// percent-escaped: a namespace can be user-defined, and `/` in one would
    /// otherwise write into a directory that does not exist — or, worse, one
    /// that does.
    func url(namespace: String, mnemonic: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.|"))
        let key = "\(namespace)|\(mnemonic)"
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? "unknown"
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    /// The cached record, or `nil` when absent, unreadable, or written by a
    /// build whose shape has since changed.
    public func load(namespace: String, mnemonic: String) -> SecurityFundamentals? {
        guard let data = try? Data(contentsOf: url(namespace: namespace, mnemonic: mnemonic)),
              let record = try? Self.decoder.decode(SecurityFundamentals.self, from: data),
              record.version == SecurityFundamentals.currentVersion
        else { return nil }
        return record
    }

    /// Writes `record`, creating the directory on first use.
    ///
    /// Failure is swallowed on purpose: this is a cache, and a page that cannot
    /// write one should still show what it just fetched.
    public func save(_ record: SecurityFundamentals, namespace: String, mnemonic: String) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(record) else { return }
        try? data.write(to: url(namespace: namespace, mnemonic: mnemonic), options: .atomic)
    }

    /// Forgets one security.
    public func remove(namespace: String, mnemonic: String) {
        try? fileManager.removeItem(at: url(namespace: namespace, mnemonic: mnemonic))
    }

    /// Forgets everything. Offered because a cache the user cannot clear is a
    /// cache they cannot trust.
    public func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    /// Bytes on disk, for the settings line that says what clearing would free.
    public func sizeOnDisk() -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(0) { total, name in
            let path = directory.appendingPathComponent(name).path
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return total + (size ?? 0)
        }
    }

    /// How many securities are cached.
    public func count() -> Int {
        (try? fileManager.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
