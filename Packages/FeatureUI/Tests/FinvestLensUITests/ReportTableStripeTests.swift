//
//  ReportTableStripeTests.swift
//  FinvestLens — FeatureUI
//
//  A report table's stripe and its total's rule run the whole width of the
//  row. Put on a `GridRow`, a background is drawn cell by cell, and 1.2
//  shipped that way: stripes broken into blocks at every column gap, and a
//  total's rule in pieces (Capital Gains, seen 4 Nov 2026). GnuCash's reports
//  stripe the whole row, the second plain one first (`tr.alternate-row`,
//  html-fonts.scm; `odd-row?` from #t, portfolio.scm and trep-engine.scm).
//
//  Drawn with `ImageRenderer` on a transparent background and read by pixel:
//  a pixel row is "covered" when nothing in it is left transparent. A stripe
//  covers every pixel row of its band; a stripe or rule drawn per cell leaves
//  the column gaps clear and covers none.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import FinvestLensUI

@Suite("Report table stripes and rules run the full width")
@MainActor
struct ReportTableStripeTests {

    /// Runs of pixel rows in which every pixel is drawn, top to bottom.
    private func coveredRuns(_ view: some View) throws -> (width: Int, runs: [Range<Int>]) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var runs: [Range<Int>] = []
        var start: Int?
        for y in 0..<height {
            let covered = (0..<width).allSatisfy { pixels[(y * width + $0) * 4 + 3] > 0 }
            if covered, start == nil { start = y }
            if !covered, let first = start { runs.append(first..<y); start = nil }
        }
        if let first = start { runs.append(first..<height) }
        return (width, runs)
    }

    private func row(_ label: String, _ units: Int, _ cost: Int, _ proceeds: Int) -> ReportDocumentRow {
        ReportDocumentRow(label: label, cells: [.units(Decimal(units)), .money(Decimal(cost)), .money(Decimal(proceeds))])
    }

    @Test("A comparative table: two full-width stripes, and the total's rule across the row")
    func comparative() throws {
        let section = ReportDocumentSection(
            title: "T",
            rows: [row("VAS", 40, 3696, 4248), row("Sell VAS", 40, 3696, 4248),
                   row("NDQ", 15, 722, 856), row("Sell NDQ", 15, 722, 856), row("BHP", 0, 0, 0)],
            columns: ["Units", "Cost base", "Proceeds"],
            cellTotals: (label: "Total", cells: [.units(55), .money(4418), .money(5104)]))
        let (width, runs) = try coveredRuns(ReportTableView(section: section, code: "AUD"))
        #expect(width > 400)
        // Rows 1 and 3, each a band many pixels tall. Five rows, so the last
        // is plain and the total's rule does not run into a stripe.
        #expect(runs.filter { $0.count >= 20 }.count == 2, "\(runs)")
        // The rule under the title and the total's: thin and full width.
        #expect(runs.filter { $0.count <= 4 }.count == 2, "\(runs)")
    }

    @Test("A single-column table: the same, through the other grid")
    func single() throws {
        let section = ReportDocumentSection(
            title: "T",
            rows: (1...5).map { ReportDocumentRow(label: "Account \($0)", amount: Decimal($0 * 1000)) },
            total: (label: "Total", amount: 10_000))
        let (_, runs) = try coveredRuns(ReportTableView(section: section, code: "AUD"))
        #expect(runs.filter { $0.count >= 20 }.count == 2, "\(runs)")
        #expect(runs.filter { $0.count <= 4 }.count == 2, "\(runs)")
    }
}

@Suite("A trade's mark and its key")
struct TradeMarkTests {

    @Test("A buy and a sale differ in shape, not colour alone, and the key draws a symbol that exists")
    func marks() {
        #expect(TradeMark.buy.keySymbol != TradeMark.sale.keySymbol)
        #expect(TradeMark.buy.colour != TradeMark.sale.colour)
        for mark in TradeMark.allCases {
            #expect(NSImage(systemSymbolName: mark.keySymbol, accessibilityDescription: nil) != nil, "\(mark)")
        }
        #expect(TradeMark(isBuy: true) == .buy)
        #expect(TradeMark(isBuy: false) == .sale)
    }
}
#endif
