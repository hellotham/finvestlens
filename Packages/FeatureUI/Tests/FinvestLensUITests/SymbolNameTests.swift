//
//  SymbolNameTests.swift
//  FinvestLens — FeatureUI
//
//  Every report's icon is a symbol the system can draw. A name SF Symbols does
//  not have compiles, draws nothing, and is noticed only as a blank in the
//  Reports gallery and a "No symbol named …" line in the log: Payable Aging's
//  `building.2.crop.circle.badge.clock` shipped that way in 1.2 (4 Nov 2026).
//  Asked of AppKit's own symbol set, so it runs where the package suite does.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if canImport(AppKit)
import AppKit
import Testing
@testable import FinvestLensUI

@Suite("Report icons are real symbols")
struct SymbolNameTests {

    @Test("Each report kind's icon names a symbol the system draws", arguments: ReportKind.allCases)
    func reportIcon(kind: ReportKind) {
        #expect(NSImage(systemSymbolName: kind.icon, accessibilityDescription: nil) != nil,
                "\(kind.rawValue): \(kind.icon)")
    }
}
#endif
