//
//  ReportNarrator.swift
//  FinvestLens — Intelligence
//
//  Commentary for a financial report (`FR-AI-06`), on the ForecastNarrator
//  model: the figures are computed deterministically by the Reports engine and
//  handed over as facts — the model observes, it never calculates. An annual
//  report's notes point at what moved and what dominates; that is a language
//  task over numbers already known, which is the one kind of arithmetic a
//  language model can be trusted with.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The numbers a report commentary is written from.
public struct ReportFacts: Sendable {
    public var reportTitle: String
    public var periodLabel: String
    public var currencyCode: String
    /// Headline figures, label → amount, in display order.
    public var headline: [(String, Decimal)]
    /// The largest line items, label → amount, already ranked by the report.
    public var lines: [(String, Decimal)]

    public init(reportTitle: String, periodLabel: String, currencyCode: String,
                headline: [(String, Decimal)], lines: [(String, Decimal)]) {
        self.reportTitle = reportTitle
        self.periodLabel = periodLabel
        self.currencyCode = currencyCode
        self.headline = headline
        self.lines = lines
    }
}

import FoundationModels

/// Turns a computed report into two-to-four short observations.
public enum ReportNarrator {

    @Generable
    struct ModelNotes {
        @Guide(description: "Two to four short observations grounded ONLY in the given figures — what dominates, what the relationship between the headline numbers is. No advice, no speculation, no invented numbers.", .maximumCount(4))
        var notes: [String]
    }

    public static func narrate(facts: ReportFacts) async throws -> [String] {
        // The instructions say never to invent or recompute a number; this is
        // what checks. Unchecked, the macOS 27 model wrote that income
        // exceeded expenses by a figure 31.70 away from the net income it had
        // been given, and quoted percentage shares it had worked out itself
        // (12 October 2026). A note that quotes a number the report does not
        // contain is dropped; if none survive the model is asked again, and
        // after the last draft there is no commentary to show.
        var wroteSomething = false
        return try await LanguageModels.firstSoundDraft(
            text: { $0.joined(separator: " ") },
            quoting: labels(of: facts),
            nothingSound: .modelFailure(wroteSomething
                ? String(localized: "The commentary quoted figures that are not in this report, so it was discarded.")
                : LanguageModels.speaksOfOwnModel
                    ? String(localized: "Your model had nothing to say about this report.")
                    : String(localized: "Apple Intelligence had nothing to say about this report."))
        ) {
            let drafted = try await draft(facts: facts)
            wroteSomething = wroteSomething || !drafted.isEmpty
            let grounded = drafted.filter { LanguageModels.isCleanProse($0) && isGrounded($0, facts: facts) }
            // The guide asks for two-to-four notes, but the model does not
            // always honour the ceiling; enforce it so the section stays tight.
            return grounded.isEmpty ? nil : Array(grounded.prefix(4))
        }
    }

    /// What the model wrote, before anything has checked it.
    static func draft(facts: ReportFacts) async throws -> [String] {
        let headline = facts.headline
            .map { "- \($0.0): \($0.1) \(facts.currencyCode)" }
            .joined(separator: "\n")
        let lines = shownLines(of: facts)
            .map { "- \($0.0): \($0.1) \(facts.currencyCode)" }
            .joined(separator: "\n")

        let model = try await LanguageModels.respond(
            .reportNarrator,
            instructions: """
                You write brief notes for the reports section of a personal finance \
                app, in the tone of an annual report's commentary. Use only the \
                figures provided — never invent or recompute numbers. Be concrete \
                and calm; no financial advice, no recommendations.
                """,
            prompt: """
                Report: \(facts.reportTitle)
                Period: \(facts.periodLabel)
                Headline figures:
                \(headline)
                Largest line items:
                \(lines.isEmpty ? "(none)" : lines)
                """,
            generating: ModelNotes.self
        )
        return model.notes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The line items the model is shown: the report's first twelve. One
    /// definition, so the prompt and the check cannot disagree about which.
    static func shownLines(of facts: ReportFacts) -> ArraySlice<(String, Decimal)> {
        facts.lines.prefix(12)
    }

    /// The report's own words, which a note may repeat as given.
    static func labels(of facts: ReportFacts) -> String {
        ([facts.reportTitle, facts.periodLabel] + facts.headline.map(\.0) + shownLines(of: facts).map(\.0))
            .joined(separator: " ")
    }

    /// Whether every number in `note` is one of the report's own figures.
    static func isGrounded(_ note: String, facts: ReportFacts,
                           locale: Locale = LanguageModels.personLocale) -> Bool {
        let lines = shownLines(of: facts)
        return FigureGrounding.isGrounded(
            note,
            facts: FigureGrounding.Facts(
                figures: facts.headline.map(\.1) + lines.map(\.1),
                // "the 2 largest line items": how many of each were listed.
                counts: Array(0...max(facts.headline.count, lines.count)),
                quotableText: labels(of: facts),
                currencyCode: facts.currencyCode),
            locale: locale)
    }
}
