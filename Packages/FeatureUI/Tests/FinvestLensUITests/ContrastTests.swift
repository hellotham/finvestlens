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
        // Read from `AppAccent` itself since 22 Nov 2026, so an accent added
        // or changed is measured without anyone copying it here.
        let accents = AppAccent.allCases.map { ($0.rawValue, $0.standardValues.light, $0.standardValues.dark) }
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

    // MARK: The 22 Nov 2026 contrast pass (NFR-05)

    /// The light toolbar glass a "Save" or "Cancel" sits on, as read from the
    /// iPhone 18 Pro screen.
    static let lightGlass = (0.93, 0.93, 0.94)
    /// iOS's dark secondary background, the darkest a dark-mode accent sits on
    /// that is not black.
    static let darkGrouped = (0.1098, 0.1098, 0.1176)

    /// A prominent button's fill under white text. The dark-mode accent was
    /// pale and white on it measured 2.15:1 from the screen.
    @Test("Every accent's fill carries white text at 4.5:1, and 7:1 under Increase Contrast")
    func fillsCarryWhiteText() {
        for accent in AppAccent.allCases {
            let standard = Self.ratio((1, 1, 1), accent.fillValue)
            #expect(standard >= 4.5, "white on \(accent.rawValue)'s fill is \(standard), under 4.5:1")
            let high = Self.ratio((1, 1, 1), accent.highContrastValues.light)
            #expect(high >= 7.0, "white on \(accent.rawValue)'s high-contrast fill is \(high), under 7:1")
        }
    }

    /// Apple's Sufficient Contrast criteria accept an app whose Increase
    /// Contrast setting "applies sufficient contrast"; these variants are how
    /// this one does for the colour it owns.
    @Test("Under Increase Contrast every accent reads at 7:1 as text")
    func highContrastAccentsReachSeven() {
        for accent in AppAccent.allCases {
            let (light, dark) = accent.highContrastValues
            let onWhite = Self.ratio(light, Self.lightRow)
            #expect(onWhite >= 7.0, "\(accent.rawValue) high-contrast on white is \(onWhite)")
            let onDark = Self.ratio(dark, Self.darkGrouped)
            #expect(onDark >= 7.0, "\(accent.rawValue) high-contrast on #1C1C1E is \(onDark)")
        }
    }

    /// The default accent as toolbar text: 4.33:1 on the light glass before
    /// it was deepened.
    @Test("The default accent reads at 4.5:1 on the light toolbar glass")
    func defaultAccentReadsOnGlass() {
        let r = Self.ratio(AppAccent.lavender.standardValues.light, Self.lightGlass)
        #expect(r >= 4.5, "lavender on the light glass is \(r), under 4.5:1")
    }
}
