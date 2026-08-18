//
//  BoxTests.swift
//  FinvestLens — Cloud
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensCloud

/// A scripted transport: each entry answers one request, in order, and every
/// request is recorded so a test can assert what was actually sent.
final class StubTransport: BoxTransport, @unchecked Sendable {
    struct Reply {
        let status: Int; let body: Data; let headers: [String: String]

        static func ok(_ json: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: 200, body: Data(json.utf8), headers: headers)
        }
        static func status(_ code: Int, _ json: String = "{}",
                           headers: [String: String] = [:]) -> Reply {
            Reply(status: code, body: Data(json.utf8), headers: headers)
        }
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var sent: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // `withLock`, not lock/unlock: NSLock's pair is unavailable from an
        // async context because a suspension while holding it would deadlock.
        try lock.withLock {
            sent.append(request)
            guard !replies.isEmpty else { throw BoxError.malformedResponse("no scripted reply") }
            let reply = replies.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: nil, headerFields: reply.headers)!
            return (reply.body, response)
        }
    }
}

struct StubPresenter: BoxAuthorizationPresenting {
    let callback: URL
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        // Echo the state back, as Box does.
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "\(callback.absoluteString)?code=THECODE&state=\(state)")!
    }
}

private let config = BoxAppConfiguration(clientID: "abc123",
                                         redirectURI: "finvestlens://box-auth")

@Suite("Box OAuth")
struct BoxOAuthTests {

    @Test("Sign-in exchanges the code with a PKCE verifier and stores the tokens")
    func signInStoresTokens() async throws {
        let transport = StubTransport([
            .ok(#"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#)
        ])
        let store = InMemoryBoxTokenStore()
        let auth = BoxAuthenticator(configuration: config, transport: transport, store: store,
                                    presenter: StubPresenter(callback: URL(string: "finvestlens://box-auth")!),
                                    now: { Date(timeIntervalSince1970: 0) })
        try await auth.signIn()

        #expect(store.tokens()?.accessToken == "AT")
        #expect(store.tokens()?.refreshToken == "RT")
        // No client secret is sent — PKCE exists so a desktop app needs none.
        let body = String(data: transport.sent[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("code_verifier="))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(!body.contains("client_secret"))
    }

    @Test("A mismatched state is refused")
    func stateMismatchRefused() async {
        struct EvilPresenter: BoxAuthorizationPresenting {
            func authorize(url: URL, callbackScheme: String) async throws -> URL {
                URL(string: "finvestlens://box-auth?code=THECODE&state=someone-elses")!
            }
        }
        let auth = BoxAuthenticator(configuration: config, transport: StubTransport([]),
                                    store: InMemoryBoxTokenStore(), presenter: EvilPresenter())
        await #expect(throws: BoxError.self) { try await auth.signIn() }
    }

    @Test("An expired access token refreshes before use")
    func refreshesWhenExpired() async throws {
        let store = InMemoryBoxTokenStore(BoxTokens(accessToken: "OLD", refreshToken: "RT",
                                                    expiresAt: Date(timeIntervalSince1970: 10)))
        let transport = StubTransport([
            .ok(#"{"access_token":"NEW","refresh_token":"RT2","expires_in":3600}"#)
        ])
        let auth = BoxAuthenticator(configuration: config, transport: transport, store: store,
                                    presenter: StubPresenter(callback: URL(string: "finvestlens://box-auth")!),
                                    now: { Date(timeIntervalSince1970: 1000) })
        #expect(try await auth.accessToken() == "NEW")
        #expect(store.tokens()?.refreshToken == "RT2")
    }

    @Test("A revoked refresh token clears the stored grant rather than looping")
    func revokedGrantClears() async {
        let store = InMemoryBoxTokenStore(BoxTokens(accessToken: "OLD", refreshToken: "DEAD",
                                                    expiresAt: Date(timeIntervalSince1970: 10)))
        let transport = StubTransport([.status(400, #"{"error":"invalid_grant"}"#)])
        let auth = BoxAuthenticator(configuration: config, transport: transport, store: store,
                                    presenter: StubPresenter(callback: URL(string: "finvestlens://box-auth")!),
                                    now: { Date(timeIntervalSince1970: 1000) })
        await #expect(throws: BoxError.notAuthenticated) { _ = try await auth.accessToken() }
        #expect(store.tokens() == nil, "a dead grant must not stay on disk")
    }

    @Test("No client id configured is refused before any network call")
    func notConfigured() async {
        let transport = StubTransport([])
        let auth = BoxAuthenticator(configuration: BoxAppConfiguration(clientID: "", redirectURI: "x://y"),
                                    transport: transport, store: InMemoryBoxTokenStore(),
                                    presenter: StubPresenter(callback: URL(string: "x://y")!))
        await #expect(throws: BoxError.notConfigured) { try await auth.signIn() }
        #expect(transport.sent.isEmpty)
    }
}

@Suite("Box client")
struct BoxClientTests {

    private func signedIn(_ transport: StubTransport) -> BoxClient {
        let store = InMemoryBoxTokenStore(BoxTokens(accessToken: "AT", refreshToken: "RT",
                                                    expiresAt: Date(timeIntervalSince1970: 9_000_000)))
        let auth = BoxAuthenticator(configuration: config, transport: transport, store: store,
                                    presenter: StubPresenter(callback: URL(string: "finvestlens://box-auth")!),
                                    now: { Date(timeIntervalSince1970: 0) })
        return BoxClient(transport: transport, auth: auth)
    }

    @Test("Folder listing keeps books and folders, with their etags")
    func listing() async throws {
        let json = #"""
        {"entries":[
          {"id":"1","type":"file","name":"Ashley Bears.finvestlens","etag":"7","size":4096,
           "modified_at":"2026-08-17T02:00:00Z"},
          {"id":"2","type":"folder","name":"Archive","etag":"0"},
          {"id":"3","type":"file","name":"notes.txt","etag":"1"}
        ]}
        """#
        let client = signedIn(StubTransport([.ok(json)]))
        let items = try await client.items()
        #expect(items.count == 3)
        #expect(items[0].isBook)
        #expect(items[0].etag == "7")
        #expect(items[0].size == 4096)
        #expect(items[1].kind == .folder)
        #expect(!items[2].isBook)
    }

    @Test("Upload sends If-Match and multipart, and returns the new etag")
    func uploadSendsIfMatch() async throws {
        let transport = StubTransport([.ok(#"{"entries":[{"id":"1","name":"B.finvestlens","etag":"8"}]}"#)])
        let client = signedIn(transport)
        let item = try await client.uploadNewVersion(fileID: "1", data: Data("db".utf8),
                                                     fileName: "B.finvestlens", ifMatch: "7")
        #expect(item.etag == "8")
        let sent = transport.sent[0]
        #expect(sent.value(forHTTPHeaderField: "If-Match") == "7")
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer AT")
        let body = String(data: sent.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains(#"filename="B.finvestlens""#))
    }

    @Test("Box answering 412 becomes a version conflict, not a generic failure")
    func conflictSurfaces() async {
        // The cloud twin of the document's fingerprint check: someone else
        // saved a newer version, and this save must not overwrite it.
        let transport = StubTransport([.status(412, "{}", headers: ["ETag": "9"])])
        let client = signedIn(transport)
        await #expect(throws: BoxError.versionConflict(currentEtag: "9")) {
            _ = try await client.uploadNewVersion(fileID: "1", data: Data(),
                                                  fileName: "B.finvestlens", ifMatch: "7")
        }
    }

    @Test("A 401 refreshes the token once and retries, rather than failing the save")
    func retriesOnceOn401() async throws {
        let transport = StubTransport([
            .status(401, #"{"code":"unauthorized"}"#),                                  // first try
            .ok(#"{"access_token":"NEW","refresh_token":"RT","expires_in":3600}"#),     // refresh
            .ok(#"{"entries":[{"id":"1","name":"B.finvestlens","etag":"8"}]}"#),         // retry
        ])
        let client = signedIn(transport)
        let item = try await client.uploadNewVersion(fileID: "1", data: Data(),
                                                     fileName: "B.finvestlens", ifMatch: "7")
        #expect(item.etag == "8")
        #expect(transport.sent.count == 3)
        #expect(transport.sent[2].value(forHTTPHeaderField: "Authorization") == "Bearer NEW")
    }

    @Test("Download returns the bytes and authorises the request")
    func download() async throws {
        let transport = StubTransport([.ok("SQLite format 3")])
        let client = signedIn(transport)
        let data = try await client.download("1")
        #expect(String(data: data, encoding: .utf8) == "SQLite format 3")
        #expect(transport.sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer AT")
    }
}
