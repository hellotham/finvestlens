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
        case .malformedResponse(let detail):
            String(localized: "Box sent an answer that couldn’t be read (\(detail)).")
        }
    }
}
