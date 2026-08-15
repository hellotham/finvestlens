//
//  ModeSidebarTests.swift
//  FinvestLens — FeatureUI
//
//  P12/N2 — one sidebar per mode. The exit criterion this pins is plan.md §13d
//  #1: "Every mode's sidebar contains exactly one kind of thing, two levels
//  deep, and no list of commands."
//
//  Depth is the part worth a machine's attention. It was two levels when the
//  sidebar was designed and four by the time anyone counted, because each
//  addition looked small on its own — so the rule is asserted here rather than
//  remembered.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Mode sidebars")
struct ModeSidebarTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
    }

    /// A book with one of most things, so every mode's sidebar has instances to
    /// list rather than being trivially two levels deep by being empty.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        _ = try #require(model.addAccount(name: "Everyday", type: .bank))
        model.addBudget(Budget(name: "Monthly"))
        model.addRuleGroup(named: "Imports")
        return Fixture(model: model, url: url)
    }

    /// Every row, depth-first, with the level it sits at.
    private func walk(_ rows: [SidebarRow], level: Int = 1) -> [(row: SidebarRow, level: Int)] {
        rows.flatMap { row in
            [(row, level)] + walk(row.children ?? [], level: level + 1)
        }
    }

    @Test("No mode's sidebar goes deeper than two levels")
    func twoLevels() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        for mode in AppMode.allCases where mode != .accounts {
            let rows = ModeSidebarRows.groups(for: mode, model: f.model).flatMap(\.rows)
            let deepest = walk(rows).map(\.level).max() ?? 0
            #expect(deepest <= 2, "\(mode.rawValue) is \(deepest) levels deep")
        }
        // Accounts is the stated exception: GnuCash users expect the tree, and
        // the guidance is written "in general" (navigation-design §4.2).
    }

    /// Every row leads somewhere, and no two rows lead to the same place.
    ///
    /// Both halves matter. A duplicate id makes `List` selection ambiguous — and
    /// the first draft of this sidebar built collection rows with `.random()`
    /// GUIDs, which are unique but regenerate on every body pass, so a selection
    /// would have survived exactly until the next redraw.
    @Test("Sidebar rows have distinct, stable destinations")
    func distinctStableIDs() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        for mode in AppMode.allCases where mode != .accounts {
            let first = walk(ModeSidebarRows.groups(for: mode, model: f.model).flatMap(\.rows))
            let ids = first.map(\.row.id)
            #expect(Set(ids).count == ids.count, "\(mode.rawValue) repeats a destination")

            // Same model, second build: the ids must be identical.
            let second = walk(ModeSidebarRows.groups(for: mode, model: f.model).flatMap(\.rows))
            #expect(second.map(\.row.id) == ids, "\(mode.rawValue) rebuilds different ids")
        }
    }

    /// A row belongs to the mode that lists it — otherwise clicking it would
    /// switch mode, which is exactly what selection must never do
    /// (navigation-design §4.3).
    @Test("Every row belongs to the mode that lists it")
    func rowsStayInTheirMode() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        for mode in AppMode.allCases where mode != .accounts {
            for entry in walk(ModeSidebarRows.groups(for: mode, model: f.model).flatMap(\.rows)) {
                #expect(AppMode(hosting: entry.row.id) == mode,
                        "\(mode.rawValue) lists a row owned by \(AppMode(hosting: entry.row.id).rawValue)")
            }
        }
    }

    /// A collection's name is ours and is localized; an instance's is the
    /// user's and must not go near the catalog. Exactly one of the two labels
    /// is ever set, and this is what says so.
    @Test("Each row carries exactly one kind of label")
    func oneLabelKind() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        for mode in AppMode.allCases where mode != .accounts {
            for entry in walk(ModeSidebarRows.groups(for: mode, model: f.model).flatMap(\.rows)) {
                let hasKey = entry.row.key != nil
                let hasText = entry.row.text != nil
                #expect(hasKey != hasText,
                        "\(mode.rawValue) has a row with \(hasKey && hasText ? "both" : "neither") label")
            }
        }
    }

    /// The book's collections reach the sidebar — the wiring N2 exists for.
    @Test("Planning lists the book's plans")
    func planningListsInstances() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let rows = ModeSidebarRows.groups(for: .planning, model: f.model).flatMap(\.rows)
        let budgets = try #require(rows.first { $0.id == .budgets })
        let budgetID = try #require(f.model.budgets.first?.id)
        #expect(budgets.children?.map(\.id) == [.budget(budgetID)])
        #expect(budgets.children?.first?.text == "Monthly")
    }

    @Test("Records lists the book's rule groups and its log")
    func recordsListsInstances() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let rows = ModeSidebarRows.groups(for: .records, model: f.model).flatMap(\.rows)
        let rules = try #require(rows.first { $0.id == .rules })
        #expect(rules.children?.contains { $0.text == "Imports" } == true)
        // The audit log is a collection the book keeps, which is why it is a
        // destination now rather than the modal sheet it used to be.
        #expect(rows.contains { $0.id == .auditLog })
    }

    /// The catalogue is grouped the way the gallery groups it, so the two name
    /// the same things the same way.
    @Test("Reports lists the whole standard catalogue")
    func reportsListsCatalogue() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let groups = ModeSidebarRows.groups(for: .reports, model: f.model)
        let listed = groups.flatMap(\.rows).compactMap { $0.id.reportKind }
        #expect(Set(listed) == Set(ReportKind.allCases))
        #expect(groups.contains { $0.rows.contains { $0.id == .reports } })
    }

    /// An empty collection is absent, not disabled. HIG *Tab bars*: "Don't
    /// disable or hide tab bar buttons… If a section is empty, explain why" —
    /// the mode itself is always there; a collection with nothing in it simply
    /// has nothing to list.
    @Test("Business omits its empty collections but keeps the mode")
    func businessStaysThin() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let groups = ModeSidebarRows.groups(for: .business, model: f.model)
        #expect(groups.flatMap(\.rows).contains { $0.id == .business })
        #expect(!groups.contains { $0.id == "customers" })
        #expect(AppMode.business.isOnToolbarByDefault)
    }
}

// MARK: - Defects the review found, fixed 15 Aug 2026

@MainActor
@Suite("Mode sidebars — regressions")
struct ModeSidebarRegressionTests {

    private func fixture() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    /// Deleting an object used to leave its tab open, titled by a fallback,
    /// showing an empty page until the next relaunch.
    @Test("Deleting an account closes its tab")
    func deletedAccountLosesItsTab() throws {
        let (model, url) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let keep = try #require(model.addAccount(name: "Everyday", type: .bank))
        let doomed = try #require(model.addAccount(name: "Old Card", type: .credit))
        model.navigate(to: .account(keep))
        model.navigate(to: .account(doomed), inNewTab: true)
        model.selectTab(1)                       // the *other* tab is active
        #expect(model.openTabs.count == 3)

        try model.deleteAccount(doomed)
        #expect(model.openTabs == [.generalLedger, .account(keep)])
        #expect(model.sidebarSelection == .account(keep), "the user was moved off their tab")
    }

    /// Deleting a budget, goal or rule group closes its tab too — the prune is
    /// in the edit funnel, not in one delete.
    @Test("Deleting a rule group closes its tab")
    func deletedRuleGroupLosesItsTab() throws {
        let (model, url) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.addRuleGroup(named: "Imports")
        let group = try #require(model.ruleGroups.first?.id)
        model.navigate(to: .ruleGroup(group))
        #expect(model.openTabs.contains(.ruleGroup(group)))

        model.deleteRuleGroup(group)
        #expect(!model.openTabs.contains(.ruleGroup(group)))
    }

    /// Name order applies to a mode's *instances*, never to its collection
    /// headings — alphabetising Budgets above Planner would reorder the mode's
    /// own structure rather than its contents.
    @Test("Name order sorts instances, not headings")
    func nameOrderSortsInstancesOnly() throws {
        let (model, url) = try fixture()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.addRuleGroup(named: "Zebra")
        model.addRuleGroup(named: "Apple")
        let rows = ModeSidebarRows.groups(for: .records, model: model).flatMap(\.rows)
        let sorted = model.sortedRows(rows, by: .name)

        #expect(sorted.map(\.id) == rows.map(\.id), "a heading moved")
        let rules = try #require(sorted.first { $0.id == .rules })
        #expect(rules.children?.map(\.text) == ["Apple", "Zebra"])
    }

    /// Every mode offers a sort now; only Accounts offers the account-only
    /// criteria.
    @Test("Every mode offers a sort, Accounts offers more")
    func sortIsOfferedEverywhere() {
        #expect(SidebarSort.cases(for: .accounts).count > SidebarSort.cases(for: .planning).count)
        for mode in AppMode.allCases where mode != .accounts {
            #expect(SidebarSort.cases(for: mode) == [.manual, .name])
            // "Manual Order" only means something where an order can be set.
            #expect(SidebarSort.manual.title(in: mode) != SidebarSort.manual.title)
        }
    }

    /// A saved view captures what is on the board, not a copy of the view it
    /// was saved from.
    @Test("A saved view captures the cards actually shown")
    func savedViewCapturesTheBoard() throws {
        let (model, url) = try fixture()
        defer {
            model.close()
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(
                forKey: "overview.views:\(url.standardizedFileURL.path)")
        }

        // What DashboardView passes: this view's cards, less the hidden ones.
        let shown = OverviewView.mix.overviewCards.filter { $0 != .alerts && $0 != .wellbeing }
        model.saveOverviewView(named: "Trimmed", cards: shown)
        let saved = try #require(model.customOverviewViews.first)
        #expect(saved.overviewCards == shown)
        #expect(saved.overviewCards.count < OverviewView.mix.overviewCards.count,
                "the saved view is a copy of its source")
    }
}
