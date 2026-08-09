//
//  LiveScanOCRTests.swift
//  FinvestLens — Intelligence
//
//  The OCR fallback has no synthetic test that means anything: a PDF this
//  suite renders itself carries embedded text, so it never takes the scan
//  path at all. Point `FL_SCAN_PDF` at a folder of real scans and run:
//
//      FL_SCAN_PDF=~/path/to/scans swift test \
//        --package-path Packages/Intelligence --filter LiveScanOCR
//
//  Skipped otherwise. It prints sizes and counts only — never recognised
//  text — so its output is safe to paste into a review.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import Foundation
import Testing
import PDFKit
@testable import FinvestLensIntelligence

private let scanPath = ProcessInfo.processInfo.environment["FL_SCAN_PDF"]

@Suite("LiveScanOCR", .enabled(if: scanPath != nil), .timeLimit(.minutes(20)), .serialized)
struct LiveScanOCRTests {

    /// PDFs under the configured path whose embedded text is negligible — the
    /// ones that actually exercise Vision rather than the text path.
    private func scans(limit: Int = 8) throws -> [URL] {
        let root = URL(fileURLWithPath: try #require(scanPath))
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "pdf" } ?? []
        let imageOnly = found.filter { url in
            guard let doc = PDFDocument(url: url) else { return false }
            let sampled = (0..<min(doc.pageCount, 3))
                .reduce(0) { $0 + (doc.page(at: $1)?.string ?? "").count }
            return sampled < 32
        }
        return Array(imageOnly.sorted { $0.path < $1.path }.prefix(limit))
    }

    @Test("Image-only PDFs come back as text through the OCR fallback")
    func scannedPagesRecognise() async throws {
        let files = try scans()
        try #require(!files.isEmpty, "FL_SCAN_PDF contains no image-only PDFs to test")
        var withAmounts = 0
        for url in files {
            let pages = try await DocumentText.extractPages(from: url)
            let text = pages.map(\.text).joined(separator: "\n")
            print("  \(pages.count) page(s), \(text.count) chars, \(text.filter(\.isNumber).count) digits")

            // The bar is recognition, not accuracy: a scan that comes back
            // empty has taken the fallback and got nothing, which is the
            // failure this harness exists to catch.
            #expect(!pages.isEmpty)
            #expect(text.count > 100)
            if text.range(of: #"\d+\.\d{2}"#, options: .regularExpression) != nil { withAmounts += 1 }
        }
        // Not every scan is financial — some are letters and notices — so this
        // is a floor on the batch rather than a rule for each file.
        #expect(withAmounts * 2 >= files.count)
    }
}

private let receiptPath = ProcessInfo.processInfo.environment["FL_RECEIPT_DIR"]

/// Photographed till receipts, which are the hardest thing this reads: thermal
/// print, a curled page, and a layout that is mostly numbers.
///
///     FL_RECEIPT_DIR=~/path/to/receipts swift test \
///       --package-path Packages/Intelligence --filter LiveReceipts
@Suite("LiveReceipts", .enabled(if: receiptPath != nil && IntelligenceAvailability.current().isAvailable),
       .timeLimit(.minutes(20)), .serialized)
struct LiveReceiptTests {

    @Test("Receipt photographs recognise as whole lines, not a column of fragments")
    func receiptsReflowIntoLines() async throws {
        let root = URL(fileURLWithPath: try #require(receiptPath))
        let images = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) } ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!images.isEmpty, "FL_RECEIPT_DIR contains no images")

        // Evenly spaced rather than the first few, so one shop's template
        // cannot stand in for the batch.
        let step = max(images.count / 10, 1)
        let sample = stride(from: 0, to: images.count, by: step).prefix(10).map { images[$0] }

        var analysed = 0
        for url in sample {
            let text = try await DocumentText.extractText(from: url)
            let rows = text.split(separator: "\n")
            let lines = max(rows.count, 1)
            let perLine = text.count / lines

            // The bar that matters is not line *length* — a narrow till roll
            // prints "MILK 3.50" and that is a whole line at nine characters.
            // It is whether an item ended up beside its price at all. Vision
            // returns one observation per *run* of text, so unreflowed output
            // puts the name on one line and the amount on the next, and almost
            // no line holds both; reflowed, a good third of them do. That is
            // also precisely what InvoiceAnalyzer is asked to read, "each
            // item's amount from the end of its own line".
            let paired = rows.filter { row in
                row.contains(where: \.isLetter) && row.contains(where: \.isNumber)
            }.count
            let pairedShare = Double(paired) / Double(lines)
            #expect(pairedShare >= 0.2,
                    "only \(Int(pairedShare * 100))% of lines pair text with a number, reflow may have regressed")

            // Analysis itself is reported, not asserted: on real photographs
            // the on-device model refuses a minority outright with
            // "An unsupported language or locale was used", and that rate is a
            // property of the model rather than of this code.
            if let invoice = try? await InvoiceAnalyzer.analyze(text: text, candidates: []) {
                analysed += 1
                print("  \(text.count) chars / \(lines) lines (\(perLine) per line, "
                      + "\(Int(pairedShare * 100))% paired), \(invoice.lineItems.count) line item(s)")
            } else {
                print("  \(text.count) chars / \(lines) lines (\(perLine) per line, "
                      + "\(Int(pairedShare * 100))% paired), declined")
            }
        }
        // Most should still get through; a wholesale collapse is a real failure.
        #expect(analysed * 2 >= sample.count)
    }
}
#endif
