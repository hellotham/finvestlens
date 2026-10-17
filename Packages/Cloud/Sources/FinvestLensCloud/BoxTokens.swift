//
//  BoxTokens.swift
//  FinvestLens — Cloud
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(Security)
import Security
#endif

/// An OAuth token pair, with the moment the access token stops being usable.
public struct BoxTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Treated as expired a minute early, so a token does not die in flight
    /// between the check and the request reaching Box.
    public func isExpired(asOf now: Date) -> Bool {
        expiresAt.addingTimeInterval(-60) <= now
    }
}

/// Where the token pair lives between launches.
///
/// Tokens are as sensitive as a password — a refresh token is a standing grant
/// to the user's entire Box account — so the production implementation is the
/// Keychain and nothing writes them to `UserDefaults`, a file, or a log.
public protocol BoxTokenStoring: Sendable {
    func tokens() -> BoxTokens?
    func setTokens(_ tokens: BoxTokens?) throws
}

/// In-memory store for tests and previews.
public final class InMemoryBoxTokenStore: BoxTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BoxTokens?

    public init(_ initial: BoxTokens? = nil) { stored = initial }

    public func tokens() -> BoxTokens? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func setTokens(_ tokens: BoxTokens?) throws {
        lock.lock(); defer { lock.unlock() }
        stored = tokens
    }
}

/// Where the Box app's client secret is kept — a protocol so the app's tests
/// never touch the real Keychain item.
public protocol BoxClientSecretStoring: Sendable {
    func secret() -> String?
    func setSecret(_ secret: String?) throws
}

/// A secret held in memory — tests and previews.
public final class InMemoryBoxClientSecretStore: BoxClientSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public init(_ initial: String? = nil) { stored = initial }

    public func secret() -> String? { lock.withLock { stored } }

    public func setSecret(_ secret: String?) throws {
        lock.withLock { stored = (secret?.isEmpty ?? true) ? nil : secret }
    }
}

#if canImport(Security)
/// The Keychain refused to keep a Box credential — the client secret or the
/// sign-in's tokens.
///
/// Its own error, with the Keychain's own reason: these were thrown as
/// ``BoxError/malformedResponse(_:)``, which put "Box sent an answer that
/// couldn't be read" in front of a refusal Box had no part in, and which the
/// upload retry counts as worth trying again.
public struct BoxKeychainError: LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) { self.status = status }

    public var errorDescription: String? {
        let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? String(localized: "error \(status)")
        return String(localized: "The Keychain couldn’t keep the Box credential: \(reason)")
    }
}

/// The Box application's client secret.
///
/// Box has no PKCE, so the `authorization_code` exchange requires a secret.
/// It is the *user's own* app secret rather than one shipped in the binary,
/// but it is still a credential: it belongs in the Keychain, never in
/// `UserDefaults` beside the client id.
public struct BoxClientSecretStore: BoxClientSecretStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.hellotham.finvestlens.box",
                account: String = "client-secret") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func secret() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String?) throws {
        guard let secret, !secret.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw BoxKeychainError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw BoxKeychainError(status: status)
        }
    }
}

/// The production store: one generic-password item in the login keychain.
public struct KeychainBoxTokenStore: BoxTokenStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.hellotham.finvestlens.box",
                account: String = "oauth-tokens") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func tokens() -> BoxTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(BoxTokens.self, from: data)
    }

    public func setTokens(_ tokens: BoxTokens?) throws {
        guard let tokens else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let data = try JSONEncoder().encode(tokens)
        // Update in place if present, otherwise add. `kSecAttrAccessible` is
        // `AfterFirstUnlock` so a background autosave can refresh the token on
        // a locked-but-booted Mac, but the item never leaves the device.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw BoxKeychainError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw BoxKeychainError(status: status)
        }
    }
}
#endif
