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
#endif
