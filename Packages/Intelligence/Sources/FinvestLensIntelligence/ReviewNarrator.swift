//
//  ReviewNarrator.swift
//  FinvestLens — Intelligence
//
//  The Financial Review deck's voice (docs/report-redesign.md §3.3): each
//  slide computes a deterministic facts pack, and the on-device model turns
//  it into an investor-deck action title and a one-to-two-sentence insight.
//  The established contract holds: the model proposes from the given figures
//  only; deterministic code disposes — the deck always has a deterministic
//  headline to fall back to, so Apple Intelligence being off never leaves an
//  empty title.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The numbers one slide is about — everything the narrator may use.
public struct ReviewSlideFacts: Sendable {
    /// The slide's section label ("Spending", "Portfolio").
    public var kicker: String
    public var periodLabel: String
    public var currencyCode: String
    /// Headline figures, label → amount in `currencyCode`, display order.
    public var figures: [(String, Decimal)]
    /// Ratios the slide states, label → percent (already ×100): a savings
    /// rate, a yield, the largest holding's share. Kept apart from `figures`
    /// because they are not amounts — handed over in one list, the model was
    /// told "Savings rate percent: 26.5 AUD", and a check that reads a number
    /// with its unit cannot then tell a true "26.5%" from an invented one.
    public var ratios: [(String, Decimal)]
    /// Whole numbers the slide states that are neither: how many disposals,
    /// how many holdings.
    public var counts: [(String, Int)]
    /// Changes vs the prior period, label → signed percent (already ×100),
    /// where a comparison exists.
    public var deltaPercents: [(String, Decimal)]
    /// What a figure is, by label, where the slide knows — said in words on
    /// its line, and held to by the checks. A figure with no role is listed
    /// as it is.
    public var roles: [String: FigureRole]
    /// The figures that are one listed figure less another, by label, as the
    /// slide computed them — said on their lines, so the model need not work
    /// a relation out, and read by the checks.
    public var relations: [String: FigureRelation]

    public init(kicker: String, periodLabel: String, currencyCode: String,
                figures: [(String, Decimal)], ratios: [(String, Decimal)] = [],
                counts: [(String, Int)] = [], deltaPercents: [(String, Decimal)] = [],
                roles: [String: FigureRole] = [:], relations: [String: FigureRelation] = [:]) {
        self.kicker = kicker
        self.periodLabel = periodLabel
        self.currencyCode = currencyCode
        self.figures = figures
        self.ratios = ratios
        self.counts = counts
        self.deltaPercents = deltaPercents
        self.roles = roles
        self.relations = relations
    }
}

/// What a narrated figure is. The deck knows — it computed each one — and the
/// model, handed a bare list, did not: one draft had expenses "sono scese di
/// 66.610,82 AUD" (fallen by their own total), another the opening net worth
/// as the size of a difference, and four had expenses above income
/// (17 October 2026).
public enum FigureRole: Sendable, Hashable {
    /// Where something stands at the end of the period, or on a report's
    /// date: a net worth, a closing figure. Never the size of a change.
    case balance
    /// Where something stood at the start of the period: an opening figure.
    case openingBalance
    /// How far something moved over the period.
    case change
    /// Money in over the period, which adds to the total: income.
    case inflow
    /// Money out over the period, which takes from it: expenses.
    case outflow
    /// Value added over the period that is not money in: a revaluation.
    case gain
    /// Value lost over the period that is not money out.
    case loss
}

/// A figure that is one listed figure less another — a net surplus is
/// income less expenses — by their labels. Given by whoever computed it.
/// Worked out from the numbers instead, it named the wrong pair whenever the
/// difference was not the smallest of three: expenses as "Income less Net
/// surplus" at a savings rate over a half, liabilities as "Assets less Equity"
/// on every balance sheet with more equity than debt (17 October review).
public struct FigureRelation: Sendable, Hashable {
    public var minuend: String
    public var subtrahend: String

    public init(_ minuend: String, less subtrahend: String) {
        self.minuend = minuend
        self.subtrahend = subtrahend
    }

    /// The relation as the model reads it on the figure's line.
    var words: String { "\(minuend) less \(subtrahend)" }
}

/// What the model writes for a slide.
public struct ReviewSlideStory: Sendable {
    public var headline: String
    public var insight: String

    public init(headline: String, insight: String) {
        self.headline = headline
        self.insight = insight
    }
}

/// The dispose half of "the model proposes; deterministic code disposes":
/// every number in a story must round-match a listed figure — as it is, or
/// in thousands or millions where the story says "k" or "m" — or a listed
/// change where it carries a percent sign, or be a year the slide names. A
/// story quoting any number not grounded in its facts is rejected — the
/// caller falls back to the deterministic headline.
public enum ReviewStoryValidator {

    /// Whether every number in `story` is one of the slide's facts — read in
    /// the person's own number format as well as English's
    /// (``FigureGrounding``).
    public static func isGrounded(_ story: ReviewSlideStory,
                                  facts: ReviewSlideFacts) -> Bool {
        isGrounded(story, facts: facts, locale: LanguageModels.personLocale)
    }

    static func isGrounded(_ story: ReviewSlideStory, facts: ReviewSlideFacts,
                           locale: Locale) -> Bool {
        FigureGrounding.isGrounded(story.headline + "\n" + story.insight,
                                   facts: figureFacts(of: facts), locale: locale)
    }

    /// The slide's figures as the checks read them: every amount, ratio and
    /// count it states, and — from its roles and relations
    /// (``FigureGrounding/Facts/attribute(_:roles:relations:)``) — which
    /// amounts are balances and which may be said as a change, and which way.
    /// One definition, so the number check and the attribution checks
    /// cannot disagree about which.
    static func figureFacts(of facts: ReviewSlideFacts) -> FigureGrounding.Facts {
        var figures = FigureGrounding.Facts(
            figures: facts.figures.map(\.1),
            percentages: facts.ratios.map(\.1) + facts.deltaPercents.map(\.1),
            // The counts the slide states, and how many figures were
            // listed: "the 2 largest", "all 3 categories".
            counts: facts.counts.map(\.1) + Array(0...facts.figures.count),
            quotableText: labels(of: facts),
            currencyCode: facts.currencyCode)
        figures.attribute(facts.figures, roles: facts.roles, relations: facts.relations)
        return figures
    }

    /// Whether a story about a slide that lists a change quotes it, as the
    /// percentage it was given as. A slide that lists no change, or only
    /// changes of nothing, asks for none.
    ///
    /// Not required of a story — a slide's opening page says "net worth
    /// rose 31.2k" as often as "8.2%", and both are the change — but it is
    /// what excuses one from ``contradictsAListedChange(_:facts:locale:)``,
    /// and what the survey counts.
    static func statesAListedChange(_ story: ReviewSlideStory, facts: ReviewSlideFacts,
                                    locale: Locale = LanguageModels.personLocale) -> Bool {
        let changes = facts.deltaPercents.map(\.1).filter { $0 != 0 }
        guard !changes.isEmpty else { return true }
        return FigureGrounding.quotesPercentage(story.headline + "\n" + story.insight,
                                                anyOf: changes, locale: locale)
    }

    /// Whether a story calls unchanged what its slide says changed: the
    /// slide lists a change of one percent or more, the story does not
    /// quote it, and it uses one of the words below.
    ///
    /// A check of words, which nothing else here is, and so kept narrow.
    /// It exists because the number check cannot see this at all, and it
    /// was half of what the model wrote: given "Total spending: -8.4% vs
    /// prior period", 52 of the 108 drafts that check accepted on
    /// 12 October 2026 said spending was "stable", "unchanged" or that
    /// there was "no change" — sixteen of sixteen in Italian. Putting the
    /// change in words on the figure's own line (``ReviewNarrator/prompt(for:)``)
    /// took that to none in 114; this is for the day a model stops reading
    /// the prompt that way, and it declines a draft, never repairs one.
    ///
    /// A story that quotes the change is let through whatever else it
    /// says: "down 8.4%, though broadly stable" is an opinion about a
    /// figure it has given.
    static func contradictsAListedChange(_ story: ReviewSlideStory, facts: ReviewSlideFacts,
                                         locale: Locale = LanguageModels.personLocale) -> Bool {
        guard facts.deltaPercents.contains(where: { abs($0.1) >= 1 }),
              !statesAListedChange(story, facts: facts, locale: locale) else { return false }
        let text = (story.headline + " " + story.insight).lowercased()
        return unchangedWords.contains(where: text.contains)
    }

    /// Whether a story says one of the slide's figures of the wrong thing
    /// (FigureAttribution.swift): a balance as the size of a change —
    /// "superou o início do período em 381.200 AUD" — a change the other
    /// way from the one it quotes, or a comparison its figures contradict.
    /// Three Portuguese drafts of the opening slide, 12 October 2026, put
    /// expenses of 66.6k "acima do valor inicial de 381,2 mil AUD"; all four
    /// Japanese drafts of it on 17 October had expenses above income.
    static func misattributes(_ story: ReviewSlideStory, facts: ReviewSlideFacts,
                              locale: Locale = LanguageModels.personLocale) -> Bool {
        FigureGrounding.misattributes(story.headline + "\n" + story.insight,
                                      facts: figureFacts(of: facts), locale: locale)
    }

    /// Whether a story may be shown: prose, every number one of the slide's,
    /// no change called unchanged, and no figure said of the wrong thing.
    /// What ``ReviewNarrator/story(facts:)`` holds a draft to, and what the
    /// survey replay counts.
    static func isSound(_ story: ReviewSlideStory, facts: ReviewSlideFacts,
                        locale: Locale = LanguageModels.personLocale) -> Bool {
        LanguageModels.isCleanProse(story.headline + story.insight)
            && isGrounded(story, facts: facts, locale: locale)
            && !contradictsAListedChange(story, facts: facts, locale: locale)
            && !misattributes(story, facts: facts, locale: locale)
    }

    /// "Nothing changed", as the 27 model said it in the eight languages
    /// the app is translated into — taken from its own drafts, not from a
    /// dictionary. Stems, matched anywhere: "stabil" is stabil, stabile,
    /// Stabilität and stabilité.
    private static let unchangedWords = [
        "stable", "stabil", "unchanged", "no change", "steady", "remained at", "remains at",
        "unverändert", "keine veränderung", "gleich geblieben",
        "inchangé", "sans changement",
        "estable", "sin cambios", "sin variaci", "se mantuvo", "se mantiene",
        "invariat", "nessuna variazione",
        "estáve", "estabiliz", "sem varia", "não há varia", "inalterad",
        "安定", "横ばい", "変動なし", "変動はありません", "変化なし", "変化はありません",
        "減少はありません", "増加はありません",
        "稳定", "穩定", "持平", "不变", "无变化", "没有变化",
    ]

    /// The slide's own words — the period label ("FY 2025–26"), the kicker,
    /// the figure labels. Numbers in them are text to repeat, not figures,
    /// and the words themselves reach the model in the language the app was
    /// built in, whatever language it is asked to answer in.
    static func labels(of facts: ReviewSlideFacts) -> String {
        ([facts.periodLabel, facts.kicker] + facts.figures.map(\.0) + facts.ratios.map(\.0)
            + facts.counts.map(\.0) + facts.deltaPercents.map(\.0))
            .joined(separator: " ")
    }
}

import FoundationModels

public enum ReviewNarrator {

    @Generable
    struct ModelStory {
        @Guide(description: "An investor-deck action title of 5 to 12 words that states the slide's conclusion from the given figures — like 'Spending fell 8% as travel normalised'. State facts, never advice. Use only the given numbers; round naturally.")
        var headline: String
        @Guide(description: "One or two calm sentences of insight grounded ONLY in the given figures: what dominates, what changed versus the prior period, how the figures relate as their lines say. No advice, no speculation, no invented numbers.")
        var insight: String
    }

    public static func story(facts: ReviewSlideFacts) async throws -> ReviewSlideStory {
        // A slide that quotes a number it was not given, calls unchanged
        // what it was told had changed, or says one of its figures of the
        // wrong thing (``ReviewStoryValidator/isSound(_:facts:locale:)``), is
        // never shown; the rest of the policy — how many drafts, what happens
        // to a sound one in the wrong language — is the narrators' shared one.
        try await LanguageModels.firstSoundDraft(
            text: { $0.headline + " " + $0.insight },
            quoting: ReviewStoryValidator.labels(of: facts),
            nothingSound: .modelFailure(
                String(localized: "The model misstated the slide’s figures."))
        ) {
            guard let story = try await draft(facts: facts),
                  ReviewStoryValidator.isSound(story, facts: facts) else { return nil }
            return story
        }
    }

    /// What the model is told to be. Kept apart from the request so that the
    /// language survey can send these same words with the language order in
    /// other places, and measure which place works.
    static let instructions = """
        You write one slide of a personal financial review, in the voice \
        of a CFO presenting results: factual, specific, calm. The title \
        states the slide's conclusion. Quote numbers ONLY as they appear \
        in the lists — you may round to at most one decimal place or \
        express thousands as k and millions as m. NEVER derive numbers \
        that are not listed: no differences, no ratios, no percentages \
        of your own. Where a figure is listed with its change on the \
        prior period, say which way it moved and by that percentage. \
        Where no change is listed, describe none: not a rise, not a \
        fall, and not "stable" or "unchanged". Call each figure by its \
        label. Where a line says what a figure is, keep to it: a figure \
        as at a date is where something stood, never the size of a \
        change. Relate figures only as their lines do. Never advise.
        """

    /// The slide's facts as the model reads them. Each number goes as what
    /// it is: an amount with its currency, a ratio with its percent sign, a
    /// count with neither.
    ///
    /// A change goes in words, on the line of the figure it is a change in.
    /// It used to be a list of its own underneath — "Changes: - Total
    /// spending: -8.4% vs prior period" — and the model mostly did not
    /// connect the two: of 108 drafts the number check accepted on
    /// 12 October 2026, 26 quoted the change and 52 called spending "stable"
    /// or "unchanged", which no check of numbers can catch.
    ///
    /// What each figure *is* goes on its line too — as at a date, money in,
    /// money out — with the relation the slide computed it from, where it is
    /// one of its figures less another. Handed a bare list, the model worked
    /// these out for itself and got them wrong: expenses "fallen by" their
    /// own total, the opening net worth as the size of a difference, and in
    /// all four Japanese drafts of one slide, expenses above income
    /// (17 October 2026). The words say when a figure was, not what it is
    /// called: "a balance at a point in time" was taken for a name, and the
    /// next survey had net worth called a "balance", "saldo" or "余额" in 13
    /// of 64 drafts, against 2 before (17 October review).
    static func prompt(for facts: ReviewSlideFacts) -> String {
        var unplaced = facts.deltaPercents
        let amounts = facts.figures.map { label, amount -> String in
            var notes: [String] = []
            if let role = facts.roles[label] { notes.append(words(for: role)) }
            if let found = unplaced.firstIndex(where: { $0.0 == label }) {
                notes.append(change(unplaced.remove(at: found).1))
            }
            if let relation = facts.relations[label] { notes.append(relation.words) }
            return "- \(label): \(amount) \(facts.currencyCode)"
                + (notes.isEmpty ? "" : " — " + notes.joined(separator: "; "))
        }
        let figures = (amounts
            + facts.ratios.map { "- \($0.0): \($0.1)%" }
            + facts.counts.map { "- \($0.0): \($0.1)" })
            .joined(separator: "\n")
        // A change in something that is not itself listed as a figure.
        let changes = unplaced.map { "- \($0.0): \(change($0.1))" }.joined(separator: "\n")
        return """
            Slide section: \(facts.kicker)
            Period: \(facts.periodLabel)
            Figures:
            \(figures)
            \(changes.isEmpty ? "" : "Changes:\n\(changes)")
            """
    }

    /// A role as the model reads it on the figure's line: when the figure
    /// was, or what moved over the period — never a noun the model could
    /// take for the figure's name.
    static func words(for role: FigureRole) -> String {
        switch role {
        case .balance: "as at the end of the period"
        case .openingBalance: "as at the start of the period"
        case .change: "the change over the period"
        case .inflow: "money in over the period"
        case .outflow: "money out over the period"
        case .gain: "value added over the period, not money in"
        case .loss: "value lost over the period, not money out"
        }
    }

    /// "down 8.4% on the prior period" — the direction as a word, so that
    /// it does not ride on a minus sign.
    private static func change(_ percent: Decimal) -> String {
        direction(of: percent, size: "\(abs(percent))%", on: "the prior period",
                  unchanged: "unchanged on the prior period")
    }

    /// Which way `amount` went from `reference`, as the narrators say it:
    /// "up 1351 AUD on today's balance", "down 8.4% on the prior period".
    static func direction(of amount: Decimal, size: String, on reference: String, unchanged: String) -> String {
        amount == 0 ? unchanged : "\(amount > 0 ? "up" : "down") \(size) on \(reference)"
    }

    /// What the model wrote, before anything has checked it. Separate from
    /// ``story(facts:)`` so the check can be tested against the model's real
    /// output in each language, which is the only way to know what it has to
    /// read.
    ///
    /// `nil` when the model wrote no headline: a slide without a title is not
    /// a draft, and another may have one.
    static func draft(facts: ReviewSlideFacts) async throws -> ReviewSlideStory? {
        let response = try await LanguageModels.respond(
            .reviewNarrator, instructions: instructions, prompt: prompt(for: facts),
            generating: ModelStory.self)
        let headline = response.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let insight = response.insight.trimmingCharacters(in: .whitespacesAndNewlines)
        return headline.isEmpty ? nil : ReviewSlideStory(headline: headline, insight: insight)
    }
}
