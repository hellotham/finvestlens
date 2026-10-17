//
//  BoxTransport.swift
//  FinvestLens — Cloud
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The HTTP surface the Box client needs, narrow enough to stub in tests.
///
/// Deliberately not shared with `FinvestLensQuotes`' `HTTPFetching`: that one
/// throws `QuoteError` and lives in a sibling package this one must not depend
/// on. Two small protocols beat a dependency edge that points sideways.
public protocol BoxTransport: Sendable {
    /// Returns the body and the response, so callers can read `etag` and
    /// distinguish 409/412 without the transport deciding what is fatal.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Fetches a response body into a file of its own, reporting bytes as
    /// they arrive — a book is tens of megabytes, which is too much to hold
    /// in memory on the way to disk, and too long to wait on without a bar.
    /// The file is the caller's to move or delete.
    func download(_ request: URLRequest,
                  progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void)
        async throws -> (URL, HTTPURLResponse)
}

extension BoxTransport {
    /// For transports that only `send`: the body, written to a file.
    public func download(_ request: URLRequest,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void)
        async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-download-\(UUID().uuidString)")
        try data.write(to: file)
        progress(Int64(data.count), Int64(data.count))
        return (file, response)
    }
}

/// The production transport.
public struct URLSessionBoxTransport: BoxTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BoxError.malformedResponse("not an HTTP response")
        }
        return (data, http)
    }

    /// Downloads to a file, reading the task's own byte counts every fifth of
    /// a second for the bar — no download delegate, whose
    /// `didFinishDownloadingTo` would race the async API for the file.
    public func download(_ request: URLRequest,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void)
        async throws -> (URL, HTTPURLResponse) {
        let watcher = TaskWatcher()
        let reporter = Task {
            while !Task.isCancelled {
                if let task = watcher.task {
                    let expected = task.countOfBytesExpectedToReceive
                    progress(task.countOfBytesReceived, expected > 0 ? expected : nil)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }
        let (location, response) = try await session.download(for: request, delegate: watcher)
        guard let http = response as? HTTPURLResponse else {
            throw BoxError.malformedResponse("not an HTTP response")
        }
        // Moved at once: the system's temporary file is not ours to keep.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: file)
        return (file, http)
    }
}

/// Holds the task URLSession creates for a download, so its byte counts can
/// be read while the async call is still waiting.
private final class TaskWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var current: URLSessionTask?

    var task: URLSessionTask? { lock.withLock { current } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { current = task }
    }
}

/// What can go wrong talking to Box.
public enum BoxError: Error, Equatable, Sendable {
    /// No Box app has been configured — the user has not supplied a client id.
    case notConfigured
    /// Nobody is signed in, or the refresh token has been revoked.
    case notAuthenticated
    /// The user dismissed Box's sign-in sheet.
    case signInCancelled
    /// Box refused the request. `status` is the HTTP code; `code` is Box's own
    /// machine-readable string where it sent one.
    case api(status: Int, code: String?, message: String?)
    /// The Box file changed since it was downloaded — someone else saved.
    /// Carries the etag Box currently holds, for the message shown to the user.
    case versionConflict(currentEtag: String?)
    /// Box has the file but is not ready to send it yet — it was uploaded
    /// moments ago — and kept saying so.
    case notReadyYet
    case malformedResponse(String)

    /// Whether retrying with a refreshed access token could plausibly work.
    public var isAuthExpiry: Bool {
        if case .api(let status, _, _) = self { return status == 401 }
        return false
    }
}

/// What went wrong, in words for the person. Without this an error reached
/// the screen through string interpolation as its debug description —
/// `api(status: 403, code: Optional("access_denied"), message: nil)`, in the
/// middle of an alert, in every language.
///
/// What Box itself said is passed on as Box wrote it: it is Box's sentence,
/// not this app's, and it says more than any paraphrase could. A response
/// that could not be read says so; the detail after it is for a bug report.
extension BoxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Box isn’t set up. Add a Box client ID and secret in Settings.")
        case .notAuthenticated:
            String(localized: "You’re not signed in to Box, or the sign-in has expired. Connect again.")
        case .signInCancelled:
            String(localized: "The Box sign-in was cancelled.")
        case .api(let status, _, let message?) where !message.isEmpty:
            String(localized: "Box refused the request (\(status)): \(message)")
        case .api(let status, let code?, _) where !code.isEmpty:
            String(localized: "Box refused the request (\(status)): \(code)")
        case .api(let status, _, _):
            String(localized: "Box refused the request (\(status)).")
        case .versionConflict:
            String(localized: "The file on Box has changed since it was downloaded.")
        case .notReadyYet:
            String(localized: "Box isn’t ready to send this file yet — it was probably saved moments ago. Try again in a minute.")
        case .malformedResponse(let detail):
            String(localized: "Box sent an answer that couldn’t be read (\(detail)).")
        }
    }
}
