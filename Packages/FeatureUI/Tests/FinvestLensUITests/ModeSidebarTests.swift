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
