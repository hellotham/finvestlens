//
//  BudgetAdvisor.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FoundationModels

/// Observed spending for one category, computed deterministically by the
/// caller from the book (the model never sees raw transactions).
public struct SpendingHistory: Sendable, Identifiable {
    public var id: GncGUID { categoryID }
    public let categoryID: GncGUID
    public let fullName: String
    public let monthlyAverage: Decimal
    public let monthlyMinimum: Decimal
    public let monthlyMaximum: Decimal

    public init(categoryID: GncGUID, fullName: String,
                monthlyAverage: Decimal, monthlyMinimum: Decimal, monthlyMaximum: Decimal) {
        self.categoryID = categoryID
        self.fullName = fullName
        self.monthlyAverage = monthlyAverage
        self.monthlyMinimum = monthlyMinimum
        self.monthlyMaximum = monthlyMaximum
    }
}

/// One proposed budget line with the model's reasoning.
public struct BudgetSuggestionLine: Sendable, Identifiable {
    public var id: GncGUID { categoryID }
    public let categoryID: GncGUID
    public let fullName: String
    public let monthlyAmount: Decimal
    public let rationale: String

    public init(categoryID: GncGUID, fullName: String, monthlyAmount: Decimal, rationale: String) {
        self.categoryID = categoryID
        self.fullName = fullName
        self.monthlyAmount = monthlyAmount
        self.rationale = rationale
    }
}

/// A complete proposed budget.
public struct BudgetSuggestion: Sendable {
    public let lines: [BudgetSuggestionLine]
    public let summary: String

    public var totalBudget: Decimal {
        lines.reduce(0) { $0 + $1.monthlyAmount }
    }
}

/// Proposes a monthly budget from spending statistics (`FR-AI-05`).
///
/// The arithmetic (per-category monthly average/min/max) is computed
/// deterministically by the caller; the model's job is judgement — trimming
/// discretionary categories, keeping fixed ones at their observed level,
/// rounding to human-friendly figures, and explaining each choice. That
/// keeps the numbers auditable and the model's contribution reviewable.
public enum BudgetAdvisor {

    @Generable
    struct ModelBudgetLine {
        @Guide(description: "The category, copied EXACTLY from the spending list")
        var category: String
        @Guide(description: "Suggested monthly budget amount, a plain number")
        var monthlyAmount: String
        @Guide(description: "One short sentence explaining the suggestion")
        var rationale: String
    }

    @Generable
    struct ModelBudget {
        /// One line per input category is the whole contract. The forty here
        /// is the ceiling a static schema can state, and the most categories
        /// ``suggest(history:monthlyIncome:currencyCode:)`` offers; each
        /// request is made with `lines` fixed at exactly the number offered
        /// (``LanguageModels/countedSchema(for:property:count:)``), so the
        /// model can neither stop short nor go on to budget for categories
        /// nobody has.
        @Guide(description: "One line per spending category from the input", .maximumCount(40))
        var lines: [ModelBudgetLine]
        @Guide(description: "Two or three sentences summarising the overall plan and any savings opportunity")
        var summary: String
    }

    /// The most categories one request budgets for — ``ModelBudget``'s cap.
    static let categoryLimit = 40

    public static func suggest(
        history: [SpendingHistory],
        monthlyIncome: Decimal,
        currencyCode: String
    ) async throws -> BudgetSuggestion {
        guard !history.isEmpty else {
            return BudgetSuggestion(lines: [], summary: String(localized: "No spending history to budget from."))
        }

        let observed = Array(
            history.sorted { $0.monthlyAverage > $1.monthlyAverage }.prefix(categoryLimit)
        )

        // The safety guardrails occasionally refuse borderline personal-finance
        // wording; the refusal is deterministic per input, so retrying with a
        // simplified listing sidesteps it, and pure averages remain as a
        // deterministic floor — the button never comes back empty-handed
        // because of *what was asked*. The floor is for a model that will
        // not write this plan: it declined it, or its language is not one
        // it writes. A model that is not there at all — unavailable, busy,
        // out of allowance — is told to the person instead, because averages
        // presented as "Apple Intelligence declined" would be untrue.
        do {
            return try await modelSuggestion(observed, monthlyIncome: monthlyIncome,
                                             currencyCode: currencyCode, includeRanges: true)
        } catch let error as IntelligenceError where error.isAboutTheRequest {
            do {
                return try await modelSuggestion(observed, monthlyIncome: monthlyIncome,
                                                 currencyCode: currencyCode, includeRanges: false)
            } catch let error as IntelligenceError where error.isAboutTheRequest {
                return averageBasedSuggestion(observed)
            }
        }
    }

    private static func modelSuggestion(
        _ observed: [SpendingHistory],
        monthlyIncome: Decimal,
        currencyCode: String,
        includeRanges: Bool
    ) async throws -> BudgetSuggestion {
        let listing = observed.map { line in
            includeRanges
                ? "- \(line.fullName): average \(line.monthlyAverage)/month (range \(line.monthlyMinimum)–\(line.monthlyMaximum))"
                : "- \(line.fullName): average \(line.monthlyAverage)/month"
        }.joined(separator: "\n")

        let model = try await LanguageModels.respond(
            .budgetAdvisor,
            instructions: """
                You fill in a budget planning table. For each spending category you are \
                given its observed monthly spending; write a target monthly amount in \
                \(currencyCode) and a short note. Keep essential categories (housing, \
                utilities, insurance, groceries) near their observed average; set \
                discretionary categories slightly below average. Round to sensible \
                whole amounts. Copy category names exactly.
                """,
            prompt: """
                Total available per month: \(monthlyIncome) \(currencyCode)

                Observed spending:
                \(listing)
                """,
            generating: ModelBudget.self,
            exactly: observed.count, of: "lines"
        )

        var lines: [BudgetSuggestionLine] = []
        var used = Set<GncGUID>()
        let candidates = observed.map { CategoryCandidate(id: $0.categoryID, fullName: $0.fullName) }
        for line in model.lines {
            guard let hit = AccountNameMatcher.match(line.category, in: candidates),
                  used.insert(hit.id).inserted,
                  let amount = IntelligenceParsing.amount(line.monthlyAmount),
                  amount >= 0
            else { continue }
            lines.append(BudgetSuggestionLine(
                categoryID: hit.id,
                fullName: hit.fullName,
                monthlyAmount: amount,
                rationale: line.rationale
            ))
        }
        return BudgetSuggestion(lines: lines, summary: model.summary)
    }

    /// Deterministic floor when the model will not write the plan: each
    /// category budgeted at its observed monthly average.
    static func averageBasedSuggestion(_ observed: [SpendingHistory]) -> BudgetSuggestion {
        BudgetSuggestion(
            lines: observed.map {
                BudgetSuggestionLine(categoryID: $0.categoryID,
                                     fullName: $0.fullName,
                                     monthlyAmount: $0.monthlyAverage,
                                     rationale: String(localized: "Matches your observed monthly average."))
            },
            summary: LanguageModels.speaksOfOwnModel
                ? String(localized: "Budgeted from your monthly averages over the observed period. Your model didn’t refine this plan, so no trims were applied.")
                : String(localized: "Budgeted from your monthly averages over the observed period. Apple Intelligence didn’t refine this plan, so no trims were applied.")
        )
    }
}
