//
//  BoxOAuth.swift
//  FinvestLens — Cloud
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit

/// Identifies this app to Box.
///
/// Box requires every client to be a registered application, so these come
/// from the user's **own** Box developer console rather than being baked in: a
/// client secret shipped in a binary is not a secret, and a shipped client id
/// would make every user's traffic look like one developer's.
///
/// A secret is unavoidable here. Box does not implement PKCE — verified
/// against its API reference on 18 Aug 2026: `GET /authorize` accepts only
/// `response_type`, `client_id`, `redirect_uri`, `state` and `scope` (no
/// `code_challenge`), and `POST /oauth2/token` has no `code_verifier` and
/// requires `client_secret` for the `authorization_code` grant. So the secret
/// is the user's own, kept in their Keychain, never in `UserDefaults` or a
/// file.
public struct BoxAppConfiguration: Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String
    /// Must match the redirect URI registered on the Box application exactly.
    public var redirectURI: String

    public init(clientID: String, clientSecret: String, redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    /// The custom scheme half of ``redirectURI``, which the web-auth session
    /// needs in order to know when Box has finished.
    public var callbackScheme: String? {
        URLComponents(string: redirectURI)?.scheme
    }
}

/// Presents Box's sign-in page and returns the `code` it redirects back with.
///
/// A protocol so the exchange can be tested without a browser — and so the
/// app, not this package, owns the `ASWebAuthenticationSession` presentation
/// context. **The user signs in to Box themselves, in Box's own web sheet.**
/// Nothing here sees or stores a password.
public protocol BoxAuthorizationPresenting: Sendable {
    /// Opens `url`, waits for a redirect to `callbackScheme`, and returns it.
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}

/// A random, URL-safe nonce — used for the OAuth `state` value, which Box
/// *does* support and which is what stops a redirect the user did not start
/// from planting someone else's Box account in their app.
enum Nonce {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// base64url without padding — URL-safe, so it survives a query string.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Signs in to Box and keeps the access token fresh.
public actor BoxAuthenticator {
    public static let authorizeEndpoint = URL(string: "https://account.box.com/api/oauth2/authorize")!
    public static let tokenEndpoint = URL(string: "https://api.box.com/oauth2/token")!

    private let configuration: BoxAppConfiguration
    private let transport: BoxTransport
    private let store: BoxTokenStoring
    private let presenter: BoxAuthorizationPresenting
    private let now: @Sendable () -> Date

    public init(configuration: BoxAppConfiguration,
                transport: BoxTransport,
                store: BoxTokenStoring,
                presenter: BoxAuthorizationPresenting,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.presenter = presenter
        self.now = now
    }

    public var isSignedIn: Bool { store.tokens() != nil }

    /// Forgets the tokens. Box's own session is not ended — the user revokes
    /// the application from their Box account if they want that.
    public func signOut() throws { try store.setTokens(nil) }

    /// Runs the authorization-code flow and stores the resulting tokens.
    public func signIn() async throws {
        guard !configuration.clientID.isEmpty, !configuration.clientSecret.isEmpty else {
            throw BoxError.notConfigured
        }
        guard let scheme = configuration.callbackScheme else { throw BoxError.notConfigured }

        let state = Nonce.make()
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: configuration.redirectURI),
            .init(name: "state", value: state),
        ]

        let callback = try await presenter.authorize(url: components.url!, callbackScheme: scheme)
        let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // The state check is what stops a redirect the user did not start from
        // planting someone else's Box account in their app.
        guard returned.first(where: { $0.name == "state" })?.value == state else {
            throw BoxError.malformedResponse("state mismatch on the OAuth callback")
        }
        guard let code = returned.first(where: { $0.name == "code" })?.value else {
            throw BoxError.malformedResponse("no authorization code in the callback")
        }
        try await exchange(form: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
            "redirect_uri": configuration.redirectURI,
        ])
    }

    /// A valid access token, refreshing first if the stored one has aged out.
    public func accessToken() async throws -> String {
        guard let tokens = store.tokens() else { throw BoxError.notAuthenticated }
        guard tokens.isExpired(asOf: now()) else { return tokens.accessToken }
        try await exchange(form: [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
        ])
        guard let refreshed = store.tokens() else { throw BoxError.notAuthenticated }
        return refreshed.accessToken
    }

    /// Drops the stored access token's validity so the next call refreshes.
    /// Used when Box answers 401 despite a token we believed was live.
    public func invalidateAccessToken() throws {
        guard var tokens = store.tokens() else { return }
        tokens.expiresAt = .distantPast
        try store.setTokens(tokens)
    }

    private func exchange(form: [String: String]) async throws {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { key, value in
            "\(Self.escape(key))=\(Self.escape(value))"
        }.joined(separator: "&").utf8)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            // A refresh that Box rejects means the grant is gone (revoked, or
            // the refresh token was already spent). Clearing the tokens turns
            // a permanent 400 loop into a plain "sign in again".
            if response.statusCode == 400 || response.statusCode == 401 {
                try? store.setTokens(nil)
                throw BoxError.notAuthenticated
            }
            throw BoxError.api(status: response.statusCode, code: nil,
                               message: String(data: data, encoding: .utf8))
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw BoxError.malformedResponse("token response was not the expected shape")
        }
        try store.setTokens(BoxTokens(accessToken: decoded.access_token,
                                      refreshToken: decoded.refresh_token,
                                      expiresAt: now().addingTimeInterval(decoded.expires_in)))
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
