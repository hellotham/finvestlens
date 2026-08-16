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

/// Decides whether the mode row's buttons could show words or only symbols.
///
/// **Nothing consults this today.** `ModeBar` always draws the words, because
/// all seven fit at every width the window can take. It is kept as the answer
/// to the question a future `ModeBar` would have to ask — a longer language, a
/// larger text size — and it is kept *correct* for that day rather than left to
/// rot: see `reservedForTheRest` and `AppModel.modeRowWidth`, both of which had
/// gone stale when the modes left the toolbar.
///
/// The HIG asks for both things at once and they compete. *Toolbars*: "Make
/// sure the meaning of each control is clear. Don't make people guess or
/// experiment to figure out what a toolbar item does." And, on the same page:
/// "avoid layouts that cause toolbar items to overflow by default."
///
/// Measured on 16 Aug 2026, both ways. **Beside** the symbol the five default
/// modes come to 488pt and all seven to 669pt — and at a 986pt window that was
/// enough to push Reports and Business into the system overflow menu, seen on
/// screen. **Under** it they come to 329pt and 452pt, which fits all seven
/// inside the 860pt minimum window with room to spare. So the stacked layout is
/// what the app uses and this measurement is the guard rather than the
/// deciding factor — it still drops to symbols if a future language or an
/// accessibility text size makes even the stacked words too wide.
/// which is why this is a measurement rather than a preference. Unlabelled
/// icons were never a decision; they are what shipped when
/// `navigation-design.md` §4.1 (one labelled control) lost to §4.1a (system
/// toolbar customisation, which needs one item per mode).
///
/// Labels are measured, never assumed: they are localised into eight languages
/// and German in particular is longer than the English these numbers came from.
enum ModeLabelFit {

    /// What one mode's button occupies with its name **under** its symbol: the
    /// wider of the two, plus the button's own padding.
    ///
    /// Stacked, the label is set in the small system font and the symbol is
    /// narrower than any of the words, so the word is the width. Beside the
    /// symbol it was symbol + gap + word, which is what made five modes 488pt
    /// and pushed two of them into the overflow menu at a 986pt window.
    static func width(of title: String) -> CGFloat {
        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        #else
        // A serviceable estimate off-platform; the toolbar this governs is
        // macOS-only, so this branch exists to keep the type building.
        let text = CGFloat(title.count) * 6
        #endif
        return max(symbolWidth, ceil(text)) + horizontalPadding
    }

    /// The symbol at `.large` image scale.
    static let symbolWidth: CGFloat = 18
    /// The button's own horizontal padding.
    static let horizontalPadding: CGFloat = 16
    /// Kept for callers that still name it.
    static var symbolAndPadding: CGFloat { symbolWidth + horizontalPadding }

    /// Everything on the mode row that is not a mode: its own horizontal inset,
    /// and nothing else.
    ///
    /// It was **260**, and before that 380 — the sidebar toggle plus the
    /// trailing group of search, create and inspector, back when all of them
    /// shared one toolbar with the modes. They do not: the modes have a row to
    /// themselves and the secondary controls stayed in the title bar, so
    /// reserving a quarter of the row for absent controls understated the space
    /// by roughly 250pt. Paired with `AppModel.modeRowWidth`, which used to
    /// overstate it by the sidebar's width — two errors that partly cancelled,
    /// which is the worst way for a measurement to be wrong.
    ///
    /// Declared here rather than on `ModeBar` and read from there: a `View` is
    /// `@MainActor`-isolated, so its statics cannot initialise this nonisolated
    /// one.
    static let reservedForTheRest: CGFloat = 12

    /// Whether `modes` can all show their labels in a row of `available` points.
    static func labelsFit(_ modes: [AppMode], in available: CGFloat) -> Bool {
        guard available > 0 else { return false }
        // `name`, not `title`: the localised text the button will actually
        // draw. Measuring the English source would size German wrongly.
        let needed = modes.reduce(CGFloat(0)) { $0 + width(of: $1.name) }
        return needed + reservedForTheRest <= available
    }

}
