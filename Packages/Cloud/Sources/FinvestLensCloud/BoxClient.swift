//
//  BoxClient.swift
//  FinvestLens — Cloud
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

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

    public init(id: String, kind: Kind, name: String,
                etag: String? = nil, size: Int64? = nil, modifiedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.etag = etag; self.size = size; self.modifiedAt = modifiedAt
    }

    public var isBook: Bool { kind == .file && name.hasSuffix(".finvestlens") }
}

/// Reads and writes files in the signed-in user's Box account.
///
/// Every request goes through ``authorized(_:)``, which attaches a fresh
/// access token and retries once on a 401 — Box expires tokens on its own
/// schedule and a save is the worst moment to surface that as a failure.
public actor BoxClient {
    public static let apiBase = URL(string: "https://api.box.com/2.0")!
    public static let uploadBase = URL(string: "https://upload.box.com/api/2.0")!

    private let transport: BoxTransport
    private let auth: BoxAuthenticator

    public init(transport: BoxTransport, auth: BoxAuthenticator) {
        self.transport = transport
        self.auth = auth
    }

    // MARK: Browsing

    /// The entries of a folder — `"0"` is Box's root.
    public func items(inFolder folderID: String = "0", limit: Int = 200) async throws -> [BoxItem] {
        var components = URLComponents(
            url: Self.apiBase.appendingPathComponent("folders/\(folderID)/items"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "fields", value: "id,type,name,etag,size,modified_at"),
            .init(name: "limit", value: String(limit)),
        ]
        let (data, _) = try await authorized(URLRequest(url: components.url!))
        struct Response: Decodable { let entries: [Entry] }
        struct Entry: Decodable {
            let id: String; let type: String; let name: String
            let etag: String?; let size: Int64?; let modified_at: String?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BoxError.malformedResponse("folder listing was not the expected shape")
        }
        return decoded.entries.compactMap { entry in
            guard let kind = BoxItem.Kind(rawValue: entry.type) else { return nil }
            return BoxItem(id: entry.id, kind: kind, name: entry.name, etag: entry.etag,
                           size: entry.size,
                           modifiedAt: entry.modified_at.flatMap(Self.parseDate))
        }
    }

    /// Current metadata for one file — used before a save to see whether Box
    /// holds a version this app has not downloaded.
    public func file(_ fileID: String) async throws -> BoxItem {
        var components = URLComponents(
            url: Self.apiBase.appendingPathComponent("files/\(fileID)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "fields", value: "id,type,name,etag,size,modified_at")]
        let (data, _) = try await authorized(URLRequest(url: components.url!))
        struct Entry: Decodable {
            let id: String; let type: String; let name: String
            let etag: String?; let size: Int64?; let modified_at: String?
        }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data),
              let kind = BoxItem.Kind(rawValue: entry.type) else {
            throw BoxError.malformedResponse("file metadata was not the expected shape")
        }
        return BoxItem(id: entry.id, kind: kind, name: entry.name, etag: entry.etag,
                       size: entry.size, modifiedAt: entry.modified_at.flatMap(Self.parseDate))
    }

    // MARK: Content

    /// Downloads a file's bytes.
    public func download(_ fileID: String) async throws -> Data {
        let url = Self.apiBase.appendingPathComponent("files/\(fileID)/content")
        let (data, _) = try await authorized(URLRequest(url: url))
        return data
    }

    /// Uploads `data` as a **new version** of an existing file.
    ///
    /// `ifMatch` is the etag the caller last saw. Box answers 412 when the
    /// file has moved on since, which becomes ``BoxError/versionConflict`` —
    /// the cloud twin of the document's fingerprint check, and the reason a
    /// second device cannot silently overwrite this one's work.
    @discardableResult
    public func uploadNewVersion(fileID: String, data: Data,
                                 fileName: String, ifMatch: String?) async throws -> BoxItem {
        let url = Self.uploadBase.appendingPathComponent("files/\(fileID)/content")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let boundary = "finvestlens.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(boundary: boundary, fileName: fileName, data: data)

        let (body, response) = try await authorized(request, allowRetryOn401: true)
        if response.statusCode == 412 {
            throw BoxError.versionConflict(currentEtag: response.value(forHTTPHeaderField: "ETag"))
        }
        struct Response: Decodable { let entries: [Entry] }
        struct Entry: Decodable { let id: String; let name: String; let etag: String? }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: body),
              let entry = decoded.entries.first else {
            throw BoxError.malformedResponse("upload response was not the expected shape")
        }
        return BoxItem(id: entry.id, kind: .file, name: entry.name, etag: entry.etag)
    }

    static func multipartBody(boundary: String, fileName: String, data: Data) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: Plumbing

    /// Attaches the bearer token, and retries once if Box says it expired.
    private func authorized(_ request: URLRequest,
                            allowRetryOn401: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var attempt = request
        attempt.setValue("Bearer \(try await auth.accessToken())",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(attempt)

        if response.statusCode == 401, allowRetryOn401 {
            // The token was live by our clock and dead by Box's. Force a
            // refresh and go once more rather than surfacing a sign-in prompt
            // in the middle of someone's save.
            try await auth.invalidateAccessToken()
            var retry = request
            retry.setValue("Bearer \(try await auth.accessToken())",
                           forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await transport.send(retry)
            guard (200..<300).contains(retryResponse.statusCode) || retryResponse.statusCode == 412 else {
                throw Self.apiError(status: retryResponse.statusCode, body: retryData)
            }
            return (retryData, retryResponse)
        }
        guard (200..<300).contains(response.statusCode) || response.statusCode == 412 else {
            throw Self.apiError(status: response.statusCode, body: data)
        }
        return (data, response)
    }

    private static func apiError(status: Int, body: Data) -> BoxError {
        struct Failure: Decodable { let code: String?; let message: String? }
        let decoded = try? JSONDecoder().decode(Failure.self, from: body)
        return .api(status: status, code: decoded?.code, message: decoded?.message)
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
