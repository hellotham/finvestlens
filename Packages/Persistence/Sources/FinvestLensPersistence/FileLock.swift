//
//  FileLock.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import OSLog
import CryptoKit
#if os(macOS)
import IOKit
#else
import Security
#endif

/// Metadata about who holds a document lock.
public struct LockHolder: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var instanceID: String
    public var pid: Int32
    public var acquiredAt: Date
    public var heartbeatAt: Date
    /// Which machine wrote the lock — ``MachineIdentity/current`` there.
    /// Absent from a lock written before 12 Oct 2026, which is then known
    /// only by its host name.
    public var machineID: String?

    public init(host: String, user: String, instanceID: String, pid: Int32,
                acquiredAt: Date, heartbeatAt: Date, machineID: String? = nil) {
        self.host = host
        self.user = user
        self.instanceID = instanceID
        self.pid = pid
        self.acquiredAt = acquiredAt
        self.heartbeatAt = heartbeatAt
        self.machineID = machineID
    }
}

/// This machine, by something steadier than its name.
///
/// A host name is not an identity: two Macs of one model owned by one person
/// share a default name until they meet on a network, one Mac answered
/// `macbookpro128.local` one day and its ISP's reverse-DNS name the next, and
/// an iPhone answers `localhost`. A lock that syncs between such a pair must
/// not let one read the other's live holder as "a pid that isn't running
/// here". So a lock also carries this:
///
/// - **macOS** — a digest of the hardware UUID: the same for every tool on
///   the Mac, sandboxed or not. A digest, because the lock file travels with
///   the book to wherever the book is synced.
/// - **iOS** — a value minted once and kept in the Keychain as
///   *this-device-only*. Not `UserDefaults`: a backup restored onto a second
///   phone, or a device-to-device transfer, copies preferences, and two
///   phones would then answer to one identity — each reading the other's
///   live lock as its own dead one. A this-device-only Keychain item is not
///   carried to another device.
///
/// One limit is accepted and stated: two **virtual** Macs cloned from one
/// image share a hardware UUID. They also share a host name, so the
/// host-name rule this replaces was no better; the §6.2 fingerprint check at
/// save is what stands behind the lock there.
enum MachineIdentity {
    static let current: String? = compute()

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    #if os(macOS)
    private static func compute() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        return digest(uuid)
    }
    #else
    private static let service = "com.hellotham.finvestlens.machine-identity"
    private static let account = "machineID"

    /// `nil` when the Keychain will not answer (locked before first unlock,
    /// or refused) — which only means nothing is broken without asking.
    private static func compute() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var found: CFTypeRef?
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(read as CFDictionary, &found) == errSecSuccess,
           let data = found as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let minted = digest(UUID().uuidString)
        var add = query
        add[kSecValueData as String] = Data(minted.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? minted : nil
    }
    #endif
}

/// Declares the sibling lock file as a *related item* of the document, so a
/// sandboxed app's user-selected access to `Book.finvestlens` extends to
/// `Book.lock` (the app also declares the `lock` extension with
/// `NSIsRelatedItemType` in its Info.plist).
private final class LockFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    #if os(macOS)
    // Unavailable on iOS, where documents live in the app container and no
    // related-item grant is needed.
    let primaryPresentedItemURL: URL?
    #endif
    let presentedItemOperationQueue = OperationQueue()

    init(lockURL: URL, documentURL: URL) {
        self.presentedItemURL = lockURL
        #if os(macOS)
        self.primaryPresentedItemURL = documentURL
        #endif
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
}

/// An application-level advisory lock guarding a document on shared storage
/// (Architecture §6.1).
///
/// Because SQLite's own locking is unreliable over SMB/NFS, FinvestLens enforces
/// single-writer access with a sibling `<document>.lock` file carrying holder
/// metadata and a heartbeat. A lock whose heartbeat has gone stale (holder
/// crashed) can be broken. Creation uses an atomic "write-if-absent" so two
/// machines cannot both acquire.
///
/// All lock-file I/O goes through `NSFileCoordinator` with a related-item
/// presenter, which is what lets a sandboxed app touch the sibling file at a
/// user-selected location.
/// Releases this process's locks when it is terminated by a signal.
///
/// `deinit` and `release()` cover the paths where the app gets to run code on
/// the way out. They do not cover a `SIGTERM` from `killall`, a `SIGHUP` when
/// a session ends, or a ⌃C in a headless run — and a lock left by one of
/// those is indistinguishable, from outside, from a lock held by a live
/// writer. Under a lock that *syncs*, it is worse than a local nuisance: the
/// stranded file propagates to every other machine and locks them out too,
/// until the heartbeat ages out.
///
/// `SIGKILL` and a hard power loss cannot be caught by anything, by design;
/// those are what `FileLock.isProvablyDead` is for.
enum LockReaper {
    private static let queue = DispatchQueue(label: "com.hellotham.finvestlens.lockreaper")
    /// lock file → the instance id we wrote into it, so the reaper only ever
    /// removes a lock this process actually holds.
    nonisolated(unsafe) private static var held: [URL: String] = [:]
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func register(_ url: URL, instanceID: String) {
        queue.sync {
            held[url] = instanceID
            guard sources.isEmpty else { return }
            for number in [SIGTERM, SIGINT, SIGHUP] {
                // The default disposition kills us before a dispatch source
                // ever runs, so it has to be ignored first.
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { reapAndExit(number) }
                source.resume()
                sources.append(source)
            }
        }
    }

    static func deregister(_ url: URL) {
        queue.sync { held[url] = nil }
    }

    /// Remove only the lock files still carrying our own instance id — another
    /// process may have legitimately taken one over since.
    private static func reapAndExit(_ number: Int32) {
        for (url, instanceID) in held {
            let onDisk = (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder().decode(LockHolder.self, from: $0)
            }
            guard onDisk?.instanceID == instanceID else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        held.removeAll()
        exit(number == SIGINT ? 130 : 143)
    }
}

public final class FileLock {

    public enum LockError: Error, Equatable {
        case alreadyLocked(LockHolder)
        case notHeldByUs
        /// We believed we held the lock, but the on-disk file now names another
        /// instance — our stale lock was legitimately broken (e.g. this machine
        /// slept past the staleness window). Continuing to rewrite the file
        /// would clobber the new holder and leave two live writers.
        case lockLost(LockHolder)
    }

    /// Stand-in holder reported when a lock file exists but cannot be read or
    /// decoded (crash mid-create, zero bytes). Its ancient heartbeat makes it
    /// read as stale everywhere, so the UI offers Break Lock instead of the
    /// old behaviour — silently degrading to lockless mode.
    public static let unreadableHolder = LockHolder(
        host: "unknown", user: "unknown", instanceID: "", pid: 0,
        acquiredAt: .distantPast, heartbeatAt: .distantPast)

    /// The document being guarded.
    public let documentURL: URL
    /// The sibling lock file URL.
    public let lockURL: URL

    /// How often the holder should refresh the heartbeat.
    public let heartbeatInterval: TimeInterval
    /// A lock is considered stale after this long without a heartbeat.
    public let staleAfter: TimeInterval

    private let instanceID = UUID().uuidString
    private var held = false
    private let presenter: LockFilePresenter

    public init(
        documentURL: URL,
        heartbeatInterval: TimeInterval = 25,
        staleAfter: TimeInterval = 90
    ) {
        self.documentURL = documentURL
        // Same base name, different extension ("Book.finvestlens" →
        // "Book.lock") — required for the sandbox related-item grant.
        self.lockURL = documentURL.deletingPathExtension().appendingPathExtension("lock")
        self.heartbeatInterval = heartbeatInterval
        self.staleAfter = staleAfter
        self.presenter = LockFilePresenter(lockURL: lockURL, documentURL: documentURL)
        // The related-item presenter is only wanted under App Sandbox; outside
        // it each coordination spends ~0.5 s failing to get an extension that
        // is not needed (see `RelatedSidecar.isSandboxed`).
        if RelatedSidecar.isSandboxed { NSFileCoordinator.addFilePresenter(presenter) }
    }

    /// The coordinator for this lock's I/O: carrying the related-item
    /// presenter under the sandbox, plain elsewhere.
    private func coordinator() -> NSFileCoordinator {
        RelatedSidecar.isSandboxed ? NSFileCoordinator(filePresenter: presenter) : NSFileCoordinator()
    }

    deinit {
        // A dropped lock object must not leave its file behind. This is the
        // last of three nets — `release()` on the normal path, the signal
        // reaper on an abnormal one, and this for an object that simply goes
        // out of scope with the lock still held.
        if held { release() }
        LockReaper.deregister(lockURL)
        if RelatedSidecar.isSandboxed { NSFileCoordinator.removeFilePresenter(presenter) }
    }

    /// `true` if this instance currently holds the lock.
    public var isHeldByUs: Bool { held }

    /// Lock-file failures degrade the document to lockless rather than stop
    /// it, so they are logged — the one place a sandbox refusal shows.
    static let log = Logger(subsystem: "com.hellotham.finvestlens", category: "lock")

    // MARK: Coordinated lock-file I/O

    private func coordinatedRead() -> Data? {
        var data: Data?
        var coordError: NSError?
        coordinator()
            .coordinate(readingItemAt: lockURL, options: [.withoutChanges],
                        error: &coordError) { url in
                data = try? Data(contentsOf: url)
            }
        return data
    }

    private func coordinatedWrite(options: NSFileCoordinator.WritingOptions,
                                  _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var bodyError: Error?
        coordinator()
            .coordinate(writingItemAt: lockURL, options: options,
                        error: &coordError) { url in
                do { try body(url) } catch { bodyError = error }
            }
        if let bodyError { throw bodyError }
        if let coordError { throw coordError }
    }

    /// The current holder, or `nil` if the lock file is absent/unreadable.
    /// Whether the lock file is there at all — asked **inside** a
    /// coordination scope, because under App Sandbox the sibling file is
    /// visible only through the related-item grant a coordination carries.
    /// A plain `fileExists` can answer "no" for a lock that is plainly there,
    /// and the callers of this are the ones about to overwrite a book.
    public func exists() -> Bool {
        var found = false
        var coordError: NSError?
        coordinator()
            .coordinate(readingItemAt: lockURL, options: [.withoutChanges],
                        error: &coordError) { url in
                found = (try? url.checkResourceIsReachable()) ?? false
            }
        return found
    }

    public func currentHolder() -> LockHolder? {
        guard let data = coordinatedRead() else { return nil }
        return try? JSONDecoder().decode(LockHolder.self, from: data)
    }

    /// `true` if a lock exists but its heartbeat has aged past ``staleAfter``.
    /// An unreadable/corrupt lock file counts as stale — it has no live holder
    /// and must be breakable, not a permanent silent bar to locking.
    public func isStale(now: Date = Date()) -> Bool {
        guard let holder = currentHolder() else { return exists() }
        if Self.isProvablyDead(holder) { return true }
        return now.timeIntervalSince(holder.heartbeatAt) > staleAfter
    }

    /// A lock whose holder we can *prove* is gone, without waiting out the
    /// heartbeat window.
    ///
    /// Only ever true for a lock written by **this host**: there the pid is
    /// ours to interrogate, and a pid that no longer exists cannot be holding
    /// anything. A lock from another host must still be judged by heartbeat
    /// alone — the whole point of a lock that syncs is that a holder on
    /// another machine is real, and "that pid isn't running *here*" says
    /// nothing about it. Getting this backwards would break the cross-machine
    /// guarantee the lock exists to provide.
    ///
    /// Waiting `staleAfter` for a crash on the user's own machine is not
    /// caution, it is a lockout: the process is measurably absent, and the
    /// person sitting in front of it is the same person who owns the book.
    static func isProvablyDead(_ holder: LockHolder) -> Bool {
        guard isThisMachine(holder) else { return false }
        guard holder.pid != ProcessInfo.processInfo.processIdentifier else { return false }
        guard holder.pid > 0 else { return true }
        // `kill(pid, 0)` sends nothing; it only asks. ESRCH is the one answer
        // that means "no such process" — EPERM means it exists but belongs to
        // someone else, which is still alive. A recycled pid reads as alive,
        // which errs towards waiting rather than towards breaking a live lock.
        return kill(holder.pid, 0) != 0 && errno == ESRCH
    }

    /// Whether `holder` was written here. A lock that names its machine is
    /// judged by that alone; one from before locks carried it, by host name.
    static func isThisMachine(_ holder: LockHolder) -> Bool {
        if let theirs = holder.machineID { return theirs == MachineIdentity.current }
        return holder.host == ProcessInfo.processInfo.hostName
    }

    /// A lock that may be broken **without asking**: written by this very
    /// machine — by identity, never by host name alone — by a process that no
    /// longer exists. A crash, a force-quit, an installer replacing the app
    /// while a book was open: nobody holds the book and there is nothing for
    /// its owner to decide, so the open simply proceeds. Everything else —
    /// another machine, an old lock known only by host name, a holder that
    /// cannot be read — is still put to the person.
    public static func canBreakWithoutAsking(_ holder: LockHolder) -> Bool {
        guard let theirs = holder.machineID, let ours = MachineIdentity.current,
              theirs == ours else { return false }
        return isProvablyDead(holder)
    }

    /// Acquires the lock, throwing ``LockError/alreadyLocked(_:)`` if another
    /// live holder has it.
    public func acquire(now: Date = Date()) throws {
        let holder = makeHolder(now: now)
        let data = try JSONEncoder().encode(holder)
        do {
            // Atomic create-if-absent: fails if the file already exists.
            try coordinatedWrite(options: []) { url in
                try data.write(to: url, options: [.withoutOverwriting])
            }
            held = true
            Self.log.info("acquired \(self.lockURL.lastPathComponent, privacy: .public)")
            LockReaper.register(lockURL, instanceID: instanceID)
        } catch {
            if let existing = currentHolder() {
                throw LockError.alreadyLocked(existing)
            }
            let nsError = error as NSError
            Self.log.error("could not create \(self.lockURL.lastPathComponent, privacy: .public): \(nsError.localizedDescription, privacy: .public) (\(nsError.domain, privacy: .public) \(nsError.code))")
            if exists() {
                // The file exists but is unreadable/corrupt. Report it as a
                // (stale) unknown holder so the caller offers Break Lock —
                // rethrowing the raw file error made the document layer treat
                // this as "locking unsupported here" and open lockless.
                throw LockError.alreadyLocked(Self.unreadableHolder)
            }
            throw error
        }
    }

    /// Breaks the lock held by exactly `judged` and acquires it — the path a
    /// lock takes when it is broken **without asking**. The caller has
    /// established that `judged` is a dead process of this machine
    /// (``canBreakWithoutAsking(_:)``); this removes that holder and no
    /// other. The looser rule of ``breakStaleLockAndAcquire(now:)`` — an old
    /// heartbeat, an unreadable file — is one a person consented to, so it
    /// is not applied here: if a sync replaced the file between the judgement
    /// and the delete, whoever is there now is refused, not removed.
    public func breakLock(heldBy judged: LockHolder, now: Date = Date()) throws {
        var replacement: LockHolder?
        var unreadable = false
        try? coordinatedWrite(options: [.forDeleting]) { url in
            guard let data = try? Data(contentsOf: url) else { return }   // already gone
            guard let current = try? JSONDecoder().decode(LockHolder.self, from: data) else {
                unreadable = true
                return
            }
            guard current == judged else {
                replacement = current
                return
            }
            try? FileManager.default.removeItem(at: url)
        }
        if let replacement { throw LockError.alreadyLocked(replacement) }
        if unreadable { throw LockError.alreadyLocked(Self.unreadableHolder) }
        try acquire(now: now)
    }

    /// Breaks a stale lock and acquires it. Throws if the existing lock is
    /// **not** stale (a live holder).
    ///
    /// Two machines can race to break the same stale lock. The delete re-reads
    /// the file *inside* its coordination scope and only removes the exact
    /// stale holder that was judged — a different or freshly re-created holder
    /// means another breaker already won, and their new lock is left alone
    /// (the final `acquire` then fails with `alreadyLocked` for us).
    public func breakStaleLockAndAcquire(now: Date = Date()) throws {
        let judged = currentHolder()
        if let judged, !Self.isProvablyDead(judged),
           now.timeIntervalSince(judged.heartbeatAt) <= staleAfter {
            throw LockError.alreadyLocked(judged)
        }
        var raceWinner: LockHolder?
        try? coordinatedWrite(options: [.forDeleting]) { url in
            let current = (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder().decode(LockHolder.self, from: $0)
            }
            if let current, !Self.isProvablyDead(current),
               current != judged || now.timeIntervalSince(current.heartbeatAt) <= staleAfter {
                raceWinner = current
                return
            }
            // Still the judged stale holder (or an unreadable husk): remove it.
            try? FileManager.default.removeItem(at: url)
        }
        if let raceWinner { throw LockError.alreadyLocked(raceWinner) }
        try acquire(now: now)
    }

    /// Refreshes the heartbeat timestamp; must be called by the holder.
    ///
    /// Verifies on-disk ownership first: if another machine legitimately broke
    /// our stale lock while this process slept, blindly rewriting the file
    /// would clobber the new holder and leave two live writers. In that case
    /// `held` drops and ``LockError/lockLost(_:)`` is thrown so the caller can
    /// warn the user. (If the file merely vanished mid-break, the rewrite
    /// re-creates our lock and the rival's create-if-absent backs off.)
    public func refreshHeartbeat(now: Date = Date()) throws {
        guard held else { throw LockError.notHeldByUs }
        if let onDisk = currentHolder(), onDisk.instanceID != instanceID {
            held = false
            throw LockError.lockLost(onDisk)
        }
        let holder = makeHolder(now: now)
        let data = try JSONEncoder().encode(holder)
        try coordinatedWrite(options: [.forReplacing]) { url in
            try data.write(to: url, options: [.atomic])
        }
    }

    /// Releases the lock if we hold it (removes the lock file).
    public func release() {
        guard held else { return }
        if let holder = currentHolder(), holder.instanceID == instanceID {
            try? coordinatedWrite(options: [.forDeleting]) { url in
                try FileManager.default.removeItem(at: url)
            }
            Self.log.info("released \(self.lockURL.lastPathComponent, privacy: .public)")
        } else {
            Self.log.error("release: \(self.lockURL.lastPathComponent, privacy: .public) is not ours on disk (unreadable or another holder)")
        }
        held = false
        LockReaper.deregister(lockURL)
    }

    private func makeHolder(now: Date) -> LockHolder {
        LockHolder(
            host: ProcessInfo.processInfo.hostName,
            user: NSUserName(),
            instanceID: instanceID,
            pid: ProcessInfo.processInfo.processIdentifier,
            acquiredAt: now,
            heartbeatAt: now,
            machineID: MachineIdentity.current
        )
    }
}
