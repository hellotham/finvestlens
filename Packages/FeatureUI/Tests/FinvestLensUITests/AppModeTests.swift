//
//  AppModeTests.swift
//  FinvestLens — FeatureUI
//
//  P12/N1 — the navigation spine. Modes exist so that leaving an area and
//  coming back returns you where you were, which is a claim about *stored
//  state*, not about pixels: it is testable here without a window.
//
//  The migration is the part with teeth. A book last opened before P12 has one
//  flat destination stored and no mode at all; if that maps wrongly, a user
//  reopens somewhere they did not leave — the risk plan.md §13d names.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("App modes")
struct AppModeTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let bank: GncGUID
        let other: GncGUID
    }

    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Everyday", type: .bank))
        let other = try #require(model.addAccount(name: "Savings", type: .bank))
        return Fixture(model: model, url: url, bank: bank, other: other)
    }

    // MARK: The mode/destination map

    /// Every mode's home belongs to that mode. Without this, switching to a mode
    /// would land on a destination hosted elsewhere and bounce straight back
    /// out — the loop is only closed if the map agrees with itself.
    @Test("Each mode's default destination is hosted by that mode")
    func defaultsRoundTrip() {
        for mode in AppMode.allCases {
            #expect(AppMode(hosting: mode.defaultSelection) == mode,
                    "\(mode.rawValue) lands somewhere it does not own")
        }
    }

    @Test("Destinations are hosted where the design says")
    func hostingMap() {
        #expect(AppMode(hosting: .dashboard) == .overview)
        #expect(AppMode(hosting: .generalLedger) == .accounts)
        #expect(AppMode(hosting: .account(.random())) == .accounts)
        #expect(AppMode(hosting: .investments) == .investments)
        #expect(AppMode(hosting: .reports) == .reports)
        #expect(AppMode(hosting: .business) == .business)
        // Billable time exists to be invoiced, so it lives beside the invoices
        // rather than in Records (navigation-design §4.2).
        #expect(AppMode(hosting: .timeMileage) == .business)
        #expect(AppMode(hosting: .budgets) == .planning)
        #expect(AppMode(hosting: .scheduled) == .planning)
        #expect(AppMode(hosting: .goals) == .planning)
        #expect(AppMode(hosting: .planner) == .planning)
        // Rules failed the working-session test: you arrive at one from an
        // import, you do not go there. A Records collection, not a mode.
        #expect(AppMode(hosting: .rules) == .records)
        #expect(AppMode(hosting: .emergencyRecords) == .records)
    }

    /// Accounts is a *working* mode and Overview already carries the reading
    /// layer, so Accounts lands on the ledger rather than a second hub
    /// (navigation-design §4.4).
    @Test("Accounts lands on All Transactions, not a hub")
    func accountsLandsOnLedger() {
        #expect(AppMode.accounts.defaultSelection == .generalLedger)
        // Overview's home is the Mix *view*, which is a row its sidebar
        // actually carries. `.dashboard` was not, so the sidebar highlighted
        // nothing at launch and clicking Mix opened a second tab of the same
        // board.
        #expect(AppMode.overview.defaultSelection == .overviewView("mix"))
    }

    // MARK: Toolbar and shortcuts

    @Test("Five modes are on the toolbar, and every mode has a button")
    func toolbarDefault() {
        #expect(AppMode.toolbarDefault.count == 5)
        #expect(AppMode.toolbarDefault == [.overview, .accounts, .investments, .reports, .business])
        // Planning and Records are modes in full; they are simply not in
        // everyone's way (navigation-design §4.1a).
        #expect(!AppMode.planning.isOnToolbarByDefault)
        #expect(!AppMode.records.isOnToolbarByDefault)
        // The toolbar lists its items one by one because a customisation id has
        // to be a constant. This is the guard against that list drifting.
        #expect(ModeToolbar.modes == AppMode.allCases)
    }

    /// ⌘1…⌘n, one per mode and none shared — the reason nothing is hidden by
    /// the five-mode default.
    @Test("Every mode has its own number shortcut")
    func shortcutsAreDistinct() {
        let keys = AppMode.allCases.map(\.shortcut)
        #expect(Set(keys.map(\.character)).count == AppMode.allCases.count)
        #expect(AppMode.allCases.first?.shortcut.character == "1")
        #expect(keys.allSatisfy { $0.character.isNumber })
    }

    /// Every mode's home must be a row its own sidebar carries, or the window
    /// opens with nothing selected and the row that shows the same content
    /// opens a duplicate tab. Overview failed this until 15 Aug 2026.
    @Test("Every mode's home is a row its sidebar carries")
    func homeIsSelectable() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        for mode in AppMode.allCases {
            let home = mode.defaultSelection
            if mode == .accounts {
                #expect(home == .generalLedger)   // built in the view, not the row list
                continue
            }
            let rows = ModeSidebarRows.groups(for: mode, model: f.model).flatMap(\.rows)
            let ids = rows.flatMap { [$0.id] + ($0.children ?? []).map(\.id) }
            #expect(ids.contains(home), "\(mode.rawValue)'s home is not in its sidebar")
        }
    }

    // MARK: Per-mode state

    /// plan.md §13d exit criterion 4: switching mode and returning restores that
    /// mode's selection.
    @Test("A mode remembers where it was")
    func modesKeepTheirPlace() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.selectedAccountID = f.bank
        #expect(f.model.mode == .accounts)

        f.model.showMode(.reports)
        #expect(f.model.sidebarSelection == .reports)
        #expect(f.model.selectedAccountID == nil)

        f.model.showMode(.accounts)
        #expect(f.model.selectedAccountID == f.bank)
    }

    @Test("Navigating to another mode's destination switches mode")
    func navigateCrossesModes() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .budgets)
        #expect(f.model.mode == .planning)
        #expect(f.model.sidebarSelection == .budgets)

        f.model.navigate(to: .account(f.other))
        #expect(f.model.mode == .accounts)
        #expect(f.model.selectedAccountID == f.other)

        // Planning kept its own place while Accounts was showing.
        f.model.showMode(.planning)
        #expect(f.model.sidebarSelection == .budgets)
    }

    /// Clearing the account is not a request to leave Accounts — it lands on
    /// that mode's home instead of jumping to Overview.
    @Test("Clearing the account stays in Accounts")
    func clearingStaysPut() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.selectedAccountID = f.bank
        f.model.selectedAccountID = nil
        #expect(f.model.mode == .accounts)
        #expect(f.model.sidebarSelection == .generalLedger)
    }

    @Test("Closing the book forgets every mode's place")
    func closeResetsNavigation() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }

        f.model.navigate(to: .budgets)
        f.model.selectedAccountID = f.bank
        f.model.close()

        #expect(f.model.mode == .overview)
        #expect(f.model.selectedAccountID == nil)
        f.model.showMode(.planning)
        #expect(f.model.sidebarSelection == .planner, "one book's desk opened on top of the next")
    }

    // MARK: Session restoration

    @Test("Each mode's place survives a reopen")
    func sessionRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { UserDefaults.standard.removeObject(forKey: navigationKey(url)) }

        let first = AppModel()
        try first.newDocument(at: url)
        let bank = try #require(first.addAccount(name: "Everyday", type: .bank))
        first.navigate(to: .budgets)
        first.selectedAccountID = bank
        first.showMode(.planning)          // left the window in Planning
        try first.save()
        first.close()

        let second = AppModel()
        await second.openBook(at: url)
        #expect(second.mode == .planning)
        #expect(second.sidebarSelection == .budgets)
        // …and Accounts still remembers the register, unopened this session.
        second.showMode(.accounts)
        #expect(second.selectedAccountID == bank)
        second.close()
    }

    /// The migration. A book last opened before P12 has one flat destination and
    /// no mode; the mode has to be derived from the destination, or the user
    /// reopens at Overview rather than where they were.
    @Test("A pre-P12 session restores into the mode that owns it")
    func migratesFlatSelection() async throws {
        let url = try seededBook()
        defer { try? FileManager.default.removeItem(at: url) }
        defer {
            UserDefaults.standard.removeObject(forKey: legacyKey(url))
            UserDefaults.standard.removeObject(forKey: navigationKey(url))
        }

        // Exactly what the old build wrote: one key, one bare destination.
        UserDefaults.standard.removeObject(forKey: navigationKey(url))
        UserDefaults.standard.set("budgets", forKey: legacyKey(url))

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.mode == .planning)
        #expect(model.sidebarSelection == .budgets)
        model.close()
    }

    /// The pre-P11 spelling has to keep working through the new format too — it
    /// is the same stored string, one migration further back.
    @Test("The pre-P11 “prices” spelling still restores")
    func migratesPricesSpelling() async throws {
        let url = try seededBook()
        defer { try? FileManager.default.removeItem(at: url) }
        defer {
            UserDefaults.standard.removeObject(forKey: legacyKey(url))
            UserDefaults.standard.removeObject(forKey: navigationKey(url))
        }

        UserDefaults.standard.removeObject(forKey: navigationKey(url))
        UserDefaults.standard.set("prices", forKey: legacyKey(url))

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.mode == .investments)
        model.close()
    }

    /// An account deleted between sessions must not leave a dead selection —
    /// that mode drops back to its home, and the others are untouched.
    @Test("A vanished account falls back to its mode's home")
    func vanishedAccountFallsBack() async throws {
        let url = try seededBook()
        defer { try? FileManager.default.removeItem(at: url) }
        defer { UserDefaults.standard.removeObject(forKey: navigationKey(url)) }

        // A stored desk pointing at an account this book has never had, beside
        // a Reports selection that must survive untouched.
        let ghost = GncGUID.random().hexString
        UserDefaults.standard.set(
            #"{"mode":"accounts","selections":{"accounts":"account:\#(ghost)","reports":"reports"}}"#,
            forKey: navigationKey(url))

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.mode == .accounts)
        #expect(model.selectedAccountID == nil)
        #expect(model.sidebarSelection == .generalLedger)
        model.showMode(.reports)
        #expect(model.sidebarSelection == .reports)
        model.close()
    }

    // MARK: Helpers

    private func seededBook() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let seed = AppModel()
        try seed.newDocument(at: url)
        seed.close()
        return url
    }

    private func navigationKey(_ url: URL) -> String {
        "session.navigation:\(url.standardizedFileURL.path)"
    }

    private func legacyKey(_ url: URL) -> String {
        "session.sidebarSelection:\(url.standardizedFileURL.path)"
    }
}

/// The desk-state codec, both directions.
///
/// It was two independent switches — `encode` compiler-checked, `decode` a raw
/// string switch that nothing checked — and they drifted inside a day:
/// `.auditLog` encoded and did not decode, so that tab was written on every
/// navigation and dropped on every reopen. This walks a value of every case
/// through both halves.
@MainActor
@Suite("Desk-state codec")
struct SessionCodecTests {

    /// Every case, with a payload where it takes one.
    private static let everyCase: [SidebarSelection] = [
        .dashboard, .generalLedger, .reports, .investments, .business,
        .timeMileage, .planner, .budgets, .goals, .scheduled, .rules,
        .emergencyRecords, .auditLog,
        .account(.random()), .budget(.random()), .goal(.random()),
        .scheduledTransaction(.random()), .invoice(.random()), .customer(.random()),
        .vendor(.random()), .job(.random()), .employee(.random()),
        .ruleGroup(UUID()), .emergencyRecord(UUID()), .savedReport(UUID()),
        .security("ASX|BHP"), .report(.balanceSheet),
        .overviewView("mix"), .overviewCard(view: "mix", card: "netWorth"),
    ]

    @Test("Every destination survives the round trip")
    func everyCaseRoundTrips() {
        for selection in Self.everyCase {
            let raw = AppModel.encode(selection)
            #expect(!raw.isEmpty, "\(selection) encoded to nothing")
            #expect(AppModel.decodeSelection(raw) == selection,
                    "\(selection) encoded as \(raw) and decoded to \(String(describing: AppModel.decodeSelection(raw)))")
        }
    }

    /// The pre-P11 spelling still restores rather than dropping the user back
    /// to the dashboard.
    @Test("The pre-P11 “prices” spelling still decodes")
    func legacySpelling() {
        #expect(AppModel.decodeSelection("prices") == .investments)
    }

    /// Nothing in the payload-free table may share a name, or one destination
    /// would decode as another.
    @Test("Payload-free names are distinct")
    func plainNamesAreDistinct() {
        let names = AppModel.plainCases.map(\.0)
        #expect(Set(names).count == names.count)
    }
}
