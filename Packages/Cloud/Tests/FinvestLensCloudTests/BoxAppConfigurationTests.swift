//
//  BoxAppConfigurationTests.swift
//  FinvestLens — Cloud
//
//  A Box app's configuration never describes its client ID or secret: a
//  published build carries FinvestLens's own, and nothing — a log line, an
//  error, a debugger's dump — may show them. The values here are made up.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensCloud

@Suite("A Box app's configuration keeps its values to itself")
struct BoxAppConfigurationTests {

    @Test("Description, interpolation, reflection and dump say whether, never what")
    func redacted() {
        let configuration = BoxAppConfiguration(clientID: "made-up-id-1234", clientSecret: "made-up-secret-5678",
                                                redirectURI: "finvestlens://box-auth")
        var dumped = ""
        dump(configuration, to: &dumped)
        let renderings = [configuration.description, String(describing: configuration), "\(configuration)",
                          String(reflecting: configuration), dumped]
        for text in renderings {
            #expect(!text.contains("made-up-id-1234") && !text.contains("made-up-secret-5678"), "\(text)")
        }
        #expect(configuration.description.contains("clientSecret: set"))
        #expect(BoxAppConfiguration(clientID: "", clientSecret: "", redirectURI: "x").description.contains("clientSecret: none"))
    }
}
