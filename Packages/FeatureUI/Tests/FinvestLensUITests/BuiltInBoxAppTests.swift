//
//  BuiltInBoxAppTests.swift
//  FinvestLens — FeatureUI
//
//  A build that carries FinvestLens's own Box app signs everyone in through
//  it: nothing to set up, and the person's own Box-app settings — the client
//  ID in preferences, the secret in the Keychain — are not read. A build
//  without it (one made from the public source) keeps asking for a Box app of
//  the person's own. The values here are made up.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensCloud
@testable import FinvestLensUI

/// A secret store that counts how often it is asked.
private final class CountingSecretStore: BoxClientSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func secret() -> String? { lock.withLock { count += 1 }; return "own-secret" }
    func setSecret(_ secret: String?) throws {}
}

@MainActor
@Suite("FinvestLens's own Box app, when the build carries it")
struct BuiltInBoxAppTests {

    private func makeModel() -> (AppModel, CountingSecretStore, cleanup: () -> Void) {
        let suite = "finvestlens.tests.box-app.\(UUID().uuidString)"
        let model = AppModel(authenticator: AllowAllAuthenticator())
        model.boxDefaults = UserDefaults(suiteName: suite)!
        let store = CountingSecretStore()
        model.boxSecretStore = store
        return (model, store, { model.close(); UserDefaults().removePersistentDomain(forName: suite) })
    }

    @Test("Built in: it is what signs in, there is nothing to set up, and the person's own settings are not read")
    func builtIn() {
        let (model, store, cleanup) = makeModel()
        defer { cleanup() }
        model.boxClientID = "own-id"

        model.builtInBoxApp = BuiltInBoxCredentials(clientID: "built-in-id", clientSecret: "built-in-secret")

        #expect(model.usesBuiltInBoxApp)
        #expect(model.isBoxConfigured)
        let configuration = model.boxConfiguration
        #expect(configuration.clientID == "built-in-id")
        #expect(configuration.clientSecret == "built-in-secret")
        #expect(configuration.redirectURI == AppModel.boxRedirectURI)
        #expect(store.reads == 0, "the person's own secret is not read from the Keychain")
    }

    @Test("Without it: a Box app of the person's own, as before")
    func ownBoxApp() {
        let (model, store, cleanup) = makeModel()
        defer { cleanup() }

        #expect(!model.usesBuiltInBoxApp)
        #expect(!model.isBoxConfigured, "no client ID yet")
        model.boxClientID = "own-id"
        #expect(model.isBoxConfigured)
        #expect(model.boxConfiguration.clientID == "own-id")
        #expect(model.boxConfiguration.clientSecret == "own-secret")
        #expect(store.reads > 0)
    }

    @Test("The built-in credentials never describe themselves")
    func redacted() {
        let credentials = BuiltInBoxCredentials(clientID: "made-up-id-1234", clientSecret: "made-up-secret-5678")
        var dumped = ""
        dump(credentials, to: &dumped)
        let (model, _, cleanup) = makeModel()
        defer { cleanup() }
        model.builtInBoxApp = credentials
        var dumpedModelValue = ""
        dump(model.builtInBoxApp, to: &dumpedModelValue)
        for text in ["\(credentials)", String(describing: credentials), String(reflecting: credentials), dumped,
                     String(describing: model.builtInBoxApp), dumpedModelValue] {
            #expect(!text.contains("made-up-id-1234") && !text.contains("made-up-secret-5678"), "\(text)")
        }
    }

    @Test("Tokens from the person's own Box app go when the built-in one arrives, with the reason")
    func ownAppTokensRetired() throws {
        let (model, _, cleanup) = makeModel()
        defer { cleanup() }
        model.boxClientID = "their-own-app"
        model.boxTokenStore = InMemoryBoxTokenStore(BoxTokens(accessToken: "AT", refreshToken: "RT",
                                                              expiresAt: .distantFuture))
        #expect(model.isBoxSignedIn)

        model.builtInBoxApp = BuiltInBoxCredentials(clientID: "built-in-id", clientSecret: "built-in-secret")

        #expect(!model.isBoxSignedIn)
        let notice = try #require(model.boxSignInNotice)
        #expect(notice.contains("its own Box app"))
    }

    @Test("Tokens from the same app stay, and are marked as its")
    func sameAppTokensKept() {
        let (model, _, cleanup) = makeModel()
        defer { cleanup() }
        model.boxClientID = "built-in-id"
        let store = InMemoryBoxTokenStore(BoxTokens(accessToken: "AT", refreshToken: "RT", expiresAt: .distantFuture))
        model.boxTokenStore = store

        model.builtInBoxApp = BuiltInBoxCredentials(clientID: "built-in-id", clientSecret: "built-in-secret")

        #expect(model.isBoxSignedIn)
        #expect(model.boxSignInNotice == nil)
        #expect(store.tokens()?.clientID == "built-in-id")
    }
}
