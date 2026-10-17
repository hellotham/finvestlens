//
//  AppModel+Box.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import FinvestLensCloud
import FinvestLensPersistence
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

/// Presents Box's own sign-in page in a system web sheet.
///
/// `ASWebAuthenticationSession` is the only route that is honest about what is
/// happening: the page is Box's, in a browser the app cannot read, and the app
/// receives a one-time code rather than a password. Nothing in FinvestLens
/// ever sees the user's Box credentials.
final class WebAuthBoxPresenter: NSObject, BoxAuthorizationPresenting,
                                 ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {

    /// One sign-in: its sheet, and the caller waiting for Box's answer.
    ///
    /// Per attempt, not per presenter. The presenter lives as long as the
    /// cached authenticator, and the first version kept the "answered" flag on
    /// the presenter itself and never cleared it — so after the first
    /// sign-in, cancelled or not, every later one ignored Box's answer and
    /// waited for ever, with the Connect button greyed out.
    private final class Attempt: @unchecked Sendable {
        let lock = NSLock()
        var session: ASWebAuthenticationSession?
        var continuation: CheckedContinuation<URL, Error>?

        /// Resumes exactly once. `start()` returning false *and* the
        /// completion firing would otherwise resume twice, which is fatal.
        func finish(with result: Result<URL, Error>) {
            let waiting: CheckedContinuation<URL, Error>? = lock.withLock {
                let waiting = continuation
                continuation = nil
                session = nil
                return waiting
            }
            waiting?.resume(with: result)
        }
    }

    private let lock = NSLock()
    /// The attempt running now, held so its session is not released — the
    /// system does not retain an `ASWebAuthenticationSession`, and dropping
    /// the last reference closes the sheet with no callback.
    private nonisolated(unsafe) var current: Attempt?

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let attempt = Attempt()
        // A new sign-in replaces one still showing: that one is answered as
        // cancelled rather than left waiting.
        let previous: Attempt? = lock.withLock {
            let previous = current
            current = attempt
            return previous
        }
        previous?.finish(with: .failure(BoxError.signInCancelled))
        return try await withCheckedThrowingContinuation { continuation in
            attempt.lock.withLock { attempt.continuation = continuation }
            // `ASWebAuthenticationSession` must be created and started on the
            // main actor — the presentation-context protocol is
            // `NS_SWIFT_UI_ACTOR` — while `BoxAuthenticator` is an actor, so
            // this is reached from its executor, not the main thread.
            Task { @MainActor in
                let created = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(callbackScheme),
                    completionHandler: Self.completion(for: attempt))
                created.presentationContextProvider = self
                created.prefersEphemeralWebBrowserSession = false
                attempt.lock.withLock { attempt.session = created }
                if !created.start() {
                    attempt.finish(with: .failure(BoxError.signInCancelled))
                }
            }
        }
    }

    /// The completion body, built by a **`nonisolated`** factory so the
    /// returned closure is not main-actor isolated.
    ///
    /// This is the crash that shipped: conforming to
    /// `ASWebAuthenticationPresentationContextProviding` — which the SDK marks
    /// `NS_SWIFT_UI_ACTOR` — makes this whole class `@MainActor`, so a closure
    /// written inline here inherited that isolation. AuthenticationServices
    /// then invoked it on `com.apple.NSXPCConnection…SafariLaunchAgent`, the
    /// runtime's isolation check failed, and the app died with
    /// `EXC_BREAKPOINT` in `dispatch_assert_queue_fail` the moment Box
    /// redirected back. Built here, the closure carries no isolation and any
    /// queue may call it.
    private nonisolated static func completion(for attempt: Attempt) -> @Sendable (URL?, Error?) -> Void {
        { callback, error in
            if let callback {
                attempt.finish(with: .success(callback))
            } else if let error = error as? ASWebAuthenticationSessionError,
                      error.code == .canceledLogin {
                attempt.finish(with: .failure(BoxError.signInCancelled))
            } else {
                attempt.finish(with: .failure(error ?? BoxError.signInCancelled))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.compactMap(\.keyWindow).first { return window }
        // iOS 26 deprecated every scene-less `UIWindow` initializer, so the
        // fallback is a fresh window on a connected scene. A sign-in is only
        // ever started from a control inside a scene, so one is connected;
        // the trap records that invariant rather than offering a path.
        guard let scene = scenes.first else {
            preconditionFailure("Box sign-in started with no window scene to present in")
        }
        return UIWindow(windowScene: scene)
        #endif
    }
}

/// The token store the authenticator writes through, telling the model each
/// time the sign-in changes — including when the authenticator itself clears
/// a grant Box refused, which no view would otherwise hear of.
final class ObservedBoxTokenStore: BoxTokenStoring, @unchecked Sendable {
    private let base: BoxTokenStoring
    private let changed: @Sendable () -> Void

    init(_ base: BoxTokenStoring, changed: @escaping @Sendable () -> Void) {
        self.base = base
        self.changed = changed
    }

    func tokens() -> BoxTokens? { base.tokens() }

    func setTokens(_ tokens: BoxTokens?) throws {
        try base.setTokens(tokens)
        changed()
    }
}

/// One Box folder's contents, as the browser shows them.
public struct BoxFolderContents: Sendable {
    public var folders: [BoxItem]
    public var books: [BoxItem]
    /// Files that are not books — counted, so an empty-looking folder can
    /// say why it looks empty.
    public var otherFileCount: Int
}

/// What Box said before a book from it opens.
enum BoxOpenCheck: Sendable {
    /// The book is in a Box account other than the one signed in now.
    case inAnotherAccount
    /// The copy here is Box's current version.
    case current(BoxUser)
    /// A newer version, downloaded to a file — to be checked, then put in
    /// place of the copy.
    case downloaded(BoxUser, BoxItem, URL)
}

/// What this device holds of a Box book.
public enum BoxCopyState: Sendable, Equatable {
    /// No copy here: opening downloads it.
    case notOnThisDevice
    /// A copy that matches what Box has.
    case onThisDevice
    /// A copy with work Box has not got yet.
    case changesToUpload
    /// Saves here that Box refused, waiting on the person.
    case conflicted
}

/// Where opening a Box book has got to, for the opening screen.
public enum BoxOpenPhase: Equatable, Sendable {
    /// Asking Box whether it has a newer version.
    case checking
    /// Downloading it — the fraction, once Box has said how big it is.
    case downloading(Double?)
}

@MainActor
extension AppModel {

    // MARK: Configuration

    /// The Box application's client id, from the user's own Box developer
    /// console. Empty until they set it — Box has no anonymous API, and a
    /// client id shipped in the binary would make every user's traffic look
    /// like one developer's.
    public var boxClientID: String {
        get { boxDefaults.string(forKey: "finvestlens.box.clientID") ?? "" }
        set {
            boxDefaults.set(newValue, forKey: "finvestlens.box.clientID")
            boxSessionRevision &+= 1
        }
    }

    /// Must match the redirect URI registered on that Box application.
    public static let boxRedirectURI = "finvestlens://box-auth"

    /// The Box app's client secret, in the Keychain — Box has no PKCE, so the
    /// token exchange needs one, and a credential does not belong beside the
    /// client id in `UserDefaults`. Read from the Keychain once, then held:
    /// views ask for it as they draw.
    public var boxClientSecret: String {
        get {
            if let cached = boxSecretCache { return cached }
            let stored = boxSecretStore.secret() ?? ""
            boxSecretCache = stored
            return stored
        }
        set {
            guard newValue != boxClientSecret else { return }
            // A refusal is said, not swallowed: the first version used
            // `try?`, so a secret the Keychain would not keep was held in
            // memory, worked until the app quit, and was gone at the next
            // launch with nothing to say why.
            do {
                try boxSecretStore.setSecret(newValue)
                boxSecretFailure = nil
            } catch {
                boxSecretFailure = String(localized: "\(error.localizedDescription) Until it can be kept, the secret lasts only until FinvestLens quits.")
            }
            boxSecretCache = newValue
            boxSessionRevision &+= 1
        }
    }

    public var boxConfiguration: BoxAppConfiguration {
        BoxAppConfiguration(clientID: boxClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                            clientSecret: boxClientSecret,
                            redirectURI: Self.boxRedirectURI)
    }

    /// Whether a Box app has been described in Settings — without one there
    /// is no signing in at all. The one rule, used by every view that asks.
    public var isBoxConfigured: Bool {
        _ = boxSessionRevision
        return !boxClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !boxClientSecret.isEmpty
    }

    // MARK: Session

    /// The one authenticator every Box request goes through, made again only
    /// when the app's Box settings change.
    ///
    /// One, so that requests made together share a token refresh: a refresh
    /// token is good once, and a second authenticator would spend it again,
    /// be refused, and sign the person out (``BoxAuthenticator``).
    func boxAuthenticator() -> BoxAuthenticator {
        let configuration = boxConfiguration
        if let cached = boxAuthenticatorCache, cached.configuration == configuration {
            return cached.authenticator
        }
        let store = ObservedBoxTokenStore(boxTokenStore) { [weak self] in
            Task { @MainActor in self?.boxSignInChanged() }
        }
        let authenticator = BoxAuthenticator(configuration: configuration, transport: boxTransport,
                                             store: store, presenter: WebAuthBoxPresenter())
        boxAuthenticatorCache = (configuration, authenticator)
        return authenticator
    }

    func boxClient() -> BoxClient {
        BoxClient(transport: boxTransport, auth: boxAuthenticator())
    }

    func boxSignInChanged() {
        boxSignedInCache = nil
        boxSessionRevision &+= 1
    }

    public var isBoxSignedIn: Bool {
        _ = boxSessionRevision
        if let cached = boxSignedInCache { return cached }
        let signedIn = boxTokenStore.tokens() != nil
        boxSignedInCache = signedIn
        return signedIn
    }

    /// Signs in to Box, throwing what went wrong. The sheet is Box's; this
    /// never sees a password. Closing the sheet is not an error.
    public func signInToBox() async throws {
        guard isBoxConfigured else { throw BoxError.notConfigured }
        do {
            try await boxAuthenticator().signIn()
        } catch BoxError.signInCancelled {
            return
        }
        // Possibly a different account from the last one.
        boxAccountCache = nil
        boxSignInChanged()
        showToast(.success, "Connected to Box.")
        resumeBoxUploads()
    }

    /// Forgets the tokens. Box's own grant is revoked from the user's Box
    /// account, which this deliberately does not do on their behalf.
    ///
    /// The books stay linked: their copies here may hold work Box has not
    /// got, and it goes up once the person connects again — to the account
    /// each book is in, and no other.
    public func disconnectBox() {
        try? boxTokenStore.setTokens(nil)
        boxAccountCache = nil
        boxSignInChanged()
        showToast(.success, "Disconnected from Box.")
    }

    /// Who is signed in to Box — asked once per sign-in, and before any book
    /// is sent, so that a book goes only to the account it is in.
    func boxAccount() async throws -> BoxUser {
        if let cached = boxAccountCache { return cached }
        let user = try await boxClient().currentUser(timeout: 20)
        boxAccountCache = user
        return user
    }

    // MARK: Records

    /// Reads every record from disk into ``boxLinks``.
    func reloadBoxLinks() {
        boxLinks = boxLibrary.allRecords()
    }

    /// Writes a record, and keeps ``boxLinks`` in step for the views.
    func saveBoxLink(_ link: BoxBookLink) {
        try? boxLibrary.write(link)
        boxLinks[link.fileID] = link
    }

    func forgetBoxLink(_ fileID: String) {
        boxLibrary.removeRecord(fileID)
        boxLinks[fileID] = nil
    }

    // MARK: Browsing

    /// The folders and books in a Box folder (`"0"` is the top), each group
    /// sorted as the Finder sorts names.
    public func boxFolderContents(_ folderID: String) async throws -> BoxFolderContents {
        do {
            let items = try await boxClient().items(inFolder: folderID)
            let byName: (BoxItem, BoxItem) -> Bool = {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let folders = items.filter { $0.kind == .folder }.sorted(by: byName)
            let books = items.filter { $0.isBook && BoxLibrary.isSafeFileID($0.id) }.sorted(by: byName)
            return BoxFolderContents(folders: folders, books: books,
                                     otherFileCount: items.count - folders.count - books.count)
        } catch {
            noteBoxFailure(error)
            throw error
        }
    }

    /// A failure that may mean the sign-in is gone: the views are told to
    /// look again, so a browser stuck on "not signed in" offers Connect.
    private func noteBoxFailure(_ error: Error) {
        if case BoxError.notAuthenticated = error { boxSignInChanged() }
    }

    /// What this device holds of a Box book, for the browser to say. The
    /// cheap look only — a copy whose date moved is shown as changed until
    /// something hashes it.
    public func boxCopyState(of item: BoxItem) -> BoxCopyState {
        guard let link = boxLinks[item.id] else { return .notOnThisDevice }
        guard let look = BoxLibrary.look(at: boxLibrary.copyURL(for: link)) else { return .notOnThisDevice }
        if link.conflict != nil { return .conflicted }
        if link.uploadRequested || link.pendingUpload != nil { return .changesToUpload }
        return link.looksSynced(look) ? .onThisDevice : .changesToUpload
    }

    /// Whether `url` is the copy here of a book on Box — Recents shows it as
    /// one, and does not offer to rename or move it, which would cut the link.
    public func isBoxCopy(_ url: URL) -> Bool {
        boxLibrary.fileID(ofCopyAt: url) != nil
    }

    /// The Box file the open book is the copy of, if it is one.
    var openBoxFileID: String? {
        guard let url = documentURL else { return nil }
        return boxLibrary.fileID(ofCopyAt: url)
    }

    /// Whether ⌘S has something to do for the open Box book even with
    /// nothing unsaved: work Box has not got, or a decision waiting.
    public var openBoxBookNeedsUpload: Bool {
        _ = boxLinks
        guard let fileID = openBoxFileID, let link = boxLibrary.record(fileID) else { return false }
        if link.conflict != nil || link.uploadRequested || link.pendingUpload != nil { return true }
        return !link.looksSynced(BoxLibrary.look(at: boxLibrary.copyURL(for: link)))
    }

    /// Removes this device's copy of a Box book — the book stays on Box, and
    /// opening it again downloads it. Its audit log and its record stay: the
    /// log is the only record of the changes made on this device, and goes on
    /// beside the next copy.
    ///
    /// Only a copy that matches what Box has, and not the open one: anything
    /// else is the only record of some work.
    public func removeBoxCopy(of item: BoxItem) async throws {
        guard let link = boxLibrary.record(item.id) else { return }
        let copy = boxLibrary.copyURL(for: link)
        guard !(documentURL.map { BoxLibrary.samePath($0, copy) } ?? false) else {
            throw BookFileError("Close the book before removing it from this device.")
        }
        guard link.conflict == nil, !link.uploadRequested, link.pendingUpload == nil,
              boxWorkTasks[item.id] == nil else {
            throw BookFileError("This copy has changes Box hasn’t got yet, so it stays.")
        }
        guard await copyMatchesBox(link) else {
            throw BookFileError("This copy has changes Box hasn’t got yet, so it stays.")
        }
        guard let busy = boxLibrary.tryLock(item.id) else {
            throw BookFileError("Box is still busy with this book. Try again in a moment.")
        }
        defer { boxLibrary.unlock(busy) }
        try FileManager.default.removeItem(at: copy)
        removeRecent(copy)
        boxLinks[item.id] = boxLibrary.record(item.id)
    }

    /// Whether the copy is what Box has: the cheap look first, and a hash
    /// when the date has moved — a save that changed nothing moves it too.
    func copyMatchesBox(_ link: BoxBookLink) async -> Bool {
        let copy = boxLibrary.copyURL(for: link)
        if link.looksSynced(BoxLibrary.look(at: copy)) { return true }
        guard let synced = link.syncedSHA256,
              let snapshot = try? await Task.detached(priority: .userInitiated, operation: {
                  try BoxLibrary.Reader(copy).snapshot()
              }).value else { return false }
        guard snapshot.sha256 == synced else { return false }
        // The same bytes under a new date: remember the date, so the next
        // look is cheap again.
        var updated = boxLibrary.record(link.fileID) ?? link
        updated.syncedSize = snapshot.size
        updated.syncedModified = snapshot.modified
        saveBoxLink(updated)
        return true
    }

    // MARK: Opening

    /// Opens a book from Box: the copy here, brought up to date first — or
    /// left as it is when it holds work Box has not got.
    public func openBoxBook(_ item: BoxItem, inFolder folderID: String) async {
        guard item.isBook, BoxLibrary.isSafeFileID(item.id) else { return }
        var link = boxLibrary.record(item.id) ?? BoxBookLink(fileID: item.id, fileName: item.name)
        link.parentID = folderID
        saveBoxLink(link)
        await openBook(at: boxLibrary.copyURL(for: link))
    }

    /// Whether a copy is open in another process — another copy of the app,
    /// or a tool — judged by the book's own lock.
    private static func heldElsewhere(_ copy: URL) -> Bool {
        let lock = FileLock(documentURL: copy)
        guard let holder = lock.currentHolder() else { return false }
        return !lock.isStale() && !FileLock.canBreakWithoutAsking(holder)
    }

    /// Makes the copy of a Box book current before it opens, returning
    /// whether there is a copy to open. Called by ``openBook(at:breakStaleLock:)``
    /// for every path in the Box library — Recents and session restore
    /// included — so a book reopened on a second device is the version the
    /// first one saved, not the one this device last had.
    ///
    /// The copy is never replaced while it holds work Box does not have —
    /// decided from its bytes, not from a record a crash or another tool
    /// could have left behind — nor while another process has it open.
    func prepareBoxCopy(_ fileID: String) async -> Bool {
        guard var link = boxLibrary.record(fileID) else { return true }
        let copy = boxLibrary.copyURL(for: link)
        let haveCopy = FileManager.default.fileExists(atPath: copy.path)
        if haveCopy {
            if link.conflict != nil || link.uploadRequested || link.pendingUpload != nil { return true }
            if await !copyMatchesBox(link) { return true }
            if Self.heldElsewhere(copy) { return true }
        }

        guard isBoxSignedIn else {
            if haveCopy {
                showToast(.info, "Not connected to Box — opened the copy on this device.")
                return true
            }
            documentError = DocumentError(
                message: String(localized: "Connect to Box in Settings to open “\(link.bookName)”."))
            return false
        }
        guard let busy = boxLibrary.tryLock(fileID) else {
            if haveCopy { return true }
            documentError = DocumentError(
                message: String(localized: "Box is still busy with this book. Try again in a moment."))
            return false
        }
        defer { boxLibrary.unlock(busy) }

        boxOpenPhase = .checking
        boxOpenCancelled = false
        defer { boxOpenPhase = nil; boxOpenCancel = nil }
        // The talking to Box, in a task of its own so Cancel can stop it.
        let known = link
        let work = Task { () throws -> BoxOpenCheck in
            let account = try await self.boxAccount()
            if known.isInAnotherAccount(than: account) { return .inAnotherAccount }
            let client = self.boxClient()
            let current = try await client.file(fileID, timeout: 20)
            if haveCopy, current.etag != nil, current.etag == known.etag { return .current(account) }
            self.boxOpenPhase = .downloading(nil)
            let download = try await client.download(fileID, version: current.versionID) { received, expected in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.boxOpenPhase else { return }
                    self.boxOpenPhase = .downloading(expected.map { Double(received) / Double(max($0, 1)) })
                }
            }
            return .downloaded(account, current, download)
        }
        boxOpenCancel = { work.cancel() }
        do {
            switch try await work.value {
            case .inAnotherAccount:
                guard haveCopy else { throw BoxOtherAccountError(login: link.accountLogin) }
                showToast(.info, verbatim: String(localized: "“\(link.bookName)” is in another Box account, so the copy on this device opened. Its changes go to Box when you connect that account."))
                return !boxOpenCancelled
            case .current(let account):
                if link.accountID == nil {
                    link.bind(to: account)
                    saveBoxLink(link)
                }
                return !boxOpenCancelled
            case .downloaded(let account, let current, let download):
                defer { try? FileManager.default.removeItem(at: download) }
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try BoxLibrary.validateBook(at: download)
                    let snapshot = try BoxLibrary.Reader(download).snapshot()
                    try BoxLibrary.replace(copy, with: download)
                    return snapshot
                }.value
                let look = BoxLibrary.look(at: copy)
                link.bind(to: account)
                link.etag = current.etag
                link.fileName = current.name
                link.parentID = current.parentID ?? link.parentID
                link.syncedSHA256 = snapshot.sha256
                link.syncedSHA1 = snapshot.sha1Hex
                link.syncedSize = look?.size ?? snapshot.size
                link.syncedModified = look?.modified ?? snapshot.modified
                link.uploadRequested = false
                link.conflict = nil
                link.pendingUpload = nil
                link.lastRefusal = nil
                saveBoxLink(link)
                // Cancelled while the copy was being put in place: it is in
                // place, and current — only the opening stops.
                return !boxOpenCancelled
            }
        } catch {
            if boxOpenCancelled {
                // The person chose not to wait. Nothing was replaced; the
                // book that was open stays.
                if !haveCopy, link.syncedSHA256 == nil { forgetBoxLink(fileID) }
                return false
            }
            noteBoxFailure(error)
            if haveCopy {
                showToast(.failure, verbatim: String(localized: "Couldn’t reach Box (\(error.localizedDescription)) — opened the copy on this device."))
                return true
            }
            // Never came down: nothing here to keep a record of.
            if link.syncedSHA256 == nil { forgetBoxLink(fileID) }
            documentError = DocumentError(
                message: String(localized: "Couldn’t download “\(link.bookName)” from Box: \(error.localizedDescription)"))
            return false
        }
    }

    /// Stops waiting for Box while a book from it opens — Cancel on the
    /// opening screen. Nothing is replaced, and the book that was open stays
    /// open. A request is stopped at once; a token refresh already under way
    /// is shared with every other request and is not, so a Cancel made while
    /// one runs takes effect when it answers — within its twenty seconds.
    public func cancelBoxOpen() {
        guard boxOpenPhase != nil else { return }
        boxOpenCancelled = true
        boxOpenCancel?()
    }

    /// After a Box book opens: an upload it still owes starts, or its
    /// conflict is put to the person again.
    func boxBookDidOpen() {
        guard let fileID = openBoxFileID, let link = boxLibrary.record(fileID) else { return }
        boxLinks[fileID] = link
        if link.conflict != nil {
            presentBoxConflict(link)
        } else if (link.uploadRequested || link.pendingUpload != nil) && link.lastRefusal == nil {
            startBoxUpload(fileID)
        }
    }

    private func presentBoxConflict(_ link: BoxBookLink) {
        guard let reason = link.conflict, !boxResolving.contains(link.fileID) else { return }
        boxConflict = BoxConflict(fileID: link.fileID, bookName: link.bookName, reason: reason)
    }

    // MARK: Uploading — on explicit saves only

    /// Asks for the open Box book to go up. The explicit moments — ⌘S,
    /// closing the book, switching books, quitting, leaving the app on
    /// iPhone and iPad — call this; autosave does not (the owner's decision,
    /// 17 Oct 2026: about 70 MB a time, every five minutes, was too much to
    /// send for a book the next explicit save sends anyway).
    func requestUploadOfOpenBoxBook(announce: Bool) {
        guard let fileID = openBoxFileID else { return }
        requestBoxUpload(fileID, announce: announce)
    }

    func requestBoxUpload(_ fileID: String, announce: Bool) {
        guard var link = boxLibrary.record(fileID) else { return }
        if link.conflict != nil {
            if announce { presentBoxConflict(link) }
            return
        }
        if !link.uploadRequested || link.lastRefusal != nil {
            link.uploadRequested = true
            link.lastRefusal = nil
            saveBoxLink(link)
        }
        boxUploadFailuresReported.remove(fileID)
        startBoxUpload(fileID, announce: announce)
    }

    /// Starts uploading a Box book unless something is already working on it
    /// in this process — that one goes round again for a save made meanwhile,
    /// and, when this request asked to be told, tells the person how it went.
    /// (The first version dropped the asking: ⌘S during an upload already
    /// running heard nothing back when it worked.)
    func startBoxUpload(_ fileID: String, announce: Bool = false) {
        if announce { boxAnnounceRequested.insert(fileID) }
        guard boxWorkTasks[fileID] == nil else { return }
        boxRetryTasks[fileID]?.cancel()
        boxRetryTasks[fileID] = nil
        boxWorkTasks[fileID] = Task { [weak self] in
            await self?.runBoxUpload(fileID)
            self?.boxWorkTasks[fileID] = nil
        }
    }

    /// What one pass of an upload found.
    private enum UploadPass {
        case alreadyOnBox(BoxLibrary.Snapshot)
        case uploaded(BoxItem, BoxLibrary.Snapshot)
    }

    /// Sends the copy until Box has what is on disk, then clears the request.
    private func runBoxUpload(_ fileID: String) async {
        // Another process, or a download or Keep Both here, is working on the
        // book; whoever holds it finishes, and the request stays on record.
        guard let busy = boxLibrary.tryLock(fileID) else {
            boxAnnounceRequested.remove(fileID)
            return
        }
        defer { boxLibrary.unlock(busy) }
        var sent = false
        for _ in 0..<8 {
            guard var link = boxLibrary.record(fileID), link.uploadRequested, link.conflict == nil else { break }
            let copy = boxLibrary.copyURL(for: link)
            guard FileManager.default.fileExists(atPath: copy.path) else { break }
            do {
                guard isBoxSignedIn else { throw BoxError.notAuthenticated }
                let account = try await boxAccount()
                guard !link.isInAnotherAccount(than: account) else {
                    throw BoxOtherAccountError(login: link.accountLogin)
                }
                let pass = try await uploadPass(copy: copy, link: link)
                link = boxLibrary.record(fileID) ?? link
                let snapshot: BoxLibrary.Snapshot
                switch pass {
                case .alreadyOnBox(let seen):
                    snapshot = seen
                case .uploaded(let item, let seen):
                    snapshot = seen
                    link.etag = item.etag ?? link.etag
                    link.fileName = item.name
                    link.parentID = item.parentID ?? link.parentID
                    sent = true
                }
                link.bind(to: account)
                link.syncedSHA256 = snapshot.sha256
                link.syncedSHA1 = snapshot.sha1Hex
                link.syncedSize = snapshot.size
                link.syncedModified = snapshot.modified
                link.pendingUpload = nil
                link.lastRefusal = nil
                // A save that landed while this pass was reading leaves the
                // file unlike the snapshot: go round again rather than call
                // it sent.
                link.uploadRequested = !link.looksSynced(BoxLibrary.look(at: copy))
                saveBoxLink(link)
                boxRetryAttempts[fileID] = nil
                boxUploadFailuresReported.remove(fileID)
            } catch {
                handleUploadFailure(error, fileID: fileID, announce: boxAnnounceRequested.remove(fileID) != nil)
                return
            }
        }
        if boxAnnounceRequested.remove(fileID) != nil, sent { showToast(.success, "Uploaded to Box.") }
    }

    /// Where the file on Box stands, against this device's record and the
    /// copy about to go up.
    private enum BoxStanding {
        /// Box has these very bytes: an upload that reached it whose answer
        /// never came back — a connection lost at the end, a suspension, a
        /// crash.
        case alreadyThere(BoxItem)
        /// Box has the version this device last had — under a new name or in
        /// another folder, perhaps. The upload goes on top of it, as it is.
        case current(BoxItem)
        /// Another device has saved since.
        case changed
    }

    /// Asked of Box before each upload, by the SHA-1 Box gives for a file.
    ///
    /// Without it, an upload whose answer was lost was sent again guarded by
    /// the version it had already replaced, and Box's 412 read as another
    /// device's save — Keep Both then put a second copy of the same book
    /// beside it. And since an upload names the file, and Box renames a file
    /// to the name an upload gives (its reference, *Upload file version*:
    /// "If specified, the file will be renamed when the new version is
    /// uploaded"), a rename made on Box was undone by the next save here.
    private func standing(of link: BoxBookLink, against snapshot: BoxLibrary.Snapshot,
                          client: BoxClient) async throws -> BoxStanding {
        let item = try await client.file(link.fileID)
        guard let sha1 = item.sha1?.lowercased() else {
            return item.etag == link.etag ? .current(item) : .changed
        }
        if sha1 == snapshot.sha1Hex { return .alreadyThere(item) }
        if item.etag == link.etag || sha1 == link.syncedSHA1 { return .current(item) }
        return .changed
    }

    /// One reading of the copy, sent if Box has not got it: in one request
    /// under the chunked API's 20 MB floor, in parts above it — parts that
    /// are recorded as Box acknowledges them, so an upload cut off by a quit
    /// or a suspension goes on from the last part next time. A 412 — a save
    /// made elsewhere between the look and the upload, or a rename, if a
    /// rename moves the etag — is looked at once more before it is called a
    /// conflict.
    private func uploadPass(copy: URL, link: BoxBookLink) async throws -> UploadPass {
        let reader = try BoxLibrary.Reader(copy)
        let snapshot = try await Task.detached(priority: .utility) { try reader.snapshot() }.value
        if snapshot.sha256 == link.syncedSHA256 { return .alreadyOnBox(snapshot) }
        let client = boxClient()
        for look in 0..<2 {
            let target: BoxItem
            switch try await standing(of: link, against: snapshot, client: client) {
            case .alreadyThere(let item): return .uploaded(item, snapshot)
            case .changed: throw BoxError.versionConflict(currentEtag: nil)
            case .current(let item): target = item
            }
            do {
                let item = try await send(snapshot, from: reader, over: target, link: link, client: client)
                return .uploaded(item, snapshot)
            } catch BoxError.versionConflict where look == 0 {
                continue
            }
        }
        throw BoxError.versionConflict(currentEtag: nil)
    }

    /// Sends a snapshot as a new version of `target` — guarded by its etag,
    /// and under the name it has now.
    private func send(_ snapshot: BoxLibrary.Snapshot, from reader: BoxLibrary.Reader, over target: BoxItem,
                      link: BoxBookLink, client: BoxClient) async throws -> BoxItem {
        if snapshot.size < boxChunkThreshold {
            let data = try await Task.detached(priority: .utility) {
                try reader.read(offset: 0, count: snapshot.size)
            }.value
            return try await client.uploadNewVersion(fileID: link.fileID, data: data,
                                                     fileName: target.name, ifMatch: target.etag)
        }
        return try await uploadInParts(reader: reader, snapshot: snapshot, link: link, client: client,
                                       open: { try await client.createUploadSession(forFile: link.fileID,
                                                                                    size: snapshot.size) },
                                       ifMatch: target.etag, parentID: nil)
    }

    /// A chunked upload, resumed where a record says one stopped — when the
    /// copy is still the bytes it was sending and the session has not
    /// expired — and begun again otherwise.
    ///
    /// A resumed session Box no longer has, or whose parts no longer fit it,
    /// is begun again at once with a new one. Only a resumed one: from a
    /// session opened moments ago a 404 means what it says — the file has
    /// gone — and is passed on to be asked about. The first version made the
    /// difference by whether any part had gone yet, so a session kept with
    /// none sent was taken for a deleted book, and one kept with some was
    /// restarted under a status code Box never sent, said to the person in
    /// those words.
    private func uploadInParts(reader: BoxLibrary.Reader, snapshot: BoxLibrary.Snapshot, link: BoxBookLink,
                               client: BoxClient, open: () async throws -> BoxUploadSession,
                               ifMatch: String?, parentID: String?) async throws -> BoxItem {
        var record = boxLibrary.record(link.fileID) ?? link
        var resumable: BoxPendingUpload?
        if let kept = record.pendingUpload {
            if kept.sha256 == snapshot.sha256,
               (kept.session.expiresAt ?? .distantFuture) > Date().addingTimeInterval(600) {
                resumable = kept
            } else {
                await client.abort(kept.session)
            }
        }
        while true {
            var pending: BoxPendingUpload
            let resuming = resumable != nil
            if let resumed = resumable {
                pending = resumed
                resumable = nil
            } else {
                let session = try await open()
                pending = BoxPendingUpload(session: session, sha256: snapshot.sha256,
                                           sha1Base64: snapshot.sha1Base64, size: snapshot.size, parts: [])
                record = boxLibrary.record(link.fileID) ?? record
                record.pendingUpload = pending
                saveBoxLink(record)
            }
            do {
                let partSize = pending.session.partSize
                var offset: Int64 = 0
                while offset < snapshot.size {
                    let length = min(partSize, snapshot.size - offset)
                    if !pending.parts.contains(where: { $0.offset == offset }) {
                        let start = offset
                        let chunk = try await Task.detached(priority: .utility) {
                            try reader.read(offset: start, count: length)
                        }.value
                        let part = try await client.uploadPart(chunk, offset: offset, totalSize: snapshot.size,
                                                               session: pending.session)
                        pending.parts.append(part)
                        record = boxLibrary.record(link.fileID) ?? record
                        record.pendingUpload = pending
                        saveBoxLink(record)
                    }
                    offset += length
                }
                return try await client.commit(pending.session, parts: pending.parts,
                                               wholeFileSHA1: snapshot.sha1Base64, ifMatch: ifMatch,
                                               parentID: parentID)
            } catch BoxError.api(let status, _, _) where resuming && [404, 409, 410, 416].contains(status) {
                record = boxLibrary.record(link.fileID) ?? record
                record.pendingUpload = nil
                saveBoxLink(record)
            }
        }
    }

    /// What a failed upload means. A conflict waits for the person; an
    /// answer a retry may cure — no network, Box busy or down — is tried
    /// again by itself, sooner and then less often, and the moment the
    /// network comes back; a refusal a retry will not cure is said plainly
    /// and waits for the next explicit save.
    private func handleUploadFailure(_ error: Error, fileID: String, announce: Bool) {
        guard var link = boxLibrary.record(fileID) else { return }
        switch error {
        case BoxError.versionConflict:
            link.conflict = .changedOnBox
            saveBoxLink(link)
            presentBoxConflict(link)
        case BoxError.api(let status, _, _) where status == 404:
            link.conflict = .goneFromBox
            saveBoxLink(link)
            presentBoxConflict(link)
        case BoxError.notAuthenticated:
            noteBoxFailure(error)
            reportUploadFailure(error, link: link, announce: announce)
        case is BoxOtherAccountError:
            // Neither a refusal nor worth retrying: it goes up when the
            // account it is in is connected (``signInToBox()``).
            reportUploadFailure(error, link: link, announce: announce)
        case _ where Self.isTransient(error):
            reportUploadFailure(error, link: link, announce: announce)
            scheduleBoxRetry(fileID)
        default:
            link.lastRefusal = error.localizedDescription
            saveBoxLink(link)
            documentError = DocumentError(
                message: String(localized: "Box refused “\(link.bookName)”: \(error.localizedDescription) It is saved on this device; press ⌘S to try again."))
        }
    }

    private func reportUploadFailure(_ error: Error, link: BoxBookLink, announce: Bool) {
        guard announce || !boxUploadFailuresReported.contains(link.fileID) else { return }
        boxUploadFailuresReported.insert(link.fileID)
        showToast(.failure, verbatim: String(localized: "Couldn’t upload “\(link.bookName)” to Box: \(error.localizedDescription) It’s saved on this device and will be uploaded later."))
    }

    /// Whether trying again could work without anyone doing anything.
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        switch error {
        case BoxError.notReadyYet: return true
        case BoxError.api(let status, _, _): return status == 429 || status >= 500
        case BoxError.malformedResponse: return true
        default: return false
        }
    }

    private func scheduleBoxRetry(_ fileID: String) {
        let attempt = (boxRetryAttempts[fileID] ?? 0) + 1
        boxRetryAttempts[fileID] = attempt
        let delays: [Duration] = [.seconds(30), .seconds(120), .seconds(300), .seconds(900)]
        let delay = delays[min(attempt - 1, delays.count - 1)]
        boxRetryTasks[fileID]?.cancel()
        boxRetryTasks[fileID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.boxRetryTasks[fileID] = nil
            self?.startBoxUpload(fileID)
        }
        watchNetworkForBox()
    }

    /// Wakes the waiting uploads the moment the network comes back.
    ///
    /// On a return only. A monitor reports the network as it is the moment
    /// it starts — on a connected machine, "satisfied" — and the first
    /// version took that, and any change while connected (another Wi-Fi, a
    /// VPN), for the network coming back: each cancelled the retry just
    /// scheduled and tried again at once, so the back-off never held. It
    /// showed as a test that passed here and failed on CI, where the retry it
    /// looked for had been cancelled by then.
    private func watchNetworkForBox() {
        guard boxPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let watch = BoxNetworkWatch()
        monitor.pathUpdateHandler = { [weak self] path in
            guard watch.returned(path.status == .satisfied) else { return }
            Task { @MainActor in self?.resumeBoxUploads() }
        }
        monitor.start(queue: DispatchQueue(label: "com.hellotham.finvestlens.box-network"))
        boxPathMonitor = monitor
    }

    /// Starts every upload an explicit save asked for that has not happened
    /// yet — at launch, on connecting, when iOS brings the app back and when
    /// the network returns. Autosaved work waits for an explicit save.
    public func resumeBoxUploads() {
        reloadBoxLinks()
        guard isBoxSignedIn else { return }
        for (fileID, link) in boxLinks where link.uploadRequested && link.conflict == nil && link.lastRefusal == nil
            && FileManager.default.fileExists(atPath: boxLibrary.copyURL(for: link).path) {
            startBoxUpload(fileID)
        }
    }

    /// Whether anything is going to or from Box now — the status chip, and
    /// the quit that waits for it.
    public var hasBoxWorkInFlight: Bool { !boxWorkTasks.isEmpty }

    /// Waits for the Box work under way — at most `limit`, or until
    /// ``stopWaitingForBox()`` — before the app quits or iOS suspends it.
    /// What is not done by then stays on record and goes next time; a
    /// chunked upload goes on from its last part.
    ///
    /// Not a task group: a group waits for all its children even when told
    /// to cancel, and a child waiting on an upload's `value` does not stop
    /// for cancellation — so the first version waited for the whole upload,
    /// minutes on a slow line, whatever the limit said.
    public func finishBoxWork(within limit: Duration) async {
        let running = Array(boxWorkTasks.values)
        guard !running.isEmpty else { return }
        let gate = BoxWaitGate()
        boxQuitGate = gate
        defer { boxQuitGate = nil }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.arm(continuation)
            Task { for task in running { await task.value }; gate.open() }
            Task { try? await Task.sleep(for: limit); gate.open() }
        }
    }

    /// Ends a ``finishBoxWork(within:)`` wait now — "Quit Now".
    public func stopWaitingForBox() {
        boxQuitGate?.open()
    }

    /// The Mac's quit, when Box work is under way: the window shows what it is
    /// waiting for, with a way to stop waiting, and nothing else can be
    /// started meanwhile — a book opened during the wait would be lost when
    /// the app goes.
    public func finishBoxWorkBeforeQuit() async {
        isFinishingBoxWorkBeforeQuit = true
        defer { isFinishingBoxWorkBeforeQuit = false }
        await finishBoxWork(within: .seconds(30))
    }

    // MARK: Conflicts

    /// Puts this device's version of a conflicted Box book on Box as a book
    /// of its own, beside the other version — which is not touched — and
    /// carries on with it there.
    ///
    /// Box keeps a file's earlier versions only on premium accounts (its API
    /// reference, *List all file versions*), so replacing the other version
    /// is not offered: on other accounts it would be gone. Two books on Box
    /// is a state the person can sort out; a lost version is not.
    ///
    /// The copy cannot be opened while this runs, and whether it is open is
    /// asked again after the upload — the first version decided once, before
    /// a long upload, and could move a file out from under a book opened
    /// meanwhile. Quitting waits for it like any upload.
    public func resolveBoxConflict(_ conflict: BoxConflict) async {
        boxConflict = nil
        let key = "resolve-\(conflict.fileID)"
        guard !boxResolving.contains(conflict.fileID), boxWorkTasks[key] == nil else { return }
        boxResolving.insert(conflict.fileID)
        let work = Task { [weak self] in
            guard let self else { return }
            await self.keepBoth(conflict)
        }
        boxWorkTasks[key] = work
        await work.value
        boxWorkTasks[key] = nil
        boxResolving.remove(conflict.fileID)
    }

    private func keepBoth(_ conflict: BoxConflict) async {
        guard let link = boxLibrary.record(conflict.fileID) else { return }
        let copy = boxLibrary.copyURL(for: link)
        // What is on screen goes up too — saved first, with the book open.
        if let open = documentURL, BoxLibrary.samePath(open, copy), hasUnsavedChanges {
            do { try save() } catch {
                documentError = DocumentError(message: String(localized: "Couldn’t save “\(link.bookName)”: \(error.localizedDescription)"))
                return
            }
        }
        guard let busy = boxLibrary.tryLock(conflict.fileID) else {
            documentError = DocumentError(message: String(localized: "Box is still busy with this book. Try again in a moment."))
            return
        }
        let created: BoxItem
        let folder: String
        let snapshot: BoxLibrary.Snapshot
        let account: BoxUser
        do {
            // Never into another account: there the book's folder answers as
            // missing too, and "the top folder" would be someone else's.
            account = try await boxAccount()
            guard !link.isInAnotherAccount(than: account) else {
                throw BoxOtherAccountError(login: link.accountLogin)
            }
            let client = boxClient()
            var start = link.parentID ?? "0"
            if conflict.reason == .changedOnBox,
               let parent = try? await client.file(link.fileID, timeout: 20).parentID {
                start = parent
            }
            let reader = try BoxLibrary.Reader(copy)
            snapshot = try await Task.detached(priority: .userInitiated) { try reader.snapshot() }.value
            (created, folder) = try await uploadAsNewBook(reader: reader, snapshot: snapshot, conflict: conflict,
                                                          link: link, folder: start, client: client)
        } catch {
            boxLibrary.unlock(busy)
            noteBoxFailure(error)
            documentError = DocumentError(
                message: String(localized: "Couldn’t put your version of “\(link.bookName)” on Box: \(error.localizedDescription) It is still saved on this device."))
            return
        }
        boxLibrary.unlock(busy)

        // Box has it. The copy here becomes the new book's copy — asked now,
        // not before the upload, whether it is open.
        let openNow = documentURL.map { BoxLibrary.samePath($0, copy) } ?? false
        if openNow { guard saveAndCloseIfOpen() else { return } }
        var moved = BoxBookLink(fileID: created.id, fileName: created.name,
                                parentID: created.parentID ?? folder, etag: created.etag,
                                syncedSHA256: snapshot.sha256, syncedSize: snapshot.size,
                                syncedModified: snapshot.modified, syncedSHA1: snapshot.sha1Hex,
                                accountID: account.id, accountLogin: account.login)
        let destination = boxLibrary.copyURL(for: moved)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: copy, to: destination)
        } catch {
            documentError = DocumentError(
                message: String(localized: "Couldn’t put your version of “\(link.bookName)” on Box: \(error.localizedDescription) It is still saved on this device."))
            if openNow {
                // The book closed for the move goes back on screen. It is
                // still being resolved, which `openBook` refuses, so that ends
                // first; the conflict stays on record and the next ⌘S asks
                // again — not now, over the alert that says what went wrong.
                boxResolving.remove(conflict.fileID)
                await openBook(at: copy)
                boxConflict = nil
            }
            return
        }
        bookMoved(from: copy, to: destination)
        // A save on closing after the reading above is work Box has not got;
        // closing is an explicit save, so it goes up.
        if !moved.looksSynced(BoxLibrary.look(at: destination)) { moved.uploadRequested = true }
        saveBoxLink(moved)
        forgetBoxLink(conflict.fileID)
        boxLibrary.removeFolderIfEmpty(conflict.fileID)
        showToast(.success, verbatim: String(localized: "Your version is on Box as “\(created.name)”."))
        if openNow {
            boxResolving.remove(conflict.fileID)
            await openBook(at: destination)
        } else if moved.uploadRequested {
            startBoxUpload(created.id)
        }
    }

    /// Puts the snapshot on Box as a new book, returning it and the folder it
    /// went to: under its own name when the original has gone, otherwise as a
    /// conflicted copy, under a name the folder does not have yet.
    ///
    /// If an interrupted earlier attempt already left these exact bytes in
    /// the folder — Box says each file's SHA-1 — that book is taken rather
    /// than a second copy made. A folder that has gone too falls back to the
    /// top of the person's Box. Any other refusal is passed on in Box's own
    /// words: Box answers 409 for a full account as well as for a taken name,
    /// and the first version took every 409 for a name and sent the whole
    /// book again, up to eight times.
    private func uploadAsNewBook(reader: BoxLibrary.Reader, snapshot: BoxLibrary.Snapshot,
                                 conflict: BoxConflict, link: BoxBookLink, folder: String,
                                 client: BoxClient) async throws -> (BoxItem, String) {
        var targets = [folder]
        if folder != "0" { targets.append("0") }
        var lastError: Error?
        for target in targets {
            do {
                let siblings = try await client.items(inFolder: target)
                if let earlier = siblings.first(where: {
                    $0.isBook && $0.sha1?.lowercased() == snapshot.sha1Hex && $0.size == snapshot.size
                        && $0.id != link.fileID
                }) {
                    return (earlier, target)
                }
                let taken = Set(siblings.map { $0.name.lowercased() })
                let now = Date()
                var names = (0..<20).map { BoxLibrary.conflictCopyName(for: link.fileName, at: now, attempt: $0) }
                if conflict.reason == .goneFromBox { names.insert(link.fileName, at: 0) }
                guard let name = names.first(where: { !taken.contains($0.lowercased()) }) else {
                    throw BoxError.api(status: 409, code: "item_name_in_use", message: nil)
                }
                if snapshot.size < boxChunkThreshold {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try reader.read(offset: 0, count: snapshot.size)
                    }.value
                    return (try await client.uploadNewFile(named: name, inFolder: target, data: data), target)
                }
                let item = try await uploadInParts(
                    reader: reader, snapshot: snapshot, link: link, client: client,
                    open: { try await client.createUploadSession(newFileNamed: name, inFolder: target,
                                                                 size: snapshot.size) },
                    ifMatch: nil, parentID: target)
                return (item, target)
            } catch BoxError.api(let status, let code, let message) where status == 404 && target != "0" {
                lastError = BoxError.api(status: status, code: code, message: message)
                continue
            }
        }
        throw lastError ?? BoxError.malformedResponse("no folder to upload to")
    }
}

/// The network as the monitor last reported it, to tell its coming back
/// from a report that it is there.
final class BoxNetworkWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var wasSatisfied: Bool?

    /// Whether this report is the network returning: connected now, after a
    /// report that it was not. The first report is how things are, not a
    /// change.
    func returned(_ satisfied: Bool) -> Bool {
        lock.withLock {
            defer { wasSatisfied = satisfied }
            return satisfied && wasSatisfied == false
        }
    }
}

/// Opens once, from whichever of its callers gets there first: the uploads
/// finishing, the time running out, or "Quit Now".
final class BoxWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = lock.withLock {
            if opened { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func open() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !opened else { return nil }
            opened = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume()
    }
}
