//
//  InvoiceAnalyzer.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FoundationModels

/// One line item read from an invoice, with an optional category suggestion.
public struct InvoiceLineItem: Sendable, Identifiable {
    public let id = UUID()
    public var itemDescription: String
    public var amount: Decimal
    public var suggestedCategoryID: GncGUID?

    public init(itemDescription: String, amount: Decimal, suggestedCategoryID: GncGUID? = nil) {
        self.itemDescription = itemDescription
        self.amount = amount
        self.suggestedCategoryID = suggestedCategoryID
    }
}

/// The analysed contents of an invoice PDF.
public struct InvoiceAnalysis: Sendable {
    public var vendor: String
    public var date: Date?
    public var total: Decimal
    public var lineItems: [InvoiceLineItem]
    /// `false` when the invoice was longer than the model could read in one
    /// request and only its leading part was — so line items further down
    /// are missing, and the review should say so rather than let the sum's
    /// shortfall speak for itself.
    public var readWholeDocument: Bool
    /// A payment reference or invoice number carried by a QR code or barcode
    /// on the document — what Vision's barcode reader found there, not what
    /// the model made of it. `nil` for a document read as text, and for one
    /// with no code.
    public var reference: String?
    /// Whether this is the reading of the document's picture rather than of
    /// its text.
    public var readFromPicture: Bool

    public init(vendor: String, date: Date?, total: Decimal, lineItems: [InvoiceLineItem],
                readWholeDocument: Bool = true, reference: String? = nil, readFromPicture: Bool = false) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.lineItems = lineItems
        self.readWholeDocument = readWholeDocument
        self.reference = reference
        self.readFromPicture = readFromPicture
    }

    /// Sum of line items — compare with `total` to surface OCR/extraction
    /// discrepancies in review UI rather than silently posting them.
    public var lineItemSum: Decimal {
        lineItems.reduce(0) { $0 + $1.amount }
    }
}

/// Reads an invoice PDF and proposes an expense split per line item
/// (`FR-AI-03`), so one card charge can be recorded against the accounts it
/// actually covers.
public enum InvoiceAnalyzer {

    @Generable
    struct ModelLineItem {
        @Guide(description: "What was purchased, short")
        var item: String
        @Guide(description: "The line's total price, the amount printed at the end of that same line — a positive number unless the line is a discount or refund")
        var amount: String
    }

    @Generable
    struct ModelInvoice: DocumentAnswer {
        /// Fifty line items of answer, at the forty tokens a printed line
        /// costs, is the whole reserve.
        static let replyReserve = 2_000

        @Guide(description: "Vendor or store name")
        var vendor: String
        @Guide(description: "Invoice date in yyyy-MM-dd format, empty if not shown")
        var date: String
        @Guide(description: "Grand total of the invoice as printed")
        var total: String
        /// Fifty lines is past any invoice or receipt this reads in practice,
        /// and what the request keeps back for the answer (`replyReserve`,
        /// above). The ceiling exists to stop
        /// runaway generation, not to trim real invoices: measured on
        /// statement pages, an unbounded array spent 3,900 tokens repeating
        /// itself and failed, where the same request capped answered in a
        /// fifth of the time.
        @Guide(description: "Every billed line item — one entry per printed line, never merged. Exclude subtotal, tax-only, and total rows; keep discounts as negative amounts.", .maximumCount(50))
        var lineItems: [ModelLineItem]
    }

    /// The invoice as read off its picture, with what a code on it carries.
    @Generable
    struct ModelPicturedInvoice {
        @Guide(description: "The invoice or receipt in the image")
        var invoice: ModelInvoice
        @Guide(description: "The payment reference or invoice number encoded in a QR code or barcode on the document, exactly as the barcode tool reports it. Empty if the document has no code.")
        var reference: String
    }

    static let instructions = """
        You read invoices and receipts. Extract the vendor, date, grand total, \
        and each billed line item exactly as printed. Each printed line is one \
        line item — never merge adjacent lines, and take each item's amount \
        from the end of its own line. The line items should add up to the \
        grand total. Never invent line items.
        """

    /// One reading of an invoice, by either route.
    struct Reading {
        var invoice: ModelInvoice
        /// Only the leading part of the document was read.
        var truncated = false
        var reference: String?
        var fromPicture = false
    }

    /// How far a reading can be trusted without knowing the answer: whether
    /// its total is a figure printed in the document, and whether its line
    /// items add up to it.
    ///
    /// `source` is the document's text as Vision read it — the same text
    /// for both routes, and not the model's. The total counts for more than
    /// the arithmetic: a receipt whose prices leave the tax out adds up to
    /// less than its total and is still read right, while a total that is
    /// printed nowhere is a misread however tidy the sum.
    static func standing(of invoice: ModelInvoice, in source: String) -> Int {
        let amounts = invoice.lineItems.compactMap { IntelligenceParsing.amount($0.amount) }
        var standing = 0
        if let total = IntelligenceParsing.amount(invoice.total), total != 0 {
            if SourceGrounding.isAmountPrinted(invoice.total, in: source) { standing += 2 }
            if !amounts.isEmpty, amounts.reduce(0, +) == total { standing += 1 }
        }
        return standing
    }

    /// What a picture's reading needs for the text not to be read as well:
    /// a total that is printed in the document. Its lines need not add up
    /// to it — on a bill with a tax line they do not — and asking for the
    /// text whenever they did not was a second request on most documents
    /// that changed the answer on none of fifteen.
    static let standsAlone = 2

    /// Which of two readings of one document to keep. The picture's, unless
    /// the text's stands better: on fifteen synthetic receipts — clean,
    /// photographed, handwritten, faint and tilted — the picture read with
    /// Vision's tools had every total right and ten line-item lists, and
    /// the text thirteen and six (12 October 2026).
    static func preferred(pictured: Reading?, written: Reading?, source: String) -> Reading? {
        guard let pictured else { return written }
        guard let written else { return pictured }
        return standing(of: written.invoice, in: source) > standing(of: pictured.invoice, in: source)
            ? written : pictured
    }

    /// The reference the model reports, if it is what the barcode reader
    /// found on the page; nothing otherwise. The model is asked to copy it,
    /// and this is what checks that it did: a reference is typed into a
    /// payment, and one the model composed is worse than none.
    static func groundedReference(_ claimed: String, in barcodes: String) -> String? {
        let reference = claimed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.count >= 4, barcodes.contains(reference) else { return nil }
        return reference
    }

    /// The invoice read off its picture, with Vision's text and barcode
    /// tools offered — or `nil` where a picture cannot be shown, or the
    /// model would not or could not read this one. A failure of the model
    /// itself is thrown: the text route would meet it too.
    static func read(picture: DocumentPicture) async throws -> Reading? {
        let seeing = instructions + """
             The document is the image labelled \(LanguageModels.pictureLabel). \
            Read its text with the OCR tool and take every name and number from what \
            the tool returns, not from the image itself.
            """
        do {
            // The barcode reader is offered, and a reference asked for, only
            // where Vision has already found a code on the page.
            if await DocumentText.hasBarcode(picture) {
                guard let (answer, readings) = try await LanguageModels.respond(
                    .invoiceAnalyzer,
                    instructions: seeing + " The document carries a QR code or a barcode: read it with the barcode tool.",
                    prompt: "Read this receipt or invoice.",
                    picture: picture, readingCodes: true, generating: ModelPicturedInvoice.self)
                else { return nil }
                return Reading(invoice: answer.invoice,
                               reference: groundedReference(answer.reference, in: readings.barcodes),
                               fromPicture: true)
            }
            guard let (invoice, _) = try await LanguageModels.respond(
                .invoiceAnalyzer, instructions: seeing, prompt: "Read this receipt or invoice.",
                picture: picture, generating: ModelInvoice.self)
            else { return nil }
            return Reading(invoice: invoice, fromPicture: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IntelligenceError where error.endsABatch {
            throw error
        } catch {
            return nil
        }
    }

    /// Extracts vendor, date, total, and line items, then categorises each
    /// line item against `candidates` (pass expense accounts).
    ///
    /// - Parameters:
    ///   - text: the document's text — its own, or as Vision read it.
    ///   - picture: the document as an image, where it is one (a
    ///     photographed receipt, a scanned page: `DocumentText.picture`).
    ///     It is read first, with Vision's tools, and the text is read only
    ///     if that reading's total is not printed in the document
    ///     (``standing(of:in:)``).
    ///   - explainRefusal: ask the model why, if it refuses the document — a
    ///     second request, for when one invoice is being read and a person
    ///     will see the reason.
    public static func analyze(
        text: String,
        picture: DocumentPicture? = nil,
        candidates: [CategoryCandidate],
        explainRefusal: Bool = false
    ) async throws -> InvoiceAnalysis {
        let source = SourceGrounding.folded(text)
        var pictured: Reading?
        if let picture { pictured = try await read(picture: picture) }

        var written: Reading?
        if pictured.map({ standing(of: $0.invoice, in: source) < standsAlone }) ?? true {
            do {
                // The invoice is cut to what the model it runs on can read
                // beside the instructions and fifty line items of answer —
                // measured in that model's tokens (`LanguageModels.fit`). An
                // invoice longer than that is read from the top, and the
                // result says so.
                let (invoice, truncated) = try await LanguageModels.respond(
                    .invoiceAnalyzer, instructions: instructions,
                    document: text, framing: { "Invoice text:\n\n\($0)" },
                    generating: ModelInvoice.self, explainRefusal: explainRefusal)
                written = Reading(invoice: invoice, truncated: truncated)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // With a reading of the picture in hand, the text's refusal
                // is not the document's.
                guard pictured != nil else { throw error }
            }
        }
        guard let reading = preferred(pictured: pictured, written: written, source: source) else {
            throw IntelligenceError.emptyDocument
        }
        let invoice = reading.invoice
        let truncated = reading.truncated

        var items: [InvoiceLineItem] = invoice.lineItems.compactMap { line in
            guard let amount = IntelligenceParsing.amount(line.amount), amount != 0 else { return nil }
            return InvoiceLineItem(itemDescription: line.item, amount: amount)
        }

        // Sign reconciliation: the model occasionally emits stray minus signs.
        // When the printed grand total matches the sum of absolute values (but
        // not the signed sum), the signs were wrong — real discounts keep the
        // signed sum equal to the total, so they are left untouched.
        if let total = IntelligenceParsing.amount(invoice.total), total > 0 {
            let signedSum = items.reduce(Decimal(0)) { $0 + $1.amount }
            let absoluteSum = items.reduce(Decimal(0)) { $0 + abs($1.amount) }
            if signedSum != total, absoluteSum == total {
                for index in items.indices {
                    items[index].amount = abs(items[index].amount)
                }
            }
        }

        // Second pass: map each line item onto the book's expense accounts.
        if !candidates.isEmpty, !items.isEmpty {
            let categorizables = items.map {
                CategorizationItem(id: $0.id, payee: $0.itemDescription, amount: -$0.amount)
            }
            let suggestions = try await TransactionCategorizer.suggest(
                items: categorizables, candidates: candidates
            )
            for index in items.indices {
                items[index].suggestedCategoryID = suggestions[items[index].id]
            }
        }

        return InvoiceAnalysis(
            vendor: invoice.vendor,
            date: IntelligenceParsing.date(invoice.date),
            total: IntelligenceParsing.amount(invoice.total) ?? items.reduce(0) { $0 + $1.amount },
            lineItems: items,
            readWholeDocument: !truncated,
            reference: reading.reference,
            readFromPicture: reading.fromPicture
        )
    }
}
