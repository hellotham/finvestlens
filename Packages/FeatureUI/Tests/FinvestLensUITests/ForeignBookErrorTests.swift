//
//  ForeignBookErrorTests.swift
//  FinvestLens — FeatureUI
//
//  Opening a GnuCash file: the message and the Import button follow one
//  answer to "does this device import?" (`AppModel.canImportGnuCash`). On
//  iPhone and iPad the message used to say "import it" and the alert offered
//  only OK, because each decided for itself (7 Nov 2026). Both answers are
//  asked here, so the message a phone shows is checked on the Mac that runs
//  the suite.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

@MainActor
@Suite("Opening a GnuCash file says what this device can do")
struct ForeignBookErrorTests {
    let url = URL(fileURLWithPath: "/tmp/Household.gnucash")

    @Test("Where books import, an XML book is offered for import")
    func importing() {
        let error = AppModel.foreignBookError(.gnuCashBook, at: url, canImport: true)
        #expect(error.gnuCashImportURL == url)
        #expect(error.message.contains("import it to create a native copy"))
        #expect(!error.message.contains("on a Mac"))
    }

    @Test("Where nothing imports, there is no Import, and the message says where to go")
    func notImporting() {
        let error = AppModel.foreignBookError(.gnuCashBook, at: url, canImport: false)
        #expect(error.gnuCashImportURL == nil)
        #expect(error.message.contains("with FinvestLens on a Mac"))
    }

    @Test("A GnuCash SQLite book is never offered for import, and each device says how to go on",
          arguments: [true, false])
    func sqliteBook(canImport: Bool) {
        let error = AppModel.foreignBookError(.gnuCashSQLite, at: url, canImport: canImport)
        #expect(error.gnuCashImportURL == nil)
        #expect(error.message.contains(canImport ? "File ▸ Import GnuCash… here" : "with FinvestLens on a Mac"))
    }

    @Test("This device's answer is the default")
    func defaultIsThisDevice() {
        let error = AppModel.foreignBookError(.gnuCashBook, at: url)
        #expect((error.gnuCashImportURL != nil) == AppModel.canImportGnuCash)
        #if os(macOS)
        #expect(AppModel.canImportGnuCash)
        #endif
    }
}
