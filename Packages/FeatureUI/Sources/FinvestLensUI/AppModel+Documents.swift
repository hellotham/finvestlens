//
//  AppModel+Documents.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Transaction document links (`FR-AI-08`), modelled on GnuCash's
//  associations: a transaction carries an `assoc_uri` slot holding either an
//  absolute `file://` URI or a path **relative to the document folder** — a
//  user setting (GnuCash's "path head"), defaulting to the folder the book
//  lives in so links stay valid when a book and its documents move together
//  (e.g. on a NAS).
//

import Foundation
import FinvestLensPersistence
import FinvestLensEngine
#if os(macOS)
import AppKit
#endif

@MainActor
extension AppModel {

    static let documentFolderDefaultsKey = "finvestlens.documentFolderPath"
    static let secondaryDocumentFolderDefaultsKey = "finvestlens.documentFolderPathSecondary"
    /// Beside each path, the security-scoped bookmark that lets a sandboxed
    /// build back into the folder on the next launch (`ScopedBookmark`). A
    /// folder chosen before the sandbox has a path and no bookmark; its
    /// files read as missing until it is chosen again in Settings.
    static let documentFolderBookmarkKey = "finvestlens.documentFolderBookmark"
    static let secondaryDocumentFolderBookmarkKey = "finvestlens.documentFolderBookmarkSecondary"

    /// Each folder's bookmark, resolved once per session and its scoped
    /// access started then (on macOS, under the sandbox); dropped when the
    /// folder is re-chosen. The resolved URL is kept only for the access —
    /// the folder the app reports is the path the person chose, which a
    /// resolved bookmark may spell differently (`/private/var` for `/var`).
    private static var resolvedFolders: [String: (url: URL, accessing: Bool)] = [:]

    private func scopedFolder(pathKey: String, bookmarkKey: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty else {
            return nil
        }
        if Self.resolvedFolders[bookmarkKey] == nil,
           let data = UserDefaults.standard.data(forKey: bookmarkKey),
           let resolved = ScopedBookmark.resolve(data) {
            Self.resolvedFolders[bookmarkKey] =
                (resolved.url, resolved.url.startAccessingSecurityScopedResource())
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func setScopedFolder(_ url: URL?, pathKey: String, bookmarkKey: String) {
        if let previous = Self.resolvedFolders.removeValue(forKey: bookmarkKey), previous.accessing {
            previous.url.stopAccessingSecurityScopedResource()
        }
        UserDefaults.standard.set(url?.path ?? "", forKey: pathKey)
        if let url, let data = ScopedBookmark.make(url) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    // MARK: New-book placement

    /// A non-colliding URL for a new book in `directory`: `Untitled`,
    /// `Untitled 2`, `Untitled 3`, … On iOS the caller passes the app's
    /// Documents directory — user-visible in Files under
    /// "On My iPhone ▸ finvestlens" — never the purgeable temporary
    /// directory. A leftover sibling `.lock` also counts as a collision, so
    /// a new book can never adopt a stale lock.
    public static func newBookURL(in directory: URL,
                                  baseName: String = "Untitled") -> URL {
        func candidate(_ index: Int) -> URL {
            let name = index == 1 ? baseName : "\(baseName) \(index)"
            return directory.appendingPathComponent(name)
                .appendingPathExtension("finvestlens")
        }
        var index = 1
        while FileManager.default.fileExists(atPath: candidate(index).path)
            || FileManager.default.fileExists(
                atPath: candidate(index).deletingPathExtension()
                    .appendingPathExtension("lock").path) {
            index += 1
        }
        return candidate(index)
    }

    // MARK: Folder setting

    /// The user-chosen document folder, or `nil` to use the book's folder.
    public var configuredDocumentFolder: URL? {
        get {
            scopedFolder(pathKey: Self.documentFolderDefaultsKey,
                         bookmarkKey: Self.documentFolderBookmarkKey)
        }
        set {
            setScopedFolder(newValue, pathKey: Self.documentFolderDefaultsKey,
                            bookmarkKey: Self.documentFolderBookmarkKey)
        }
    }

    /// Where relative document links resolve: the configured folder, else the
    /// folder containing the open book.
    public var effectiveDocumentFolder: URL? {
        configuredDocumentFolder ?? documentURL?.deletingLastPathComponent()
    }

    /// An optional fallback: a relative link not found under the primary folder
    /// is also looked for here (e.g. an archive folder, or the old location
    /// after a move).
    public var secondaryDocumentFolder: URL? {
        get {
            scopedFolder(pathKey: Self.secondaryDocumentFolderDefaultsKey,
                         bookmarkKey: Self.secondaryDocumentFolderBookmarkKey)
        }
        set {
            setScopedFolder(newValue, pathKey: Self.secondaryDocumentFolderDefaultsKey,
                            bookmarkKey: Self.secondaryDocumentFolderBookmarkKey)
        }
    }

    // MARK: Cloud files

    /// Whether an iCloud placeholder (`.name.icloud`) sits where `url` should
    /// be — the file is in the cloud, not yet downloaded. (Modern File
    /// Provider files are *dataless* instead: they exist at their real path
    /// and materialise on read, so `fileExists` already reports them.)
    nonisolated static func cloudPlaceholderExists(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// Cloud-aware existence: at its path (possibly dataless), or as an iCloud
    /// placeholder awaiting download.
    nonisolated static func fileIsPresentOrInCloud(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || cloudPlaceholderExists(url)
    }

    /// Makes sure `url`'s content is local, asking the cloud to download when
    /// it isn't and polling briefly. Returns whether the file is readable.
    public func ensureLocalFile(_ url: URL, timeout: TimeInterval = 30) async -> Bool {
        await Self.waitForLocalFile(url, timeout: timeout)
    }

    /// The actor-free core of ``ensureLocalFile(_:timeout:)`` — usable from
    /// parallel pipelines.
    nonisolated static func waitForLocalFile(_ url: URL, timeout: TimeInterval = 30) async -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        guard cloudPlaceholderExists(url) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    // MARK: Attach / resolve

    /// `attachDocument`, with the failure routed to the status overlay (F20)
    /// — "attach did nothing" was a configuration problem the user never saw
    /// (no document folder, an unwritable folder). Returns success.
    @discardableResult
    public func attachDocumentReporting(named name: String, data: Data,
                                        to transactionID: GncGUID) -> Bool {
        do {
            _ = try attachDocument(named: name, data: data, to: transactionID)
            return true
        } catch {
            showToast(.failure, "Couldn’t attach “\(name)” — \(error.localizedDescription)")
            return false
        }
    }

    /// Copies a document into the document folder (reusing an identical
    /// existing file, uniquing the name otherwise) and links it to the
    /// transaction as a relative path.
    ///
    /// - Returns: the stored link.
    @discardableResult
    public func attachDocument(named name: String, data: Data,
                               to transactionID: GncGUID) throws -> String {
        guard let book, let transaction = book.transaction(with: transactionID) else {
            throw TransactionEntryError.notFound
        }
        guard let folder = effectiveDocumentFolder else {
            throw DocumentLinkError.noFolder
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while true {
            let target = folder.appendingPathComponent(candidate)
            if let existing = try? Data(contentsOf: target) {
                if existing == data { break }  // same document already stored
                candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                counter += 1
            } else {
                try data.write(to: target, options: .atomic)
                break
            }
        }
        // Only the link is undoable — the copied file stays on disk.
        editing([transactionID], named: "Attach Document") {
            transaction.documentLink = candidate
        }
        return candidate
    }

    /// Resolves a transaction's document link to a file URL: absolute
    /// `file://` URIs as-is, plain paths relative to the document folder
    /// (absolute paths are honoured too). A relative link that is not found
    /// under the primary folder is also tried under the secondary folder; when
    /// it exists nowhere, the primary location is reported (that is where the
    /// "not found" message should point).
    public func linkedDocumentURL(for transactionID: GncGUID) -> URL? {
        guard let link = book?.transaction(with: transactionID)?.documentLink else { return nil }
        let candidates = linkedDocumentCandidates(for: link)
        return Self.firstPresent(candidates) ?? candidates.first
    }

    /// Where a link's file could be, in the order to try: the pure half of
    /// the resolution, so the stats can run wherever the caller wants them.
    /// GnuCash writes `assoc_uri` percent-encoded ("Cba%20atm.png"), so the
    /// decoded form is the primary interpretation; the raw string stays as a
    /// fallback for plain paths we stored ourselves (or names that really
    /// contain a literal "%"). A relative link is tried under the primary
    /// folder, then the secondary; the first candidate is also where a
    /// "not found" message should point.
    func linkedDocumentCandidates(for link: String) -> [URL] {
        if link.hasPrefix("file://") {
            return URL(string: link).map { [$0] } ?? []
        }
        var names: [String] = []
        if let decoded = link.removingPercentEncoding, decoded != link {
            names.append(decoded)
        }
        names.append(link)
        if link.hasPrefix("/") {
            return names.map { URL(fileURLWithPath: $0) }
        }
        let folders = [effectiveDocumentFolder, secondaryDocumentFolder].compactMap { $0 }
        return folders.flatMap { folder in names.map { folder.appendingPathComponent($0) } }
    }

    /// The first candidate that is present, at its path or as a cloud
    /// placeholder. Actor-free, so a detached task can run it for a whole list.
    nonisolated static func firstPresent(_ candidates: [URL]) -> URL? {
        candidates.first { fileIsPresentOrInCloud($0) }
    }

    public func hasLinkedDocument(_ transactionID: GncGUID) -> Bool {
        book?.transaction(with: transactionID)?.documentLink != nil
    }

    /// The raw stored link (relative path, absolute path, or URL), if any.
    public func documentLink(for transactionID: GncGUID) -> String? {
        book?.transaction(with: transactionID)?.documentLink
    }

    /// Stores `link` verbatim (`nil` removes the association). One undoable
    /// action; the file itself is never touched.
    public func setDocumentLink(_ link: String?, for transactionID: GncGUID) {
        guard let book, let txn = book.transaction(with: transactionID),
              txn.documentLink != link else { return }
        editing([transactionID], named: link == nil ? "Remove Document Link" : "Set Document Link") {
            txn.documentLink = link
        }
    }

    /// Links an existing file **in place** — no copy, unlike
    /// ``attachDocument(named:data:to:)``.
    ///
    /// Stored **relative** to whichever configured document folder contains it
    /// — primary or secondary — so the link survives the archive being moved,
    /// renamed, or synced to a different machine where the provider path
    /// differs. Only a file under neither is stored absolute, because then
    /// there is no base to be relative to.
    ///
    /// Relativising against the *secondary* folder matters as soon as the
    /// documents live in more than one place — invoices in one folder,
    /// statements in another. Checking only the primary silently wrote the
    /// user's full home path into the book for every document in the second
    /// folder.
    public func linkDocument(at url: URL, to transactionID: GncGUID) {
        setDocumentLink(Self.relativeLink(for: url, under: documentFolders), for: transactionID)
    }

    /// The configured roots a relative link may be resolved against, primary
    /// first — the same order ``linkedDocumentURL(for:)`` searches.
    public var documentFolders: [URL] {
        [effectiveDocumentFolder, secondaryDocumentFolder].compactMap { $0 }
    }

    /// `url` expressed relative to the first folder that contains it, else its
    /// absolute path. Subfolders are preserved (`2026-01/Coles.png`).
    public static func relativeLink(for url: URL, under folders: [URL]) -> String {
        let path = url.standardizedFileURL.path
        for folder in folders {
            let base = folder.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }

    /// One transaction's document association, for the book-wide list
    /// (GnuCash's Tools ▸ Transaction Linked Documents).
    public struct LinkedDocument: Identifiable, Sendable {
        public let id: GncGUID
        public var date: Date
        public var description: String
        public var link: String
        /// The resolved file's name, or the raw link for a web URL.
        public var displayName: String
        public var isWeb: Bool
        /// `false` when a file link points at something no longer present.
        public var exists: Bool
    }

    /// Every transaction that carries a document link, newest first — the
    /// roll-up GnuCash offers so links aren't only reachable one register row
    /// at a time. Synchronous, with the file checks inline: the headless
    /// tools want it that way. The sheet uses ``linkedDocumentsOffMain()``.
    public func linkedDocuments() -> [LinkedDocument] {
        let entries = linkedDocumentEntries()
        return Self.settle(entries, found: entries.map { $0.candidates.isEmpty ? nil : Self.firstPresent($0.candidates) })
    }

    /// The same list, with every stat run off the main actor: the gather
    /// (pure — the book and the folder settings) happens here, the detached
    /// task tries each link's candidate paths, and the list is settled from
    /// what it found. The reference book links ~770 documents on a
    /// cloud-synced folder, and each check is a `stat` the file provider may
    /// answer slowly — the Linked Documents sheet used to run them all inside
    /// its `body`, and the first version of this ran all but the last one
    /// there too (Performance Review 2).
    public func linkedDocumentsOffMain() async -> [LinkedDocument] {
        let entries = linkedDocumentEntries()
        let candidates = entries.map(\.candidates)
        guard candidates.contains(where: { !$0.isEmpty }) else { return entries.map(\.doc) }
        let found = await Task.detached(priority: .userInitiated) {
            candidates.map { $0.isEmpty ? nil : Self.firstPresent($0) }
        }.value
        return Self.settle(entries, found: found)
    }

    private typealias LinkedDocumentEntry = (doc: LinkedDocument, candidates: [URL])

    /// Every linked transaction, newest first, each with the paths its file
    /// could be at (none for a web link) and `exists`/`displayName` still to
    /// be settled.
    private func linkedDocumentEntries() -> [LinkedDocumentEntry] {
        guard let book else { return [] }
        return book.transactions.compactMap { txn -> LinkedDocumentEntry? in
            guard let link = txn.documentLink else { return nil }
            let isWeb = link.hasPrefix("http://") || link.hasPrefix("https://")
            let candidates = isWeb ? [] : linkedDocumentCandidates(for: link)
            return (LinkedDocument(
                id: txn.guid,
                date: txn.datePosted,
                description: txn.transactionDescription,
                link: link,
                displayName: isWeb ? link : (candidates.first?.lastPathComponent ?? link),
                isWeb: isWeb,
                exists: isWeb), candidates)
        }
        .sorted { $0.doc.date > $1.doc.date }
    }

    /// Applies what the stats found: a file link exists when a candidate was
    /// present, and is named after that candidate.
    private static func settle(_ entries: [LinkedDocumentEntry], found: [URL?]) -> [LinkedDocument] {
        zip(entries, found).map { entry, hit in
            var doc = entry.doc
            guard !entry.candidates.isEmpty else { return doc }
            doc.exists = hit != nil
            if let hit { doc.displayName = hit.lastPathComponent }
            return doc
        }
    }

    /// Opens the linked document in its default application (macOS). On iOS
    /// the attachments panel offers Quick Look instead — this reports that
    /// rather than silently doing nothing (F22).
    public func openLinkedDocument(for transactionID: GncGUID) {
        guard let url = linkedDocumentURL(for: transactionID) else { return }
        #if os(macOS)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            infoMessage = "The linked document “\(url.lastPathComponent)” was not found in \(url.deletingLastPathComponent().path)."
        }
        #else
        showToast(.info, "Use Quick Look to view attachments on this device.")
        #endif
    }

    public enum DocumentLinkError: LocalizedError {
        case noFolder

        public var errorDescription: String? {
            switch self {
            case .noFolder:
                return "No document folder is available — open a book or choose a folder in Settings."
            }
        }
    }
}


/// A user-facing book-file operation failure (rename/move).
public struct BookFileError: LocalizedError {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
extension AppModel {

    /// Renames a **closed** book file in place — the iOS flow for books that
    /// land in Documents as "Untitled" (deferred.md §4); harmless on macOS
    /// too. Moves the audit-log sidecar along and updates Recents. Throws on
    /// collision or I/O failure.
    public func renameBook(at url: URL, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard documentURL != url else {
            throw BookFileError("Close the book before renaming it.")
        }
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(trimmed)
            .appendingPathExtension(url.pathExtension)
        guard destination != url else { return }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw BookFileError("A book named “\(trimmed)” already exists there.")
        }
        try manager.moveItem(at: url, to: destination)
        try? RelatedSidecar(documentURL: url, pathExtension: "audit").move(alongside: destination)
        replaceRecent(url, with: destination)
    }

    /// After a Files-app move (`fileMover`), point Recents at the new home and
    /// bring the audit sidecar along.
    public func bookMoved(from oldURL: URL, to newURL: URL) {
        try? RelatedSidecar(documentURL: oldURL, pathExtension: "audit").move(alongside: newURL)
        replaceRecent(oldURL, with: newURL)
    }

    private func replaceRecent(_ oldURL: URL, with newURL: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "finvestlens.recentBookPaths") ?? []
        if let index = paths.firstIndex(of: oldURL.path) {
            paths[index] = newURL.path
        } else {
            paths.insert(newURL.path, at: 0)
        }
        UserDefaults.standard.set(Array(paths.prefix(5)), forKey: "finvestlens.recentBookPaths")
        var bookmarks = UserDefaults.standard
            .dictionary(forKey: Self.recentBookmarksKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: oldURL.path)
        if let bookmark = ScopedBookmark.make(newURL) { bookmarks[newURL.path] = bookmark }
        UserDefaults.standard.set(bookmarks, forKey: Self.recentBookmarksKey)
        recentBooks = Self.loadRecents()
    }
}
