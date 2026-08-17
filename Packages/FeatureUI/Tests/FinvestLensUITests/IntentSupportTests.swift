//
//  IntentSupportTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Intent support summaries")
struct IntentSupportTests {

    @Test("Net-worth summary reads the last-opened book")
    func netWorth() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)   // records the last-book path
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let opening = try #require(model.addAccount(name: "Opening", type: .equity))
        try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Open",
                                 currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("1000")),
            SplitInput(accountID: opening, value: dec("-1000")),
        ])
        try model.save()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let summary = IntentSupport.netWorthSummary()
        #expect(summary.contains("net worth"))
        #expect(summary.contains("1,000") || summary.contains("1000"))
    }

    @Test("No book yields a friendly message")
    func noBook() {
        UserDefaults.standard.removeObject(forKey: "finvestlens.lastBookPath")
        #expect(IntentSupport.netWorthSummary().contains("No FinvestLens book"))
    }
}

@MainActor
@Suite("Lock transitions keep the widget honest")
struct LockWidgetSyncTests {

    private func makeBook() throws -> (model: AppModel, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        // `AllowAllAuthenticator`, not the default `BiometricAuthenticator`.
        // The real one calls `LAContext.evaluatePolicy`, which on a CI runner
        // with a logged-in account can evaluate device-password policy and then
        // block forever on a prompt nobody can answer — this test hung the
        // FeatureUI job for 22 minutes. BookLockTests already does it this way.
        let model = AppModel(authenticator: AllowAllAuthenticator())
        try model.newDocument(at: url)
        return (model, url)
    }

    @Test("Locking and unlocking both republish, so the widget cannot contradict the lock")
    func bothTransitionsPublish() async throws {
        // Locking mid-session used to leave real net worth and bill totals on
        // the Lock Screen until the next save, and unlocking never restored
        // the widget or the alert schedule that opening a protected book had
        // cleared. Both transitions now go through `publishWidgetData`.
        let (model, url) = try makeBook()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.requireAuthentication = true
        model.lockNow()
        #expect(model.isLocked)

        // Unlock succeeds without LocalAuthentication in tests, by design.
        let ok = await model.unlock()
        #expect(ok)
        #expect(!model.isLocked)
    }
}
