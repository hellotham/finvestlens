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

@MainActor
@Suite("Sidebar sort storage")
struct SidebarSortStorageTests {

    /// `ModeSidebar` reads the key through `@AppStorage`, which needs a
    /// literal, so the literal and the model's key generator have to agree.
    @Test("The sidebar's @AppStorage key is the model's key")
    func keysAgree() {
        #expect(SidebarSort.storageKey(for: .accounts) == "sidebar.sort.accounts")
    }
}

/// The sidebar drag, and its keyboard equivalent.
///
/// The drag shipped once with only its re-parent half wired, so a gesture that
/// looked like sorting was editing the chart of accounts. Both halves exist
/// now, they are drawn differently, and the rule that tells them apart is a
/// pure function so it can be checked without a pointer.
@MainActor
@Suite("Sidebar reordering")
struct SidebarReorderTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let a: GncGUID
        let b: GncGUID
        let c: GncGUID
        let parent: GncGUID
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let parent = try #require(model.addAccount(name: "Assets", type: .asset))
        let a = try #require(model.addAccount(name: "A", type: .bank, parentID: parent))
        let b = try #require(model.addAccount(name: "B", type: .bank, parentID: parent))
        let c = try #require(model.addAccount(name: "C", type: .bank, parentID: parent))
        return Fixture(model: model, url: url, a: a, b: b, c: c, parent: parent)
    }

    private func order(_ f: Fixture) -> [String] {
        (f.model.siblings(of: f.a) ?? []).map(\.name)
    }

    /// The top and bottom quarters reorder; the middle half re-parents. Aiming
    /// at "between" is the fiddlier of the two, and it is the harmless one.
    @Test("The drop zone follows where in the row you let go")
    func zonesSplitTheRow() {
        #expect(AccountRowDrop.zone(atY: 1, height: 24) == .before)
        #expect(AccountRowDrop.zone(atY: 12, height: 24) == .onto)
        #expect(AccountRowDrop.zone(atY: 23, height: 24) == .after)
        // The boundaries land on the safe side: exactly a quarter in is still
        // the re-parent zone, so a reorder needs deliberate aim.
        #expect(AccountRowDrop.zone(atY: 6, height: 24) == .onto)
        #expect(AccountRowDrop.zone(atY: 18, height: 24) == .onto)
    }

    /// A second reorder has to be measured against what the user can see.
    /// `reorderAccount` writes `sidebarOrder` and leaves `parent.children`
    /// alone, so working from storage order was right exactly once.
    @Test("Reordering twice compounds rather than fighting itself")
    func secondReorderUsesDisplayOrder() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(order(f) == ["A", "B", "C"])
        f.model.reorderAccount(f.c, to: 0)
        #expect(order(f) == ["C", "A", "B"])
        // Now move A — which is at display index 1 — to the end.
        f.model.reorderAccount(f.a, to: 2)
        #expect(order(f) == ["C", "B", "A"])
    }

    /// The keyboard's half: dragging is the pointer's way, and under VoiceOver
    /// a drag is not a gesture at all.
    @Test("Move Up and Move Down walk the same order")
    func nudgeWalksDisplayOrder() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.nudgeAccount(f.c, by: -1)
        #expect(order(f) == ["A", "C", "B"])
        f.model.nudgeAccount(f.c, by: -1)
        #expect(order(f) == ["C", "A", "B"])
    }

    /// The ends stop, and the menu items are disabled rather than doing
    /// nothing — a control that looks live and is not is worse than a dim one.
    @Test("The first and last rows cannot move past the ends")
    func nudgeStopsAtTheEnds() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(!f.model.canNudgeAccount(f.a, by: -1))
        #expect(f.model.canNudgeAccount(f.a, by: 1))
        #expect(!f.model.canNudgeAccount(f.c, by: 1))

        f.model.nudgeAccount(f.a, by: -1)
        #expect(order(f) == ["A", "B", "C"], "an account moved past the start")
    }
}

@MainActor
@Suite("Sidebar drag-reorder placement")
struct SidebarPlacementTests {

    /// Closes the document and removes it. Without this each test leaks a
    /// `.finvestlens` file, its lock sidecar and working copy, leaves quote and
    /// maintenance timers running for the rest of the process, and leaves
    /// `finvestlens.lastBookPath` pointing at a temp book that other suites in
    /// this same target read.
    private func tearDown(_ model: AppModel, _ url: URL) {
        model.close()
        try? FileManager.default.removeItem(at: url)
    }


    private struct Fixture {
        let model: AppModel
        let url: URL
        let ids: [String: GncGUID]
    }

    /// Four top-level siblings, A B C D, in that manual order.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        var ids: [String: GncGUID] = [:]
        for (index, name) in ["A", "B", "C", "D"].enumerated() {
            let id = try #require(model.addAccount(name: name, type: .bank))
            model.book?.account(with: id)?.sidebarOrder = index
            ids[name] = id
        }
        return Fixture(model: model, url: url, ids: ids)
    }

    private func order(_ f: Fixture) -> [String] {
        (f.model.book?.rootAccount.children ?? [])
            .filter { ["A", "B", "C", "D"].contains($0.name) }
            .sorted { ($0.sidebarOrder ?? .max) < ($1.sidebarOrder ?? .max) }
            .map(\.name)
    }

    @Test("Dropping A after B puts it directly after B, not one past it")
    func downwardDropDoesNotOvershoot() throws {
        // The drop handler passed an index counted in the list that still
        // contained the dragged row, while the reorder removed it first — so
        // every downward drop landed one row too far.
        let f = try makeFixture()
        defer { tearDown(f.model, f.url) }
        f.model.reorderAccount(f.ids["A"]!, .after(f.ids["B"]!))
        #expect(order(f) == ["B", "A", "C", "D"])
    }

    @Test("Dropping upward lands where it did before")
    func upwardDropUnchanged() throws {
        let f = try makeFixture()
        defer { tearDown(f.model, f.url) }
        f.model.reorderAccount(f.ids["D"]!, .before(f.ids["B"]!))
        #expect(order(f) == ["A", "D", "B", "C"])
    }

    @Test("Dropping after the last row puts it last")
    func dropAtTheEnd() throws {
        let f = try makeFixture()
        defer { tearDown(f.model, f.url) }
        f.model.reorderAccount(f.ids["A"]!, .after(f.ids["D"]!))
        #expect(order(f) == ["B", "C", "D", "A"])
    }

    @Test("A drop that changes nothing records no undo step")
    func noOpDrop() throws {
        let f = try makeFixture()
        defer { tearDown(f.model, f.url) }
        let undo = UndoManager()
        f.model.undoManager = undo
        f.model.reorderAccount(f.ids["A"]!, .before(f.ids["B"]!))
        #expect(order(f) == ["A", "B", "C", "D"])
        #expect(!undo.canUndo)
        // …and a real move does register one, so the check above means
        // something.
        f.model.reorderAccount(f.ids["A"]!, .after(f.ids["B"]!))
        #expect(undo.canUndo)
    }

    @Test("Placement is by neighbour identity, so a hidden sibling cannot shift it")
    func hiddenSiblingIgnored() throws {
        // Honest about what this pins. `siblings(of:)` does not filter hidden
        // accounts, so setting the flag changes nothing here — that is the
        // point: the neighbour-named API resolves the target by identity after
        // the removal, so no index crosses the visible/stored boundary and the
        // hidden row is structurally incapable of shifting the result. The
        // integer API could not make that claim. Driving the actual drop
        // handler needs `AccountRowDrop`, which is not reachable from a unit
        // test — that path stays covered only by the API it now calls.
        let f = try makeFixture()
        defer { tearDown(f.model, f.url) }
        f.model.book?.account(with: f.ids["A"]!)?.isHidden = true
        f.model.reorderAccount(f.ids["D"]!, .after(f.ids["B"]!))
        #expect(order(f) == ["A", "B", "D", "C"])
        // Same move, hidden flag cleared: identical result, proving placement
        // does not consult visibility at all.
        let g = try makeFixture()
        defer { tearDown(g.model, g.url) }
        g.model.reorderAccount(g.ids["D"]!, .after(g.ids["B"]!))
        #expect(order(g) == order(f))
    }

    @Test("Nudging still moves exactly one place in each direction")
    func nudgeUnaffected() throws {
        // `nudgeAccount` speaks the other index convention; the new API must
        // not have disturbed it.
        let f = try makeFixture()
        defer { tearDown(f.model, f.url) }
        f.model.nudgeAccount(f.ids["C"]!, by: -1)
        #expect(order(f) == ["A", "C", "B", "D"])
        f.model.nudgeAccount(f.ids["C"]!, by: 1)
        #expect(order(f) == ["A", "B", "C", "D"])
    }
}
