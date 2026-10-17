//
//  BoxLibrary.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit
import FinvestLensCloud
import FinvestLensPersistence

/// Which Box file a book on this device came from, what Box has of it, and
/// what this device still owes Box.
public struct BoxBookLink: Codable, Equatable, Sendable {
    public var fileID: String
    /// The file's name on Box, as last seen. Sent back with each upload, so
    /// an upload leaves the name as it was.
    public var fileName: String
    /// The copy's file name here, under `<library>/<fileID>/` — the name the
    /// book had when it first came down. It is the window's title and the
    /// Recents entry, so it does not change under the person if Box's does.
    public var localName: String
    /// The Box folder the file was last seen in: where Keep Both puts this
    /// device's version when Box cannot say where the file is now.
    public var parentID: String?
    /// Box's version marker for the version this device last downloaded or
    /// uploaded, sent as `If-Match` so an upload cannot replace a version
    /// this device never saw.
    public var etag: String?
    /// What Box has of this book: the SHA-256 of the bytes last downloaded or
    /// uploaded — the test of whether the copy holds work Box has not got —
    /// and the copy's size and modification date at that moment, which let
    /// the test skip hashing when nothing has touched the file since.
    public var syncedSHA256: String?
    public var syncedSize: Int64?
    public var syncedModified: Date?
    /// The same bytes' SHA-1, which is the digest Box gives for a file — so
    /// that what Box has can be compared with what this device last had
    /// without downloading it: an upload whose answer was lost is then seen
    /// to have landed, and a rename or a move on Box is not taken for
    /// another device's save.
    public var syncedSHA1: String?
    /// The Box account the book is in: its user id, and its login to name it
    /// by. A book is only ever sent to that account — Box answers a file
    /// another account cannot see as missing, which read as "deleted" and
    /// had Keep Both put the book in that other account's top folder.
    public var accountID: String?
    public var accountLogin: String?
    /// Set by an explicit save — ⌘S, closing the book, switching books,
    /// quitting, leaving the app on iPhone and iPad — and cleared once Box
    /// has the copy. Autosave never sets it (the owner's decision,
    /// 17 Oct 2026: a book goes up on explicit actions only).
    public var uploadRequested: Bool
    /// Why Box refused the last upload, when what to do next is the person's
    /// decision rather than a retry.
    public var conflict: BoxConflict.Reason?
    /// A chunked upload under way, to go on with next time.
    public var pendingUpload: BoxPendingUpload?
    /// Box's words for the last refusal a retry will not cure — until the
    /// next explicit save tries again.
    public var lastRefusal: String?

    public init(fileID: String, fileName: String, localName: String? = nil,
                parentID: String? = nil, etag: String? = nil,
                syncedSHA256: String? = nil, syncedSize: Int64? = nil, syncedModified: Date? = nil,
                syncedSHA1: String? = nil, accountID: String? = nil, accountLogin: String? = nil,
                uploadRequested: Bool = false, conflict: BoxConflict.Reason? = nil,
                pendingUpload: BoxPendingUpload? = nil, lastRefusal: String? = nil) {
        self.fileID = fileID
        self.fileName = fileName
        self.localName = localName ?? BoxLibrary.localName(for: fileName)
        self.parentID = parentID
        self.etag = etag
        self.syncedSHA256 = syncedSHA256
        self.syncedSize = syncedSize
        self.syncedModified = syncedModified
        self.syncedSHA1 = syncedSHA1
        self.accountID = accountID
        self.accountLogin = accountLogin
        self.uploadRequested = uploadRequested
        self.conflict = conflict
        self.pendingUpload = pendingUpload
        self.lastRefusal = lastRefusal
    }

    /// The name a person knows the book by.
    public var bookName: String { (localName as NSString).deletingPathExtension }

    /// The cheap look: whether the copy's size and date are what they were
    /// when Box last had it. `false` means "hash it to be sure", not "changed".
    func looksSynced(_ look: BoxLibrary.FileLook?) -> Bool {
        guard let look, let syncedSize, let syncedModified else { return false }
        return look.size == syncedSize && abs(look.modified.timeIntervalSince(syncedModified)) < 0.001
    }

    /// Whether the book is in a Box account other than `account`. A record
    /// not yet bound to one is bound by its first exchange with Box.
    func isInAnotherAccount(than account: BoxUser) -> Bool {
        accountID.map { $0 != account.id } ?? false
    }

    mutating func bind(to account: BoxUser) {
        accountID = account.id
        accountLogin = account.login
    }
}

/// A book in a Box account other than the one connected now.
struct BoxOtherAccountError: LocalizedError {
    let login: String?

    var errorDescription: String? {
        if let login {
            return String(localized: "It is in the Box account \(login), not the one connected now — connect to that account in Settings.")
        }
        return String(localized: "It is in another Box account, not the one connected now — connect to that account in Settings.")
    }
}

/// A chunked upload under way: the session, the snapshot of the copy it is
/// sending (by its digests), and the parts Box has acknowledged.
public struct BoxPendingUpload: Codable, Equatable, Sendable {
    public var session: BoxUploadSession
    public var sha256: String
    public var sha1Base64: String
    public var size: Int64
    public var parts: [BoxUploadedPart]
}

/// A Box book whose changes here cannot go to Box without a decision.
public struct BoxConflict: Identifiable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// Another device saved a newer version to Box since this one last
        /// had it — Box answered 412 to the upload's `If-Match`.
        case changedOnBox
        /// The file is not on Box any more, or not where this device can
        /// reach it — Box answered 404.
        case goneFromBox
    }
    public var id: String { fileID }
    public let fileID: String
    public let bookName: String
    public let reason: Reason

    public init(fileID: String, bookName: String, reason: Reason) {
        self.fileID = fileID
        self.bookName = bookName
        self.reason = reason
    }

    /// The alert's title.
    public var title: String {
        switch reason {
        case .changedOnBox: String(localized: "“\(bookName)” Changed on Box")
        case .goneFromBox: String(localized: "“\(bookName)” Is No Longer on Box")
        }
    }

    /// The alert's explanation: what happened, what the action does, and
    /// that nothing is lost by waiting.
    public var message: String {
        switch reason {
        case .changedOnBox:
            String(localized: "Another device saved a newer version to Box after this device last had it, so your changes weren’t uploaded over it. Keep Both puts your version on Box beside it as a separate book, and you carry on with yours; the other version is left as it is. Your changes stay on this device either way.")
        case .goneFromBox:
            String(localized: "The book was deleted on Box, or moved somewhere you can’t reach, so your changes can’t be uploaded to it. Upload as New Book puts your version on Box again, in the folder it was in. Your changes stay on this device either way.")
        }
    }

    /// The button that resolves it.
    public var actionTitle: String {
        switch reason {
        case .changedOnBox: String(localized: "Keep Both")
        case .goneFromBox: String(localized: "Upload as New Book")
        }
    }
}

/// Where books opened from Box are kept on this device, and the record of
/// which Box file each one came from.
///
/// A Box book's copy is `<root>/<Box file id>/<name>`, and its record is
/// `box-record.json` beside it, so **the folder is the link**. The first
/// version kept one link for "the book from Box" in a preference and uploaded
/// whatever book was open while it was set; a second kept every book's
/// record in one preference that each process loaded once and rewrote whole,
/// so a second copy of the app, or one record it could not read, erased the
/// others. A record of its own, read fresh whenever a decision depends on it,
/// is right however many processes look.
///
/// A copy rather than the file itself because a book is SQLite, which needs
/// a real file with byte-range access and locking; no web API offers either.
/// Application Support rather than the temporary folder because iOS empties
/// that.
public struct BoxLibrary: Sendable {
    public let root: URL
    private let rootPath: String
    private let resolvedRootPath: String

    public static let recordName = "box-record.json"
    /// Held (`flock`) for the length of any download, upload or Keep Both of
    /// one book, by any process: one operation on a copy at a time.
    static let busyName = ".box-busy"

    public init(root: URL) {
        self.root = root
        self.rootPath = Self.clean(root.standardizedFileURL.path)
        self.resolvedRootPath = Self.clean(root.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    public static let standard = BoxLibrary(
        root: URL.applicationSupportDirectory.appendingPathComponent("FinvestLens/Box", isDirectory: true))

    private static func clean(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: Places

    func folder(for fileID: String) -> URL {
        root.appendingPathComponent(fileID, isDirectory: true)
    }

    /// Where a Box book's copy lives on this device.
    public func copyURL(for link: BoxBookLink) -> URL {
        folder(for: link.fileID).appendingPathComponent(link.localName, isDirectory: false)
    }

    /// The Box file a path is the copy of — `nil` for every other path.
    ///
    /// Text only, no file system: this is asked on every save and of every
    /// Recents row, and a book on a network share must not cost a lookup on
    /// that share each time. Copies are only ever named from `root`, so its
    /// spelling — or its resolved spelling, for a path that went through
    /// `/private` — is the whole test.
    public func fileID(ofCopyAt url: URL) -> String? {
        let path = Self.clean(url.standardizedFileURL.path)
        for base in [rootPath, resolvedRootPath] where path.hasPrefix(base + "/") {
            let rest = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            guard rest.count == 2, !rest[1].isEmpty else { return nil }
            let id = String(rest[0])
            return Self.isSafeFileID(id) ? id : nil
        }
        return nil
    }

    /// Two file URLs naming the same place, however they were spelt.
    public static func samePath(_ a: URL, _ b: URL) -> Bool {
        let plain = clean(a.standardizedFileURL.path) == clean(b.standardizedFileURL.path)
        return plain || clean(a.resolvingSymlinksInPath().standardizedFileURL.path)
            == clean(b.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// Box's ids are digits. Anything else — a separator, a dot, an empty
    /// string — is refused before it becomes part of a path: the id arrives
    /// from a server, and `..` from a server is not a folder name.
    public static func isSafeFileID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: Records

    private func recordURL(_ fileID: String) -> URL {
        folder(for: fileID).appendingPathComponent(Self.recordName)
    }

    /// The record of a Box book, read from disk now.
    public func record(_ fileID: String) -> BoxBookLink? {
        guard Self.isSafeFileID(fileID),
              let data = try? Data(contentsOf: recordURL(fileID)),
              let link = try? JSONDecoder().decode(BoxBookLink.self, from: data),
              link.fileID == fileID else { return nil }
        return link
    }

    public func write(_ link: BoxBookLink) throws {
        guard Self.isSafeFileID(link.fileID) else { return }
        try FileManager.default.createDirectory(at: folder(for: link.fileID), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(link).write(to: recordURL(link.fileID), options: .atomic)
    }

    public func removeRecord(_ fileID: String) {
        guard Self.isSafeFileID(fileID) else { return }
        try? FileManager.default.removeItem(at: recordURL(fileID))
    }

    /// Every record in the library, one folder at a time; a folder whose
    /// record cannot be read is passed over, not allowed to empty the rest.
    public func allRecords() -> [String: BoxBookLink] {
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [:] }
        var records: [String: BoxBookLink] = [:]
        for id in folders where Self.isSafeFileID(id) {
            if let link = record(id) { records[id] = link }
        }
        return records
    }

    /// Removes a book's folder if nothing of the person's is left in it — the
    /// busy marker is not theirs.
    func removeFolderIfEmpty(_ fileID: String) {
        let folder = folder(for: fileID)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              contents.allSatisfy({ $0 == Self.busyName }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: One operation at a time

    /// Takes the book's busy lock if no one — in this process or another —
    /// holds it, returning the descriptor to give back; `nil` when it is held.
    func tryLock(_ fileID: String) -> Int32? {
        guard Self.isSafeFileID(fileID) else { return nil }
        try? FileManager.default.createDirectory(at: folder(for: fileID), withIntermediateDirectories: true)
        let path = folder(for: fileID).appendingPathComponent(Self.busyName).path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    func unlock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    // MARK: Looking at a copy

    /// A file's size and modification date — the cheap look.
    public struct FileLook: Equatable, Sendable {
        public var size: Int64
        public var modified: Date
    }

    public static func look(at url: URL) -> FileLook? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileLook(size: size, modified: modified)
    }

    /// One reading of a copy: its digests, its size and date, all from the
    /// same open file — so a save that replaces the file meanwhile does not
    /// mix two versions into one upload.
    public struct Snapshot: Sendable {
        public var sha256: String
        public var sha1Base64: String
        public var sha1Hex: String
        public var size: Int64
        public var modified: Date
    }

    /// An open copy, read in place: the descriptor keeps the version that was
    /// opened even if a save puts a new file at the path.
    final class Reader: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()

        init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
        deinit { try? handle.close() }

        func snapshot() throws -> Snapshot {
            try lock.withLock {
                try handle.seek(toOffset: 0)
                var sha256 = SHA256()
                var sha1 = Insecure.SHA1()
                var size: Int64 = 0
                while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    sha256.update(data: chunk)
                    sha1.update(data: chunk)
                    size += Int64(chunk.count)
                }
                var info = stat()
                let modified: Date
                if fstat(handle.fileDescriptor, &info) == 0 {
                    modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
                } else {
                    modified = Date()
                }
                let sha1Digest = Data(sha1.finalize())
                return Snapshot(sha256: sha256.finalize().map { String(format: "%02x", $0) }.joined(),
                                sha1Base64: sha1Digest.base64EncodedString(),
                                sha1Hex: sha1Digest.map { String(format: "%02x", $0) }.joined(),
                                size: size, modified: modified)
            }
        }

        func read(offset: Int64, count: Int64) throws -> Data {
            try lock.withLock {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: Int(count)) ?? Data()
            }
        }
    }

    // MARK: Checking a download

    /// SQLite databases begin with these 16 bytes.
    public static let sqliteMagic = Data("SQLite format 3".utf8) + [0]

    /// Refuses a download that is not a FinvestLens book before it can
    /// replace anything: an empty answer would open as an *empty* book, whose
    /// first save would go up over the real one, and any other SQLite file —
    /// a GnuCash book with the wrong name — would replace the copy and only
    /// then fail to open. The same test the book's own store makes.
    public static func validateBook(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        guard head == sqliteMagic else {
            throw BookFileError("Box sent something that isn’t a FinvestLens book.")
        }
        do {
            _ = try SQLiteDocumentStore(readOnlyPath: url.path)
        } catch {
            throw BookFileError("Box sent something that isn’t a FinvestLens book.")
        }
    }

    /// Puts a checked download in place of the copy, atomically.
    public static func replace(_ copy: URL, with download: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: copy.path) {
            _ = try manager.replaceItemAt(copy, withItemAt: download)
        } else {
            try manager.moveItem(at: download, to: copy)
        }
    }

    // MARK: Names

    /// A file name for the copy of a Box file named `boxName`: Box's own name,
    /// made safe to be one path component.
    public static func localName(for boxName: String) -> String {
        var name = boxName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if !name.hasSuffix(".finvestlens") { name += ".finvestlens" }
        if name == ".finvestlens" { name = String(localized: "Book") + ".finvestlens" }
        return name
    }

    /// The name this device's version takes when it goes up beside the one
    /// it conflicts with: the book's name, marked as a conflicted copy, with
    /// the time — so two such copies are told apart, and sort by when.
    /// `attempt` numbers a name already taken.
    public static func conflictCopyName(for boxName: String, at date: Date,
                                        attempt: Int = 0,
                                        calendar: Calendar = .current) -> String {
        let base = (boxName as NSString).deletingPathExtension
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // Digits only, and no colon or slash: this is a file name first.
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d",
                           parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0)
        let marked = String(localized: "\(base) (conflicted copy \(stamp))",
                            comment: "The name of a book uploaded beside a version it conflicts with. The second value is a date and time.")
        return (attempt > 0 ? "\(marked) \(attempt + 1)" : marked) + ".finvestlens"
    }
}
