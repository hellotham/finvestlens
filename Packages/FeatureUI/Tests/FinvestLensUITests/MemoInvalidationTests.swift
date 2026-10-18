//
//  MemoInvalidationTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The memos added for the performance review's first batch — the typed
//  account lists (P4), the accent colour (R9f) and the equity choices of the
//  close sheet (P3.2) — each answer from a cache. A cache is only right while
//  it is dropped when what it was built from changes; these hold each one to
//  that.
//

import Foundation
import SwiftUI
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Memos follow what they were built from", .serialized)
struct MemoInvalidationTests {

    private func withBook(_ body: (AppModel) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        try body(model)
    }

    @Test("The typed account lists follow a new account")
    func typedLists() throws {
        try withBook { model in
            _ = try #require(model.addAccount(name: "Bank", type: .bank))
            let before = model.settlementAccountNodes.count
            #expect(model.expenseAccountNodes.isEmpty)
            _ = try #require(model.addAccount(name: "Groceries", type: .expense))
            _ = try #require(model.addAccount(name: "Savings", type: .bank))
            #expect(model.expenseAccountNodes.map(\.name) == ["Groceries"])
            #expect(model.settlementAccountNodes.count == before + 1)
        }
    }

    @Test("The equity choices follow a new equity account")
    func equityChoices() throws {
        try withBook { model in
            let first = model.equityAccountChoices.count
            _ = try #require(model.addAccount(name: "Retained Earnings", type: .equity))
            #expect(model.equityAccountChoices.count == first + 1)
            #expect(model.equityAccountChoices.contains { $0.name.hasSuffix("Retained Earnings") })
        }
    }

    @Test("The Price History document follows the date order")
    func priceHistoryFollowsTheDateOrder() throws {
        let saved = UserDefaults.standard.string(forKey: AppDateFormat.orderKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AppDateFormat.orderKey) }
            else { UserDefaults.standard.removeObject(forKey: AppDateFormat.orderKey) }
        }
        try withBook { model in
            let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "Commonwealth Bank", smallestFraction: 10000)
            _ = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let date = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 16, hour: 12)))
            model.addPrice(commodity: cba, currency: .aud, date: date, value: 120)
            @MainActor func row() throws -> String {
                try #require(model.priceHistoryDocument()?.sections.first?.rows.first?.label)
            }
            UserDefaults.standard.set(DateOrder.dmy.rawValue, forKey: AppDateFormat.orderKey)
            let dayFirst = try row()
            UserDefaults.standard.set(DateOrder.ymd.rawValue, forKey: AppDateFormat.orderKey)
            let yearFirst = try row()
            // Same book, same revision: only the setting moved, and the
            // memoised document moved with it (17 October review).
            #expect(dayFirst != yearFirst)
            #expect(yearFirst.contains(AppDateFormat(order: .ymd).long(date)))
        }
    }

    @Test("A warm forecast is there to draw before its task lands")
    func forecastPeek() throws {
        try withBook { model in
            let bank = try #require(model.addAccount(name: "Bank", type: .bank))
            #expect(model.cachedCashFlowForecast(accountID: bank) == nil, "nothing built yet")
            let built = model.cashFlowForecast(accountID: bank)
            #expect(model.cachedCashFlowForecast(accountID: bank) == built)
            _ = try #require(model.addAccount(name: "Savings", type: .bank))
            #expect(model.cachedCashFlowForecast(accountID: bank) == nil, "the book moved; the memo went with it")
        }
    }

    @Test("The accent colour follows the picker's write to the defaults")
    func accentFollowsTheDefaults() throws {
        let saved = UserDefaults.standard.string(forKey: AppearanceKey.accent)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AppearanceKey.accent) }
            else { UserDefaults.standard.removeObject(forKey: AppearanceKey.accent) }
        }
        // Each accent is an adaptive colour built afresh per call, and two
        // of those never compare equal; compared as they resolve — which is
        // what a view draws — they do.
        let environment = EnvironmentValues()
        func drawn(_ color: Color) -> Color.Resolved { color.resolve(in: environment) }
        let other = try #require(AppAccent.allCases.first { $0 != .lavender })
        UserDefaults.standard.set(AppAccent.lavender.rawValue, forKey: AppearanceKey.accent)
        #expect(drawn(Color.appAccent) == drawn(AppAccent.lavender.color))
        // Read twice: the second comes from the cache.
        #expect(drawn(Color.appAccent) == drawn(AppAccent.lavender.color))
        UserDefaults.standard.set(other.rawValue, forKey: AppearanceKey.accent)
        #expect(drawn(Color.appAccent) == drawn(other.color), "the write dropped the cached accent")
        #expect(drawn(Color.appAccent) != drawn(AppAccent.lavender.color))
    }
}

@Suite("The newest transactions, picked in one pass")
struct NewestTransactionsTests {

    @Test("The first n of a newest-first sort, a day's transactions in book order")
    func matchesTheSort() {
        // Many days with several transactions each, in no order at all.
        var generator = SystemRandomNumberGenerator()
        let transactions = (0..<2_000).map { index in
            Transaction(currency: .aud,
                        datePosted: Date(timeIntervalSince1970: Double(Int.random(in: 0..<300, using: &generator)) * 86_400),
                        description: "\(index)")
        }
        // And in date order with several a day, the shape a book keeps.
        let inOrder = transactions.enumerated()
            .sorted { $0.element.datePosted != $1.element.datePosted
                        ? $0.element.datePosted < $1.element.datePosted : $0.offset < $1.offset }
            .map(\.element)
        for count in [0, 1, 40, 2_000] {
            let stable = Array(inOrder.enumerated()
                .sorted { $0.element.datePosted != $1.element.datePosted
                            ? $0.element.datePosted > $1.element.datePosted : $0.offset < $1.offset }
                .map(\.element).prefix(count))
            #expect(AppModel.newest(count, of: inOrder).map(ObjectIdentifier.init) == stable.map(ObjectIdentifier.init))
        }
        for count in [0, 1, 40, 1_999, 2_000, 2_500] {
            let sorted = Array(transactions.sorted { $0.datePosted > $1.datePosted }.prefix(count))
            let stable = Array(transactions.enumerated()
                .sorted { $0.element.datePosted != $1.element.datePosted
                            ? $0.element.datePosted > $1.element.datePosted : $0.offset < $1.offset }
                .map(\.element).prefix(count))
            let picked = AppModel.newest(count, of: transactions)
            #expect(picked.map(ObjectIdentifier.init) == stable.map(ObjectIdentifier.init))
            #expect(picked.map(ObjectIdentifier.init) == sorted.map(ObjectIdentifier.init))
        }
    }
}
