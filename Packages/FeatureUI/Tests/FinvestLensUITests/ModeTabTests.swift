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

// MARK: - Defects found by review, 15 Aug 2026

@MainActor
@Suite("Mode tabs — regressions")
struct ModeTabRegressionTests {

    private func book() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    /// ⌘T and the strip's `+` opened a **duplicate of the home tab**.
    ///
    /// They first did nothing at all — asking for a second tab on what is
    /// showing, where the never-a-duplicate rule fires before the new-tab
    /// branch. The fix for that appended `mode.defaultSelection` directly,
    /// bypassing the dedupe — but that selection *is* the home tab, derived as
    /// index 0 and never stored, so the result was a second copy of it that
    /// `restoreNavigation` filtered out again on reopen: a tab you could make
    /// but not keep.
    ///
    /// The contract now: New Tab opens one of the mode's **other**
    /// destinations, and each one only once.
    @Test("New Tab opens a destination that is not already open")
    func newTabOpensADestination() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Everyday", type: .bank))
        let savings = try #require(model.addAccount(name: "Savings", type: .bank))

        model.showMode(.accounts)
        #expect(model.openTabs.count == 1)

        model.openNewTab()
        #expect(model.openTabs.count == 2)
        #expect(model.activeTabIndex == 1)
        #expect(model.openTabs[1] != model.openTabs[0], "New Tab duplicated the home tab")

        model.openNewTab()
        #expect(model.openTabs.count == 3, "a second New Tab did nothing")
        #expect(Set(model.openTabs).count == 3, "New Tab opened something already open")
        #expect(Set(model.openTabs).isSuperset(of: [.account(bank), .account(savings)]))
    }

    /// Nothing left to open is a no-op, not a duplicate. A book with no
    /// accounts has exactly one thing Accounts can show, and it is already tab
    /// 0 — which is the state the old implementation turned into a second copy
    /// of it.
    @Test("New Tab does nothing when the mode has nothing else to show")
    func newTabIsANoOpWhenExhausted() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.showMode(.accounts)
        model.openNewTab()
        #expect(model.openTabs.count == 1)
        #expect(model.unopenedTabDestinations.isEmpty)
    }

    /// Clicking the collection row after opening one of its instances.
    ///
    /// Reported 16 Aug 2026: "Clicking on reports in the sidebar does not
    /// work." Reproduced on screen — with Balance Sheet showing, clicking
    /// "All Reports" left the selection, the tab and the content unchanged.
    @Test("Selecting a mode's home row returns to it")
    func homeRowIsSelectable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.showMode(.reports)
        #expect(model.sidebarSelection == .reports)

        // Open a report, as clicking one in the sidebar does.
        model.navigate(to: .report(.balanceSheet))
        #expect(model.sidebarSelection == .report(.balanceSheet))
        #expect(model.activeTabIndex == 1)

        // Now click "All Reports" — the collection row.
        model.navigate(to: .reports)
        #expect(model.sidebarSelection == .reports, "the home row did not take the selection")
        #expect(model.activeTabIndex == 0, "the home tab did not become active")
    }

    /// A stored active index that outruns its tab list used to crash the next
    /// single-click navigation: the replace branch subscripted `extras` with it.
    @Test("An out-of-range stored tab index does not crash a navigation")
    func poisonedIndexIsSurvivable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let key = "session.navigation:\(url.standardizedFileURL.path)"
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: key)
        }

        let seed = AppModel()
        try seed.newDocument(at: url)
        let bank = try #require(seed.addAccount(name: "Everyday", type: .bank))
        try seed.save()
        seed.close()

        // A desk state naming one tab that no longer exists, with the index
        // still pointing past the end of what survives the filter.
        let ghost = GncGUID.random().hexString
        UserDefaults.standard.set(
            #"{"mode":"accounts","tabs":{"accounts":["account:\#(ghost)"]},"active":{"accounts":1}}"#,
            forKey: key)

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.activeTabIndex == 0)
        // The navigation that used to trap.
        model.navigate(to: .account(bank))
        #expect(model.openTabs == [.generalLedger, .account(bank)])
        model.close()
    }

    /// Dropping a dead tab shifts every index after it. Restoring the stored
    /// index unchanged landed the user on the tab *next to* the one they left.
    @Test("A dropped tab does not shift the restored selection")
    func droppedTabKeepsThePlace() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let key = "session.navigation:\(url.standardizedFileURL.path)"
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: key)
        }

        let seed = AppModel()
        try seed.newDocument(at: url)
        let b = try #require(seed.addAccount(name: "B", type: .bank))
        let c = try #require(seed.addAccount(name: "C", type: .bank))
        try seed.save()
        seed.close()

        // [home, ghost, B, C] with C active; the ghost is filtered out.
        let ghost = GncGUID.random().hexString
        let stored = """
        {"mode":"accounts","tabs":{"accounts":["account:\(ghost)","account:\(b.hexString)",\
        "account:\(c.hexString)"]},"active":{"accounts":3}}
        """
        UserDefaults.standard.set(stored, forKey: key)

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.openTabs == [.generalLedger, .account(b), .account(c)])
        // Clamped into the list rather than left pointing past its end.
        #expect(model.openTabs.indices.contains(model.activeTabIndex))
        model.close()
    }

    /// `.auditLog` encoded but had no decode arm, so a Records Audit Log tab
    /// was written on every navigation and dropped on every reopen.
    @Test("An Audit Log tab survives a reopen")
    func auditLogTabRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let key = "session.navigation:\(url.standardizedFileURL.path)"
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: key)
        }

        let first = AppModel()
        try first.newDocument(at: url)
        first.navigate(to: .auditLog)
        try first.save()
        first.close()

        let second = AppModel()
        await second.openBook(at: url)
        #expect(second.mode == .records)
        #expect(second.openTabs.contains(.auditLog), "the Audit Log tab was dropped")
        second.close()
    }
}

@MainActor
@Suite("Tab indices survive a standing tab")
struct StandingTabIndexTests {

    /// A book with a portfolio, so Investments has a standing tab between the
    /// home tab and anything the user opened.
    private func makeFixture() throws -> (model: AppModel, url: URL, security: GncGUID) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let broker = try #require(model.addAccount(name: "Broker", type: .asset))
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA.AX",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let holding = try #require(model.addAccount(name: "CBA", type: .stock,
                                                    commodity: cba, parentID: broker))
        let cash = try #require(model.addAccount(name: "Cash", type: .bank))
        // A portfolio is a parent of a holding with units still in it, so the
        // holding needs a buy before Broker becomes a standing tab.
        _ = try model.addTransaction(date: Date(timeIntervalSince1970: 0), description: "Buy",
                                     currency: .aud,
                                     splits: [SplitInput(accountID: holding, value: 1000,
                                                         quantity: 10),
                                              SplitInput(accountID: cash, value: -1000)])
        // `restoreNavigation` is the public way into a mode here.
        model.restoreNavigation(mode: .investments, tabs: [:], active: [:])
        return (model, url, holding)
    }

    /// Closes the document and removes it. Without this each test leaks a
    /// `.finvestlens` file, its lock sidecar and working copy, leaves quote and
    /// maintenance timers running for the rest of the process, and leaves
    /// `finvestlens.lastBookPath` pointing at a temp book that other suites in
    /// this same target read.
    private func tearDown(_ model: AppModel, _ url: URL) {
        model.close()
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Investments really does have a standing tab in this fixture")
    func fixtureHasAStandingTab() throws {
        // Without this the tests below would pass for the wrong reason.
        let (model, url, _) = try makeFixture()
        defer { tearDown(model, url) }
        #expect(model.firstClosableTabIndex(in: .investments) > 1)
    }

    @Test("A restored index onto a standing tab is not clamped away")
    func restoreKeepsAStandingTabIndex() throws {
        // The clamp counted stored tabs plus one for home and forgot the
        // standing tabs, so a valid index was pulled back to the last one it
        // believed existed and the restore opened on the wrong tab.
        let (model, url, _) = try makeFixture()
        defer { tearDown(model, url) }
        let standingIndex = 1
        model.restoreNavigation(mode: .investments, tabs: [:],
                                active: [.investments: standingIndex])
        #expect(model.activeTabIndex == standingIndex)
        #expect(model.openTabs[model.activeTabIndex] == model.tabs(in: .investments)[standingIndex])
    }

    @Test("A stored tab that has since become standing is not shown twice, and closing works")
    func storedDuplicateOfAStandingTab() throws {
        let (model, url, security) = try makeFixture()
        defer { tearDown(model, url) }
        let portfolio = try #require(model.tabs(in: .investments).dropFirst().first)
        // Desk state written when this account was not yet a portfolio.
        let commodity = try #require(model.book?.account(with: security)?.commodity)
        model.restoreNavigation(
            mode: .investments,
            tabs: [.investments: [portfolio,
                                  .security(SidebarSelection.securityKey(commodity))]],
            active: [.investments: 0])
        let strip = model.tabs(in: .investments)
        #expect(strip.filter { $0 == portfolio }.count == 1)

        // Closing the last tab must remove *that* tab. Indexing storage with a
        // display index took the portfolio out of the stored list instead,
        // leaving the clicked tab on screen.
        let last = strip.count - 1
        let doomed = strip[last]
        model.closeTab(last)
        #expect(!model.tabs(in: .investments).contains(doomed))
        #expect(model.tabs(in: .investments).contains(portfolio))
    }
}
