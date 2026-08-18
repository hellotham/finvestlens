//
//  AppModel+Box.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensCloud
import FinvestLensPersistence
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

#if canImport(AuthenticationServices)
/// Presents Box's own sign-in page in a system web sheet.
///
/// `ASWebAuthenticationSession` is the only route that is honest about what is
/// happening: the page is Box's, in a browser the app cannot read, and the app
/// receives a one-time code rather than a password. Nothing in FinvestLens
/// ever sees the user's Box credentials.
final class WebAuthBoxPresenter: NSObject, BoxAuthorizationPresenting,
                                 ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: BoxError.signInCancelled)
                } else {
                    continuation.resume(throwing: error ?? BoxError.signInCancelled)
                }
            }
            session.presentationContextProvider = self
            // The user's Box session in Safari is deliberately *not* reused:
            // an ephemeral sheet means signing out of the app really signs out.
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: BoxError.signInCancelled)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #endif
    }
}
#endif

/// Which Box file a locally-cached book came from, so a save knows where to
/// put it back and which version it was working against.
public struct BoxBookLink: Codable, Equatable, Sendable {
    public var fileID: String
    public var fileName: String
    /// Box's version marker as of the last download or upload. Sent as
    /// `If-Match` so a save cannot overwrite a version this device never saw.
    public var etag: String?

    public init(fileID: String, fileName: String, etag: String?) {
        self.fileID = fileID; self.fileName = fileName; self.etag = etag
    }
}

@MainActor
extension AppModel {

    // MARK: Configuration

    /// The Box application's client id, from the user's own Box developer
    /// console. Empty until they set it — Box has no anonymous API, and a
    /// client id shipped in the binary would make every user's traffic look
    /// like one developer's.
    public var boxClientID: String {
        get { UserDefaults.standard.string(forKey: "finvestlens.box.clientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "finvestlens.box.clientID") }
    }

    /// Must match the redirect URI registered on that Box application.
    public static let boxRedirectURI = "finvestlens://box-auth"

    public var boxConfiguration: BoxAppConfiguration {
        BoxAppConfiguration(clientID: boxClientID, redirectURI: Self.boxRedirectURI)
    }

    /// Which Box file the open book came from, if it came from Box at all.
    public var boxLink: BoxBookLink? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "finvestlens.box.link") else { return nil }
            return try? JSONDecoder().decode(BoxBookLink.self, from: data)
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "finvestlens.box.link")
            } else {
                defaults.removeObject(forKey: "finvestlens.box.link")
            }
        }
    }

    // MARK: Session

    #if canImport(AuthenticationServices)
    private func makeAuthenticator() -> BoxAuthenticator {
        BoxAuthenticator(configuration: boxConfiguration,
                         transport: URLSessionBoxTransport(),
                         store: KeychainBoxTokenStore(),
                         presenter: WebAuthBoxPresenter())
    }

    private func makeClient() -> BoxClient {
        BoxClient(transport: URLSessionBoxTransport(), auth: makeAuthenticator())
    }

    public var isBoxSignedIn: Bool { KeychainBoxTokenStore().tokens() != nil }

    /// Signs in to Box. The sheet is Box's; this never sees a password.
    public func connectBox() async {
        guard !boxClientID.isEmpty else {
            documentError = DocumentError(
                message: "Set a Box client ID in Settings ▸ Document first. Create a Box app at developer.box.com with redirect URI \(Self.boxRedirectURI).")
            return
        }
        do {
            try await makeAuthenticator().signIn()
            showToast(.success, "Connected to Box.")
        } catch BoxError.signInCancelled {
            // The user closed the sheet. Not an error worth an alert.
        } catch {
            documentError = DocumentError(message: "Couldn’t connect to Box: \(error)")
        }
    }

    /// Forgets the tokens. Box's own grant is revoked from the user's Box
    /// account, which this deliberately does not do on their behalf.
    public func disconnectBox() {
        try? KeychainBoxTokenStore().setTokens(nil)
        boxLink = nil
        showToast(.success, "Disconnected from Box.")
    }

    /// The `.finvestlens` books in a Box folder.
    public func boxBooks(inFolder folderID: String = "0") async -> [BoxItem] {
        do { return try await makeClient().items(inFolder: folderID) }
        catch {
            documentError = DocumentError(message: "Couldn’t list Box: \(error)")
            return []
        }
    }

    /// The local cache path a Box book is downloaded to.
    ///
    /// A cache, not a copy the user manages: SQLite needs a real file with
    /// byte-range access and locking, which no HTTP API provides, so a
    /// cloud-hosted book is always worked on locally and pushed back. Kept in
    /// Application Support (not the temporary directory, which iOS purges).
    public static func boxCacheURL(for item: BoxItem) -> URL {
        let base = URL.applicationSupportDirectory.appendingPathComponent("FinvestLens/Box",
                                                                          isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(item.id)-\(item.name)")
    }

    /// Downloads a Box book and opens it.
    public func openBoxBook(_ item: BoxItem) async {
        do {
            let data = try await makeClient().download(item.id)
            let cache = Self.boxCacheURL(for: item)
            try data.write(to: cache, options: .atomic)
            boxLink = BoxBookLink(fileID: item.id, fileName: item.name, etag: item.etag)
            await openBook(at: cache)
        } catch {
            documentError = DocumentError(message: "Couldn’t open from Box: \(error)")
        }
    }

    /// Pushes the just-saved local file back to Box as a new version.
    ///
    /// Called after the document's own write-back, so the bytes on disk are
    /// the ones being uploaded. A `versionConflict` means another device saved
    /// while this one was editing — reported rather than resolved, because
    /// merging two books is not something to guess at.
    public func uploadToBoxIfLinked() async {
        guard var link = boxLink, let document else { return }
        do {
            let data = try Data(contentsOf: document.fileURL)
            let updated = try await makeClient().uploadNewVersion(
                fileID: link.fileID, data: data, fileName: link.fileName, ifMatch: link.etag)
            link.etag = updated.etag
            boxLink = link
        } catch BoxError.versionConflict {
            documentError = DocumentError(
                message: "This book changed on Box since you opened it. Your changes are saved locally; open the Box copy to compare before uploading.")
        } catch {
            documentError = DocumentError(message: "Couldn’t upload to Box: \(error)")
        }
    }
    #else
    public var isBoxSignedIn: Bool { false }
    public func connectBox() async {}
    public func disconnectBox() {}
    public func boxBooks(inFolder folderID: String = "0") async -> [BoxItem] { [] }
    public func openBoxBook(_ item: BoxItem) async {}
    public func uploadToBoxIfLinked() async {}
    #endif
}
