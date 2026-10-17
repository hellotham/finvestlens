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
    /// What a headline figure is, by label, where the report knows
    /// (``FigureRole``): said on its line and held to by the checks.
    public var roles: [String: FigureRole]
    /// The headline figures that are one of the others less another, by
    /// label, as the report computed them.
    public var relations: [String: FigureRelation]
    /// What each line is, by position in `lines` — money in or money out, a
    /// balance — where the report knows; empty where it does not. A cash
    /// flow lists its sources and destinations by size, unsigned, and this
    /// is all that tells a card paid off from a card spent on.
    public var lineRoles: [FigureRole?]

    public init(reportTitle: String, periodLabel: String, currencyCode: String,
                headline: [(String, Decimal)], lines: [(String, Decimal)],
                roles: [String: FigureRole] = [:], relations: [String: FigureRelation] = [:],
                lineRoles: [FigureRole?] = []) {
        self.reportTitle = reportTitle
        self.periodLabel = periodLabel
        self.currencyCode = currencyCode
        self.headline = headline
        self.lines = lines
        self.roles = roles
        self.relations = relations
        self.lineRoles = lineRoles
    }

    /// The role of the line at `index`, if the report gave one.
    func lineRole(at index: Int) -> FigureRole? {
        lineRoles.indices.contains(index) ? lineRoles[index] : nil
    }
}

import FoundationModels

/// Turns a computed report into two-to-four short observations.
public enum ReportNarrator {

    @Generable
    struct ModelNotes {
        @Guide(description: "Two to four short observations grounded ONLY in the given figures — what dominates, how the headline figures relate as their lines say. No advice, no speculation, no invented numbers.", .maximumCount(4))
        var notes: [String]
    }

    public static func narrate(facts: ReportFacts) async throws -> [String] {
        // The instructions say never to invent or recompute a number; this is
        // what checks. Unchecked, the macOS 27 model wrote that income
        // exceeded expenses by a figure 31.70 away from the net income it had
        // been given, and quoted percentage shares it had worked out itself
        // (12 October 2026). A note that quotes a number the report does not
        // contain is dropped, and so is one that says one of its figures of
        // the wrong thing (``isSound(_:facts:locale:)``); if none survive the
        // model is asked again, and after the last draft there is no
        // commentary to show.
        var wroteSomething = false
        return try await LanguageModels.firstSoundDraft(
            text: { $0.joined(separator: " ") },
            quoting: labels(of: facts),
            nothingSound: .modelFailure(wroteSomething
                ? String(localized: "The commentary misstated this report’s figures, so it was discarded.")
                : LanguageModels.speaksOfOwnModel
                    ? String(localized: "Your model had nothing to say about this report.")
                    : String(localized: "Apple Intelligence had nothing to say about this report."))
        ) {
            let drafted = try await draft(facts: facts)
            wroteSomething = wroteSomething || !drafted.isEmpty
            let sound = drafted.filter { isSound($0, facts: facts) }
            // The guide asks for two-to-four notes, but the model does not
            // always honour the ceiling; enforce it so the section stays tight.
            return sound.isEmpty ? nil : Array(sound.prefix(4))
        }
    }

    /// What the model wrote, before anything has checked it.
    static func draft(facts: ReportFacts) async throws -> [String] {
        let model = try await LanguageModels.respond(
            .reportNarrator,
            instructions: """
                You write brief notes for the reports section of a personal finance \
                app, in the tone of an annual report's commentary. Use only the \
                figures provided — never invent or recompute numbers. Be concrete \
                and calm; no financial advice, no recommendations.
                """,
            prompt: prompt(for: facts),
            generating: ModelNotes.self
        )
        return model.notes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The report as the model reads it, each figure with what it is where
    /// the report knows (``ReviewNarrator/words(for:)``), and a headline
    /// figure that is one of the others less another saying so — "Net
    /// income: … — Income less Expenses" — so the model need not work out how
    /// they relate. A line goes with its side: the cash flow's sources and
    /// destinations are unsigned, and its commentary had salary as an
    /// expense (17 October review).
    static func prompt(for facts: ReportFacts) -> String {
        let headline = facts.headline
            .map { label, amount -> String in
                let notes = [facts.roles[label].map(ReviewNarrator.words(for:)), facts.relations[label]?.words]
                    .compactMap { $0 }
                return "- \(label): \(amount) \(facts.currencyCode)"
                    + (notes.isEmpty ? "" : " — " + notes.joined(separator: "; "))
            }
            .joined(separator: "\n")
        let lines = shownLines(of: facts).enumerated()
            .map { index, line in
                "- \(line.0): \(line.1) \(facts.currencyCode)"
                    + (facts.lineRole(at: index).map { " — " + ReviewNarrator.words(for: $0) } ?? "")
            }
            .joined(separator: "\n")
        return """
            Report: \(facts.reportTitle)
            Period: \(facts.periodLabel)
            Headline figures:
            \(headline)
            Largest line items:
            \(lines.isEmpty ? "(none)" : lines)
            """
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

    /// The report's figures as the checks read them: every amount the prompt
    /// states, and — from the roles and relations the report gave
    /// (``FigureGrounding/Facts/attribute(_:roles:relations:)``) — which are
    /// balances, which may be said as a change, and which way. One
    /// definition, so the number check and the attribution checks cannot
    /// disagree about which.
    static func figureFacts(of facts: ReportFacts) -> FigureGrounding.Facts {
        let lines = shownLines(of: facts)
        var figures = FigureGrounding.Facts(
            figures: facts.headline.map(\.1) + lines.map(\.1),
            // "the 2 largest line items": how many of each were listed.
            counts: Array(0...max(facts.headline.count, lines.count)),
            quotableText: labels(of: facts),
            currencyCode: facts.currencyCode)
        figures.attribute(facts.headline, roles: facts.roles, relations: facts.relations)
        for (index, line) in lines.enumerated() { figures.attribute(line.1, as: facts.lineRole(at: index)) }
        return figures
    }

    /// Whether `note` may be shown: prose, every number one of the report's,
    /// and none of them said of the wrong thing (FigureAttribution.swift).
    /// What ``narrate(facts:)`` holds each note to, and what the survey
    /// replay counts.
    static func isSound(_ note: String, facts: ReportFacts,
                        locale: Locale = LanguageModels.personLocale) -> Bool {
        LanguageModels.isCleanProse(note) && isGrounded(note, facts: facts, locale: locale)
            && !misattributes(note, facts: facts, locale: locale)
    }

    /// Whether `note` says one of the report's figures of the wrong thing: a
    /// balance as the size of a change, a change the other way from the one
    /// it quotes, or a comparison its figures contradict.
    static func misattributes(_ note: String, facts: ReportFacts,
                              locale: Locale = LanguageModels.personLocale) -> Bool {
        FigureGrounding.misattributes(note, facts: figureFacts(of: facts), locale: locale)
    }

    /// Whether every number in `note` is one of the report's own figures.
    static func isGrounded(_ note: String, facts: ReportFacts,
                           locale: Locale = LanguageModels.personLocale) -> Bool {
        FigureGrounding.isGrounded(note, facts: figureFacts(of: facts), locale: locale)
    }
}
