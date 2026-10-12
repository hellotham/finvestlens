//
//  LiveSuites.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensIntelligence

/// Every suite that asks the device's model something, under one parent.
///
/// There is one model, and Swift Testing runs suites side by side. Each of
/// these was `.serialized` on its own, which orders the tests *within* a
/// suite and nothing else — so three suites queued behind the same model at
/// once, and a test that times a request (the budget that once ran for 221
/// seconds must now come back inside 60) was timing its neighbours too.
/// `.serialized` here applies to everything nested below.
///
/// `FL_LOCALE=de_DE swift test --package-path Packages/Intelligence --filter
/// LiveModelTests` runs the same tests as that person: the eight features on
/// their synthetic English documents, with the instructions carrying that
/// locale. It is how "extraction is unaffected by the person's locale" is
/// checked rather than supposed.
@Suite("Live model", .serialized, PersonLocaleFromEnvironment())
enum Live {}

/// Runs every test below it under the locale named by `FL_LOCALE`, if one is.
/// A test that sets its own locale (the language suites) still gets its own:
/// the inner task-local value wins.
///
/// A test trait as well as a suite trait: one that applies recursively is
/// handed down to the tests themselves, and Swift Testing traps while
/// building its plan if it is not one.
struct PersonLocaleFromEnvironment: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard let identifier = ProcessInfo.processInfo.environment["FL_LOCALE"], !identifier.isEmpty else {
            return try await function()
        }
        try await LanguageModels.$localeOverride.withValue(Locale(identifier: identifier)) {
            try await function()
        }
    }
}
