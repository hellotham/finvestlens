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

    public init(vendor: String, date: Date?, total: Decimal, lineItems: [InvoiceLineItem],
                readWholeDocument: Bool = true) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.lineItems = lineItems
        self.readWholeDocument = readWholeDocument
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

    /// Extracts vendor, date, total, and line items, then categorises each
    /// line item against `candidates` (pass expense accounts).
    ///
    /// - Parameter explainRefusal: ask the model why, if it refuses the
    ///   document — a second request, for when one invoice is being read
    ///   and a person will see the reason.
    public static func analyze(
        text: String,
        candidates: [CategoryCandidate],
        explainRefusal: Bool = false
    ) async throws -> InvoiceAnalysis {
        let instructions = """
            You read invoices and receipts. Extract the vendor, date, grand total, \
            and each billed line item exactly as printed. Each printed line is one \
            line item — never merge adjacent lines, and take each item's amount \
            from the end of its own line. The line items should add up to the \
            grand total. Never invent line items.
            """
        // The invoice is cut to what the model it runs on can read beside
        // the instructions and fifty line items of answer — measured in that
        // model's tokens (`LanguageModels.fit`). An invoice longer than that
        // is read from the top, and the result says so.
        let (invoice, truncated) = try await LanguageModels.respond(
            .invoiceAnalyzer, instructions: instructions,
            document: text, framing: { "Invoice text:\n\n\($0)" },
            generating: ModelInvoice.self, explainRefusal: explainRefusal)

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
            readWholeDocument: !truncated
        )
    }
}
