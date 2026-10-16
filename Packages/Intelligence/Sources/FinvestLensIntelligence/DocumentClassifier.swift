//
//  DocumentClassifier.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FoundationModels

/// What kind of financial document a PDF is, deciding how Smart Import
/// handles it (`FR-AI-07`).
public enum FinancialDocumentKind: String, Sendable, CaseIterable {
    case bankStatement = "bank statement"
    case dividendStatement = "dividend statement"
    case invoice = "invoice or receipt"
    case unknown = "something else"

    public var displayName: String {
        switch self {
        case .bankStatement: return String(localized: "Bank statement")
        case .dividendStatement: return String(localized: "Dividend statement")
        case .invoice: return String(localized: "Invoice / receipt")
        case .unknown: return String(localized: "Unrecognised")
        }
    }
}

/// Classifies a financial document from its extracted text.
///
/// The on-device model reads the opening of the document; a deterministic
/// keyword heuristic answers when the model is unavailable (or declines) and
/// serves as the tie-breaker for `unknown` answers — classification must
/// never be the step that fails a whole import batch.
public enum DocumentClassifier {

    /// Whether a document is a security paying its holder — a dividend, an ETF
    /// or trust distribution, a capital-note interest payment.
    ///
    /// This decides *direction*: money coming in rather than going out. Get it
    /// wrong and the document is hunted for among purchases, so a distribution
    /// sitting in the book on the right day for the right amount is never
    /// found. That is not hypothetical — it cost 10 of 17 real statements
    /// before this existed.
    ///
    /// Two independent signals are required, which is what keeps a shop
    /// receipt out: what is being paid (a dividend or a distribution), and the
    /// registry vocabulary that only a holding statement uses. Requiring
    /// *franking* language instead was the original rule, and Australian
    /// paperwork does not cooperate with it — a NAB capital-note advice says
    /// "distribution" and never "dividend", while a Vanguard advice says
    /// "dividend" and never "franked". Each failed a different half of that
    /// test; both name a payment date and a record date.
    public static func isSecurityIncome(_ text: String) -> Bool {
        let lower = text.lowercased()
        func containsAny(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }
        let payment = containsAny(["dividend", "distribution"])
        let registry = containsAny(["payment date", "record date", "franking", "franked",
                                    "imputation", "ex-date", "ex date", "securities held",
                                    "units held", "holder identification", "reinvestment plan"])
        return payment && registry
    }

    /// How a purchase was paid for, as far as the receipt admits.
    public enum Tender: String, Sendable, Equatable {
        /// Paid in notes and coins — so no card transaction exists to match.
        case cash
        /// Paid by card, so a transaction should exist. If none does, the
        /// statement carrying it has not been imported — a data gap, not a
        /// matching failure, and worth telling someone about.
        case card
        /// The receipt does not say, or could not be read.
        case unknown
    }

    /// What a receipt says it was paid with.
    ///
    /// Worth knowing because an unmatched receipt has two very different
    /// explanations. A cash purchase has no bank transaction and never will —
    /// it can only be *entered*. A card purchase has one somewhere, and its
    /// absence means a statement is missing.
    ///
    /// Cash is asserted only when the receipt says so **and** says nothing
    /// about a card. That asymmetry is not fussiness: card dockets routinely
    /// print `CHANGE 0.00`, and an EFTPOS receipt offering cash out prints
    /// the word "cash" while being the most card-like document there is. A
    /// single marker in isolation decides nothing.
    ///
    /// This never says which cash *account* — a receipt records that money
    /// left a wallet, not whose. That fact is not in the document and no
    /// amount of reading will find it.
    public static func tender(_ text: String) -> Tender {
        let lower = text.lowercased()
        func containsAny(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }
        // Read broadly, and deliberately so. The two mistakes are not
        // equal: failing to spot a card leaves a receipt unmatched, which
        // costs nothing, while failing to spot it and calling the purchase
        // cash *creates a transaction that never happened* — and it will
        // double-count the moment the real statement is imported. So anything
        // that smells of a card wins, including bare words like "debit" that
        // a stricter list would miss when OCR mangles the phrase around them.
        let card = containsAny(["eftpos", "visa", "mastercard", "master card", "amex",
                                "american express", "credit", "debit", "contactless",
                                "paywave", "paypass", "card", "chip", "swipe", "tap ",
                                "auth", "approved", "merchant copy", "terminal", "aid:",
                                "account type", "savings a", "cheque a"])
        if card { return .card }
        let cash = containsAny(["cash", "tendered", "change due"])
        return cash ? .cash : .unknown
    }

    /// Deterministic fallback. Order matters: a "dividend statement" contains
    /// the word "statement", so dividends are recognised first.
    public static func classifyByKeywords(_ text: String) -> FinancialDocumentKind {
        let lower = text.lowercased()
        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { lower.contains($0) }
        }
        if containsAny(["dividend", "distribution statement", "franking", "franked"]) {
            return .dividendStatement
        }
        if containsAny(["tax invoice", "invoice", "receipt #", "receipt no"]) {
            return .invoice
        }
        if lower.contains("statement") || containsAny(["opening balance", "closing balance"]) {
            return .bankStatement
        }
        if containsAny(["total", "subtotal", "amount due", "gst"]) {
            return .invoice
        }
        return .unknown
    }

    /// Classifies with the on-device model, falling back to keywords
    /// whenever the model cannot answer — unavailable, refused, or an answer
    /// that is none of the kinds.
    public static func classify(text: String) async -> FinancialDocumentKind {
        // No session instructions, on purpose. Against the macOS 27 model
        // (9 Oct 2026) *any* instructions — the original definitions, or a
        // bare "you are an assistant for a personal finance app" role line —
        // made the guardrail refuse a synthetic tax invoice as "May contain
        // sensitive content", and the original wording refused a plain bank
        // statement too; the classifier then fell back to keywords without
        // anyone noticing. With the same guidance carried in the prompt, all
        // three LiveModelTests fixtures classify correctly. Apple's advice
        // for a built-in prompt that trips a guardrail is exactly this:
        // re-phrase until it does not (Improving the safety of generative
        // model output, read 9 Oct 2026). `permissiveContentTransformations`
        // is no alternative — it applies only to string responses, and this
        // is guided generation.
        //
        // The 1,500 characters are a sample, not a window: the top of a
        // document says what it is. No model this runs on is too small for
        // them — 1,500 digits are 1,725 tokens at the worst rate measured —
        // so the sample goes as it is.
        let sample = String(text.prefix(1500))
        let prompt = """
            Which kind of financial document is this text: bank statement, \
            dividend statement, invoice or receipt, or something else? A bank \
            or credit card statement lists many dated transactions with a \
            running balance. A dividend statement reports a single dividend or \
            distribution payment. An invoice or receipt lists purchased items \
            with a total.

            \(sample)
            """
        do {
            let answer = try await LanguageModels.respond(
                .documentClassifier, prompt: prompt, generating: ModelKind.self)
            let kind = FinancialDocumentKind(rawValue: answer.kind.lowercased()) ?? .unknown
            return kind == .unknown ? classifyByKeywords(text) : kind
        } catch {
            return classifyByKeywords(text)
        }
    }

    @Generable
    struct ModelKind {
        @Guide(description: "The document kind", .anyOf([
            "bank statement", "dividend statement", "invoice or receipt", "something else",
        ]))
        var kind: String
    }
}
