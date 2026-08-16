//
//  ModeLabelFitTests.swift
//  FinvestLens — FeatureUI
//
//  Whether the toolbar's modes can say their names (`FR-NAV-01`).
//
//  Reported 16 Aug 2026: the modes are "the most important part of the app" and
//  shipped as unlabelled icons — "completely opaque for the beginner". The
//  label was always on the `Label`; macOS draws a bordered toggle icon-only,
//  and `navigation-design.md` §4.1 had asked for labels while §4.1a's system
//  toolbar customisation forced one item per mode. Nobody chose the outcome.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

@MainActor
@Suite("Mode label fit")
struct ModeLabelFitTests {

    private var defaults: [AppMode] { AppMode.toolbarDefault }

    /// Measured in the system font on 16 Aug 2026: the five default modes come
    /// to 488pt labelled, which with the 380pt reserved for the rest of the
    /// toolbar needs 868pt.
    ///
    /// So they do **not** fit the 860pt minimum window — by eight points — and
    /// this test says so rather than rounding in their favour. They fit from
    /// there up, including the 986pt window this was reported from and the
    /// 1280pt default. Someone who squeezes the window to its floor gets
    /// symbols, which is the documented degradation and not a failure.
    /// Updated 16 Aug 2026: emptying the title area returned about 120pt, and
    /// stacking the names under the symbols saved another 159pt, so the words
    /// survive at every width the window can take.
    @Test("The default five fit every window the app allows")
    func defaultsFit() {
        #expect(ModeLabelFit.labelsFit(defaults, in: 860), "the minimum window")
        #expect(ModeLabelFit.labelsFit(defaults, in: 986))
        #expect(ModeLabelFit.labelsFit(defaults, in: 1_280))
    }

    /// Stacked, **all seven** fit the minimum window — 452pt of labels against
    /// 860pt. Beside the symbol they were 669pt and two of them ended up in the
    /// system overflow menu at 986pt, seen on screen 16 Aug 2026. This is the
    /// measurement that made the layout worth changing.
    @Test("All seven fit once the names sit under the symbols")
    func allSevenFitStacked() {
        #expect(ModeLabelFit.labelsFit(AppMode.allCases, in: 860))
        // And the saving is real, not rounding: the stacked five are well
        // under the side-by-side five's 488pt.
        let five = AppMode.toolbarDefault.reduce(CGFloat(0)) { $0 + ModeLabelFit.width(of: $1.name) }
        #expect(five < 400, "measured 329pt stacked, against 488pt beside")
    }

    /// The guard still exists, for a language or an accessibility text size
    /// that makes even the stacked words too wide. It simply no longer fires at
    /// any width this window can take.
    @Test("The degradation is still there for a window too small to hold them")
    func narrowWindowDropsLabels() {
        #expect(!ModeLabelFit.labelsFit(defaults, in: 400))
        #expect(!ModeLabelFit.labelsFit(defaults, in: 0), "no measurement yet is not a licence")
    }

    /// Widths come from the localised text, so a longer language shrinks the
    /// window at which labels survive rather than overflowing it.
    @Test("A longer name costs more room")
    func longerNamesCostMore() {
        #expect(ModeLabelFit.width(of: "Investments") > ModeLabelFit.width(of: "Reports"))
        #expect(ModeLabelFit.width(of: "") == ModeLabelFit.symbolAndPadding,
                "a nameless mode still occupies its symbol and padding")
    }

    /// The model asks about the modes actually on the toolbar, not all seven —
    /// so leaving the defaults alone keeps the labels, and adding a sixth is
    /// the act that spends the room.
    @Test("The model measures the visible modes at the measured width")
    func modelUsesVisibleModes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(!model.modeLabelsFit, "nothing measured yet")
        model.windowWidth = 1_280
        #expect(model.modeLabelsFit)
        model.windowWidth = 986
        #expect(model.modeLabelsFit, "the window this was reported from")
        model.windowWidth = 400
        #expect(!model.modeLabelsFit)
    }

    /// Every mode on the toolbar by default is one of the five the design
    /// names, and the measurement is taken over exactly those.
    @Test("The default set is the five the design names")
    func defaultSet() {
        #expect(AppMode.toolbarDefault == [.dashboard, .accounts, .investments, .reports, .business])
        #expect(AppMode.allCases.filter(\.isOnToolbarByDefault) == AppMode.toolbarDefault)
    }
}
