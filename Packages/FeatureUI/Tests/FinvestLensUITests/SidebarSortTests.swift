//
//  SidebarSortTests.swift
//  FinvestLens — FeatureUI
//
//  P12/N7 — sidebar sorting and manual order (`FR-NAV-12`).
//
//  The manual order lives in the account's own kvp, so it round-trips like
//  everything else. GnuCash has no such slot and ignores it — the right failure
//  mode, and the reason the order is a book edit rather than desk state.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Sidebar sorting")
struct SidebarSortTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let zebra: GncGUID
        let apple: GncGUID
        let mango: GncGUID
    }

    /// Three siblings, deliberately not in name order, with different balances
    /// and different first postings.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let zebra = try #require(model.addAccount(name: "Zebra", type: .bank))
        let apple = try #require(model.addAccount(name: "Apple", type: .bank))
        let mango = try #require(model.addAccount(name: "Mango", type: .bank))
        let income = try #require(model.addAccount(name: "Salary", type: .income))

        // Zebra is posted first and holds the most.
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "a",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: zebra, value: 300),
                                              SplitInput(accountID: income, value: -300)])
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 86_400), description: "b",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: apple, value: 100),
                                              SplitInput(accountID: income, value: -100)])
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 172_800), description: "c",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: mango, value: 200),
                                              SplitInput(accountID: income, value: -200)])
        return Fixture(model: model, url: url, zebra: zebra, apple: apple, mango: mango)
    }

    private func names(_ f: Fixture, _ sort: SidebarSort) -> [String] {
        f.model.sorted(f.model.accountTree, by: sort)
            .filter { $0.name != "Salary" }
            .map(\.name)
    }

    @Test("By name, by balance, and by first transaction")
    func criteriaOrder() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(names(f, .name) == ["Apple", "Mango", "Zebra"])
        #expect(names(f, .balance) == ["Zebra", "Mango", "Apple"])
        // "Opened" is derived from the earliest posting; Zebra was posted first.
        #expect(names(f, .opened) == ["Zebra", "Apple", "Mango"])
    }

    /// Turning manual order on must change nothing until something is actually
    /// moved — otherwise choosing it would scramble a tree the user was reading.
    @Test("Manual order leaves an untouched tree alone")
    func manualIsStableUntilMoved() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let asFound = f.model.accountTree.filter { $0.name != "Salary" }.map(\.name)
        #expect(names(f, .manual) == asFound)
    }

    /// Reordering writes the whole level, so the result does not depend on what
    /// slots happened to be there before.
    @Test("Reordering moves one account and renumbers its siblings")
    func reorderWritesTheLevel() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.reorderAccount(f.mango, to: 0)
        #expect(names(f, .manual).first == "Mango")

        // Every sibling now carries a slot, so the order is total rather than
        // "one account pinned and the rest wherever they were".
        for id in [f.zebra, f.apple, f.mango] {
            #expect(f.model.manualOrder(of: id) != nil)
        }
    }

    /// A book edit, so it undoes — and the order is in the account's kvp, which
    /// is what makes it round-trip.
    @Test("A manual order is stored in the account's kvp")
    func orderIsInTheKvp() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.reorderAccount(f.apple, to: 0)
        let account = try #require(f.model.book?.account(with: f.apple))
        #expect(account.sidebarOrder == 0)

        // Clearing the slot removes it rather than writing a sentinel.
        account.sidebarOrder = nil
        #expect(f.model.manualOrder(of: f.apple) == nil)
    }

    /// Dragging is offered only under manual order: dropping something
    /// "between" a sorted list is a promise the sort breaks on the next redraw.
    @Test("Only manual order allows dragging")
    func draggingIsGatedOnManual() {
        #expect(SidebarSort.manual.allowsDragging)
        for sort in SidebarSort.allCases where sort != .manual {
            #expect(!sort.allowsDragging, "\(sort.rawValue) would let a drag fight the sort")
        }
    }

    /// The book has no opening-date field, so "First Transaction" carries a note
    /// saying where the date comes from — said, not implied.
    @Test("A derived criterion says that it is derived")
    func derivedCriterionIsExplained() {
        #expect(SidebarSort.opened.note != nil)
        #expect(SidebarSort.name.note == nil)
    }

    /// Sorting is per mode: Accounts wanting balance order says nothing about
    /// how Planning should be arranged.
    @Test("A sort belongs to one mode")
    func sortIsPerMode() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }
        defer {
            for mode in AppMode.allCases {
                UserDefaults.standard.removeObject(forKey: "sidebar.sort.\(mode.rawValue)")
            }
        }

        f.model.setSidebarSort(.balance, for: .accounts)
        #expect(f.model.sidebarSort(for: .accounts) == .balance)
        #expect(f.model.sidebarSort(for: .planning) == .manual)
    }
}
