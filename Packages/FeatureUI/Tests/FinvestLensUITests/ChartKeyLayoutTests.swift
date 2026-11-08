//
//  ChartKeyLayoutTests.swift
//  FinvestLens — FeatureUI
//
//  A chart's key wraps within the width it is given. An entry wider than a
//  whole line used to be measured at its own width: at large text sizes on a
//  phone, in German first, it ran off the screen and widened the page under it
//  (found in review, 8 Nov 2026). Sized by AppKit's own hosting view, so it
//  runs where the package suite does.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import FinvestLensUI

@MainActor
@Suite("A chart's key wraps within its width")
struct ChartKeyLayoutTests {

    private func size(of view: some View, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    @Test("An entry wider than the line wraps its own text, and the key is no wider than it was offered")
    func wideEntryWraps() {
        let long = "200-Tage-Durchschnitt und noch viel mehr, als eine Zeile fasst"
        let key = WrappingRow(spacing: 12, lineSpacing: 4) {
            Text(verbatim: "Kurs")
            Text(verbatim: long)
        }
        let line = size(of: Text(verbatim: "Kurs"), width: 400).height
        let fitted = size(of: key, width: 120)
        #expect(fitted.width <= 120, "\(fitted)")
        #expect(fitted.height > 3 * line, "the long entry takes lines of its own: \(fitted), a line \(line)")
    }

    @Test("Entries that fit share a line")
    func shortEntriesShareALine() {
        let key = WrappingRow(spacing: 12, lineSpacing: 4) {
            Text(verbatim: "Price")
            Text(verbatim: "Buy")
            Text(verbatim: "Sell")
        }
        let line = size(of: Text(verbatim: "Price"), width: 400).height
        #expect(abs(size(of: key, width: 400).height - line) < 1)
    }
}
#endif
