//
//  ExportOffMainTests.swift
//  FinvestLens — FeatureUI
//
//  File ▸ Export builds its file on a replica off the main actor (R2e). The
//  file must be the one the book itself gives, for every export.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@MainActor
@Suite("Exports off the main actor")
struct ExportOffMainTests {

    @Test("GnuCash, Ledger and every CSV are what the book itself exports")
    func sameAsOnTheBook() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Groceries", type: .expense))
        for day in 0..<20 {
            _ = try model.addTransaction(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400),
                                         description: "Shop \(day), \"quoted\"", currency: .aud, splits: [
                SplitInput(accountID: bank, value: -dec("\(day).45"), memo: "card"),
                SplitInput(accountID: food, value: dec("\(day).45"))])
        }
        let book = try #require(model.book)
        book.addPrice(Price(commodity: .usd, currency: .aud, date: Date(timeIntervalSince1970: 1_700_000_000),
                            value: dec("1.52")))

        #expect(await model.gnuCashExportDataOffMain() == model.gnuCashExportData())
        #expect(await model.gnuCashExportDataOffMain(compressed: true)?.isEmpty == false)
        #expect(await model.ledgerExportTextOffMain() == model.ledgerExportText())
        for kind in CSVExportKind.allCases {
            #expect(await model.csvExportOffMain(kind) == model.csvExport(kind))
        }
    }

    @Test("With no book open there is nothing to export")
    func nothingOpen() async {
        let model = AppModel()
        #expect(await model.gnuCashExportDataOffMain() == nil)
        #expect(await model.ledgerExportTextOffMain() == nil)
        #expect(await model.csvExportOffMain(.transactions) == nil)
    }

    @Test("A book closed while its export builds gets no export")
    func closedMeanwhile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try #require(model.addAccount(name: "Bank", type: .bank))
        // The build waits for the main actor to come back to it, which this
        // test holds until the book has closed.
        let export = Task { await model.ledgerExportTextOffMain() }
        let csv = Task { await model.csvExportOffMain(.transactions) }
        await Task.yield()
        model.close()
        #expect(await export.value == nil)
        #expect(await csv.value == nil)
    }
}
