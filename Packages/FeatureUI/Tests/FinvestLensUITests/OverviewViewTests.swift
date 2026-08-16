//
//  OverviewViewTests.swift
//  FinvestLens — FeatureUI
//
//  P12/N4 — Overview as a board of views (`FR-NAV-07` … `FR-NAV-10`).
//
//  The rule with teeth is §4.3's: **selecting changes what you see; drilling in
//  changes where you are.** Overview's views are named after modes, so the
//  trapdoor is one line of code away — and plan.md §13d exit criterion 5 asks
//  for it to be demonstrated by selecting every view and card in turn with the
//  mode selector unchanged throughout. That is what this file does.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Overview views")
struct OverviewViewTests {

    private func makeModel() throws -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        return (model, url)
    }

    private func viewsKey(_ url: URL) -> String {
        "overview.views:\(url.standardizedFileURL.path)"
    }

    /// Exit criterion 5, in full: every view and every card, selected in turn,
    /// with the mode never moving.
    @Test("No view or card selection ever switches mode")
    func selectionNeverSwitchesMode() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.showMode(.dashboard)
        for view in OverviewView.standards {
            model.navigate(to: .overviewView(view.id))
            #expect(model.mode == .dashboard, "view \(view.id) switched mode")
            for card in view.overviewCards {
                model.navigate(to: .overviewCard(view: view.id, card: card.rawValue))
                #expect(model.mode == .dashboard, "card \(card.rawValue) switched mode")
            }
        }
    }

    /// The door out is a button that says where it goes — not a side effect of
    /// selecting something.
    @Test("The board's Open button is what switches mode")
    func explicitButtonSwitchesMode() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.navigate(to: .overviewView("accounts"))
        #expect(model.mode == .dashboard)

        // What the button does.
        let target = try #require(model.currentOverviewView.mode)
        model.showMode(target)
        #expect(model.mode == .accounts)
    }

    /// Mix reports across every mode, so it has no single door — and the button
    /// must be absent rather than pointing somewhere arbitrary.
    @Test("Mix has no Open button because it has no single mode")
    func mixHasNoDoor() {
        #expect(OverviewView.everything.mode == nil)
        #expect(OverviewView.everything.overviewCards.count == OverviewCard.allCases.count)
    }

    /// A view is a *selection* of cards; each mode-named one carries the cards
    /// that report on it.
    @Test("Each standard view carries its mode's cards")
    func standardViewsCarryTheirCards() {
        for view in OverviewView.standards where view.id != "overview" {
            guard let mode = view.mode else { continue }
            for card in view.overviewCards {
                #expect(card.mode == mode,
                        "view \(view.id) lists \(card.rawValue), which reports on another mode")
            }
        }
    }

    /// `FR-NAV-07`, in its own words: "Every mode must be able to contribute at
    /// least one card, and the default board carries one from each — which
    /// requires a Business card (receivables/overdue), the one mode that
    /// contributes none today."
    ///
    /// Business held a deliberately **empty** view for a while, so the gap was
    /// visible rather than silently absent — the right call while the card did
    /// not exist, and the wrong test to keep once it did. Reports and Records
    /// had no view at all, so their absence did not even show as an empty
    /// board.
    @Test("Every mode contributes at least one card")
    func everyModeContributesACard() {
        for mode in AppMode.allCases where mode != .dashboard {
            let cards = OverviewCard.allCases.filter { $0.mode == mode }
            #expect(!cards.isEmpty, "\(mode.rawValue) contributes no Overview card")
            let view = OverviewView.standards.first { $0.id == mode.rawValue }
            #expect(view != nil, "\(mode.rawValue) has no standard view")
            #expect(view?.overviewCards.isEmpty == false,
                    "\(mode.rawValue)'s view lists no cards")
        }
    }

    /// Every card is on the "Mix" view, which is defined as all of them — so a
    /// new card cannot be added and left unreachable.
    @Test("A new card lands on the Mix board")
    func mixCarriesEveryCard() {
        #expect(Set(OverviewView.everything.overviewCards) == Set(OverviewCard.allCases))
    }

    /// A favourite *is* a saved custom view — one concept, not two.
    @Test("A saved view round-trips and becomes selectable")
    func customViewsRoundTrip() throws {
        let (model, url) = try makeModel()
        defer {
            model.close()
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: viewsKey(url))
        }

        model.saveOverviewView(named: "Tax Time", cards: [.income, .expenses])
        let saved = try #require(model.customOverviewViews.first)
        #expect(saved.name == "Tax Time")
        #expect(saved.isStandard == false)
        #expect(saved.overviewCards == [.income, .expenses])
        // Saving selects it, and selecting it does not leave Overview.
        #expect(model.sidebarSelection == .overviewView(saved.id))
        #expect(model.mode == .dashboard)

        model.deleteOverviewView(id: saved.id)
        #expect(model.customOverviewViews.isEmpty)
        #expect(model.sidebarSelection == .dashboard)
    }

    /// Every card is reachable from the toolbar list even when no view carries
    /// it — nothing is unreachable merely because it did not fit the board.
    @Test("A card no view carries is still reachable")
    func everyCardIsReachable() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        for card in OverviewCard.allCases {
            model.navigate(to: .overviewCard(view: "overview", card: card.rawValue))
            #expect(model.zoomedOverviewCard == card)
            #expect(model.mode == .dashboard)
        }
    }

    /// A stored view whose id no longer exists falls back to Mix rather than
    /// leaving the board with nothing to draw.
    @Test("An unknown view falls back to Mix")
    func unknownViewFallsBack() throws {
        let (model, url) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.navigate(to: .overviewView("no-such-view"))
        #expect(model.currentOverviewView.id == "overview")
    }
}
