//
//  BoxErrorWordsTests.swift
//  FinvestLens — Cloud
//
//  A Box error reached the alert through string interpolation, as its debug
//  description: `api(status: 403, code: Optional("access_denied"), …)`.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensCloud

@Suite("Box errors in words")
struct BoxErrorWordsTests {

    @Test("Each error says what happened, and passes on what Box said")
    func descriptions() {
        #expect(BoxError.api(status: 403, code: "access_denied", message: nil).localizedDescription
            == "Box refused the request (403): access_denied")
        #expect(BoxError.api(status: 409, code: "conflict", message: "Item with the same name already exists")
            .localizedDescription == "Box refused the request (409): Item with the same name already exists")
        #expect(BoxError.api(status: 500, code: nil, message: nil).localizedDescription
            == "Box refused the request (500).")
        let all: [BoxError] = [.notConfigured, .notAuthenticated, .signInCancelled,
                               .versionConflict(currentEtag: "3"), .notReadyYet,
                               .malformedResponse("no entries")]
        for error in all {
            let words = error.localizedDescription
            #expect(!words.contains("BoxError") && !words.contains("operation couldn"), "\(error)")
        }
    }

    #if canImport(Security)
    @Test("A refusal from the Keychain is the Keychain's, in its own words — not Box's")
    func keychainRefusal() {
        // What an unsigned build gets: -34018, a required entitlement missing.
        let words = BoxKeychainError(status: -34018).localizedDescription
        #expect(words.hasPrefix("The Keychain couldn’t keep the Box credential: "), "\(words)")
        #expect(!words.contains("Box sent"), "\(words)")
        #expect(words.count > "The Keychain couldn’t keep the Box credential: ".count + 5, "the Keychain's reason: \(words)")
    }
    #endif
}
