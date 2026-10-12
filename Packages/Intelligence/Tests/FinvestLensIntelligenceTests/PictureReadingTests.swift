//
//  PictureReadingTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A document that is a picture — a photographed receipt, a scanned page —
//  shown to the model with Vision's tools: what counts as a picture, which of
//  two readings is kept, and (live) that a page the text route gets wrong is
//  read right. Synthetic images throughout (`ReceiptImages.swift`).
//

import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import FoundationModels
@testable import FinvestLensIntelligence

@Suite("A document that is a picture")
struct DocumentPictureTests {

    /// A one-page PDF whose page is real text.
    private func textPDF(_ lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: 50, y: 740 - CGFloat(index) * 16)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A one-page PDF whose page is only an image of the receipt: a scan.
    private func scannedPDF(_ image: CGImage) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 40, y: 200, width: 532, height: 532 * CGFloat(image.height) / CGFloat(image.width)))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test("An image file is a picture")
    func imageFile() throws {
        let image = SyntheticReceipt.supermarket.image(.clean)
        let picture = try #require(DocumentText.picture(from: ReceiptImages.data(image)))
        #expect(picture.image.width == image.width)
        #expect(picture.image.height == image.height)
    }

    @Test("A photograph stored on its side comes back upright")
    func orientation() throws {
        // A phone keeps a portrait shot as landscape pixels and a note of
        // which way up it goes. The pixels alone are a receipt lying down.
        let upright = SyntheticReceipt.supermarket.image(.clean)
        let stored = ReceiptImages.lyingOnItsSide(upright)
        #expect(stored.width == upright.height)
        let file = ReceiptImages.data(stored, type: .jpeg, orientation: .right)
        let picture = try #require(DocumentText.picture(from: file))
        #expect(picture.image.width == upright.width)
        #expect(picture.image.height == upright.height)
        // The right way up, and not merely the right shape: turned the
        // other way it has the same dimensions and is upside down.
        #expect(ReceiptImages.difference(picture.image, upright) < 4)
        let wrong = try #require(DocumentText.picture(
            from: ReceiptImages.data(stored, type: .jpeg, orientation: .left)))
        #expect(ReceiptImages.difference(wrong.image, upright) > ReceiptImages.difference(picture.image, upright) * 2)
    }

    @Test("Text recognition is given the photograph upright too, at its own size")
    func uprightForRecognition() throws {
        let upright = SyntheticReceipt.supermarket.image(.clean)
        let stored = ReceiptImages.lyingOnItsSide(upright)
        let turned = try #require(DocumentText.cgImage(
            from: ReceiptImages.data(stored, type: .jpeg, orientation: .right)))
        #expect(turned.width == upright.width)
        #expect(turned.height == upright.height)
        #expect(ReceiptImages.difference(turned, upright) < 4)
        // No note of a turn: the pixels as they are.
        let untouched = try #require(DocumentText.cgImage(from: ReceiptImages.data(stored, type: .jpeg)))
        #expect(untouched.width == stored.width)
    }

    @Test("A very large photograph is brought down to a size a model has a use for")
    func bounded() throws {
        let image = SyntheticReceipt.supermarket.image(.clean)
        let context = CGContext(data: nil, width: image.width * 3, height: image.height * 3, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 3, height: image.height * 3))
        let picture = try #require(DocumentText.picture(from: ReceiptImages.data(context.makeImage()!)))
        #expect(max(picture.image.width, picture.image.height) == 2_400)
    }

    @Test("A scanned page is a picture; a page of text is not, and is read as text")
    func pdfs() {
        #expect(DocumentText.picture(from: scannedPDF(SyntheticReceipt.invoice.image(.clean))) != nil)
        #expect(DocumentText.picture(from: textPDF(SyntheticReceipt.invoice.lines)) == nil)
    }

    @Test("A code on the page is found before the model is asked about one")
    func barcodes() async {
        let plain = SyntheticReceipt.invoice.image(.clean)
        let coded = ReceiptImages.addingQRCode(to: plain, payload: "PAYREF 7741-2209-INV20418")
        #expect(await DocumentText.hasBarcode(DocumentPicture(coded)))
        #expect(!(await DocumentText.hasBarcode(DocumentPicture(plain))))
    }

    @Test("Something that is neither is nothing")
    func neither() {
        #expect(DocumentText.picture(from: Data("not an image".utf8)) == nil)
        #expect(DocumentText.picture(from: Data()) == nil)
    }
}

@Suite("Which reading of an invoice is kept")
struct InvoiceReadingTests {

    private func invoice(total: String, items: [String]) -> InvoiceAnalyzer.ModelInvoice {
        InvoiceAnalyzer.ModelInvoice(
            vendor: "Brightspark", date: "2026-01-09", total: total,
            lineItems: items.map { InvoiceAnalyzer.ModelLineItem(item: "line", amount: $0) })
    }

    private let source = SourceGrounding.folded(SyntheticReceipt.invoice.lines.joined(separator: "\n"))

    @Test("A reading stands on its total being printed, and then on its lines adding up")
    func standing() {
        // 471.00 is the subtotal — printed, and what the four lines add up to.
        #expect(InvoiceAnalyzer.standing(of: invoice(total: "471.00", items: ["95.00", "220.00", "111.00", "45.00"]),
                                         in: source) == 3)
        // The total due: printed, and the lines leave the tax out.
        #expect(InvoiceAnalyzer.standing(of: invoice(total: "518.10", items: ["95.00", "220.00", "111.00", "45.00"]),
                                         in: source) == 2)
        // A misread total is printed nowhere, however the lines add up.
        #expect(InvoiceAnalyzer.standing(of: invoice(total: "510.10", items: ["510.10"]), in: source) == 1)
        #expect(InvoiceAnalyzer.standing(of: invoice(total: "510.10", items: ["95.00"]), in: source) == 0)
        // No total at all is nothing to stand on.
        #expect(InvoiceAnalyzer.standing(of: invoice(total: "", items: ["95.00"]), in: source) == 0)
    }

    @Test("The picture's reading is kept unless the text's stands better")
    func preferred() {
        let right = invoice(total: "518.10", items: ["95.00", "220.00", "111.00", "45.00"])
        let misread = invoice(total: "510.10", items: ["95.00", "288.00"])
        func reading(_ invoice: InvoiceAnalyzer.ModelInvoice, picture: Bool) -> InvoiceAnalyzer.Reading {
            InvoiceAnalyzer.Reading(invoice: invoice, fromPicture: picture)
        }
        // Level: the picture's.
        #expect(InvoiceAnalyzer.preferred(pictured: reading(right, picture: true),
                                          written: reading(right, picture: false), source: source)?.fromPicture == true)
        // The text's stands better: the text's.
        #expect(InvoiceAnalyzer.preferred(pictured: reading(misread, picture: true),
                                          written: reading(right, picture: false), source: source)?.fromPicture == false)
        // The picture's stands better: the picture's.
        #expect(InvoiceAnalyzer.preferred(pictured: reading(right, picture: true),
                                          written: reading(misread, picture: false), source: source)?.fromPicture == true)
        // Only one of them: that one.
        #expect(InvoiceAnalyzer.preferred(pictured: nil, written: reading(right, picture: false),
                                          source: source)?.fromPicture == false)
        #expect(InvoiceAnalyzer.preferred(pictured: reading(misread, picture: true), written: nil,
                                          source: source)?.fromPicture == true)
        #expect(InvoiceAnalyzer.preferred(pictured: nil, written: nil, source: source) == nil)
    }

    @Test("A reference is what the barcode reader found, or it is nothing")
    func reference() {
        let found = #"[{"payload":"PAYREF 7741-2209-INV20418","symbology":"QR"}]"#
        #expect(InvoiceAnalyzer.groundedReference("PAYREF 7741-2209-INV20418", in: found) == "PAYREF 7741-2209-INV20418")
        #expect(InvoiceAnalyzer.groundedReference("  PAYREF 7741-2209-INV20418\n", in: found) == "PAYREF 7741-2209-INV20418")
        // Composed by the model from what it saw printed.
        #expect(InvoiceAnalyzer.groundedReference("INV-20418", in: found) == nil)
        // Nothing found, or nothing claimed.
        #expect(InvoiceAnalyzer.groundedReference("PAYREF 7741", in: "") == nil)
        #expect(InvoiceAnalyzer.groundedReference("", in: found) == nil)
        // Too short to be a reference rather than a coincidence.
        #expect(InvoiceAnalyzer.groundedReference("QR", in: found) == nil)
    }

    @Test("What the tools returned is kept by tool")
    func readings() {
        let readings = LanguageModels.PictureReadings()
        readings.note(Transcript.ToolOutput(id: "1", toolName: "getText",
                                            segments: [.text(.init(content: "TOTAL 39.28"))]))
        readings.note(Transcript.ToolOutput(id: "2", toolName: "readBarcodes",
                                            segments: [.text(.init(content: "PAYREF 7741"))]))
        #expect(readings.called == ["getText", "readBarcodes"])
        #expect(readings.text(from: "getText") == "TOTAL 39.28")
        #expect(readings.text(from: "readBarcodes") == "PAYREF 7741")
        #expect(readings.text(from: "somethingElse").isEmpty)
    }

    @Test("A request that shows no picture offers no tool and calls none")
    func toolsComeWithThePicture() {
        // Vision's readers are there where the platform has them — and the
        // only request they are offered to is one with a picture in it.
        #if canImport(_Vision_FoundationModels)
        #expect(LanguageModels.pictureTools(readingCodes: false).count == 1)
        #expect(LanguageModels.pictureTools(readingCodes: true).count == 2)
        #else
        #expect(LanguageModels.pictureTools(readingCodes: true).isEmpty)
        #endif
        for feature in IntelligenceFeature.allCases {
            #expect(feature.toolCallingMode == .disallowed, "\(feature)")
        }
    }
}

/// Vision reading a receipt, without the model. Kept with the live suites
/// because recognition needs the system's own assets, which a build machine
/// may not have.
@Suite("A photograph stored on its side is read as the upright one is",
       .enabled(if: Fixtures.modelAvailable))
struct OrientationRecognitionTests {

    @Test("Its lines survive", arguments: [0, 1, 2])
    func lines(index: Int) async throws {
        let receipt = SyntheticReceipt.all[index]
        let upright = receipt.image(.clean)
        func pairedLines(_ data: Data) async throws -> Int {
            try await DocumentText.extractText(from: data).split(separator: "\n")
                .filter { $0.contains(where: \.isLetter) && $0.contains(where: \.isNumber) }.count
        }
        let straight = try await pairedLines(ReceiptImages.data(upright, type: .jpeg))
        let turned = try await pairedLines(ReceiptImages.data(
            ReceiptImages.lyingOnItsSide(upright), type: .jpeg, orientation: .right))
        // The same lines pair a word with a number, give or take one that
        // JPEG compression can cost either way.
        #expect(abs(turned - straight) <= 1, "upright \(straight), stored on its side \(turned)")
    }
}

#if canImport(_Vision_FoundationModels)
extension Live {
/// The live model shown pictures. Skipped where the model is not available.
@Suite("An invoice read off its picture", .enabled(if: Fixtures.modelAvailable),
       .timeLimit(.minutes(6)), .serialized)
struct LivePictureTests {

    private func text(of image: CGImage) async throws -> String {
        try await DocumentText.extractText(from: ReceiptImages.data(image))
    }

    @Test("A tilted invoice, whose text alone puts the amounts on the wrong lines")
    func tiltedInvoice() async throws {
        let receipt = SyntheticReceipt.invoice
        let image = receipt.image(.tilted)
        let analysis = try await InvoiceAnalyzer.analyze(
            text: try await text(of: image), picture: DocumentPicture(image), candidates: [])
        #expect(analysis.total == receipt.total, "total \(analysis.total)")
        #expect(analysis.vendor.uppercased().contains(receipt.vendor))
        #expect(analysis.lineItems.map(\.amount).sorted() == receipt.items?.sorted(),
                "items \(analysis.lineItems.map(\.amount))")
        #expect(analysis.reference == nil)
    }

    @Test("A QR code's payload is the reference, exactly")
    func reference() async throws {
        let payload = "PAYREF 7741-2209-INV20418"
        let image = ReceiptImages.addingQRCode(to: SyntheticReceipt.invoice.image(.clean), payload: payload)
        let analysis = try await InvoiceAnalyzer.analyze(
            text: try await text(of: image), picture: DocumentPicture(image), candidates: [])
        #expect(analysis.total == SyntheticReceipt.invoice.total)
        #expect(analysis.reference == payload)
        #expect(analysis.readFromPicture)
    }

    @Test("A clean receipt reads the same with its picture as without")
    func cleanReceipt() async throws {
        let receipt = SyntheticReceipt.supermarket
        let image = receipt.image(.clean)
        let ocr = try await text(of: image)
        let written = try await InvoiceAnalyzer.analyze(text: ocr, candidates: [])
        let pictured = try await InvoiceAnalyzer.analyze(text: ocr, picture: DocumentPicture(image), candidates: [])
        #expect(written.total == receipt.total)
        #expect(pictured.total == receipt.total)
        #expect(!written.readFromPicture)
        #expect(pictured.lineItems.map(\.amount).sorted() == written.lineItems.map(\.amount).sorted())
    }
}
}
#endif

private let imageSurvey = ProcessInfo.processInfo.environment["FL_IMAGE_SURVEY"] != nil

extension Live {
/// Whether showing the model a document's picture is worth it, measured: the
/// same fifteen pages read as text and read with their picture, by the code
/// the app runs. It asserts nothing and prints every case.
///
///     FL_IMAGE_SURVEY=1 swift test --package-path Packages/Intelligence \
///         --filter PictureSurvey
@Suite("A receipt read as text, and with its picture",
       .enabled(if: imageSurvey && Fixtures.modelAvailable), .timeLimit(.minutes(30)), .serialized)
struct PictureSurvey {

    private func verdict(_ receipt: SyntheticReceipt, _ analysis: InvoiceAnalysis) -> String {
        let day = analysis.date.map {
            ISO8601DateFormatter.string(from: $0, timeZone: .current,
                                        formatOptions: [.withFullDate, .withDashSeparatorInDate])
        } ?? ""
        let items = receipt.items.map { analysis.lineItems.map(\.amount).sorted() == $0.sorted() ? "ok" : "NO" } ?? "--"
        return "vendor \(analysis.vendor.uppercased().contains(receipt.vendor) ? "ok" : "NO") "
            + "date \(day == receipt.date ? "ok" : "NO") total \(analysis.total == receipt.total ? "ok" : "NO") items \(items)"
    }

    @Test("Fifteen pages, both ways", arguments: SyntheticReceipt.Look.allCases)
    func pages(look: SyntheticReceipt.Look) async {
        let clock = ContinuousClock()
        for receipt in SyntheticReceipt.all {
            let image = receipt.image(look)
            guard let ocr = try? await DocumentText.extractText(from: ReceiptImages.data(image)) else {
                print("PICTURESURVEY \(receipt.name) [\(look.rawValue)]: no text read"); continue
            }
            for picture in [nil, DocumentPicture(image)] {
                let route = picture == nil ? "text   " : "picture"
                var analysis: InvoiceAnalysis?
                let elapsed = await clock.measure {
                    analysis = try? await InvoiceAnalyzer.analyze(text: ocr, picture: picture, candidates: [])
                }
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                guard let analysis else {
                    print("PICTURESURVEY \(receipt.name) [\(look.rawValue)] \(route): FAILED"); continue
                }
                print("PICTURESURVEY \(receipt.name) [\(look.rawValue)] \(route): \(verdict(receipt, analysis)) "
                      + "| kept \(analysis.readFromPicture ? "picture" : "text") | \(String(format: "%.2f", seconds)) s")
            }
        }
    }
}
}
