//
//  TransactionCategorizer.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A transaction (staged or posted) awaiting a category suggestion.
public struct CategorizationItem: Sendable, Identifiable {
    public let id: UUID
    public let payee: String
    public let memo: String
    public let amount: Decimal

    public init(id: UUID = UUID(), payee: String, memo: String = "", amount: Decimal) {
        self.id = id
        self.payee = payee
        self.memo = memo
        self.amount = amount
    }
}

/// Turns the model's free-text answers into account IDs, and refuses the
/// ones that break the sign invariant.
///
/// Deliberately outside ``TransactionCategorizer``: nothing here needs the
/// on-device model, so nothing here should be gated on macOS 26 — a guard
/// that can only be reached when Apple Intelligence is present is a guard
/// that cannot be unit-tested.
enum CategorySuggestionResolver {

    /// Maps the model's answers onto the batch. Pure, and separate from the
    /// request, because this is where the wrong answers are caught — and a
    /// guard that cannot be tested is not a guard.
    ///
    /// Two model behaviours are handled, both observed rather than assumed:
    ///
    /// * **Padding.** The schema asks for one suggestion per transaction but
    ///   cannot enforce the count, so the model enumerates whichever list is
    ///   more salient. Offered three categories for a single transaction it
    ///   answered three times — numbered 1, 2, 3, one per *category*. The
    ///   surplus is dropped by the range check; the real protection is that
    ///   money-out is never offered an income account in the first place, so a
    ///   pad landing on row 3 cannot be "Other Income".
    /// * **Invention.** It returns names that were never offered
    ///   (`Expenses:Transportation:Uber`). ``AccountNameMatcher`` resolves what
    ///   it can and yields `nil` otherwise, and an unmatched row simply stays
    ///   for the person to categorise.
    ///
    /// Last-numbered answer wins for a repeated number: an earlier one is a
    /// pad the model then corrected.
    static func resolve(
        answers: [(number: Int, category: String)],
        batch: [CategorizationItem],
        offered: [CategoryCandidate]
    ) -> [UUID: GncGUID] {
        var result: [UUID: GncGUID] = [:]
        for answer in answers {
            let index = answer.number - 1
            guard batch.indices.contains(index),
                  let hit = AccountNameMatcher.match(answer.category, in: offered)
            else { continue }
            // The shortlist already excludes income for spending; this
            // re-checks the account actually landed on, because
            // `AccountNameMatcher` is deliberately forgiving and a fuzzy match
            // is exactly where an invariant slips. An expense is never income —
            // better no suggestion than a wrong-signed one.
            guard !(hit.isIncome && batch[index].amount < 0) else { continue }
            result[batch[index].id] = hit.id
        }
        return result
    }
}

/// Suggests destination accounts for transactions using the on-device model
/// (`FR-AI-02`).
///
/// This is the semantic layer above the existing deterministic ladder
/// (user rules → payee history → keyword heuristics): it reads payee, memo,
/// and sign together and picks from the book's *actual* chart of accounts,
/// so "TRANSPORT FOR NSW TRAVEL" can land in `Expenses:Transport:Public
/// Transport` without a rule ever having been written. Deterministic
/// sources still take precedence at the call site — the model only fills
/// gaps, and every suggestion is reviewed before posting.
@available(macOS 26.0, iOS 26.0, *)
public enum TransactionCategorizer {

    #if canImport(FoundationModels)
    @Generable
    struct ModelSuggestion {
        @Guide(description: "The number of the transaction being categorised, from the input list")
        var number: Int
        @Guide(description: "The chosen category, copied EXACTLY from the category list")
        var category: String
    }

    @Generable
    struct ModelSuggestions {
        /// Capped at ``batchSize``: there can never be more answers than there
        /// were transactions to ask about, and without a ceiling the model
        /// enumerates the *category* list instead — offered three categories
        /// for one transaction it answered three times. Unbounded, that same
        /// repetition can run until it exhausts the context window, which is
        /// a slow failure rather than a wrong answer.
        @Guide(description: "One suggestion per input transaction, in order", .maximumCount(8))
        var suggestions: [ModelSuggestion]
    }
    #endif

    /// How many transactions to categorise per model request. The candidate
    /// list is repeated in each session, so batches keep the context small.
    static let batchSize = 8

    /// Maximum candidate accounts offered to the model per request.
    static let candidateLimit = 80

    /// Returns suggested account IDs keyed by item ID. Items the model could
    /// not confidently map (or whose answer matched no candidate) are absent.
    public static func suggest(
        items: [CategorizationItem],
        candidates: [CategoryCandidate],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [UUID: GncGUID] {
        #if canImport(FoundationModels)
        guard case .available = IntelligenceAvailability.current() else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }
        guard !items.isEmpty, !candidates.isEmpty else { return [:] }

        // Spending and receipts are categorised separately, because the
        // candidate list differs: **money out is never offered an income
        // account**. `AppModel.categoryCandidates(includeIncome:)` could
        // already express this and was passed `false` at one of its eight call
        // sites, so income categories were on the menu for nearly every
        // spending row — which is how a Coles receipt came back as Other
        // Income. Doing it here rather than at the call sites makes it a
        // property of categorisation itself, and it holds for a mixed batch,
        // which a per-call switch never could.
        //
        // The asymmetry is deliberate: money *in* may legitimately be an
        // expense account (a refund offsets what it was spent on), so only the
        // outgoing direction is constrained.
        let spendingCandidates = Array(candidates.lazy.filter { !$0.isIncome }.prefix(candidateLimit))
        guard !spendingCandidates.isEmpty || items.allSatisfy({ $0.amount > 0 }) else { return [:] }
        func instructions(for offered: [CategoryCandidate]) -> String {
            """
            You categorise personal finance transactions. Choose the single best \
            category for each transaction from this list (copy the name exactly):

            \(offered.map { "- \($0.fullName)" }.joined(separator: "\n"))

            Negative amounts are spending, positive amounts are income or refunds.
            """
        }

        var result: [UUID: GncGUID] = [:]
        // Keep spending and receipts in their own batches so each carries the
        // right candidate list.
        let spending = items.filter { $0.amount < 0 }
        let receipts = items.filter { $0.amount >= 0 }
        let allCandidates = Array(candidates.prefix(candidateLimit))
        let groups: [(items: [CategorizationItem], offered: [CategoryCandidate])] =
            [(spending, spendingCandidates), (receipts, allCandidates)].filter { !$0.0.isEmpty }
        let batches = groups.flatMap { group in
            stride(from: 0, to: group.items.count, by: batchSize).map {
                (batch: Array(group.items[$0..<min($0 + batchSize, group.items.count)]),
                 offered: group.offered)
            }
        }
        for (batchIndex, group) in batches.enumerated() {
            let (batch, offered) = group
            let listing = batch.enumerated().map { index, item in
                let memo = item.memo.isEmpty ? "" : " — \(item.memo)"
                return "\(index + 1). \(item.payee)\(memo) (\(item.amount))"
            }.joined(separator: "\n")

            let session = LanguageModelSession(instructions: instructions(for: offered))
            do {
                let response = try await session.respond(
                    to: "Categorise these transactions:\n\(listing)",
                    generating: ModelSuggestions.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                result.merge(
                    CategorySuggestionResolver.resolve(answers: response.content.suggestions.map { ($0.number, $0.category) },
                            batch: batch, offered: offered)
                ) { _, new in new }
            } catch {
                throw IntelligenceError.wrap(error)
            }
            onProgress?(batchIndex + 1, batches.count)
        }
        return result
        #else
        throw IntelligenceError.unavailable("Apple Intelligence is not available on this platform.")
        #endif
    }
}
