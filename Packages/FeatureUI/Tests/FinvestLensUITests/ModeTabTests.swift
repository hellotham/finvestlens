//
//  ModeTabTests.swift
//  FinvestLens — FeatureUI
//
//  P12/N3 — several open items within one mode (`FR-NAV-05`, `FR-NAV-06`).
//
//  The rules are GnuCash's, read 15 Aug 2026 from ~/Repositories/gnucash-reference:
//
//  - **Never a duplicate.** `gnc-main-window.cpp:3291` checks
//    `gnc_main_window_page_exists` and displays the existing page instead.
//  - **A new tab is a deliberate act.** A register opens from the account tree
//    on *double*-click (`gnc-plugin-page-account-tree.cpp:987`); single click
//    selects.
//  - **A placeholder opens nothing** — it has no register to show.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Mode tabs")
struct ModeTabTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let savings: GncGUID
        let parent: GncGUID
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let parent = try #require(model.addAccount(name: "Assets", type: .asset))
        let bank = try #require(model.addAccount(name: "Everyday", type: .bank, parentID: parent))
        let savings = try #require(model.addAccount(name: "Savings", type: .bank, parentID: parent))
        model.book?.account(with: parent)?.isPlaceholder = true
        return Fixture(model: model, url: url, bank: bank, savings: savings, parent: parent)
    }

    /// Every mode starts with exactly its home, and the home cannot be closed.
    @Test("A mode starts on its home tab, which never closes")
    func homeTabIsPinned() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        for mode in AppMode.allCases {
            f.model.showMode(mode)
            #expect(f.model.openTabs == [mode.defaultSelection])
            #expect(f.model.activeTabIndex == 0)
            f.model.closeTab(0)
            #expect(f.model.openTabs == [mode.defaultSelection], "\(mode.rawValue) lost its home")
        }
    }

    /// From the home tab a click opens a tab beside it; from anywhere else it
    /// replaces what is showing. Replacing the home would lose the one tab a
    /// mode cannot be without.
    @Test("A click replaces the current tab, except on home")
    func clickReplacesExceptOnHome() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .account(f.bank))
        #expect(f.model.openTabs == [.generalLedger, .account(f.bank)])
        #expect(f.model.activeTabIndex == 1)

        // Second click, from a non-home tab: replaces rather than accumulating.
        f.model.navigate(to: .account(f.savings))
        #expect(f.model.openTabs == [.generalLedger, .account(f.savings)])
        #expect(f.model.activeTabIndex == 1)
    }

    /// The deliberate act.
    @Test("A new tab is opened on request")
    func newTabIsDeliberate() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .account(f.bank))
        f.model.navigate(to: .account(f.savings), inNewTab: true)
        #expect(f.model.openTabs == [.generalLedger, .account(f.bank), .account(f.savings)])
        #expect(f.model.activeTabIndex == 2)
    }

    /// GnuCash checks first and displays the page it already has
    /// (`gnc-main-window.cpp:3291`). So does this — even when asked for a new
    /// tab, because two tabs on one register is the thing that check prevents.
    @Test("Opening something already open focuses its tab")
    func neverDuplicates() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .account(f.bank))
        f.model.navigate(to: .account(f.savings), inNewTab: true)
        #expect(f.model.openTabs.count == 3)

        f.model.navigate(to: .account(f.bank), inNewTab: true)
        #expect(f.model.openTabs.count == 3, "opened a duplicate tab")
        #expect(f.model.activeTabIndex == 1)

        // The home tab, likewise: navigating to it focuses rather than adds.
        f.model.navigate(to: .generalLedger, inNewTab: true)
        #expect(f.model.openTabs.count == 3)
        #expect(f.model.activeTabIndex == 0)
    }

    /// A placeholder has no register, so it opens nothing — GnuCash expands the
    /// row instead, which the sidebar's own disclosure already does.
    @Test("A placeholder account opens no tab")
    func placeholderOpensNothing() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.showMode(.accounts)
        f.model.navigate(to: .account(f.parent))
        #expect(f.model.openTabs == [.generalLedger])
        #expect(f.model.sidebarSelection == .generalLedger)
    }

    @Test("Closing a tab lands on the one that took its place")
    func closingLandsSensibly() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .account(f.bank))
        f.model.navigate(to: .account(f.savings), inNewTab: true)
        f.model.selectTab(1)
        f.model.closeTab(1)
        #expect(f.model.openTabs == [.generalLedger, .account(f.savings)])
        #expect(f.model.sidebarSelection == .account(f.savings))
    }

    @Test("Close Other Tabs keeps the one asked for, and the home")
    func closeOthers() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .account(f.bank))
        f.model.navigate(to: .account(f.savings), inNewTab: true)
        f.model.closeOtherTabs(keeping: 1)
        #expect(f.model.openTabs == [.generalLedger, .account(f.bank)])
    }

    /// Each mode keeps its own strip — that is what makes a mode a place you
    /// come back to rather than a filter over one list.
    @Test("Tabs belong to their mode")
    func tabsArePerMode() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .account(f.bank))
        f.model.showMode(.planning)
        #expect(f.model.openTabs == [.planner])

        f.model.navigate(to: .budgets)
        #expect(f.model.openTabs == [.planner, .budgets])

        f.model.showMode(.accounts)
        #expect(f.model.openTabs == [.generalLedger, .account(f.bank)])
    }

    /// plan.md §13d exit criterion 6: the open set survives relaunch.
    @Test("The open set survives a reopen")
    func tabsSurviveRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }
        defer {
            UserDefaults.standard.removeObject(
                forKey: "session.navigation:\(url.standardizedFileURL.path)")
        }

        let first = AppModel()
        try first.newDocument(at: url)
        let bank = try #require(first.addAccount(name: "Everyday", type: .bank))
        let savings = try #require(first.addAccount(name: "Savings", type: .bank))
        first.navigate(to: .account(bank))
        first.navigate(to: .account(savings), inNewTab: true)
        try first.save()
        first.close()

        let second = AppModel()
        await second.openBook(at: url)
        #expect(second.mode == .accounts)
        #expect(second.openTabs == [.generalLedger, .account(bank), .account(savings)])
        #expect(second.sidebarSelection == .account(savings))
        second.close()
    }

    /// A tab pointing at an account the book no longer has is dropped, not
    /// restored dead — the file can change outside the app.
    @Test("A vanished account's tab is dropped on restore")
    func vanishedTabDropped() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let key = "session.navigation:\(url.standardizedFileURL.path)"
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: key)
        }

        let seed = AppModel()
        try seed.newDocument(at: url)
        try seed.save()
        seed.close()

        let ghost = GncGUID.random().hexString
        UserDefaults.standard.set(
            #"{"mode":"accounts","tabs":{"accounts":["account:\#(ghost)"]},"active":{"accounts":1}}"#,
            forKey: key)

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.openTabs == [.generalLedger])
        #expect(model.activeTabIndex == 0, "landed on a tab that is not there")
        model.close()
    }

    /// A desk state written by N1 — one selection per mode, no tabs — becomes
    /// that mode's single open tab rather than being discarded.
    @Test("An N1 desk state becomes one open tab")
    func migratesN1Selections() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let key = "session.navigation:\(url.standardizedFileURL.path)"
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: key)
        }

        let seed = AppModel()
        try seed.newDocument(at: url)
        try seed.save()
        seed.close()

        UserDefaults.standard.set(
            #"{"mode":"planning","selections":{"planning":"budgets"}}"#, forKey: key)

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.mode == .planning)
        #expect(model.openTabs == [.planner, .budgets])
        #expect(model.sidebarSelection == .budgets)
        model.close()
    }
}
