//
//  ContrastTests.swift
//  FinvestLens — FeatureUI
//
//  WCAG 2.1 AA contrast, computed rather than eyeballed.
//
//  These numbers were the finding of the 16 Aug 2026 accessibility review and
//  they are asserted here because a colour is one careless edit from failing
//  again, and nothing on screen says so: a low-contrast figure looks fine to
//  whoever chose it. `systemGreen` on a white report row measured **2.22:1**,
//  less than half of what body text needs, and had been shipping.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import SwiftUI
@testable import FinvestLensUI

@Suite("Contrast (WCAG 2.1 AA)")
struct ContrastTests {

    /// sRGB → relative luminance, WCAG 2.1 §relative-luminance.
    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }

    /// WCAG 2.1 §contrast-ratio.
    static func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `fg` at `alpha` composited over an opaque `bg`.
    static func over(_ fg: (Double, Double, Double), _ alpha: Double,
                     _ bg: (Double, Double, Double)) -> (Double, Double, Double) {
        (fg.0 * alpha + bg.0 * (1 - alpha),
         fg.1 * alpha + bg.1 * (1 - alpha),
         fg.2 * alpha + bg.2 * (1 - alpha))
    }

    // The backgrounds this app actually draws on, read out of AppKit under both
    // appearances rather than assumed: `textBackgroundColor` and the two
    // `alternatingContentBackgroundColors`.
    static let lightRow = (1.0, 1.0, 1.0)
    static let lightAltRow = (0.9569, 0.9608, 0.9608)
    static let darkRow = (0.1176, 0.1176, 0.1176)
    static var darkAltRow: (Double, Double, Double) { over((1, 1, 1), 0.0471, darkRow) }

    /// What `Color.negativeAmount` and `.positiveAmount` are made of. Kept
    /// beside the assertion rather than read back out of `Color`, which has no
    /// public way to yield its components across platforms.
    static let negative = (light: (0.78, 0.19, 0.19), dark: (1.00, 0.44, 0.44))
    static let positive = (light: (0.09, 0.47, 0.22), dark: (0.40, 0.82, 0.50))

    @Test("A figure coloured by its sign meets 4.5:1 on every row it can land on")
    func signedAmountsMeetAA() {
        for (name, pair) in [("negative", Self.negative), ("positive", Self.positive)] {
            for (row, bg) in [("light", Self.lightRow), ("light alt", Self.lightAltRow)] {
                let r = Self.ratio(pair.light, bg)
                #expect(r >= 4.5, "\(name) on the \(row) row is \(r), under WCAG 1.4.3's 4.5:1")
            }
            for (row, bg) in [("dark", Self.darkRow), ("dark alt", Self.darkAltRow)] {
                let r = Self.ratio(pair.dark, bg)
                #expect(r >= 4.5, "\(name) on the \(row) row is \(r), under WCAG 1.4.3's 4.5:1")
            }
        }
    }

    /// The reason the tokens exist, pinned so nobody "simplifies" them back.
    @Test("The system colours they replaced would fail")
    func systemColoursWouldFail() {
        // NSColor.systemGreen / systemRed, resolved under the light appearance.
        let systemGreen = (0.2039, 0.7804, 0.3490)
        let systemRed = (1.0, 0.2196, 0.2353)
        #expect(Self.ratio(systemGreen, Self.lightAltRow) < 4.5,
                "systemGreen suddenly passes — re-measure before deleting the token")
        #expect(Self.ratio(systemRed, Self.lightAltRow) < 4.5,
                "systemRed suddenly passes — re-measure before deleting the token")
    }

    /// Every selectable accent, as a **non-text** control (WCAG 1.4.11, 3:1) —
    /// including on the 15% tint wash `View.sidebarInstance` paints behind a
    /// focused row, which is the weakest background any of them sits on.
    @Test("Every accent clears 3:1 as a control, on every background")
    func accentsMeetNonTextContrast() {
        let accents: [(String, (Double, Double, Double), (Double, Double, Double))] = [
            ("lavender", (0.46, 0.36, 0.80), (0.74, 0.64, 0.98)),
            ("blue", (0.00, 0.48, 1.00), (0.34, 0.64, 1.00)),
            ("teal", (0.00, 0.52, 0.56), (0.32, 0.80, 0.83)),
            ("green", (0.15, 0.53, 0.25), (0.40, 0.78, 0.46)),
            ("yellow", (0.63, 0.48, 0.00), (0.95, 0.80, 0.32)),
            ("orange", (0.76, 0.40, 0.00), (1.00, 0.62, 0.26)),
            ("pink", (0.83, 0.24, 0.54), (1.00, 0.47, 0.71)),
            ("red", (0.78, 0.19, 0.19), (1.00, 0.44, 0.44)),
            ("graphite", (0.38, 0.38, 0.41), (0.64, 0.64, 0.67)),
        ]
        #expect(accents.count == AppAccent.allCases.count,
                "an accent was added without a contrast measurement")
        for (name, light, dark) in accents {
            let backgrounds: [(String, (Double, Double, Double), (Double, Double, Double))] = [
                ("light row", light, Self.lightRow),
                ("light alt", light, Self.lightAltRow),
                ("light wash", light, Self.over(light, 0.15, Self.lightRow)),
                ("dark row", dark, Self.darkRow),
                ("dark alt", dark, Self.darkAltRow),
                ("dark wash", dark, Self.over(dark, 0.15, Self.darkRow)),
            ]
            for (where_, fg, bg) in backgrounds {
                let r = Self.ratio(fg, bg)
                #expect(r >= 3.0, "\(name) on the \(where_) is \(r), under WCAG 1.4.11's 3:1")
            }
        }
    }
}
