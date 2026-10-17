//
//  BoxBookTests.swift
//  FinvestLens — FeatureUI
//
//  A book opened from Box, end to end against a Box that behaves like Box:
//  etags that move on each upload, versions a download can name, 412 for a
//  stale If-Match, 409 for a name already taken or a full account, 404 for a
//  file or folder that is gone, chunked sessions that check every part.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import CryptoKit
import SQLite3
import FinvestLensEngine
import FinvestLensCloud
@testable import FinvestLensUI

/// A Box account in memory, answering the requests `BoxClient` and
/// `BoxAuthenticator` make.
final class FakeBox: BoxTransport, @unchecked Sendable {
    struct File {
        var name: String
        var parent: String
        /// Every version, oldest first.
        var versions: [Data]
        /// Changes that moved the etag without a new version — a rename, if
        /// Box's etag moves for one (its reference does not say).
        var metadataChanges = 0
        var data: Data { versions.last ?? Data() }
        var etag: Int { versions.count + metadataChanges }
    }
    struct Session {
        var file: String?          // a new version of this file…
        var folder: String?        // …or a new file in this folder
        var name: String
        var size: Int64
        var parts: [Int64: Data] = [:]
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var folders: Set<String> = ["0", "42"]
    private var sessions: [String: Session] = [:]
    private var nextID = 1000
    private var log: [String] = []
    private var ifMatches: [String?] = []
    private var isOffline = false
    private var partsAccepted = 0
    private var offsets: [Int64] = []

    /// Part size for chunked sessions — small, so a test book needs several.
    var partSize: Int64 = 4096
    /// After this many parts, further parts fail with a 500.
    var failPartsAfter: Int?
    /// Uploads are refused as a full account would be (409).
    var storageFull = false
    /// Uploads of new versions are refused outright (403).
    var forbidUploads = false
    /// Every request waits this long before answering.
    var stall: Duration = .zero
    /// The token endpoint refuses a refresh, as Box does for a spent grant.
    var refuseRefresh = false
    /// Downloads of a file's content wait this long before answering.
    var stallDownloads: Duration = .zero
    /// Who `/users/me` says is signed in.
    var user = (id: "U1", login: "pat@example.com")
    /// The next new version is kept, and its answer lost on the way back.
    var loseNextUploadAnswer = false

    var requests: [String] { lock.withLock { log } }
    var uploadIfMatches: [String?] { lock.withLock { ifMatches } }
    /// The part offsets Box acknowledged, in the order they came.
    var partOffsets: [Int64] { lock.withLock { offsets } }
    var offline: Bool {
        get { lock.withLock { isOffline } }
        set { lock.withLock { isOffline = newValue } }
    }
    var fileCount: Int { lock.withLock { files.count } }
    func file(_ id: String) -> File? { lock.withLock { files[id] } }
    func files(in parent: String) -> [(id: String, file: File)] {
        lock.withLock { files.filter { $0.value.parent == parent }.map { ($0.key, $0.value) } }
    }

    @discardableResult
    func add(_ name: String, data: Data, in parent: String = "42") -> String {
        lock.withLock {
            nextID += 1
            files[String(nextID)] = File(name: name, parent: parent, versions: [data])
            return String(nextID)
        }
    }

    /// Another device saves a new version.
    func saveFromElsewhere(_ id: String, data: Data) {
        lock.withLock { files[id]?.versions.append(data) }
    }

    /// Box forgets every upload session — they expired, or it dropped them.
    func dropSessions() { lock.withLock { sessions.removeAll() } }

    /// The id the next file or session Box makes will have.
    var nextFileID: String { lock.withLock { String(nextID + 1) } }

    /// Someone renames the file on Box.
    func rename(_ id: String, to name: String, movesEtag: Bool) {
        lock.withLock {
            files[id]?.name = name
            if movesEtag { files[id]?.metadataChanges += 1 }
        }
    }

    /// Another device deletes the file, or its folder.
    func remove(_ id: String) { lock.withLock { _ = files.removeValue(forKey: id) } }
    func removeFolder(_ id: String) {
        lock.withLock {
            folders.remove(id)
            files = files.filter { $0.value.parent != id }
        }
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if stall > .zero { try await Task.sleep(for: stall) }
        if stallDownloads > .zero, (request.httpMethod ?? "GET") == "GET",
           request.url?.path.hasSuffix("/content") == true {
            try await Task.sleep(for: stallDownloads)
        }
        return try lock.withLock { try answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if isOffline { throw URLError(.notConnectedToInternet) }
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        log.append("\(method) \(url.host ?? "")\(url.path)"
                   + (query.first { $0.name == "version" }.map { "?version=\($0.value ?? "")" } ?? ""))
        func reply(_ status: Int, _ json: String) -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!)
        }
        func entry(_ id: String, _ file: File) -> String {
            let name = String(data: try! JSONEncoder().encode(file.name), encoding: .utf8)!
            return #"{"id":"\#(id)","type":"file","name":\#(name),"etag":"\#(file.etag)","size":\#(file.data.count),"sha1":"\#(Self.sha1Hex(file.data))","parent":{"id":"\#(file.parent)"},"file_version":{"id":"v\#(id)-\#(file.versions.count)"}}"#
        }
        let notFound = reply(404, #"{"code":"not_found","message":"Not Found"}"#)
        let full = reply(409, #"{"code":"storage_limit_exceeded","message":"Account storage limit reached"}"#)
        let forbidden = reply(403, #"{"code":"access_denied_insufficient_permissions","message":"Access denied"}"#)

        // The token endpoint, for the authenticator's refresh.
        if url.path.hasSuffix("/oauth2/token") {
            return refuseRefresh ? reply(400, #"{"error":"invalid_grant"}"#)
                : reply(200, #"{"access_token":"AT2","refresh_token":"RT2","expires_in":3600}"#)
        }
        if url.path.hasSuffix("/users/me") {
            return reply(200, #"{"type":"user","id":"\#(user.id)","name":"Pat","login":"\#(user.login)"}"#)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        // After the version: `api.box.com/2.0/…` and `upload.box.com/api/2.0/…`.
        let route = parts.firstIndex(of: "2.0").map { Array(parts[($0 + 1)...]) } ?? parts

        if method == "GET", route.count == 3, route[0] == "folders", route[2] == "items" {
            guard folders.contains(route[1]) else { return notFound }
            let entries = files.filter { $0.value.parent == route[1] }.map { entry($0.key, $0.value) }
            return reply(200, #"{"entries":[\#(entries.joined(separator: ","))],"next_marker":null}"#)
        }
        if method == "GET", route.count == 2, route[0] == "files" {
            guard let file = files[route[1]] else { return notFound }
            return reply(200, entry(route[1], file))
        }
        if method == "GET", route.count == 3, route[0] == "files", route[2] == "content" {
            guard let file = files[route[1]] else { return notFound }
            var data = file.data
            if let version = query.first(where: { $0.name == "version" })?.value {
                guard version.hasPrefix("v\(route[1])-"),
                      let index = Int(version.split(separator: "-").last ?? ""),
                      (1...file.versions.count).contains(index) else { return notFound }
                data = file.versions[index - 1]
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        if method == "POST", route.count == 3, route[0] == "files", route[2] == "content" {
            let id = route[1]
            guard var file = files[id] else { return notFound }
            let ifMatch = request.value(forHTTPHeaderField: "If-Match")
            ifMatches.append(ifMatch)
            if storageFull { return full }
            if forbidUploads { return forbidden }
            if let ifMatch, ifMatch != String(file.etag) { return reply(412, "{}") }
            file.versions.append(try Self.uploadedFile(in: request))
            // "If specified, the file will be renamed when the new version is
            // uploaded."
            if let name = try Self.attributes(in: request)["name"] as? String, !name.isEmpty { file.name = name }
            files[id] = file
            if loseNextUploadAnswer {
                loseNextUploadAnswer = false
                throw URLError(.networkConnectionLost)
            }
            return reply(200, #"{"total_count":1,"entries":[\#(entry(id, file))]}"#)
        }
        if method == "POST", route == ["files", "content"] {
            let attributes = try Self.attributes(in: request)
            let name = attributes["name"] as? String ?? ""
            let parent = (attributes["parent"] as? [String: Any])?["id"] as? String ?? "0"
            guard folders.contains(parent) else { return notFound }
            if storageFull { return full }
            if files.values.contains(where: { $0.parent == parent && $0.name.lowercased() == name.lowercased() }) {
                return reply(409, #"{"code":"item_name_in_use","message":"Item with the same name already exists"}"#)
            }
            nextID += 1
            let file = File(name: name, parent: parent, versions: [try Self.uploadedFile(in: request)])
            files[String(nextID)] = file
            return reply(201, #"{"total_count":1,"entries":[\#(entry(String(nextID), file))]}"#)
        }
        // Chunked uploads.
        if method == "POST", route.count == 3, route[0] == "files", route[2] == "upload_sessions" {
            guard let file = files[route[1]] else { return notFound }
            if forbidUploads { return forbidden }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            return openSession(Session(file: route[1], folder: nil, name: file.name,
                                       size: (body["file_size"] as? NSNumber)?.int64Value ?? 0), url: url)
        }
        if method == "POST", route == ["files", "upload_sessions"] {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let folder = body["folder_id"] as? String ?? "0"
            let name = body["file_name"] as? String ?? ""
            guard folders.contains(folder) else { return notFound }
            if storageFull { return full }
            if files.values.contains(where: { $0.parent == folder && $0.name.lowercased() == name.lowercased() }) {
                return reply(409, #"{"code":"item_name_in_use","message":"Item with the same name already exists"}"#)
            }
            return openSession(Session(file: nil, folder: folder, name: name,
                                       size: (body["file_size"] as? NSNumber)?.int64Value ?? 0), url: url)
        }
        if method == "PUT", route.count == 3, route[0] == "files", route[1] == "upload_sessions" {
            guard var session = sessions[route[2]] else { return notFound }
            if let limit = failPartsAfter, partsAccepted >= limit { return reply(500, #"{"code":"internal"}"#) }
            let body = request.httpBody ?? Data()
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            // "bytes start-end/total": the start a multiple of the part size,
            // every part but the last exactly the part size.
            let numbers = range.dropFirst("bytes ".count).split(whereSeparator: { $0 == "-" || $0 == "/" })
                .compactMap { Int64($0) }
            guard numbers.count == 3, numbers[0] % partSize == 0, numbers[2] == session.size,
                  numbers[1] - numbers[0] + 1 == Int64(body.count),
                  Int64(body.count) == partSize || numbers[1] == session.size - 1,
                  request.value(forHTTPHeaderField: "Digest")
                    == "sha=\(Data(Insecure.SHA1.hash(data: body)).base64EncodedString())" else {
                return reply(416, #"{"code":"range_not_satisfiable"}"#)
            }
            guard session.parts[numbers[0]] == nil else {
                return reply(416, #"{"code":"range_overlaps_existing_part"}"#)
            }
            session.parts[numbers[0]] = body
            sessions[route[2]] = session
            partsAccepted += 1
            offsets.append(numbers[0])
            return reply(200, #"{"part":{"part_id":"P\#(numbers[0])","offset":\#(numbers[0]),"size":\#(body.count),"sha1":"\#(Self.sha1Hex(body))"}}"#)
        }
        if method == "POST", route.count == 4, route[1] == "upload_sessions", route[3] == "commit" {
            guard let session = sessions[route[2]] else { return notFound }
            let whole = session.parts.sorted { $0.key < $1.key }.reduce(into: Data()) { $0.append($1.value) }
            guard Int64(whole.count) == session.size,
                  request.value(forHTTPHeaderField: "Digest")
                    == "sha=\(Data(Insecure.SHA1.hash(data: whole)).base64EncodedString())" else {
                return reply(400, #"{"code":"bad_digest"}"#)
            }
            sessions[route[2]] = nil
            if let id = session.file {
                guard var file = files[id] else { return notFound }
                let ifMatch = request.value(forHTTPHeaderField: "If-Match")
                ifMatches.append(ifMatch)
                if let ifMatch, ifMatch != String(file.etag) { return reply(412, "{}") }
                file.versions.append(whole)
                files[id] = file
                return reply(201, #"{"total_count":1,"entries":[\#(entry(id, file))]}"#)
            }
            nextID += 1
            let file = File(name: session.name, parent: session.folder ?? "0", versions: [whole])
            files[String(nextID)] = file
            return reply(201, #"{"total_count":1,"entries":[\#(entry(String(nextID), file))]}"#)
        }
        if method == "DELETE", route.count == 3, route[1] == "upload_sessions" {
            sessions[route[2]] = nil
            return reply(204, "")
        }
        return notFound
    }

    private func openSession(_ session: Session, url: URL) -> (Data, HTTPURLResponse) {
        nextID += 1
        let id = "S\(nextID)"
        sessions[id] = session
        let base = "https://upload.box.com/api/2.0/files/upload_sessions/\(id)"
        let total = (session.size + partSize - 1) / partSize
        let json = #"{"id":"\#(id)","type":"upload_session","part_size":\#(partSize),"total_parts":\#(total),"session_expires_at":"2099-01-01T00:00:00Z","session_endpoints":{"upload_part":"\#(base)","commit":"\#(base)/commit","abort":"\#(base)"}}"#
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: [:])!)
    }

    // MARK: Reading an upload the way Box does

    private static func parts(of request: URLRequest) throws -> [(headers: String, body: Data)] {
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let boundary = type.components(separatedBy: "boundary=").last, let body = request.httpBody else {
            throw URLError(.badURL)
        }
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [(String, Data)] = []
        var cursor = body.startIndex
        while let start = body.range(of: delimiter, in: cursor..<body.endIndex) {
            let afterDelimiter = start.upperBound
            if body[afterDelimiter...].starts(with: Data("--".utf8)) { break }
            guard let headerEnd = body.range(of: Data("\r\n\r\n".utf8), in: afterDelimiter..<body.endIndex),
                  let next = body.range(of: Data("\r\n--\(boundary)".utf8), in: headerEnd.upperBound..<body.endIndex)
            else { break }
            let headers = String(data: body[afterDelimiter..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            parts.append((headers, body[headerEnd.upperBound..<next.lowerBound]))
            cursor = next.lowerBound + 2
        }
        return parts
    }

    /// Box refuses attributes that come after the file.
    private static func attributes(in request: URLRequest) throws -> [String: Any] {
        let parts = try parts(of: request)
        guard let first = parts.first, first.headers.contains(#"name="attributes""#),
              let object = try JSONSerialization.jsonObject(with: first.body) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }

    private static func uploadedFile(in request: URLRequest) throws -> Data {
        _ = try attributes(in: request)
        guard let file = try parts(of: request).first(where: { $0.headers.contains(#"name="file""#) }) else {
            throw URLError(.cannotParseResponse)
        }
        return Data(file.body)
    }
}

/// A Keychain that refuses, as it does an unsigned build (-34018).
final class RefusingSecretStore: BoxClientSecretStoring, @unchecked Sendable {
    func secret() -> String? { nil }
    func setSecret(_ secret: String?) throws { throw BoxKeychainError(status: -34018) }
}

@MainActor
@Suite("Books on Box", .serialized)
struct BoxBookTests {

    /// A model whose Box is `box` and whose library, settings and secret are
    /// its own — nothing here reads the real Keychain or preferences.
    private func makeModel(_ box: FakeBox, tokensExpire: Bool = false)
        -> (AppModel, BoxLibrary, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxLibrary-\(UUID().uuidString)", isDirectory: true)
        let suite = "finvestlens.tests.box.\(UUID().uuidString)"
        let library = BoxLibrary(root: root)
        let model = AppModel(authenticator: AllowAllAuthenticator())
        model.boxDefaults = UserDefaults(suiteName: suite)!
        model.boxSecretStore = InMemoryBoxClientSecretStore("s3cret")
        model.boxClientID = "client"
        model.boxTransport = box
        model.boxTokenStore = InMemoryBoxTokenStore(BoxTokens(
            accessToken: "AT", refreshToken: "RT",
            expiresAt: tokensExpire ? .distantPast : .distantFuture))
        model.boxLibrary = library
        return (model, library, {
            model.close()
            for task in model.boxRetryTasks.values { task.cancel() }
            for task in model.boxWorkTasks.values { task.cancel() }
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        })
    }

    /// A real book, as Box would hold it.
    private func bookBytes(accounts: [String] = ["Bank"]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let seed = AppModel(authenticator: AllowAllAuthenticator())
        try seed.newDocument(at: url)
        for name in accounts { _ = seed.addAccount(name: name, type: .bank) }
        try seed.save()
        seed.close()
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    /// An SQLite database that is not a FinvestLens book — a GnuCash one.
    private func foreignSQLite() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw URLError(.cannotCreateFile) }
        sqlite3_exec(db, "CREATE TABLE gnclock (hostname TEXT); CREATE TABLE splits (guid TEXT); CREATE TABLE slots (id INTEGER);", nil, nil, nil)
        sqlite3_close(db)
        return try Data(contentsOf: url)
    }

    private func item(_ id: String, _ name: String = "Household.finvestlens") -> BoxItem {
        BoxItem(id: id, kind: .file, name: name)
    }

    private func names(_ model: AppModel) -> [String] {
        model.accountTree.flatMap { [$0.name] + ($0.children ?? []).map(\.name) }
    }

    @Test("Saving any other book never sends it to Box")
    func otherBooksStayHome() async throws {
        // The first version kept one "book from Box" link and uploaded
        // whatever book was open while it was set.
        let box = FakeBox()
        let original = try bookBytes()
        let id = box.add("Household.finvestlens", data: original)
        let (model, _, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        #expect(model.openBoxFileID == id)
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: local) }
        model.newBook(at: local)
        await model.finishBoxWork(within: .seconds(5))
        let before = box.requests.count
        #expect(model.openBoxFileID == nil)
        _ = model.addAccount(name: "Cash", type: .cash)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        #expect(!box.requests.dropFirst(before).contains { $0.hasPrefix("POST") }, "\(box.requests)")
        #expect(box.file(id)?.data == original)
    }

    @Test("⌘S and closing send a Box book up; autosave keeps it on this device")
    func explicitSavesOnly() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        #expect(copy.lastPathComponent == "Household.finvestlens")

        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: false)          // autosave
        await model.finishBoxWork(within: .seconds(5))
        #expect(box.file(id)?.etag == 1, "autosave sends nothing")
        #expect(model.openBoxBookNeedsUpload, "but ⌘S has something to send")

        await model.saveWithStatus(interactive: true)           // ⌘S
        await model.finishBoxWork(within: .seconds(5))
        #expect(box.uploadIfMatches == ["1"])
        #expect(box.file(id)?.etag == 2)
        #expect(box.file(id)?.data == (try Data(contentsOf: copy)))
        #expect(!model.openBoxBookNeedsUpload)

        _ = model.addAccount(name: "Travel", type: .bank)
        await model.saveWithStatus(interactive: false)          // autosave again
        #expect(model.saveAndCloseIfOpen())                     // then close
        await model.finishBoxWork(within: .seconds(5))
        #expect(box.file(id)?.etag == 3, "closing sends the autosaved work")
        let link = try #require(library.record(id))
        #expect(!link.uploadRequested)
        #expect(box.file(id)?.data == (try Data(contentsOf: library.copyURL(for: link))))
    }

    @Test("A copy that is current is not downloaded again")
    func currentCopyIsKept() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, _, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        model.close()
        let before = box.requests.count
        await model.openBoxBook(item(id), inFolder: "42")
        let after = box.requests.dropFirst(before)
        #expect(after.contains("GET api.box.com/2.0/files/\(id)"))
        #expect(!after.contains { $0.contains("/content") })
        #expect(model.isOpen)
    }

    @Test("A newer version saved elsewhere comes down — exactly that version — before the book opens")
    func newerVersionComesDown() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        model.close()
        box.saveFromElsewhere(id, data: try bookBytes(accounts: ["Bank", "Brokerage"]))

        await model.openBook(at: copy)                          // as Recents does
        #expect(model.isOpen)
        #expect(names(model).contains("Brokerage"))
        #expect(box.requests.contains("GET api.box.com/2.0/files/\(id)/content?version=v\(id)-2"))
        #expect(library.record(id)?.etag == "2")
    }

    @Test("Something that isn't a book never replaces the copy")
    func notABookIsRefused() async throws {
        let box = FakeBox()
        let empty = box.add("Empty.finvestlens", data: Data())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(empty, "Empty.finvestlens"), inFolder: "42")
        #expect(!model.isOpen)
        #expect(model.documentError != nil)
        #expect(library.record(empty) == nil)
        model.documentError = nil

        // A real book here, then a GnuCash SQLite file put over it on Box.
        let id = box.add("Household.finvestlens", data: try bookBytes())
        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        model.close()
        let kept = try Data(contentsOf: copy)
        box.saveFromElsewhere(id, data: try foreignSQLite())
        await model.openBoxBook(item(id), inFolder: "42")
        #expect(try Data(contentsOf: copy) == kept, "the copy is untouched")
        #expect(library.record(id)?.etag == "1")
    }

    @Test("An explicit save made offline goes up when the network is back, and is never fetched over")
    func offlineExplicitSaveWaits() async throws {
        let box = FakeBox()
        let original = try bookBytes()
        let id = box.add("Household.finvestlens", data: original)
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        box.offline = true
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        #expect(library.record(id)?.uploadRequested == true)
        #expect(model.toast?.kind == .failure)
        #expect(model.boxRetryTasks[id] != nil, "a retry is on its way")
        model.close()

        box.offline = false
        let before = box.requests.count
        await model.openBoxBook(item(id), inFolder: "42")
        await model.finishBoxWork(within: .seconds(5))
        #expect(!box.requests.dropFirst(before).contains { $0.hasPrefix("GET") && $0.contains("/content") })
        let link = try #require(library.record(id))
        #expect(!link.uploadRequested)
        #expect(box.file(id)?.data == (try Data(contentsOf: library.copyURL(for: link))))
        #expect(box.file(id)?.data != original)
    }

    @Test("A failed upload waits for its retry, rather than trying again at once")
    func failedUploadWaitsForItsRetry() async throws {
        // On a connected machine the network monitor's first report is
        // "satisfied"; taken for the network coming back, it cancelled the
        // retry just scheduled and tried again straight away.
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, _, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        box.offline = true
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        try await Task.sleep(for: .milliseconds(500))
        await model.finishBoxWork(within: .seconds(5))
        #expect(model.boxRetryAttempts[id] == 1, "one failure, one retry waiting")
        #expect(model.boxRetryTasks[id] != nil)
    }

    @Test("A copy changed by something else — finlab, a crash — is noticed by its bytes")
    func outsideWriterIsNoticed() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        model.close()
        // Another model, which knows nothing of this library, edits the copy.
        let other = AppModel(authenticator: AllowAllAuthenticator())
        try await other.open(at: copy)
        _ = other.addAccount(name: "Ingested", type: .bank)
        try other.save()
        other.close()
        // Meanwhile another device saves to Box.
        box.saveFromElsewhere(id, data: try bookBytes(accounts: ["Bank", "Elsewhere"]))

        await model.openBoxBook(item(id), inFolder: "42")
        #expect(names(model).contains("Ingested"), "the work here is not fetched over")
        #expect(model.openBoxBookNeedsUpload)
        #expect(library.record(id)?.etag == "1")
    }

    @Test("Keep Both puts this device's version beside another device's, and never replaces it")
    func conflictKeepsBoth() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let elsewhere = try bookBytes(accounts: ["Bank", "Brokerage"])
        box.saveFromElsewhere(id, data: elsewhere)
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        let conflict = try #require(model.boxConflict)
        #expect(conflict.reason == .changedOnBox)
        #expect(box.file(id)?.data == elsewhere)

        await model.resolveBoxConflict(conflict)
        #expect(box.fileCount == 2)
        #expect(box.file(id)?.data == elsewhere, "still untouched")
        let copy = try #require(box.files(in: "42").first { $0.id != id })
        #expect(copy.file.name.hasPrefix("Household (conflicted copy "))
        #expect(library.record(id) == nil)
        let open = try #require(model.documentURL)
        #expect(library.fileID(ofCopyAt: open) == copy.id, "work carries on in the new book")
        #expect(copy.file.data == (try Data(contentsOf: open)))
        #expect(names(model).contains("Savings"))
    }

    @Test("A book being resolved is not opened meanwhile")
    func resolvingBookStaysShut() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }
        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        model.close()
        model.boxResolving.insert(id)
        await model.openBook(at: copy)
        #expect(!model.isOpen)
        #expect(library.record(id) != nil)
    }

    @Test("An interrupted Keep Both is finished with the copy Box already has, not a second one")
    func keepBothAdoptsEarlierCopy() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        model.close()
        box.saveFromElsewhere(id, data: try bookBytes(accounts: ["Bank", "Brokerage"]))
        // The earlier attempt reached Box and then the app was quit.
        let earlier = box.add("Household (conflicted copy 2026-10-17 09.00).finvestlens",
                              data: try Data(contentsOf: copy))
        var link = try #require(library.record(id))
        link.conflict = .changedOnBox
        try library.write(link)

        let before = box.requests.count
        await model.resolveBoxConflict(BoxConflict(fileID: id, bookName: "Household", reason: .changedOnBox))
        #expect(!box.requests.dropFirst(before).contains { $0.hasPrefix("POST upload.box.com") })
        #expect(library.record(earlier) != nil)
        #expect(box.fileCount == 2)
    }

    @Test("A book deleted on Box goes back up under its own name; a deleted folder falls back to the top")
    func goneBookGoesBackUp() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, _, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        box.removeFolder("42")
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        let conflict = try #require(model.boxConflict)
        #expect(conflict.reason == .goneFromBox)

        await model.resolveBoxConflict(conflict)
        let back = try #require(box.files(in: "0").first)
        #expect(back.file.name == "Household.finvestlens")
        #expect(model.openBoxFileID == back.id)
    }

    @Test("A full account is said in Box's words, and the book is not sent again under other names")
    func fullAccountIsSaid() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        box.remove(id)
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        let conflict = try #require(model.boxConflict)
        box.storageFull = true
        let before = box.requests.count
        await model.resolveBoxConflict(conflict)
        let uploads = box.requests.dropFirst(before).filter { $0 == "POST upload.box.com/api/2.0/files/content" }
        #expect(uploads.count == 1, "\(uploads)")
        #expect(model.documentError?.message.contains("Account storage limit reached") == true)
        #expect(library.record(id)?.conflict == .goneFromBox, "nothing lost; the question stays")
    }

    @Test("A refusal a retry won't cure is said, and not retried by itself")
    func permanentRefusal() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        box.forbidUploads = true
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        #expect(model.documentError?.message.contains("Access denied") == true)
        #expect(library.record(id)?.lastRefusal != nil)
        #expect(model.boxRetryTasks[id] == nil)
        #expect(model.openBoxBookNeedsUpload, "⌘S stays available to try again")
    }

    @Test("A large book goes up in parts, and an interrupted upload goes on from its last part")
    func chunkedUploadResumes() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }
        model.boxChunkThreshold = 1024

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        _ = model.addAccount(name: "Savings", type: .bank)
        box.failPartsAfter = 3
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        let pending = try #require(library.record(id)?.pendingUpload)
        #expect(pending.parts.count == 3)

        box.failPartsAfter = nil
        model.boxRetryTasks[id]?.cancel()
        model.resumeBoxUploads()
        await model.finishBoxWork(within: .seconds(10))
        #expect(box.file(id)?.etag == 2)
        #expect(box.file(id)?.data == (try Data(contentsOf: copy)))
        #expect(Set(box.partOffsets).count == box.partOffsets.count, "no part sent twice")
        #expect(library.record(id)?.pendingUpload == nil)
    }

    @Test("An upload session Box no longer has is begun again, and never taken for a deleted book",
          arguments: [0, 3])
    func lostSessionStartsAgain(partsSent: Int) async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }
        model.boxChunkThreshold = 1024

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        _ = model.addAccount(name: "Savings", type: .bank)
        box.failPartsAfter = partsSent
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        #expect(library.record(id)?.pendingUpload?.parts.count == partsSent)

        box.failPartsAfter = nil
        box.dropSessions()
        model.boxRetryTasks[id]?.cancel()
        model.resumeBoxUploads()
        await model.finishBoxWork(within: .seconds(10))
        #expect(library.record(id)?.conflict == nil)
        #expect(model.boxConflict == nil)
        #expect(box.file(id)?.etag == 2)
        #expect(box.file(id)?.data == (try Data(contentsOf: copy)))
        #expect(library.record(id)?.pendingUpload == nil)
    }

    @Test("A Keep Both that cannot move the copy opens the book again, and keeps the question")
    func keepBothMoveFailureReopens() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        box.saveFromElsewhere(id, data: try bookBytes(accounts: ["Bank", "Brokerage"]))
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        let conflict = try #require(model.boxConflict)
        // A file where the new book's folder would go: the move fails.
        let blocker = copy.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(box.nextFileID)
        try Data().write(to: blocker)

        await model.resolveBoxConflict(conflict)
        #expect(model.documentError?.message.contains("still saved on this device") == true)
        #expect(model.documentURL.map { BoxLibrary.samePath($0, copy) } == true, "the book is back on screen")
        #expect(names(model).contains("Savings"))
        #expect(library.record(id)?.conflict == .changedOnBox, "the question stays for the next ⌘S")
        #expect(model.boxConflict == nil, "not over the alert that says what went wrong")
        #expect(!model.boxResolving.contains(id))
    }

    @Test("A book from one Box account is never sent to another, Keep Both included")
    func bookStaysInItsAccount() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        #expect(library.record(id)?.accountID == "U1")

        // Another account connected: Box would answer this book as missing.
        box.user = (id: "U2", login: "work@example.com")
        model.boxTokenStore = InMemoryBoxTokenStore(BoxTokens(accessToken: "AT", refreshToken: "RT",
                                                              expiresAt: .distantFuture))
        let before = box.requests.count
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        #expect(!box.requests.dropFirst(before).contains { $0.hasPrefix("POST") }, "\(box.requests)")
        #expect(model.toast?.message.contains("pat@example.com") == true)
        #expect(library.record(id)?.uploadRequested == true, "it goes when that account is back")
        #expect(library.record(id)?.conflict == nil)

        var link = try #require(library.record(id))
        link.conflict = .goneFromBox
        try library.write(link)
        await model.resolveBoxConflict(BoxConflict(fileID: id, bookName: "Household", reason: .goneFromBox))
        #expect(!box.requests.dropFirst(before).contains { $0.hasPrefix("POST") })
        #expect(model.documentError?.message.contains("pat@example.com") == true)
        link.conflict = nil
        try library.write(link)
        model.documentError = nil

        box.user = (id: "U1", login: "pat@example.com")
        model.boxTokenStore = InMemoryBoxTokenStore(BoxTokens(accessToken: "AT", refreshToken: "RT",
                                                              expiresAt: .distantFuture))
        model.resumeBoxUploads()
        await model.finishBoxWork(within: .seconds(5))
        #expect(box.file(id)?.data == (try Data(contentsOf: copy)))
    }

    @Test("An upload whose answer was lost is seen to have landed, not taken for another device's save")
    func lostAnswerIsNotAConflict() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        _ = model.addAccount(name: "Savings", type: .bank)
        box.loseNextUploadAnswer = true
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        #expect(box.file(id)?.versions.count == 2, "Box kept it")
        #expect(library.record(id)?.uploadRequested == true, "the app never heard")

        model.boxRetryTasks[id]?.cancel()
        model.resumeBoxUploads()
        await model.finishBoxWork(within: .seconds(5))
        #expect(model.boxConflict == nil)
        #expect(library.record(id)?.conflict == nil)
        #expect(box.file(id)?.versions.count == 2, "not sent a second time")
        #expect(library.record(id)?.etag == "2")
        #expect(library.record(id)?.uploadRequested == false)
        #expect(box.file(id)?.data == (try Data(contentsOf: copy)))
    }

    @Test("A rename made on Box is kept by the next save, whether or not it moves the etag",
          arguments: [false, true])
    func renameOnBoxIsKept(movesEtag: Bool) async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        box.rename(id, to: "Household 2026.finvestlens", movesEtag: movesEtag)
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        #expect(model.boxConflict == nil, "a rename is not another device's save")
        #expect(box.file(id)?.name == "Household 2026.finvestlens", "not renamed back")
        #expect(box.file(id)?.data == (try Data(contentsOf: copy)))
        #expect(library.record(id)?.fileName == "Household 2026.finvestlens")
        #expect(model.documentURL == copy, "the copy here keeps its name")
    }

    @Test("Opening a book from Box can be cancelled, and the book that was open stays")
    func cancelWhileOpening() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: local) }
        model.newBook(at: local)
        let open = try #require(model.documentURL)

        box.stallDownloads = .seconds(30)
        let opening = Task { await model.openBoxBook(item(id), inFolder: "42") }
        for _ in 0..<500 {
            if case .downloading = model.boxOpenPhase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .downloading = model.boxOpenPhase else {
            Issue.record("the download never started")
            return
        }
        let started = ContinuousClock.now
        model.cancelBoxOpen()
        await opening.value
        #expect(ContinuousClock.now - started < .seconds(5), "Cancel does not wait for the download")
        #expect(model.documentURL == open)
        #expect(model.boxOpenPhase == nil)
        #expect(model.openingURL == nil)
        #expect(model.documentError == nil, "the person chose this; nothing to report")
        #expect(library.record(id) == nil, "nothing came down, so nothing is kept")
    }

    @Test("⌘S during an upload already running is told how it went")
    func explicitSaveDuringUploadIsAnswered() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }

        await model.openBoxBook(item(id), inFolder: "42")
        let copy = try #require(model.documentURL)
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: false)
        // An upload started without anyone asking to hear — at launch, or
        // when the network came back.
        var link = try #require(library.record(id))
        link.uploadRequested = true
        try library.write(link)
        box.stall = .milliseconds(300)
        model.resumeBoxUploads()
        #expect(model.hasBoxWorkInFlight)
        await model.saveWithStatus(interactive: true)
        #expect(model.hasBoxWorkInFlight, "the ⌘S arrived while the first upload ran")
        await model.finishBoxWork(within: .seconds(15))
        #expect(box.file(id)?.data == (try Data(contentsOf: copy)))
        #expect(model.toast?.message == String(localized: "Uploaded to Box."))
    }

    @Test("A client secret the Keychain won't keep is said in Settings, not lost without a word")
    func secretTheKeychainRefusesIsSaid() async throws {
        let box = FakeBox()
        let (model, _, cleanup) = makeModel(box)
        defer { cleanup() }

        model.boxSecretStore = RefusingSecretStore()
        model.boxClientSecret = "another"
        let failure = try #require(model.boxSecretFailure)
        #expect(failure.contains("The Keychain couldn’t keep the Box credential"), "\(failure)")
        #expect(model.boxClientSecret == "another", "held for this run")

        model.boxSecretStore = InMemoryBoxClientSecretStore()
        model.boxClientSecret = "kept"
        #expect(model.boxSecretFailure == nil)
    }

    @Test("Removing a copy keeps its audit log and its record; a copy with unsent work stays")
    func removingACopy() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, library, cleanup) = makeModel(box)
        defer { cleanup() }
        let book = item(id)

        await model.openBoxBook(book, inFolder: "42")
        let copy = try #require(model.documentURL)
        await #expect(throws: BookFileError.self) { try await model.removeBoxCopy(of: book) }
        _ = model.addAccount(name: "Savings", type: .bank)
        await model.saveWithStatus(interactive: false)
        model.close()
        await #expect(throws: BookFileError.self) { try await model.removeBoxCopy(of: book) }

        await model.openBoxBook(book, inFolder: "42")
        await model.saveWithStatus(interactive: true)
        await model.finishBoxWork(within: .seconds(5))
        model.close()
        let audit = copy.deletingPathExtension().appendingPathExtension("audit")
        try Data("entries".utf8).write(to: audit)
        try await model.removeBoxCopy(of: book)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: audit.path), "the device's audit log stays")
        #expect(library.record(id) != nil)
        #expect(model.boxCopyState(of: book) == .notOnThisDevice)
    }

    @Test("Waiting for Box before quitting ends at its limit, however long the upload")
    func waitingHasALimit() async throws {
        let box = FakeBox()
        let id = box.add("Household.finvestlens", data: try bookBytes())
        let (model, _, cleanup) = makeModel(box)
        defer { cleanup() }
        await model.openBoxBook(item(id), inFolder: "42")
        _ = model.addAccount(name: "Savings", type: .bank)
        box.stall = .seconds(20)
        await model.saveWithStatus(interactive: true)
        let started = ContinuousClock.now
        await model.finishBoxWork(within: .milliseconds(300))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(model.hasBoxWorkInFlight, "the upload goes on; only the wait ended")
    }

    @Test("A grant Box refuses shows as signed out, everywhere that asks")
    func refusedGrantSignsOut() async throws {
        let box = FakeBox()
        box.refuseRefresh = true
        let (model, _, cleanup) = makeModel(box, tokensExpire: true)
        defer { cleanup() }
        #expect(model.isBoxSignedIn)
        let revision = model.boxSessionRevision
        await #expect(throws: BoxError.self) { _ = try await model.boxFolderContents("42") }
        for _ in 0..<20 { await Task.yield() }
        #expect(!model.isBoxSignedIn)
        #expect(model.boxSessionRevision > revision)
    }
}

@Suite("Box library")
struct BoxLibraryTests {
    private let library = BoxLibrary(root: URL(fileURLWithPath: "/tmp/FinvestLens/Box", isDirectory: true))

    @Test("Only a copy in its Box file's folder is a Box book — by its path alone")
    func pathsAreTheLink() {
        let link = BoxBookLink(fileID: "123456", fileName: "Household.finvestlens")
        let copy = library.copyURL(for: link)
        #expect(copy.path == "/tmp/FinvestLens/Box/123456/Household.finvestlens")
        #expect(library.fileID(ofCopyAt: copy) == "123456")
        #expect(library.fileID(ofCopyAt: URL(fileURLWithPath: "/tmp/FinvestLens/Box/123456/../123456/Household.finvestlens")) == "123456")
        #expect(library.fileID(ofCopyAt: URL(fileURLWithPath: "/Users/someone/Household.finvestlens")) == nil)
        #expect(library.fileID(ofCopyAt: URL(fileURLWithPath: "/tmp/FinvestLens/Box/Household.finvestlens")) == nil)
        #expect(library.fileID(ofCopyAt: URL(fileURLWithPath: "/tmp/FinvestLens/Box/1/2/Household.finvestlens")) == nil)
        #expect(!BoxLibrary.isSafeFileID(".."))
        #expect(!BoxLibrary.isSafeFileID(""))
        #expect(!BoxLibrary.isSafeFileID("12/34"))
    }

    @Test("Uploads wake when the network comes back — not on the first report, or a change while connected")
    func networkReturnIsATransition() {
        let watch = BoxNetworkWatch()
        #expect(!watch.returned(true), "the first report is how things are")
        #expect(!watch.returned(true), "still connected: another Wi-Fi, a VPN")
        #expect(!watch.returned(false))
        #expect(watch.returned(true), "back")
        #expect(!watch.returned(true))
        let offlineAtStart = BoxNetworkWatch()
        #expect(!offlineAtStart.returned(false))
        #expect(offlineAtStart.returned(true))
    }

    @Test("A Box name becomes one safe file name")
    func localNames() {
        #expect(BoxLibrary.localName(for: "Household.finvestlens") == "Household.finvestlens")
        #expect(BoxLibrary.localName(for: "2026/27: Budget.finvestlens") == "2026-27- Budget.finvestlens")
        #expect(BoxLibrary.localName(for: "..hidden.finvestlens") == "hidden.finvestlens")
    }

    @Test("A conflicted copy is named for the book and the minute, and numbered on a retry")
    func conflictNames() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Sydney"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 5)))
        #expect(BoxLibrary.conflictCopyName(for: "Household.finvestlens", at: date, calendar: calendar)
                == "Household (conflicted copy 2026-10-17 09.05).finvestlens")
        #expect(BoxLibrary.conflictCopyName(for: "Household.finvestlens", at: date, attempt: 1, calendar: calendar)
                == "Household (conflicted copy 2026-10-17 09.05) 2.finvestlens")
    }

    @Test("Each record is its own file: one that cannot be read leaves the others")
    func recordsAreSeparate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxRecords-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BoxLibrary(root: root)
        var link = BoxBookLink(fileID: "77", fileName: "B.finvestlens", parentID: "42", etag: "3",
                               syncedSHA256: "abc", uploadRequested: true)
        link.conflict = .changedOnBox
        try library.write(link)
        try library.write(BoxBookLink(fileID: "78", fileName: "C.finvestlens"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("79"),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("79/\(BoxLibrary.recordName)"))
        let records = library.allRecords()
        #expect(records["77"] == link)
        #expect(records["78"] != nil)
        #expect(records["79"] == nil)
        #expect(records.count == 2)
    }
}
