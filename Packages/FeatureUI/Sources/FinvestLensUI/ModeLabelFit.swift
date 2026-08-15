//
//  ModeLabelFit.swift
//  FinvestLens — FeatureUI
//
//  Whether the mode buttons can afford to say their names (`FR-NAV-01`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Decides whether the toolbar's mode buttons show words or only symbols.
///
/// The HIG asks for both things at once and they compete. *Toolbars*: "Make
/// sure the meaning of each control is clear. Don't make people guess or
/// experiment to figure out what a toolbar item does." And, on the same page:
/// "avoid layouts that cause toolbar items to overflow by default."
///
/// Measured in the system font on 16 Aug 2026: the five default modes labelled
/// come to 488pt and all seven to 669pt, against a window whose minimum is
/// 860pt. With the toolbar's other 380pt that puts the default five at 868pt —
/// so they show from a little above the minimum window upwards (the 986pt
/// window this was reported from, and the 1280pt default), and a window
/// squeezed to its floor gets symbols. A fully customised seven never fits —
/// which is why this is a measurement rather than a preference. Unlabelled
/// icons were never a decision; they are what shipped when
/// `navigation-design.md` §4.1 (one labelled control) lost to §4.1a (system
/// toolbar customisation, which needs one item per mode).
///
/// Labels are measured, never assumed: they are localised into eight languages
/// and German in particular is longer than the English these numbers came from.
enum ModeLabelFit {

    /// What one mode's button occupies with its label showing: the symbol, the
    /// gap, the text, and the button's own padding.
    static func width(of title: String) -> CGFloat {
        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        #else
        // A serviceable estimate off-platform; the toolbar this governs is
        // macOS-only, so this branch exists to keep the type building.
        let text = CGFloat(title.count) * 7
        #endif
        return ceil(text) + symbolAndPadding
    }

    /// Symbol (16) + gap (4) + the bordered button's horizontal padding (20).
    static let symbolAndPadding: CGFloat = 40

    /// Everything else the toolbar has to hold: the sidebar toggle and the
    /// trailing group (search, create, inspector). Deliberately generous —
    /// being wrong towards icons costs a word, and being wrong the other way
    /// costs the overflow menu the HIG warns against.
    ///
    /// Was 380 while the window carried a title. Emptying the title area (HIG
    /// *Toolbars*: "If titling a toolbar seems redundant, you can leave the
    /// title area empty") gave back about 120pt, which is what now lets the
    /// default five keep their words at **every** width the window can take,
    /// rather than only above 868pt.
    static let reservedForTheRest: CGFloat = 260

    /// Whether `modes` can all show their labels in a window of `width`.
    static func labelsFit(_ modes: [AppMode], in available: CGFloat) -> Bool {
        guard available > 0 else { return false }
        // `name`, not `title`: the localised text the button will actually
        // draw. Measuring the English source would size German wrongly.
        let needed = modes.reduce(CGFloat(0)) { $0 + width(of: $1.name) }
        return needed + reservedForTheRest <= available
    }

}
