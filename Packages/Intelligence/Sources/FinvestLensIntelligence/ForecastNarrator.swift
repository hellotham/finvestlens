//
//  ForecastNarrator.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The numeric facts a forecast narrative is written from. All values are
/// computed deterministically from the book and scheduled transactions —
/// the model narrates, it never predicts numbers.
public struct ForecastFacts: Sendable {
    public var currencyCode: String
    public var accountName: String
    public var horizonDays: Int
    public var openingBalance: Decimal
    public var closingBalance: Decimal
    public var lowestBalance: Decimal
    public var lowestBalanceDate: Date?
    /// (date, label, amount) of upcoming scheduled cash movements.
    public var upcoming: [(Date, String, Decimal)]
    /// The projected balance after each of `upcoming`, in the same order;
    /// empty where it is not known.
    public var upcomingBalances: [Decimal]
    /// Average monthly net income over recent history.
    public var recentMonthlyNet: Decimal

    public init(currencyCode: String, accountName: String, horizonDays: Int,
                openingBalance: Decimal, closingBalance: Decimal,
                lowestBalance: Decimal, lowestBalanceDate: Date?,
                upcoming: [(Date, String, Decimal)], upcomingBalances: [Decimal] = [],
                recentMonthlyNet: Decimal) {
        self.currencyCode = currencyCode
        self.accountName = accountName
        self.horizonDays = horizonDays
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.lowestBalance = lowestBalance
        self.lowestBalanceDate = lowestBalanceDate
        self.upcoming = upcoming
        self.upcomingBalances = upcoming.count == upcomingBalances.count ? upcomingBalances : []
        self.recentMonthlyNet = recentMonthlyNet
    }

    /// The scheduled money in and money out over the whole horizon.
    var scheduledIn: Decimal { upcoming.map(\.2).filter { $0 > 0 }.reduce(0, +) }
    var scheduledOut: Decimal { upcoming.map(\.2).filter { $0 < 0 }.reduce(0) { $0 + abs($1) } }
}

/// A short cash-flow outlook for display alongside the forecast chart.
public struct ForecastInsights: Sendable {
    public let headline: String
    public let insights: [String]
}

import FoundationModels

/// Turns a computed cash-flow forecast into a plain-language outlook
/// (`FR-AI-06`): a one-line headline plus a few observations — tight months,
/// large upcoming bills, savings headroom.
public enum ForecastNarrator {

    @Generable
    struct ModelOutlook {
        @Guide(description: "One-sentence headline verdict on the cash position")
        var headline: String
        @Guide(description: "Two to four short, specific observations grounded ONLY in the given numbers", .maximumCount(4))
        var insights: [String]
    }

    public static func narrate(facts: ForecastFacts) async throws -> ForecastInsights {
        // As for the report notes: a number the forecast does not contain,
        // or a month none of its dates fall in, is not an observation. An
        // insight that fails is dropped; the headline has to stand, so a bad
        // one is asked for again. In French the model headlined an increase
        // "de 135 AUD" for balances 1,351 apart, over four accurate
        // observations (12 October 2026); the second answer was sound. A
        // true number said of the wrong thing goes the same way — four
        // headlines that day had the balance end higher *by* its closing
        // balance (``misattributes(_:facts:locale:)``).
        try await LanguageModels.firstSoundDraft(
            text: { ([$0.headline] + $0.insights).joined(separator: " ") },
            quoting: labels(of: facts),
            nothingSound: .modelFailure(
                String(localized: "The outlook misstated this forecast’s figures, so it was discarded."))
        ) {
            let model = try await draft(facts: facts)
            guard isSound(model.headline, facts: facts) else { return nil }
            return ForecastInsights(headline: model.headline,
                                    insights: model.insights.filter { isSound($0, facts: facts) })
        }
    }

    /// What the model wrote, before anything has checked it.
    static func draft(facts: ForecastFacts) async throws -> ForecastInsights {
        let model = try await LanguageModels.respond(
            .forecastNarrator, instructions: instructions, prompt: prompt(for: facts),
            generating: ModelOutlook.self
        )
        return ForecastInsights(headline: model.headline, insights: model.insights)
    }

    /// What the model is told to be.
    static let instructions = """
        You write short, factual cash-flow outlooks for a personal finance app. \
        Use only the numbers provided — never invent figures. A balance is where \
        the account stands; how far it moves is the change given beside the end \
        balance, never a balance. Be concrete and calm; no financial advice, no \
        recommendations to buy or sell anything.
        """

    /// The forecast as the model reads it — each figure with what it is, and
    /// each direction in words beside the figure it belongs to.
    ///
    /// It used to give the end balance and the change as two bare numbers on
    /// adjacent lines, and the money going out with a minus sign. Four
    /// headlines of 64 then had the balance end higher *by* its closing
    /// balance, and the signs came back as "negative" of things that were not
    /// (12 and 17 October 2026) — the shape the review slides' prompt was
    /// rebuilt to avoid (``ReviewNarrator/prompt(for:)``). The change stays a
    /// figure: left to subtract, the model wrote 135 for 1,351.
    ///
    /// For the same reason each movement goes with the balance it leaves, and
    /// the horizon's money in and out with their totals: four of the five
    /// outlooks the checks declined on 17 October had worked one of those out
    /// ("réduit le solde à 5469", scheduled spending "6000 AUD"), and the
    /// projection already holds them.
    static func prompt(for facts: ForecastFacts) -> String {
        // Dates go to the model already written the way the person reads
        // them. Given "15 Aug" and told to answer in Japanese or Chinese, the
        // macOS 27 model wrote "15月15日" and "1月1日" for 1 August
        // (12 October 2026): translating a date is one more thing for it to
        // get wrong, and the formatter does not get it wrong.
        //
        // In the Gregorian calendar, whatever the person's own: the forecast
        // list beside this outlook is Gregorian, and so is the check below.
        // A locale's calendar comes with it — the formatter printed
        // 15 August as "2 Rab. I" for a Saudi region — and an outlook that
        // names a day the list does not is one no reader can follow.
        let formatter = DateFormatter()
        formatter.locale = LanguageModels.personLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        let code = facts.currencyCode
        let lowest = facts.lowestBalanceDate.map { " on \(formatter.string(from: $0))" } ?? ""
        let balances = shownBalances(of: facts)
        let upcoming = shownMovements(of: facts).enumerated().map { index, movement in
            "- \(formatter.string(from: movement.0)): \(movement.1) — \(self.movement(movement.2, code: code))"
                + (balances.indices.contains(index) ? ", leaving \(balance(balances[index], code: code))" : "")
        }.joined(separator: "\n")
        let totals = facts.upcoming.isEmpty ? "" : """

            Scheduled over the horizon: \(facts.scheduledIn) \(code) in, \(facts.scheduledOut) \(code) out
            """
        return """
            Account: \(facts.accountName) (\(code))
            Forecast horizon: \(facts.horizonDays) days
            Balance today: \(balance(facts.openingBalance, code: code))
            Projected balance at the end: \(balance(facts.closingBalance, code: code)) — \(change(facts.closingBalance - facts.openingBalance, code: code))
            Lowest projected balance: \(balance(facts.lowestBalance, code: code))\(lowest)
            Recent months, on average: \(monthly(facts.recentMonthlyNet, code: code))\(totals)
            Scheduled movements:
            \(upcoming.isEmpty ? "(none)" : upcoming)
            """
    }

    /// A balance as the model is given it: below zero said in words, not
    /// with a minus sign.
    private static func balance(_ amount: Decimal, code: String) -> String {
        amount < 0 ? "\(abs(amount)) \(code) below zero" : "\(amount) \(code)"
    }

    /// The change to the end balance, as a direction and a size.
    private static func change(_ change: Decimal, code: String) -> String {
        ReviewNarrator.direction(of: change, size: "\(abs(change)) \(code)", on: "today's balance",
                                 unchanged: "the same as today's balance")
    }

    /// The recent monthly net, as which way it went.
    private static func monthly(_ net: Decimal, code: String) -> String {
        net == 0 ? "income matched spending"
            : net > 0 ? "income exceeded spending by \(net) \(code) a month"
                : "spending exceeded income by \(abs(net)) \(code) a month"
    }

    /// A scheduled movement, as money in or out.
    private static func movement(_ amount: Decimal, code: String) -> String {
        amount < 0 ? "\(abs(amount)) \(code) out" : "\(amount) \(code) in"
    }

    /// The scheduled movements the model is shown: the next twelve. One
    /// definition, so the prompt and the check cannot disagree about which.
    static func shownMovements(of facts: ForecastFacts) -> ArraySlice<(Date, String, Decimal)> {
        facts.upcoming.prefix(12)
    }

    /// The balances those movements leave, where they are known.
    static func shownBalances(of facts: ForecastFacts) -> ArraySlice<Decimal> {
        facts.upcomingBalances.prefix(12)
    }

    /// The forecast's own words, which the outlook may repeat as given.
    static func labels(of facts: ForecastFacts) -> String {
        ([facts.accountName] + shownMovements(of: facts).map(\.1)).joined(separator: " ")
    }

    /// The horizon as a person would say it: the days it was given in, and
    /// the whole weeks or months those days are. Ninety days is "three
    /// months" and "about 13 weeks"; saying so is not inventing a figure.
    static func horizonCounts(days: Int) -> [Int] {
        var counts = [days]
        let weeks = (Double(days) / 7).rounded()
        if weeks >= 1, abs(Double(days) - weeks * 7) <= 1 { counts.append(Int(weeks)) }
        // A month is 28 to 31 days, so a horizon within two and a half days
        // a month of a whole number of average months is that many months.
        let months = (Double(days) / 30.44).rounded()
        if months >= 1, abs(Double(days) - months * 30.44) <= months * 2.5 { counts.append(Int(months)) }
        return counts
    }

    /// The forecast's figures as the checks read them: every figure the
    /// prompt states, filed by what it is (``FigureRole``) — the balances,
    /// the change and the monthly net, each movement as money in or out, and
    /// the horizon's totals. One definition, so the prompt, the number check
    /// and the attribution checks cannot disagree about which.
    static func figureFacts(of facts: ForecastFacts) -> FigureGrounding.Facts {
        let movements = shownMovements(of: facts)
        let balances = shownBalances(of: facts)
        // The change is given to the model as a figure of its own: it wants
        // to say how far the balance moves, and left to subtract it wrote 135
        // for 1,351.
        let change = facts.closingBalance - facts.openingBalance
        let totals = facts.upcoming.isEmpty ? [] : [facts.scheduledIn, -facts.scheduledOut]
        let levels = [facts.openingBalance, facts.closingBalance, facts.lowestBalance] + Array(balances)
        let moves = [change, facts.recentMonthlyNet] + movements.map(\.2) + totals
        var figures = FigureGrounding.Facts(
            figures: levels + moves,
            // The horizon, and how many movements were listed.
            counts: horizonCounts(days: facts.horizonDays) + Array(0...movements.count),
            quotableText: labels(of: facts),
            dates: (facts.lowestBalanceDate.map { [$0] } ?? []) + movements.map(\.0),
            currencyCode: facts.currencyCode)
        figures.attribute(facts.openingBalance, as: .openingBalance)
        for level in levels.dropFirst() { figures.attribute(level, as: .balance) }
        figures.attribute(change, as: .change)
        figures.attribute(facts.recentMonthlyNet, as: .change)
        for amount in movements.map(\.2) + totals { figures.attribute(amount, as: amount < 0 ? .outflow : .inflow) }
        return figures
    }

    /// Whether `text` may be shown: prose, every number and date one the
    /// forecast contains, and none of them said of the wrong thing. What
    /// ``narrate(facts:)`` holds each headline and insight to, and what the
    /// survey replay counts.
    static func isSound(_ text: String, facts: ForecastFacts,
                        locale: Locale = LanguageModels.personLocale) -> Bool {
        LanguageModels.isCleanProse(text) && isGrounded(text, facts: facts, locale: locale)
            && !misattributes(text, facts: facts, locale: locale)
    }

    /// Whether `text` says one of the forecast's own numbers of the wrong
    /// thing (FigureAttribution.swift): a balance given as the size of the
    /// change — four headlines of the 12 October 2026 survey said the
    /// balance would end higher *by* 9,420, its closing balance — a change
    /// the other way, a comparison its figures contradict, or a negative
    /// balance in a forecast that has none.
    static func misattributes(_ text: String, facts: ForecastFacts,
                              locale: Locale = LanguageModels.personLocale) -> Bool {
        let figures = figureFacts(of: facts)
        return FigureGrounding.misattributes(text, facts: figures, locale: locale)
            || (figures.levels.allSatisfy { $0 >= 0 }
                && FigureGrounding.saysABalanceIsNegative(text, facts: figures, locale: locale))
    }

    /// Whether every number and date in `text` is one the forecast contains.
    static func isGrounded(_ text: String, facts: ForecastFacts,
                           locale: Locale = LanguageModels.personLocale) -> Bool {
        FigureGrounding.isGrounded(text, facts: figureFacts(of: facts), locale: locale)
    }
}
