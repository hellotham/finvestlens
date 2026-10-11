//
//  CompactNavigationTests.swift
//  FinvestLens — FeatureUI
//
//  The model's half of the compact shell (`AppModel.compactNavigation`): one
//  destination per mode instead of a tab per visit, and panels as sheets. The
//  stacks themselves are SwiftUI and are toured on a simulator
//  (`ScreenshotTests.testTourCompactDestinations`); what they lean on is here,
//  where it can be asserted.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Compact navigation")
struct CompactNavigationTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let accounts: [GncGUID]
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let ids = try ["Everyday", "Savings", "Card", "Groceries"].map {
            try #require(model.addAccount(name: $0, type: $0 == "Groceries" ? .expense : .bank))
        }
        return Fixture(model: model, url: url, accounts: ids)
    }

    private func finish(_ f: Fixture) {
        f.model.close()
        try? FileManager.default.removeItem(at: f.url)
    }

    /// The defect this exists to prevent: every account looked at on a phone
    /// left a tab behind that nothing on a phone could show or close, and all
    /// of them were waiting in the strip when an iPad window widened again.
    @Test("A phone session opens one destination per mode, not a tab per visit")
    func oneDestinationPerMode() throws {
        let f = try makeFixture()
        defer { finish(f) }
        f.model.compactNavigation = true

        for id in f.accounts {
            f.model.navigate(to: .account(id))
            #expect(f.model.sidebarSelection == .account(id))
            #expect(f.model.tabs(in: .accounts) == [.generalLedger, .account(id)])
        }
        // Back to the root list is the mode's home, and the visit leaves nothing.
        f.model.navigate(to: .generalLedger)
        #expect(f.model.tabs(in: .accounts) == [.generalLedger])
        #expect(f.model.sidebarSelection == .generalLedger)
    }

    /// An iPad narrowed into the compact shell had tabs of its own open. They
    /// are the user's, and they are still there when the window widens.
    @Test("Tabs open before the shell went compact are left as they were")
    func regularTabsSurvive() throws {
        let f = try makeFixture()
        defer { finish(f) }
        f.model.navigate(to: .account(f.accounts[0]), inNewTab: true)
        f.model.navigate(to: .account(f.accounts[1]), inNewTab: true)
        let before = f.model.tabs(in: .accounts)
        #expect(before == [.generalLedger, .account(f.accounts[0]), .account(f.accounts[1])])

        f.model.compactNavigation = true
        f.model.navigate(to: .account(f.accounts[2]))
        f.model.navigate(to: .account(f.accounts[3]))
        #expect(f.model.tabs(in: .accounts) == before + [.account(f.accounts[3])])
        // Revisiting one that was already open adds nothing and takes the
        // compact shell's own tab away.
        f.model.navigate(to: .account(f.accounts[0]))
        #expect(f.model.tabs(in: .accounts) == before)
        #expect(f.model.sidebarSelection == .account(f.accounts[0]))

        f.model.navigate(to: .generalLedger)
        f.model.compactNavigation = false
        #expect(f.model.tabs(in: .accounts) == before)
    }

    /// Leaving a security in Investments used to land on the last portfolio's
    /// tab — whichever standing tab the closed one had been beside.
    @Test("Home is home: leaving a destination lands on the mode's own selection")
    func homeIsHome() throws {
        let f = try makeFixture()
        defer { finish(f) }
        f.model.compactNavigation = true
        f.model.navigate(to: .budgets)
        #expect(f.model.mode == .planning)
        f.model.navigate(to: AppMode.planning.defaultSelection)
        #expect(f.model.sidebarSelection == AppMode.planning.defaultSelection)
        #expect(f.model.tabs(in: .planning) == [AppMode.planning.defaultSelection])
        #expect(f.model.selection(in: .accounts) == .generalLedger, "and other modes are untouched")
    }

    @Test("In the compact shell a panel is a sheet, and a second goes over the first")
    func panelsAreSheets() throws {
        let f = try makeFixture()
        defer { finish(f) }

        // Regular shell: an editor is a tab.
        f.model.presentedPanel = .newAccount
        #expect(f.model.presentedPanel == nil)
        #expect(f.model.sidebarSelection == .panel(.newAccount))
        f.model.navigate(to: .generalLedger)

        f.model.compactNavigation = true
        let before = f.model.sidebarSelection
        f.model.presentedPanel = .newAccount
        #expect(f.model.presentedPanel == .newAccount)
        #expect(f.model.sidebarSelection == before, "nothing navigated")

        // New Security… from inside New Account: on top, not instead.
        f.model.presentedPanel = .newSecurity
        #expect(f.model.presentedPanel == .newAccount, "the first sheet keeps what was typed")
        #expect(f.model.nestedPanel == .newSecurity)

        f.model.nestedPanel = nil
        #expect(f.model.presentedPanel == .newAccount)
        f.model.presentedPanel = nil
        #expect(f.model.presentedPanel == nil && f.model.nestedPanel == nil)

        // A panel that was never a tab still replaces, as it always did.
        f.model.presentedPanel = .find
        f.model.presentedPanel = .saveSearch
        #expect(f.model.presentedPanel == .saveSearch && f.model.nestedPanel == nil)
    }

    /// The pages the stacks push. A new selection has to be given one before
    /// it compiles; this pins the groupings that are behaviour — the Planner's
    /// three tools and a budget in focus must never push a second page.
    @Test("Selections drawn by one view share a page; accounts do not")
    func pages() throws {
        let f = try makeFixture()
        defer { finish(f) }
        #if os(iOS)
        #expect(SidebarSelection.planner.compactPage == SidebarSelection.plannerTax.compactPage)
        #expect(SidebarSelection.planner.compactPage == SidebarSelection.plannerLifetime.compactPage)
        #expect(SidebarSelection.budgets.compactPage == SidebarSelection.budget(f.accounts[0]).compactPage)
        #expect(SidebarSelection.account(f.accounts[0]).compactPage
                != SidebarSelection.account(f.accounts[1]).compactPage)
        #expect(SidebarSelection.generalLedger.compactPage != SidebarSelection.account(f.accounts[0]).compactPage)
        #expect(SidebarSelection.investments.compactPage != SidebarSelection.security("ASX:VAS").compactPage)
        #endif
    }
}
