//
//  ReceiptImages.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Receipts and invoices that never existed, drawn as images: for the tests
//  that show the model a picture, and the survey that says whether showing
//  it one is worth it. Every figure here is invented.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct SyntheticReceipt: Sendable {
    let name: String
    let lines: [String]
    let vendor: String
    /// yyyy-MM-dd
    let date: String
    let total: Decimal
    /// The billed lines. `nil` where which lines count is a matter of
    /// opinion (a card surcharge), so that the items are not scored.
    let items: [Decimal]?

    static let supermarket = SyntheticReceipt(name: "supermarket", lines: [
        "FRESHFIELDS MARKET", "12 Harbour Road, Northbridge", "ABN 12 345 678 901", "",
        "TAX INVOICE          14/03/2026 17:42", "",
        "Milk Full Cream 2L                 4.50",
        "Sourdough Loaf                     7.20",
        "Bananas 1.2kg @ 3.90/kg            4.68",
        "Free Range Eggs 12pk               8.90",
        "Olive Oil 500ml                   14.00", "",
        "SUBTOTAL                          39.28",
        "GST INCLUDED                       3.57",
        "TOTAL                             39.28", "",
        "EFTPOS VISA ****4821              39.28", "Thank you for shopping with us"],
        vendor: "FRESHFIELDS", date: "2026-03-14", total: Decimal(string: "39.28")!,
        items: ["4.50", "7.20", "4.68", "8.90", "14.00"].map { Decimal(string: $0)! })

    static let restaurant = SyntheticReceipt(name: "restaurant", lines: [
        "THE COPPER KETTLE", "Bistro & Bar", "88 Queen Street", "",
        "Table 14   Guests 2   21 Feb 2026", "",
        "2 x Flat White                     9.00",
        "1 x Eggs Benedict                 22.50",
        "1 x Avocado Toast                 19.00",
        "1 x Fresh Orange Juice             8.50", "",
        "Subtotal                          59.00",
        "Card surcharge 1.5%                0.89",
        "TOTAL AUD                         59.89", "", "GST included in total 5.44"],
        vendor: "COPPER KETTLE", date: "2026-02-21", total: Decimal(string: "59.89")!, items: nil)

    static let invoice = SyntheticReceipt(name: "invoice", lines: [
        "BRIGHTSPARK ELECTRICAL PTY LTD", "Invoice INV-20418", "Date: 2026-01-09      Due: 2026-01-23", "",
        "Bill to: Sample Customer", "",
        "Description                 Qty    Rate     Amount",
        "Call-out fee                  1   95.00      95.00",
        "Labour (hours)              2.5   88.00     220.00",
        "LED downlight 10W             6   18.50     111.00",
        "Safety switch test            1   45.00      45.00", "",
        "Subtotal                                    471.00",
        "GST 10%                                      47.10",
        "Total due                                   518.10"],
        vendor: "BRIGHTSPARK", date: "2026-01-09", total: Decimal(string: "518.10")!,
        items: ["95.00", "220.00", "111.00", "45.00"].map { Decimal(string: $0)! })

    static let all = [supermarket, restaurant, invoice]

    /// How the page looks: straight off a printer, photographed, written by
    /// hand, a faint thermal roll at low resolution, or badly tilted.
    enum Look: String, CaseIterable, Sendable { case clean, photo, handwritten, faint, tilted }

    func image(_ look: Look) -> CGImage {
        let small = look == .faint
        let width = small ? 620 : 1400
        let lineHeight: CGFloat = small ? 21 : 46
        let margin: CGFloat = small ? 40 : 90
        let height = Int(CGFloat(lines.count) * lineHeight + margin * 2)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let paper: CGFloat = look == .clean ? 1.0 : (look == .faint ? 0.93 : 0.84)
        context.setFillColor(CGColor(red: paper, green: paper, blue: paper * 0.97, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let angle: CGFloat = look == .tilted ? 0.14 : (look == .clean ? 0 : 0.04)
        let scale: CGFloat = look == .tilted ? 0.82 : 1
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: angle)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        let face = look == .handwritten ? "Bradley Hand Bold" : "Menlo"
        let font = CTFontCreateWithName(face as CFString, small ? 12 : (look == .handwritten ? 30 : 28), nil)
        let ink: CGFloat = look == .clean ? 0 : (look == .faint ? 0.55 : 0.2)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: ink, green: ink, blue: ink, alpha: 1),
        ]
        for (index, line) in lines.enumerated() {
            let y = CGFloat(height) - margin - CGFloat(index + 1) * lineHeight
            // Handwriting is not monospaced, so the amount is put at the
            // right-hand edge, as a person writing a bill puts it.
            if look == .handwritten,
               let split = line.range(of: #"\s{2,}(?=[-0-9.]+$)"#, options: .regularExpression) {
                let left = NSAttributedString(string: String(line[..<split.lowerBound]), attributes: attributes)
                let right = CTLineCreateWithAttributedString(
                    NSAttributedString(string: String(line[split.upperBound...]), attributes: attributes))
                context.textPosition = CGPoint(x: margin, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(left), context)
                let rightWidth = CGFloat(CTLineGetTypographicBounds(right, nil, nil, nil))
                context.textPosition = CGPoint(x: CGFloat(width) - margin - rightWidth, y: y)
                CTLineDraw(right, context)
            } else {
                context.textPosition = CGPoint(x: margin, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(
                    NSAttributedString(string: line, attributes: attributes)), context)
            }
        }
        return context.makeImage()!
    }
}

enum ReceiptImages {

    /// `image` with a QR code under it that carries `payload`.
    static func addingQRCode(to image: CGImage, payload: String) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        let code = CIContext().createCGImage(qr, from: qr.extent)!
        let height = image.height + code.height + 80
        let context = CGContext(data: nil, width: image.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: height))
        context.draw(image, in: CGRect(x: 0, y: code.height + 80, width: image.width, height: image.height))
        context.draw(code, in: CGRect(x: 90, y: 40, width: code.width, height: code.height))
        return context.makeImage()!
    }

    /// The image as a file's bytes. `orientation` is written as the file's
    /// EXIF orientation without the pixels being turned — which is how a
    /// phone stores a portrait photograph.
    static func data(_ image: CGImage, type: UTType = .png, orientation: CGImagePropertyOrientation? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation.rawValue }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// `image` turned a quarter-turn anticlockwise in its pixels — its top
    /// edge down the left-hand side — which is how a phone held upright
    /// stores what it sees, and what `.right` says to undo.
    static func lyingOnItsSide(_ image: CGImage) -> CGImage {
        let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }

    /// How far apart two images are, as the mean difference between them
    /// seen at 24 × 24 in grey: near nothing for the same picture, large
    /// for one that is upside down.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func grey(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 24 * 24)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 24, height: 24, bitsPerComponent: 8,
                                        bytesPerRow: 24, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 24))
            }
            return pixels
        }
        let (left, right) = (grey(a), grey(b))
        return zip(left, right).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(left.count)
    }
}
