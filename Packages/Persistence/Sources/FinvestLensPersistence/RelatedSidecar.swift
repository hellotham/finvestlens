//
//  RelatedSidecar.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import OSLog

/// A file that lives beside a document under the document's own base name —
/// `Book.finvestlens` → `Book.audit` — reached the way a sandboxed app is
/// allowed to reach it.
///
/// App Sandbox grants a user-selected file and nothing beside it. The one
/// exception is a *related item*: a sibling with the same base name and an
/// extension the app declares with `NSIsRelatedItemType`, accessed through an
/// `NSFileCoordinator` whose file presenter names the document as its
/// `primaryPresentedItemURL`. ``FileLock`` has always done this for the
/// `.lock` file; this is the same mechanism for any other sidecar, with the
/// presenter registered only for the duration of each access.
public struct RelatedSidecar: Sendable {
    public let documentURL: URL
    public let sidecarURL: URL

    /// The sidecar of `documentURL` with `pathExtension` — which must be
    /// declared as a related item type in the app's Info.plist.
    public init(documentURL: URL, pathExtension: String) {
        self.documentURL = documentURL
        self.sidecarURL = documentURL.deletingPathExtension().appendingPathExtension(pathExtension)
    }

    /// The sidecar's contents, or `nil` when it does not exist or cannot be read.
    public func read() -> Data? {
        var data: Data?
        coordinate(reading: true, options: .withoutChanges) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    public func exists() -> Bool {
        var present = false
        coordinate(reading: true, options: .withoutChanges) { url in
            present = FileManager.default.fileExists(atPath: url.path)
        }
        return present
    }

    /// Replaces the sidecar's contents.
    public func write(_ data: Data) throws {
        try coordinateWriting(options: .forReplacing) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    /// Appends to the sidecar, creating it when absent.
    public func append(_ data: Data) throws {
        try coordinateWriting(options: .forMerging) { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                try data.write(to: url)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    /// The sidecar's size in bytes, or `nil` when absent.
    public func size() -> Int? {
        var size: Int?
        coordinate(reading: true, options: .withoutChanges) { url in
            size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        }
        return size
    }

    public func remove() throws {
        try coordinateWriting(options: .forDeleting) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Moves this sidecar beside a document that has moved to `newDocumentURL`
    /// (Save As, a rename, a Files-app move). Nothing to do when absent.
    public func move(alongside newDocumentURL: URL) throws {
        guard exists() else { return }
        let destination = RelatedSidecar(documentURL: newDocumentURL,
                                         pathExtension: sidecarURL.pathExtension)
        guard let data = read() else { return }
        try destination.write(data)
        try remove()
    }

    // MARK: Coordination

    /// Whether this process runs under App Sandbox, in which case the
    /// related-item presenter is what gets the sidecar opened at all. Outside
    /// it — the test hosts, `finlab`, `finlens` — the presenter buys nothing
    /// and costs about half a second per access while the system fails to
    /// issue an extension nobody needs (`NSFileSandboxingRequestRelatedItemExtension`),
    /// so plain coordination is used there.
    static let isSandboxed: Bool =
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private func coordinator() -> (NSFileCoordinator, SidecarPresenter?) {
        guard Self.isSandboxed else { return (NSFileCoordinator(), nil) }
        let presenter = SidecarPresenter(sidecarURL: sidecarURL, documentURL: documentURL)
        NSFileCoordinator.addFilePresenter(presenter)
        return (NSFileCoordinator(filePresenter: presenter), presenter)
    }

    private func coordinate(reading: Bool, options: NSFileCoordinator.ReadingOptions,
                            _ body: (URL) -> Void) {
        let (coordinator, presenter) = coordinator()
        defer { if let presenter { NSFileCoordinator.removeFilePresenter(presenter) } }
        var error: NSError?
        coordinator.coordinate(readingItemAt: sidecarURL, options: options, error: &error) { body($0) }
        if let error {
            Self.log.error("read of \(self.sidecarURL.lastPathComponent, privacy: .public) refused: \(error.localizedDescription, privacy: .public) (\(error.domain, privacy: .public) \(error.code))")
        }
    }

    /// Sidecar failures are never fatal to an edit, so they are logged — a
    /// sandbox that refuses the related item would otherwise be invisible.
    static let log = Logger(subsystem: "com.hellotham.finvestlens", category: "sidecar")

    private func coordinateWriting(options: NSFileCoordinator.WritingOptions,
                                   _ body: (URL) throws -> Void) throws {
        let (coordinator, presenter) = coordinator()
        defer { if let presenter { NSFileCoordinator.removeFilePresenter(presenter) } }
        var coordinationError: NSError?
        var bodyError: Error?
        coordinator.coordinate(writingItemAt: sidecarURL, options: options,
                               error: &coordinationError) { url in
                do { try body(url) } catch { bodyError = error }
            }
        if let bodyError {
            Self.log.error("write to \(self.sidecarURL.lastPathComponent, privacy: .public) failed: \(bodyError.localizedDescription, privacy: .public)")
            throw bodyError
        }
        if let coordinationError {
            Self.log.error("write to \(self.sidecarURL.lastPathComponent, privacy: .public) refused: \(coordinationError.localizedDescription, privacy: .public) (\(coordinationError.domain, privacy: .public) \(coordinationError.code))")
            throw coordinationError
        }
    }
}

/// The related-item presenter: the sidecar, with the document as primary.
private final class SidecarPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    #if os(macOS)
    let primaryPresentedItemURL: URL?
    #endif
    let presentedItemOperationQueue = OperationQueue()

    init(sidecarURL: URL, documentURL: URL) {
        presentedItemURL = sidecarURL
        #if os(macOS)
        primaryPresentedItemURL = documentURL
        #endif
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
}
