//
//  AttachmentInsight.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FoundationModels

/// Reads an attachment's extracted text and answers two things at once for its
/// transaction: the best category from the book's chart, and a short friendly
/// payee ("Sydney Water") to replace the raw bank narrative — the same
/// convention the smart categoriser learns from hand-categorised transactions
/// (`FR-AI-02`/`FR-AI-08`).
public enum AttachmentInsight {

    public struct Insight: Sendable {
        public let accountID: GncGUID
        public let friendlyDescription: String
    }

    @Generable
    struct ModelAnswer: DocumentAnswer {
        /// A category name and a payee of five words.
        static let replyReserve = 128

        @Guide(description: "The chosen category, copied EXACTLY from the category list")
        var category: String
        @Guide(description: "A short friendly payee for the transaction — the merchant or counterparty the document names, e.g. 'Sydney Water'. At most five words; no reference numbers or dates.")
        var payee: String
    }

    /// One transaction, one document. Returns `nil` when the model's category
    /// matches nothing in the chart.
    ///
    /// - Parameter explainRefusal: ask the model why, if it refuses the
    ///   document — a second request, for when a person will see the reason.
    public static func analyze(
        documentText: String,
        currentDescription: String,
        amount: Decimal,
        candidates: [CategoryCandidate],
        explainRefusal: Bool = false
    ) async throws -> Insight? {
        guard !candidates.isEmpty else { return nil }

        let offered = Array(candidates.prefix(80))
        let categoryList = offered.map { "- \($0.fullName)" }.joined(separator: "\n")
        let instructions = """
            You categorise a personal finance transaction using the document \
            attached to it (a receipt, invoice or statement). Choose the single \
            best category from this list (copy the name exactly):

            \(categoryList)

            Also give a short friendly payee name for the transaction — the \
            merchant or counterparty the document names, not the bank's raw \
            narrative. Negative amounts are spending, positive amounts are \
            income or refunds.
            """
        // The category list is most of this request — up to eighty names —
        // so the document gets what is left of the model's window once that
        // is paid for (`LanguageModels.fit`). Callers pass an excerpt from
        // the top of the document, which is where a receipt says who it is
        // from; whether that excerpt was cut again is not reported.
        let (answer, _) = try await LanguageModels.respond(
            .attachmentInsight, instructions: instructions,
            document: documentText,
            framing: { text in
                """
                Transaction: \(currentDescription) (\(amount))
                Document text:
                \(text)
                """
            },
            generating: ModelAnswer.self, explainRefusal: explainRefusal)
        guard let hit = AccountNameMatcher.match(answer.category, in: offered) else {
            return nil
        }
        let payee = answer.payee.trimmingCharacters(in: .whitespaces)
        return Insight(accountID: hit.id, friendlyDescription: payee)
    }
}
