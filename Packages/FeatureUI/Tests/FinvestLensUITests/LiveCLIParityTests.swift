//
//  LiveCLIParityTests.swift
//  FinvestLens — FeatureUI
//
//  P10c exit criterion (docs/ledger-design.md §7): `finlens bal` over the
//  real book must agree with the engine's own balances to the cent.
//  Env-gated like the other live harnesses:
//
//      FL_PERF_FILE="$PWD/Ashley Bears.finvestlens" \
//      swift test --package-path Packages/FeatureUI --filter LiveCLIParity
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensPersistence
@testable import FinvestLensUI

private let bookPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@Suite(.serialized)
struct LiveCLIParityTests {

    /// Runs the built `finlens` binary, if it exists next to this checkout.
    private func finlens(_ arguments: [String]) throws -> String? {
        // swift-test runs with the PACKAGE as the working directory, so walk
        // up to the repo root looking for the built binary (or take
        // $FL_FINLENS outright).
        let suffixes = [
            "Packages/CLI/.build/arm64-apple-macosx/debug/finlens",
            "Packages/CLI/.build/x86_64-apple-macosx/debug/finlens",
            "Packages/CLI/.build/debug/finlens",
        ]
        var searched: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["FL_FINLENS"] {
            searched.append(URL(fileURLWithPath: explicit))
        }
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<5 {
            searched.append(contentsOf: suffixes.map { directory.appendingPathComponent($0) })
            directory = directory.deletingLastPathComponent()
        }
        guard let binary = searched
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return nil }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("finlens balances agree with the engine, and the book is untouched")
    func parity() throws {
        guard let bookPath else { return }
        guard let output = try finlens(["-f", bookPath, "bal", "--flat", "--no-total"]) else {
            print("finlens binary not built — skipping (swift build --package-path Packages/CLI)")
            return
        }

        let book = try SQLiteDocumentStore(readOnlyPath: bookPath).read()
        let balances = book.balancesByAccount()
        var expected: [String: Decimal] = [:]
        for account in book.accounts {
            let value = balances[ObjectIdentifier(account)] ?? 0
            if value != 0 { expected[account.fullName] = account.commodity.round(value) }
        }

        // Every printed line is "<amount> <commodity>  <account path>".
        var seen = 0
        var mismatches: [String] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard let separator = text.range(of: "  ", options: .backwards) else { continue }
            let account = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            let amountText = String(text[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard let target = expected[account] else { continue }
            // Strip the commodity and thousands separators.
            let digits = amountText.split(separator: " ").first.map(String.init) ?? amountText
            guard let parsed = Decimal(string: digits.replacingOccurrences(of: ",", with: "")) else { continue }
            seen += 1
            if parsed != target { mismatches.append("\(account): CLI \(parsed) vs engine \(target)") }
        }
        print("finlens parity: checked \(seen) account balances against the engine")
        #expect(seen > 100, "the CLI printed too few balances to be a real check")
        #expect(mismatches.isEmpty, Comment(rawValue: mismatches.prefix(5).joined(separator: "; ")))

        // The read-only guarantee, on the real book.
        let before = try Data(contentsOf: URL(fileURLWithPath: bookPath))
        _ = try finlens(["-f", bookPath, "stats"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: bookPath)) == before)
    }
}
