//
//  GroundingSurveyTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A survey, not a test: what the on-device model writes for each narrator
//  in each language, sentence by sentence, with the number check's verdict
//  beside it. It asserts nothing and prints everything, because the only way
//  to know whether a rejection is the model inventing a figure or the check
//  failing to read a true one is to read the sentence.
//
//  Off unless asked for — it makes dozens of requests:
//
//      FL_GROUNDING_SURVEY=3 swift test --package-path Packages/Intelligence \
//          --filter GroundingSurvey
//
//  The value is how many drafts to take of each. Synthetic figures only
//  (`Fixtures`); the output is safe to keep.
//

import Foundation
import Testing
import FoundationModels
@testable import FinvestLensIntelligence

private let surveyDrafts = Int(ProcessInfo.processInfo.environment["FL_GROUNDING_SURVEY"] ?? "") ?? 0

extension Live {
@Suite("What the model writes, and what the number check makes of it",
       .enabled(if: surveyDrafts > 0 && Fixtures.modelAvailable), .timeLimit(.minutes(30)), .serialized)
struct GroundingSurvey {

    static let locales = ["en_AU"] + Fixtures.translatedLocales

    private func line(_ kind: String, _ identifier: String, _ grounded: Bool, _ inLanguage: Bool, _ text: String) {
        print("SURVEY \(kind) \(identifier) \(grounded ? "ok    " : "REJECT") \(inLanguage ? "lang-ok " : "LANG-NO ") \(text)")
    }

    @Test("Report notes", arguments: locales)
    func report(identifier: String) async {
        let locale = Locale(identifier: identifier)
        await LanguageModels.$localeOverride.withValue(locale) {
            for _ in 0..<surveyDrafts {
                guard let notes = try? await ReportNarrator.draft(facts: Fixtures.income) else {
                    print("SURVEY report \(identifier) FAILED"); continue
                }
                let inLanguage = LanguageModels.isInPersonLanguage(
                    notes.joined(separator: " "), quoting: ReportNarrator.labels(of: Fixtures.income))
                for note in notes {
                    line("report", identifier, ReportNarrator.isGrounded(note, facts: Fixtures.income), inLanguage, note)
                }
            }
        }
    }

    @Test("Forecast outlooks", arguments: locales)
    func forecast(identifier: String) async {
        let locale = Locale(identifier: identifier)
        await LanguageModels.$localeOverride.withValue(locale) {
            for _ in 0..<surveyDrafts {
                guard let outlook = try? await ForecastNarrator.draft(facts: Fixtures.forecast) else {
                    print("SURVEY forecast \(identifier) FAILED"); continue
                }
                let all = [outlook.headline] + outlook.insights
                let inLanguage = LanguageModels.isInPersonLanguage(
                    all.joined(separator: " "), quoting: ForecastNarrator.labels(of: Fixtures.forecast))
                for (index, text) in all.enumerated() {
                    line(index == 0 ? "forecast-headline" : "forecast", identifier,
                         ForecastNarrator.isGrounded(text, facts: Fixtures.forecast), inLanguage, text)
                }
            }
        }
    }

    @Test("Review slides", arguments: locales)
    func review(identifier: String) async {
        let locale = Locale(identifier: identifier)
        await LanguageModels.$localeOverride.withValue(locale) {
            for _ in 0..<surveyDrafts {
                guard let story = try? await ReviewNarrator.draft(facts: Fixtures.spending) else {
                    print("SURVEY review \(identifier) FAILED"); continue
                }
                let inLanguage = LanguageModels.isInPersonLanguage(
                    story.headline + " " + story.insight,
                    quoting: ReviewStoryValidator.labels(of: Fixtures.spending))
                line("review", identifier, ReviewStoryValidator.isGrounded(story, facts: Fixtures.spending),
                     inLanguage, story.headline + " ‖ " + story.insight)
            }
        }
    }
}
}

private let languageDrafts = Int(ProcessInfo.processInfo.environment["FL_LANGUAGE_SURVEY"] ?? "") ?? 0

extension Live {
/// Where the language order goes, measured. The review slide's own
/// instructions and facts, sent with "You MUST respond in X." nowhere, at
/// the start, at the end, and at both — and each answer's language judged
/// by `Fixtures.reads(_:as:)`, which is not the recogniser the code uses.
///
///     FL_LANGUAGE_SURVEY=8 swift test --package-path Packages/Intelligence \
///         --filter LanguageOrderSurvey
///
/// This replaces a first measurement taken with `NLLanguageRecognizer` over
/// the whole answer, which the review found calling French slides English
/// when they were mostly labels — so its table measured the instrument as
/// much as the model.
@Suite("Where the language order goes", .enabled(if: languageDrafts > 0 && Fixtures.modelAvailable),
       .timeLimit(.minutes(60)), .serialized)
struct LanguageOrderSurvey {

    enum Placement: String, CaseIterable { case none, start, end, both }

    /// The same slide with its labels in French, as they would be if the
    /// app localised the facts it hands the model — to see whether the
    /// language of the *input* is what French is waiting for.
    @Test("French: labels in English against labels in French")
    func frenchLabels() async throws {
        let instructions = [
            "The person's locale is fr_FR.", "You MUST respond in French.",
            ReviewNarrator.instructions, "You MUST respond in French.",
        ].joined(separator: "\n")
        let french = ReviewSlideFacts(
            kicker: "Dépenses", periodLabel: "Exercice 2025–26", currencyCode: "AUD",
            figures: [("Dépenses totales", Decimal(string: "66610.82")!),
                      ("Alimentation", Decimal(string: "12480.55")!),
                      ("Logement", Decimal(string: "25680.00")!)],
            deltaPercents: [("Dépenses totales", Decimal(string: "-8.4")!)])
        for (name, facts) in [("English labels", Fixtures.spending), ("French labels", french)] {
            var inLanguage = 0, answered = 0, grounded = 0
            for _ in 0..<(languageDrafts * 2) {
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
                guard let story = try? await session.respond(
                    to: ReviewNarrator.prompt(for: facts), generating: ReviewNarrator.ModelStory.self,
                    options: IntelligenceFeature.reviewNarrator.options).content else { continue }
                answered += 1
                if Fixtures.reads(story.headline + " " + story.insight, as: "fr_FR") { inLanguage += 1 }
                if ReviewStoryValidator.isGrounded(
                    ReviewSlideStory(headline: story.headline, insight: story.insight),
                    facts: facts, locale: Fixtures.french) { grounded += 1 }
            }
            print("LANGSURVEY fr_FR \(name): \(inLanguage) of \(answered) in French, \(grounded) grounded")
        }
    }

    @Test("Review slides, by placement", arguments: Fixtures.translatedLocales)
    func reviewSlides(identifier: String) async throws {
        let locale = Locale(identifier: identifier)
        let language = try #require(LanguageModels.responseLanguage(for: locale))
        let phrase = "The person's locale is \(LanguageModels.localeName(locale))."
        let order = "You MUST respond in \(language)."
        for placement in Placement.allCases {
            var parts = [phrase]
            if placement == .start || placement == .both { parts.append(order) }
            parts.append(ReviewNarrator.instructions)
            if placement == .end || placement == .both { parts.append(order) }
            var inLanguage = 0, answered = 0
            for _ in 0..<languageDrafts {
                let session = LanguageModelSession(model: SystemLanguageModel.default,
                                                   instructions: parts.joined(separator: "\n"))
                guard let story = try? await session.respond(
                    to: ReviewNarrator.prompt(for: Fixtures.spending),
                    generating: ReviewNarrator.ModelStory.self,
                    options: IntelligenceFeature.reviewNarrator.options).content else { continue }
                answered += 1
                if Fixtures.reads(story.headline + " " + story.insight, as: identifier) { inLanguage += 1 }
            }
            print("LANGSURVEY \(identifier) \(placement.rawValue): \(inLanguage) of \(answered) in \(language)")
        }
    }
}
}
