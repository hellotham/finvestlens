//
//  AppearanceTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Testing
@testable import FinvestLensUI

@Suite("Appearance settings")
struct AppearanceTests {

    @Test("Theme maps to a preferred color scheme")
    func theme() {
        #expect(ColorSchemePreference.system.colorScheme == nil)
        #expect(ColorSchemePreference.light.colorScheme == .light)
        #expect(ColorSchemePreference.dark.colorScheme == .dark)
    }

    @Test("Text-size steps: five, default is the middle at 1.0×")
    func textSize() {
        #expect(TextSize.stepCount == 5)
        #expect(TextSize.defaultStep == 2)
        #expect(TextSize.scale(TextSize.defaultStep) == 1.0)
        #expect(TextSize.scale(0) < 1.0)   // smaller
        #expect(TextSize.scale(4) > 1.0)   // larger
        // Monotonic increasing across the range.
        #expect(TextSize.scale(0) < TextSize.scale(2))
        #expect(TextSize.scale(2) < TextSize.scale(4))
        // Out-of-range steps clamp to the ends.
        #expect(TextSize.scale(-3) == TextSize.scale(0))
        #expect(TextSize.scale(99) == TextSize.scale(4))
    }

    @Test("Explicit row heights are the fixed points they claim to be")
    func rowHeightSteps() {
        // The base every other register metric is a multiple of: AppKit's own
        // NSTableView.rowHeight.
        #expect(RegisterRowHeight.base == 24)
        #expect(RegisterRowHeight.standard.points(pointsPerInch: nil, screenHeight: nil) == 24)
        // Compact reproduces exactly the density the register shipped with,
        // so nobody who liked it loses it.
        #expect(RegisterRowHeight.compact.points(pointsPerInch: nil, screenHeight: nil) == 21)
        #expect(RegisterRowHeight.spacious.points(pointsPerInch: nil, screenHeight: nil) == 30)
        // An explicit choice ignores the display entirely — that is the point
        // of choosing it.
        #expect(RegisterRowHeight.compact.points(pointsPerInch: 220, screenHeight: 2000) == 21)
    }

    @Test("Automatic row height corrects part-way towards a constant physical row")
    func automaticRowHeight() {
        // The reference desktop display: no correction, so AppKit's default.
        #expect(RegisterRowHeight.automaticPoints(pointsPerInch: 109, screenHeight: 1440) == 24)
        // This project's own laptop display, measured: 1470 × 956 points across
        // 290.6 mm = 128.5 points per inch. Denser than the reference, so the
        // row grows to keep its physical size.
        #expect(RegisterRowHeight.automaticPoints(pointsPerInch: 128.5, screenHeight: 956) == 26)
        // A 92 ppi 1080p monitor is sparser: the row shrinks.
        #expect(RegisterRowHeight.automaticPoints(pointsPerInch: 92, screenHeight: 1080) == 22)
        // Monotonic in density.
        let ladder = [80.0, 100.0, 120.0, 140.0, 160.0].map {
            RegisterRowHeight.automaticPoints(pointsPerInch: $0, screenHeight: 1600)
        }
        #expect(ladder == ladder.sorted())
    }

    @Test("Automatic row height survives displays that report nothing usable")
    func automaticRowHeightDegrades() {
        // Virtual displays and capture devices report 0 mm; a divide by that is
        // how a legibility feature becomes a crash.
        #expect(RegisterRowHeight.automaticPoints(pointsPerInch: nil, screenHeight: nil) == 24)
        #expect(RegisterRowHeight.automaticPoints(pointsPerInch: 0, screenHeight: 900) == 24)
        // Absurd densities are ignored rather than clamped-to, so a bogus EDID
        // cannot drag every row to an extreme.
        #expect(RegisterRowHeight.automaticPoints(pointsPerInch: 5000, screenHeight: 1200) == 24)
        // Never outside the range, whatever the inputs.
        for ppi in stride(from: 20.0, through: 500.0, by: 7.0) {
            for height in [600.0, 900.0, 1440.0, 2160.0] {
                let points = RegisterRowHeight.automaticPoints(pointsPerInch: ppi,
                                                              screenHeight: height)
                #expect(RegisterRowHeight.range.contains(points))
            }
        }
    }

    @Test("A short screen keeps enough transactions on it")
    func automaticRowHeightFits() {
        // A dense display would ask for a tall row; a short one overrules it,
        // because a register that shows a handful of transactions is not one.
        let tall = RegisterRowHeight.automaticPoints(pointsPerInch: 160, screenHeight: 1600)
        let short = RegisterRowHeight.automaticPoints(pointsPerInch: 160, screenHeight: 700)
        #expect(short < tall)
        #expect(short * RegisterRowHeight.minimumRowsPerScreen <= 700)
    }

    @Test("Accent palette includes the default lavender and is stable")
    func accents() {
        #expect(AppAccent.allCases.contains(.lavender))
        #expect(AppAccent(rawValue: "lavender") == .lavender)
        // Every accent yields a colour and a label.
        for accent in AppAccent.allCases {
            #expect(!accent.label.isEmpty)
            _ = accent.color
        }
    }
}
