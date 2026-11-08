//
//  BoxTokenIssuerTests.swift
//  FinvestLens — Cloud
//
//  Tokens belong to the Box app they were issued to, and a refusal of the app
//  itself is not a lost grant (found in review, 8 Nov 2026). The values here
//  are made up.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensCloud

private let app = BoxAppConfiguration(clientID: "the-app", clientSecret: "made-up-secret",
                                      redirectURI: "finvestlens://box-auth")
private let presenter = StubPresenter(callback: URL(string: "finvestlens://box-auth")!)

@Suite("Box tokens and the app they belong to")
struct BoxTokenIssuerTests {

    @Test("Tokens Box issues are stamped with the app they were issued to")
    func stamped() async throws {
        let store = InMemoryBoxTokenStore()
        let transport = StubTransport([.ok(#"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#)])
        let auth = BoxAuthenticator(configuration: app, transport: transport, store: store, presenter: presenter)
        try await auth.signIn()
        #expect(store.tokens()?.clientID == "the-app")
    }

    @Test("Tokens issued to another app are never sent: they go, and the person is asked to connect")
    func anotherAppsTokens() async {
        let store = InMemoryBoxTokenStore(BoxTokens(accessToken: "AT", refreshToken: "RT",
                                                    expiresAt: .distantFuture, clientID: "their-own-app"))
        let transport = StubTransport([])
        let auth = BoxAuthenticator(configuration: app, transport: transport, store: store, presenter: presenter)
        await #expect(throws: BoxError.notAuthenticated) { _ = try await auth.accessToken() }
        #expect(store.tokens() == nil)
        #expect(transport.sent.isEmpty, "nothing was sent with them")
    }

    @Test("Tokens stored before the issuer was kept are used as they are")
    func legacyTokens() async throws {
        let store = InMemoryBoxTokenStore(BoxTokens(accessToken: "AT", refreshToken: "RT",
                                                    expiresAt: .distantFuture))
        let auth = BoxAuthenticator(configuration: app, transport: StubTransport([]), store: store,
                                    presenter: presenter)
        #expect(try await auth.accessToken() == "AT")
        // And a stored grant written before the field existed still decodes.
        let old = Data(#"{"accessToken":"AT","refreshToken":"RT","expiresAt":0}"#.utf8)
        #expect(try JSONDecoder().decode(BoxTokens.self, from: old).clientID == nil)
    }

    @Test("Box refusing the app itself keeps the grant and says so", arguments: ["invalid_client", "unauthorized_client"])
    func appRefused(code: String) async {
        let tokens = BoxTokens(accessToken: "OLD", refreshToken: "RT", expiresAt: Date(timeIntervalSince1970: 10),
                               clientID: "the-app")
        let store = InMemoryBoxTokenStore(tokens)
        let transport = StubTransport([.status(400, #"{"error":"\#(code)","error_description":"made up"}"#)])
        let auth = BoxAuthenticator(configuration: app, transport: transport, store: store, presenter: presenter,
                                    now: { Date(timeIntervalSince1970: 1000) })
        await #expect(throws: BoxError.appRefused(code: code)) { _ = try await auth.accessToken() }
        #expect(store.tokens() == tokens, "the grant is kept for when Box accepts the app again")
        #expect(BoxError.appRefused(code: code).localizedDescription.contains(code))
    }
}
