//
//  LinkPickerTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  "Link to Transaction…" asks for its rows on every keystroke. It now reads
//  an index built once per change to the transactions (Performance Review
//  P8b); these hold the index to the answers the full walk gave.
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("The link picker's search", .serialized)
struct LinkPickerTests {

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("Text, an amount prefix and a date find the same rows, newest first, after an edit too")
    func search() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        func spend(_ text: String, _ amount: Decimal, on date: Date) throws -> GncGUID {
            try model.addTransaction(date: date, description: text, currency: .aud,
                                     splits: [SplitInput(accountID: bank, value: -amount),
                                              SplitInput(accountID: food, value: amount)])
        }
        let older = try spend("Grocer", Decimal(string: "600.55")!, on: Self.day(2026, 3, 13))
        let newer = try spend("Grocer", 42, on: Self.day(2026, 4, 2))
        let other = try spend("Cafe", 18, on: Self.day(2026, 4, 1))
        let otherDay = Self.day(2026, 4, 1)

        #expect(model.transactionsForLinking(query: "").map(\.id) == [newer, other, older])
        #expect(model.transactionsForLinking(query: "GROCER").map(\.id) == [newer, older])
        #expect(model.transactionsForLinking(query: "600").map(\.id) == [older], "an amount prefix")
        let dateQuery = AppDateFormat.current.short(Self.day(2026, 3, 13))
        #expect(model.transactionsForLinking(query: dateQuery).map(\.id).contains(older))
        #expect(model.transactionsForLinking(query: "", limit: 2).map(\.id) == [newer, other])

        // An edit moves the transaction revision, and the index with it.
        model.setDocumentLink("receipt.pdf", for: other)
        _ = try model.updateTransaction(id: other, date: otherDay, description: "Grocer cafe", currency: .aud,
                                        splits: [SplitInput(accountID: bank, value: -18),
                                                 SplitInput(accountID: food, value: 18)])
        #expect(model.transactionsForLinking(query: "grocer").map(\.id) == [newer, other, older])
        #expect(model.transactionsForLinking(query: "cafe").first?.hasDocument == true)
        // No rows asked for is none (17 October review: the limit was checked
        // only after a row had been added, so 0 returned every match).
        #expect(model.transactionsForLinking(query: "", limit: 0).isEmpty)
        #expect(model.transactionsForLinking(query: "grocer", limit: -1).isEmpty)
    }

    @Test("Each keystroke finds what a fresh search would, whether it narrows the last or not")
    func keystrokes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close() }
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        for (index, text) in ["Café Roma", "Cafe Nero", "Card fee 12", "Rent 12/3", "Grocer 600"].enumerated() {
            _ = try model.addTransaction(date: Self.day(2026, 3, 1 + index), description: text, currency: .aud,
                                         splits: [SplitInput(accountID: bank, value: -Decimal(12 + index)),
                                                  SplitInput(accountID: food, value: Decimal(12 + index))])
        }
        // Typed a letter at a time — each answer narrows the one before, or
        // starts afresh where it reads amounts or dates the last did not —
        // against the same query asked of a new model state each time.
        func fresh(_ query: String) -> [GncGUID] {
            let typing = model.linkingIndex
            model.linkingIndex = nil
            defer { model.linkingIndex = typing }
            return model.transactionsForLinking(query: query).map(\.id)
        }
        for word in ["café", "card fee", "12/3", "1", "12", "grocer 6"] {
            var typed = ""
            for character in word {
                typed.append(character)
                let narrowed = model.transactionsForLinking(query: typed).map(\.id)
                #expect(narrowed == fresh(typed), "typing \(typed)")
            }
        }
        // A non-ASCII description is still searched the way it was.
        #expect(fresh("café").count == 1)
        #expect(fresh("caf").count == 2)
    }
}
