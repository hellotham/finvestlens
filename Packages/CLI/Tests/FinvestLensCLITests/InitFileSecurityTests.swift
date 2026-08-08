//
//  InitFileSecurityTests.swift
//  FinvestLens — CLI
//
//  `./.finlensrc` is read from whatever directory finlens is run in, which
//  makes every option it can set an option a *dropped file* can set. The one
//  option that writes to a path — `--output` — must therefore never be
//  honoured from an init file or the environment: a strictly read-only tool
//  that can be redirected into overwriting an arbitrary file by a planted rc
//  is not strictly read-only.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensCLICore

@Suite("finlens init-file security")
struct InitFileSecurityTests {

    private func write(_ text: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(".finlensrc").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("--output in an init file is dropped, with a warning")
    func rcOutputIgnored() throws {
        let path = try write("--output /tmp/overwritten\n--wide\n")
        let defaults = InitFile.defaults(explicitPath: path, environment: [:])
        #expect(defaults.options.output == nil)
        #expect(defaults.warnings.contains { $0.contains("--output") && $0.contains("command-line only") })
        // Harmless defaults from the same file still apply (--wide → 132 cols).
        #expect(defaults.options.columns == 132)
    }

    @Test("FINLENS_OUTPUT in the environment is dropped the same way")
    func environmentOutputIgnored() throws {
        let defaults = InitFile.defaults(explicitPath: nil,
                                         environment: ["FINLENS_OUTPUT": "/tmp/overwritten"])
        #expect(defaults.options.output == nil)
        #expect(defaults.warnings.contains { $0.contains("--output") })
    }

    @Test("--output typed at the prompt still works")
    func argvOutputStillHonoured() throws {
        let parsed = try CLIParser.parse(["balance", "--output", "/tmp/report.txt"])
        #expect(parsed.options.output == "/tmp/report.txt")
    }
}
