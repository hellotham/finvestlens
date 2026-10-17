//
//  ReopenLastBookTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

@Suite("Reopening the last book at launch")
struct ReopenLastBookTests {

    private func defaults(_ value: Any?) throws -> UserDefaults {
        let suite = "finvestlens.tests.reopen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if let value { defaults.set(value, forKey: AppModel.reopenLastBookDefaultsKey) }
        return defaults
    }

    @Test("On unless turned off — by the Settings toggle, or by a launch argument")
    func everyWayTheSettingArrives() throws {
        #expect(AppModel.reopensLastBook(try defaults(nil)), "on by default")
        #expect(AppModel.reopensLastBook(try defaults(true)))
        #expect(!AppModel.reopensLastBook(try defaults(false)), "the Settings toggle")
        // `-finvestlens.reopenLastBook NO` arrives as a string; cast to Bool
        // it was nothing, and the book reopened anyway.
        #expect(!AppModel.reopensLastBook(try defaults("NO")), "a launch argument")
        #expect(AppModel.reopensLastBook(try defaults("YES")))
    }
}
