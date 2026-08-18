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
