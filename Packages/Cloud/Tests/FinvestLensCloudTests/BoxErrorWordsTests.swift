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
                               .versionConflict(currentEtag: "3"), .malformedResponse("no entries")]
        for error in all {
            let words = error.localizedDescription
            #expect(!words.contains("BoxError") && !words.contains("operation couldn"), "\(error)")
        }
    }
}
