//
//  BoxClient.swift
//  FinvestLens — Cloud
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit

/// One item in a Box folder.
public struct BoxItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case file, folder }
    public let id: String
    public let kind: Kind
    public let name: String
    /// Box's opaque version marker. Passed back as `If-Match` on upload so a
    /// save cannot overwrite a version the app has not seen.
    public let etag: String?
    public let size: Int64?
    public let modifiedAt: Date?
    /// The folder the item is in, where Box said (`parent.id`) — only on
    /// answers that asked for it.
    public let parentID: String?
    /// Box's id for the file's current version (`file_version.id`), so a
    /// download can ask for exactly the version whose etag was read rather
    /// than whatever is newest by the time the bytes are sent.
    public let versionID: String?
    /// The SHA-1 of the file's content, in hex, as Box computes it.
    public let sha1: String?

    public init(id: String, kind: Kind, name: String,
                etag: String? = nil, size: Int64? = nil, modifiedAt: Date? = nil,
                parentID: String? = nil, versionID: String? = nil, sha1: String? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.etag = etag; self.size = size; self.modifiedAt = modifiedAt
        self.parentID = parentID; self.versionID = versionID; self.sha1 = sha1
    }

    public var isBook: Bool { kind == .file && name.hasSuffix(".finvestlens") }
}

/// Whom a Box sign-in belongs to. A book's record is bound to it, so a book
/// from one Box account is never sent to another the person signs in to
/// later — to which Box answers as if the book were gone.
public struct BoxUser: Equatable, Sendable {
    public let id: String
    public let name: String?
    /// The account's primary email address, which is how a person tells
    /// their Box accounts apart.
    public let login: String?

    public init(id: String, name: String? = nil, login: String? = nil) {
        self.id = id; self.name = name; self.login = login
    }
}

/// A chunked upload Box has opened: where its parts go, how big each must
/// be, and how long it lasts. Codable so an upload interrupted by a quit or a
/// suspension can go on from its last part next time — a session lasts seven
/// days (Box's *Chunked Uploads* guide).
public struct BoxUploadSession: Codable, Equatable, Sendable {
    public var id: String
    public var partSize: Int64
    public var totalParts: Int
    public var uploadPartURL: URL
    public var commitURL: URL
    public var abortURL: URL
    public var expiresAt: Date?

    public init(id: String, partSize: Int64, totalParts: Int, uploadPartURL: URL,
                commitURL: URL, abortURL: URL, expiresAt: Date?) {
        self.id = id; self.partSize = partSize; self.totalParts = totalParts
        self.uploadPartURL = uploadPartURL; self.commitURL = commitURL
        self.abortURL = abortURL; self.expiresAt = expiresAt
    }
}

/// One part of a chunked upload, as Box acknowledged it — handed back,
/// all of them, to commit.
public struct BoxUploadedPart: Codable, Equatable, Sendable {
    public var partID: String
    public var offset: Int64
    public var size: Int64
    /// Hex, as Box returns it.
    public var sha1: String

    public init(partID: String, offset: Int64, size: Int64, sha1: String) {
        self.partID = partID; self.offset = offset; self.size = size; self.sha1 = sha1
    }
}

/// Reads and writes files in the signed-in user's Box account.
///
/// Every request goes through ``authorized(_:)``, which attaches a fresh
/// access token and retries once on a 401 — Box expires tokens on its own
/// schedule and a save is the worst moment to surface that as a failure.
///
/// The request shapes follow Box's API reference (developer.box.com, read
/// 17 Oct 2026): an upload's `attributes` part is required and must come
/// before the `file` part; the direct upload API is for files up to 50 MB and
/// the chunked upload API for files from 20 MB, in parts of exactly the
/// session's size, each with a SHA-1 `digest`, committed with the whole
/// file's SHA-1 and `If-Match`; a folder listing is paged by marker, up to
/// 1,000 entries a page; a download may name the version it wants.
public actor BoxClient {
    public static let apiBase = URL(string: "https://api.box.com/2.0")!
    public static let uploadBase = URL(string: "https://upload.box.com/api/2.0")!

    private let transport: BoxTransport
    private let auth: BoxAuthenticator
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(transport: BoxTransport, auth: BoxAuthenticator,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.auth = auth
        self.sleep = sleep
    }

    /// The fields asked of each entry in a listing. Asking for any field
    /// means Box sends only those (plus a few of its own).
    static let listingFields = "id,type,name,etag,size,modified_at,sha1"
    /// …and of one file, where its folder and current version matter too.
    static let fileFields = "id,type,name,etag,size,modified_at,parent,file_version,sha1"

    /// One entry as Box writes it, for every answer that carries items.
    struct Entry: Decodable {
        struct Reference: Decodable { let id: String }
        let id: String
        let type: String?
        let name: String
        let etag: String?
        let size: Int64?
        let modified_at: String?
        let parent: Reference?
        let file_version: Reference?
        let sha1: String?

        func item(defaultKind: BoxItem.Kind? = nil) -> BoxItem? {
            guard let kind = type.flatMap(BoxItem.Kind.init(rawValue:)) ?? defaultKind else { return nil }
            return BoxItem(id: id, kind: kind, name: name, etag: etag, size: size,
                           modifiedAt: modified_at.flatMap(BoxClient.parseDate),
                           parentID: parent?.id, versionID: file_version?.id, sha1: sha1)
        }
    }

    // MARK: The account

    /// Who is signed in (`GET /users/me`, "the user who is currently
    /// authenticated").
    public func currentUser(timeout: TimeInterval? = nil) async throws -> BoxUser {
        struct User: Decodable { let id: String; let name: String?; let login: String? }
        var components = URLComponents(url: Self.apiBase.appendingPathComponent("users/me"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "fields", value: "id,name,login")]
        var request = URLRequest(url: components.url!)
        if let timeout { request.timeoutInterval = timeout }
        let (data, _) = try await authorized(request)
        guard let user = try? JSONDecoder().decode(User.self, from: data) else {
            throw BoxError.malformedResponse("the signed-in user was not the expected shape")
        }
        return BoxUser(id: user.id, name: user.name, login: user.login)
    }

    // MARK: Browsing

    /// Every file and folder in a folder — `"0"` is Box's root.
    ///
    /// Paged by marker until Box stops handing one back. The page cap is a
    /// bound, not an expectation: a hundred pages is a hundred thousand
    /// entries, and a server that kept returning markers must not keep this
    /// loop alive. Web links are left out — they are neither books nor
    /// folders.
    public func items(inFolder folderID: String = "0", pageSize: Int = 1000) async throws -> [BoxItem] {
        struct Page: Decodable { let entries: [Entry]; let next_marker: String? }
        var items: [BoxItem] = []
        var marker: String?
        for _ in 0..<100 {
            var components = URLComponents(
                url: Self.apiBase.appendingPathComponent("folders/\(folderID)/items"),
                resolvingAgainstBaseURL: false)!
            components.queryItems = [
                .init(name: "fields", value: Self.listingFields),
                .init(name: "limit", value: String(min(pageSize, 1000))),
                .init(name: "usemarker", value: "true"),
            ] + (marker.map { [URLQueryItem(name: "marker", value: $0)] } ?? [])
            let (data, _) = try await authorized(URLRequest(url: components.url!))
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else {
                throw BoxError.malformedResponse("folder listing was not the expected shape")
            }
            items += page.entries.compactMap { $0.item() }
            guard let next = page.next_marker, !next.isEmpty else { return items }
            marker = next
        }
        return items
    }

    /// Current metadata for one file — its etag, its version, and the folder
    /// it is in now.
    ///
    /// `timeout` is for the check made before a book opens: the answer only
    /// decides whether the copy here is current, so a network that is not
    /// answering should not hold the book shut for URLSession's full minute.
    public func file(_ fileID: String, timeout: TimeInterval? = nil) async throws -> BoxItem {
        var components = URLComponents(
            url: Self.apiBase.appendingPathComponent("files/\(fileID)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "fields", value: Self.fileFields)]
        var request = URLRequest(url: components.url!)
        if let timeout { request.timeoutInterval = timeout }
        let (data, _) = try await authorized(request)
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data),
              let item = entry.item(defaultKind: .file) else {
            throw BoxError.malformedResponse("file metadata was not the expected shape")
        }
        return item
    }

    // MARK: Downloading

    /// Downloads a file — the version named, when one is — into a temporary
    /// file of its own, which the caller moves or deletes.
    ///
    /// Box can answer that a file uploaded moments ago is not ready yet, with
    /// a `Retry-After` saying when to ask again (its *Download File* guide).
    /// That answer is not the file: an empty body taken for one would open as
    /// an empty book, so it is waited out — a few times, never for long — and
    /// then refused as ``BoxError/notReadyYet``.
    public func download(_ fileID: String, version versionID: String? = nil,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in })
        async throws -> URL {
        var components = URLComponents(
            url: Self.apiBase.appendingPathComponent("files/\(fileID)/content"),
            resolvingAgainstBaseURL: false)!
        if let versionID { components.queryItems = [.init(name: "version", value: versionID)] }
        let request = URLRequest(url: components.url!)
        for attempt in 0..<4 {
            let (file, response) = try await authorizedDownload(request, progress: progress)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            let retryAfter = Self.retryAfter(response)
            if response.statusCode == 200, retryAfter == nil || size > 0 { return file }
            try? FileManager.default.removeItem(at: file)
            guard let retryAfter, attempt < 3 else { break }
            try await sleep(.seconds(min(max(retryAfter, 0), 10)))
        }
        throw BoxError.notReadyYet
    }

    // MARK: Uploading in one request

    /// Uploads `data` as a **new version** of an existing file, in one
    /// request — for a file under the chunked API's 20 MB floor.
    ///
    /// `ifMatch` is the etag the caller last saw. Box answers 412 when the
    /// file has moved on since, which becomes ``BoxError/versionConflict`` —
    /// the cloud twin of the document's fingerprint check, and the reason a
    /// second device cannot silently overwrite this one's work.
    ///
    /// `fileName` goes in the `attributes` part, which Box requires; naming
    /// the file as it already is leaves it as it is.
    @discardableResult
    public func uploadNewVersion(fileID: String, data: Data,
                                 fileName: String, ifMatch: String?) async throws -> BoxItem {
        struct Attributes: Encodable { let name: String }
        let (body, response) = try await multipartUpload(
            to: Self.uploadBase.appendingPathComponent("files/\(fileID)/content"),
            attributes: try JSONEncoder().encode(Attributes(name: fileName)),
            fileName: fileName, data: data, ifMatch: ifMatch)
        if response.statusCode == 412 {
            throw BoxError.versionConflict(currentEtag: response.value(forHTTPHeaderField: "ETag"))
        }
        return try Self.uploaded(body)
    }

    /// Uploads `data` as a **new file** named `name` in a folder, in one
    /// request.
    ///
    /// Box refuses with a 409 when the name is taken in that folder — or the
    /// account is out of space (its reference gives both); either way it
    /// arrives as ``BoxError/api(status:code:message:)`` with Box's own words.
    @discardableResult
    public func uploadNewFile(named name: String, inFolder parentID: String,
                              data: Data) async throws -> BoxItem {
        struct Attributes: Encodable {
            struct Parent: Encodable { let id: String }
            let name: String
            let parent: Parent
        }
        let (body, _) = try await multipartUpload(
            to: Self.uploadBase.appendingPathComponent("files/content"),
            attributes: try JSONEncoder().encode(Attributes(name: name, parent: .init(id: parentID))),
            fileName: name, data: data, ifMatch: nil)
        return try Self.uploaded(body, parentID: parentID)
    }

    /// The one shape of a direct upload: a POST of the attributes, then the
    /// file, with `If-Match` when there is a version to match.
    private func multipartUpload(to url: URL, attributes: Data, fileName: String,
                                 data: Data, ifMatch: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let boundary = "finvestlens.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(boundary: boundary, attributes: attributes,
                                              fileName: fileName, data: data)
        return try await authorized(request)
    }

    /// The file an upload answered with: Box returns it in a one-entry list.
    private static func uploaded(_ body: Data, parentID: String? = nil) throws -> BoxItem {
        struct Response: Decodable { let entries: [Entry] }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: body),
              let item = decoded.entries.first?.item(defaultKind: .file) else {
            throw BoxError.malformedResponse("upload response was not the expected shape")
        }
        guard item.parentID == nil, let parentID else { return item }
        return BoxItem(id: item.id, kind: item.kind, name: item.name, etag: item.etag,
                       size: item.size, modifiedAt: item.modifiedAt,
                       parentID: parentID, versionID: item.versionID, sha1: item.sha1)
    }

    /// An upload's body: the JSON `attributes` part, then the file.
    ///
    /// The order is Box's rule — attributes after the file is refused with
    /// `metadata_after_file_contents`. The name in the file part's header is
    /// only a label (the attributes carry the real one), but a quote or a line
    /// break in it would end the header early, so those are replaced.
    static func multipartBody(boundary: String, attributes: Data,
                              fileName: String, data: Data) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        let label = fileName
            .replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"attributes\"\r\n\r\n")
        body.append(attributes)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(label)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: Uploading in parts

    /// Opens a chunked upload of a new version of `fileID`, `size` bytes long.
    public func createUploadSession(forFile fileID: String, size: Int64) async throws -> BoxUploadSession {
        struct Body: Encodable { let file_size: Int64 }
        return try await createSession(
            at: Self.uploadBase.appendingPathComponent("files/\(fileID)/upload_sessions"),
            body: try JSONEncoder().encode(Body(file_size: size)))
    }

    /// Opens a chunked upload of a new file named `name` in a folder.
    public func createUploadSession(newFileNamed name: String, inFolder folderID: String,
                                    size: Int64) async throws -> BoxUploadSession {
        struct Body: Encodable { let folder_id: String; let file_size: Int64; let file_name: String }
        return try await createSession(
            at: Self.uploadBase.appendingPathComponent("files/upload_sessions"),
            body: try JSONEncoder().encode(Body(folder_id: folderID, file_size: size, file_name: name)))
    }

    private func createSession(at url: URL, body: Data) async throws -> BoxUploadSession {
        struct Response: Decodable {
            struct Endpoints: Decodable { let upload_part: URL; let commit: URL; let abort: URL }
            let id: String
            let part_size: Int64
            let total_parts: Int
            let session_expires_at: String?
            let session_endpoints: Endpoints
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await authorized(request)
        guard let session = try? JSONDecoder().decode(Response.self, from: data), session.part_size > 0 else {
            throw BoxError.malformedResponse("upload session was not the expected shape")
        }
        return BoxUploadSession(id: session.id, partSize: session.part_size, totalParts: session.total_parts,
                                uploadPartURL: session.session_endpoints.upload_part,
                                commitURL: session.session_endpoints.commit,
                                abortURL: session.session_endpoints.abort,
                                expiresAt: session.session_expires_at.flatMap(Self.parseDate))
    }

    /// Sends one part: `data` is the file's bytes from `offset`, exactly the
    /// session's part size except for the last.
    public func uploadPart(_ data: Data, offset: Int64, totalSize: Int64,
                           session: BoxUploadSession) async throws -> BoxUploadedPart {
        struct Response: Decodable {
            struct Part: Decodable { let part_id: String; let offset: Int64; let size: Int64; let sha1: String? }
            let part: Part
        }
        var request = URLRequest(url: session.uploadPartURL)
        request.httpMethod = "PUT"
        request.setValue("sha=\(Self.sha1Base64(data))", forHTTPHeaderField: "Digest")
        request.setValue("bytes \(offset)-\(offset + Int64(data.count) - 1)/\(totalSize)",
                         forHTTPHeaderField: "Content-Range")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (body, response) = try await authorized(request)
        // A part carries no version to match: a 412 here is the session's,
        // and is passed on as Box said it.
        if response.statusCode == 412 { throw Self.apiError(status: 412, body: body) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: body) else {
            throw BoxError.malformedResponse("part upload response was not the expected shape")
        }
        let sha1 = decoded.part.sha1 ?? Self.sha1Hex(data)
        return BoxUploadedPart(partID: decoded.part.part_id, offset: decoded.part.offset,
                               size: decoded.part.size, sha1: sha1)
    }

    /// Closes a chunked upload, making the file (or its new version) from the
    /// parts. `wholeFileSHA1` is base64; `ifMatch` guards a new version the
    /// way it guards a direct upload. Box may answer that the parts are not
    /// put together yet, with a `Retry-After` — waited out a few times.
    public func commit(_ session: BoxUploadSession, parts: [BoxUploadedPart],
                       wholeFileSHA1 sha1: String, ifMatch: String?,
                       parentID: String? = nil) async throws -> BoxItem {
        struct Body: Encodable {
            struct Part: Encodable { let part_id: String; let offset: Int64; let size: Int64; let sha1: String }
            let parts: [Part]
        }
        let body = Body(parts: parts.sorted { $0.offset < $1.offset }.map {
            .init(part_id: $0.partID, offset: $0.offset, size: $0.size, sha1: $0.sha1)
        })
        var request = URLRequest(url: session.commitURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sha=\(sha1)", forHTTPHeaderField: "Digest")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        request.httpBody = try JSONEncoder().encode(body)
        for attempt in 0..<6 {
            let (answer, response) = try await authorized(request)
            if response.statusCode == 412 {
                throw BoxError.versionConflict(currentEtag: response.value(forHTTPHeaderField: "ETag"))
            }
            if response.statusCode == 202 {
                guard attempt < 5 else { break }
                try await sleep(.seconds(min(max(Self.retryAfter(response) ?? 2, 0), 10)))
                continue
            }
            return try Self.uploaded(answer, parentID: parentID)
        }
        throw BoxError.notReadyYet
    }

    /// Abandons a chunked upload. Failure is not worth reporting: an
    /// abandoned session expires on its own.
    public func abort(_ session: BoxUploadSession) async {
        var request = URLRequest(url: session.abortURL)
        request.httpMethod = "DELETE"
        _ = try? await authorized(request)
    }

    // MARK: Digests

    public static func sha1Base64(_ data: Data) -> String {
        Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
    }

    public static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Plumbing

    /// Attaches the bearer token, and retries once if Box says it expired.
    /// Answers in 2xx and 412 are returned; everything else is thrown with
    /// Box's own code and message.
    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withToken(request) { attempt in try await self.transport.send(attempt) }
    }

    private func authorizedDownload(_ request: URLRequest,
                                    progress: @escaping @Sendable (Int64, Int64?) -> Void)
        async throws -> (URL, HTTPURLResponse) {
        let (file, response) = try await withToken(request) { attempt in
            try await self.transport.download(attempt, progress: progress)
        }
        return (file, response)
    }

    /// The token-and-retry rule, for either kind of answer. A refused answer's
    /// body is read for Box's words: for a download it is in the file.
    private func withToken<Answer>(_ request: URLRequest,
                                   send: (URLRequest) async throws -> (Answer, HTTPURLResponse))
        async throws -> (Answer, HTTPURLResponse) {
        var attempt = request
        attempt.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        var (answer, response) = try await send(attempt)
        if response.statusCode == 401 {
            // The token was live by our clock and dead by Box's. Force a
            // refresh and go once more rather than surfacing a sign-in prompt
            // in the middle of someone's save.
            Self.discard(answer)
            try await auth.invalidateAccessToken()
            var retry = request
            retry.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            (answer, response) = try await send(retry)
        }
        guard (200..<300).contains(response.statusCode) || response.statusCode == 412 else {
            let body = Self.body(of: answer)
            Self.discard(answer)
            throw Self.apiError(status: response.statusCode, body: body)
        }
        return (answer, response)
    }

    private static func body<Answer>(of answer: Answer) -> Data {
        if let data = answer as? Data { return data }
        if let file = answer as? URL { return (try? Data(contentsOf: file)) ?? Data() }
        return Data()
    }

    private static func discard<Answer>(_ answer: Answer) {
        if let file = answer as? URL { try? FileManager.default.removeItem(at: file) }
    }

    private static func apiError(status: Int, body: Data) -> BoxError {
        struct Failure: Decodable { let code: String?; let message: String? }
        let decoded = try? JSONDecoder().decode(Failure.self, from: body)
        return .api(status: status, code: decoded?.code, message: decoded?.message)
    }

    /// `Retry-After` in seconds. Box's guides give seconds; an HTTP date is
    /// read as well, rather than ignored.
    static func retryAfter(_ response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max($0.timeIntervalSinceNow, 0) }
    }

    /// A fresh formatter per call. `ISO8601DateFormatter` is not `Sendable`,
    /// and this parses a handful of dates per folder listing — not the hot
    /// path that would justify an isolated cache.
    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
