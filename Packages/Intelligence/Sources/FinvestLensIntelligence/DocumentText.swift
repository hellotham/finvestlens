//
//  DocumentText.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Extracts plain text from financial documents (PDF statements, invoices).
///
/// Text-based PDFs read directly through PDFKit; pages with no text layer
/// (scans) fall back to Vision OCR on a rendered bitmap. Results are returned
/// per page so callers can chunk model requests — the on-device model has a
/// small context window, and statements are naturally page-structured.
public enum DocumentText {

    /// One page of extracted text, 1-based page numbers.
    public struct Page: Sendable {
        public let number: Int
        public let text: String
    }

    public static func extractPages(from url: URL) async throws -> [Page] {
        #if canImport(PDFKit)
        if let document = PDFDocument(url: url) {
            return try await extractPages(from: document)
        }
        #endif
        // Not a PDF — attachments are often PNG/JPEG scans; try it as an image.
        return try await extractPages(from: Data(contentsOf: url))
    }

    public static func extractPages(from data: Data) async throws -> [Page] {
        #if canImport(PDFKit)
        if let document = PDFDocument(data: data) {
            return try await extractPages(from: document)
        }
        #endif
        #if canImport(Vision)
        if let image = cgImage(from: data) {
            var text = try await recognize(image: image) ?? ""
            // A near-empty read of a photo usually means faint thermal print or
            // small type — recognition often succeeds on a 2× upscale.
            if text.count < 200, let scaled = upscaled(image, by: 2),
               let better = try? await recognize(image: scaled) ?? nil,
               better.count > text.count {
                text = better
            }
            if !text.isEmpty {
                return [Page(number: 1, text: text)]
            }
        }
        #endif
        throw IntelligenceError.emptyDocument
    }

    #if canImport(PDFKit)
    private static func extractPages(from document: PDFDocument) async throws -> [Page] {
        var pages: [Page] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = layoutText(for: page)
                ?? page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            if text.count < 32 {  // likely a scanned page — try OCR
                #if canImport(Vision)
                if let recognized = try? await ocr(page: page), recognized.count > text.count {
                    text = recognized
                }
                #endif
            }
            if !text.isEmpty {
                pages.append(Page(number: index + 1, text: text))
            }
        }
        guard !pages.isEmpty else { throw IntelligenceError.emptyDocument }
        return pages
    }

    /// Rebuilds a page's text in visual order from per-character bounds.
    ///
    /// `PDFPage.string` returns characters in content-stream order, which for
    /// column-aligned documents (statements, invoices) interleaves and reorders
    /// rows — an amount can detach from its line entirely. Reflowing by
    /// geometry (group glyphs into rows by baseline, sort each row
    /// left-to-right, respace from the x-gaps) restores the table structure
    /// the model needs.
    private static func layoutText(for page: PDFPage) -> String? {
        guard let raw = page.string as NSString?, raw.length > 0 else { return nil }

        struct PlacedChar {
            let character: String
            let x: CGFloat
            let width: CGFloat
            let baseline: CGFloat
        }
        var placed: [PlacedChar] = []
        placed.reserveCapacity(raw.length)
        // characterBounds(at:) indexes the glyph stream, which does not
        // include the newlines PDFKit synthesizes into `string` — offset by
        // the newlines seen so far or every line after the first shifts.
        var newlines = 0
        for index in 0..<raw.length {
            let character = raw.substring(with: NSRange(location: index, length: 1))
            if character == "\n" || character == "\r" {
                newlines += 1
                continue
            }
            let bounds = page.characterBounds(at: index - newlines)
            // Whitespace is reconstructed from gaps below (space glyphs often
            // have empty bounds anyway).
            guard !bounds.isEmpty, !bounds.isInfinite,
                  !character.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            placed.append(PlacedChar(character: character, x: bounds.minX,
                                     width: bounds.width, baseline: bounds.minY))
        }
        guard !placed.isEmpty else { return nil }

        // Group into rows by baseline (PDF space: top of page first). The
        // tolerance absorbs descenders and short glyphs like the period.
        let sorted = placed.sorted { $0.baseline > $1.baseline }
        let tolerance: CGFloat = 5
        var rows: [[PlacedChar]] = []
        var currentRow: [PlacedChar] = []
        var currentY = sorted[0].baseline
        for item in sorted {
            if abs(item.baseline - currentY) <= tolerance {
                currentRow.append(item)
            } else {
                rows.append(currentRow)
                currentRow = [item]
                currentY = item.baseline
            }
        }
        rows.append(currentRow)

        let lines: [String] = rows.map { row in
            let ordered = row.sorted { $0.x < $1.x }
            var line = ""
            var previousEnd: CGFloat?
            for item in ordered {
                if let end = previousEnd {
                    let gap = item.x - end
                    if gap > 12 {
                        line += "   "  // wide gap: keep the column break visible
                    } else if gap > 1.2 {
                        line += " "
                    }
                }
                line += item.character
                previousEnd = item.x + item.width
            }
            return line.trimmingCharacters(in: .whitespaces)
        }
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
    #endif

    /// Convenience: the whole document as one string (small documents such as
    /// invoices and dividend statements).
    public static func extractText(from url: URL) async throws -> String {
        try await extractPages(from: url).map(\.text).joined(separator: "\n\n")
    }

    public static func extractText(from data: Data) async throws -> String {
        try await extractPages(from: data).map(\.text).joined(separator: "\n\n")
    }

    #if canImport(PDFKit) && canImport(Vision)
    private static func ocr(page: PDFPage) async throws -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5  // ~180 dpi, enough for statement type sizes
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }

        return try await recognize(image: image)
    }
    #endif

    #if canImport(Vision)
    /// Recognises text in any image: the structured document reader first
    /// (Vision 26 — it groups a statement grid into tables, so rows/columns
    /// survive as tab-separated text), plain text recognition as fallback.
    /// Shared by the PDF scanned-page path and direct image attachments.
    private static func recognize(image: CGImage) async throws -> String? {
        if let structured = try? await recognizeDocument(image), !structured.isEmpty {
            return structured
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        let reflowed = reflow(observations)
        return reflowed.isEmpty ? nil : reflowed
    }

    /// Joins recognised fragments that sit on the same line of the image.
    ///
    /// Vision returns one observation per *run* of text, not per printed line,
    /// so a till receipt arrives as `BROCCOLINI` and `$2.98` on separate lines
    /// — 82 lines for 876 characters on a real one, about ten characters each.
    /// Two things go wrong with that. The item is severed from its price, and
    /// ``InvoiceAnalyzer`` is asked to "take each item's amount from the end of
    /// its own line", which is then impossible. And the on-device model
    /// rejects the result outright — `unsupportedLanguageOrLocale`, four
    /// receipts in five — because a column of ten-character fragments does not
    /// read as a language.
    ///
    /// The PDF path already reflows by geometry (``layoutText(for:)``); this
    /// is the same idea against Vision's normalised boxes, and it is why the
    /// two paths now produce comparably shaped text.
    private static func reflow(_ observations: [RecognizedTextObservation]) -> String {
        struct Fragment { let text: String; let x: CGFloat; let y: CGFloat; let height: CGFloat }
        let fragments: [Fragment] = observations.compactMap { observation -> Fragment? in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let box = observation.boundingBox.cgRect
            return Fragment(text: text, x: box.minX, y: box.midY, height: box.height)
        }
        guard !fragments.isEmpty else { return "" }

        // Vision's origin is bottom-left, so descending y reads top-down. The
        // tolerance is half a line's own height rather than a constant: a
        // receipt photographed close up has taller boxes than a scanned A4.
        let sorted = fragments.sorted { $0.y > $1.y }
        var lines: [String] = []
        var row: [Fragment] = []
        for fragment in sorted {
            let tolerance = max(fragment.height, row.first?.height ?? 0) / 2
            if let first = row.first, abs(fragment.y - first.y) > tolerance {
                lines.append(row.sorted { $0.x < $1.x }.map(\.text).joined(separator: "   "))
                row = []
            }
            row.append(fragment)
        }
        if !row.isEmpty {
            lines.append(row.sorted { $0.x < $1.x }.map(\.text).joined(separator: "   "))
        }
        return lines.joined(separator: "\n")
    }

    /// Decodes image data (PNG/JPEG/HEIC…) to a `CGImage` for recognition.
    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Redraws an image at `factor`× on white with high-quality interpolation.
    private static func upscaled(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor
        let height = image.height * factor
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    /// Reads a rendered page as a structured document, reconstructing detected
    /// tables as tab-separated rows so the model sees the statement grid rather
    /// than a reflowed wall of text.
    private static func recognizeDocument(_ image: CGImage) async throws -> String? {
        let observations = try await RecognizeDocumentsRequest().perform(on: image)
        guard let document = observations.first?.document else { return nil }
        var blocks: [String] = []
        for table in document.tables {
            for row in table.rows {
                let cells = row.map { $0.content.text.transcript }
                let line = cells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { blocks.append(line) }
            }
        }
        // With no table found, this reader has nothing to offer that plain
        // recognition does not: its transcript is fragment-per-line, exactly
        // the shape that severs a receipt's items from their prices and gets
        // the request refused. Returning nil hands the image to the reflowing
        // path instead, which is the whole point of preferring this one.
        guard !blocks.isEmpty else { return nil }
        let body = document.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { blocks.append(body) }
        return blocks.joined(separator: "\n")
    }
    #endif
}
