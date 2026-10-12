//
//  ReportNamesTests.swift
//  FinvestLens — FeatureUI
//
//  A report has two names: the one a saved report and the last-open tab
//  store, which never changes, and the one the reader is shown, which is in
//  their language. The gallery, the tab strip, the progress line and the
//  PDF's file name all showed the stored one — English, everywhere.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

@Suite("Report names")
struct ReportNamesTests {

    @Test("Every report has a name and a line saying what it is")
    func everyKind() {
        for kind in ReportKind.allCases {
            // Tests run without the app's catalog, so a name comes back as
            // its key — and the key is the stored name. If the two drift,
            // an English reader sees one name in the gallery and another
            // on a favourite saved from it.
            #expect(kind.title == kind.rawValue)
            #expect(!kind.blurb.isEmpty)
        }
        for group in ReportKind.Group.allCases {
            #expect(!ReportKind.allCases.filter { $0.group == group }.isEmpty)
        }
    }

    @Test("A stored kind is shown by its name; one this version does not know, as stored")
    func storedKinds() {
        #expect(ReportKind.title(of: ReportKind.balanceSheet.rawValue) == ReportKind.balanceSheet.title)
        #expect(ReportKind.title(of: "A Report From Later") == "A Report From Later")
    }

    @Test("The review decks are named")
    func decks() {
        #expect(ReviewDeckKind.financial.title == "Financial Review")
        #expect(ReviewDeckKind.investment.title == "Investment Review")
    }
}
