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
    /// Average monthly net income over recent history.
    public var recentMonthlyNet: Decimal

    public init(currencyCode: String, accountName: String, horizonDays: Int,
                openingBalance: Decimal, closingBalance: Decimal,
                lowestBalance: Decimal, lowestBalanceDate: Date?,
                upcoming: [(Date, String, Decimal)], recentMonthlyNet: Decimal) {
        self.currencyCode = currencyCode
        self.accountName = accountName
        self.horizonDays = horizonDays
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.lowestBalance = lowestBalance
        self.lowestBalanceDate = lowestBalanceDate
        self.upcoming = upcoming
        self.recentMonthlyNet = recentMonthlyNet
    }
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
        // observations (12 October 2026); the second answer was sound.
        try await LanguageModels.firstSoundDraft(
            text: { ([$0.headline] + $0.insights).joined(separator: " ") },
            quoting: labels(of: facts),
            nothingSound: .modelFailure(
                String(localized: "The outlook quoted figures that are not in this forecast, so it was discarded."))
        ) {
            let model = try await draft(facts: facts)
            func sound(_ text: String) -> Bool {
                LanguageModels.isCleanProse(text) && isGrounded(text, facts: facts)
            }
            guard sound(model.headline) else { return nil }
            return ForecastInsights(headline: model.headline, insights: model.insights.filter(sound))
        }
    }

    /// What the model wrote, before anything has checked it.
    static func draft(facts: ForecastFacts) async throws -> ForecastInsights {
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
        let lowest = facts.lowestBalanceDate.map { " on \(formatter.string(from: $0))" } ?? ""
        let upcoming = shownMovements(of: facts).map {
            "- \(formatter.string(from: $0.0)): \($0.1) (\($0.2))"
        }.joined(separator: "\n")

        let model = try await LanguageModels.respond(
            .forecastNarrator,
            instructions: """
                You write short, factual cash-flow outlooks for a personal finance app. \
                Use only the numbers provided — never invent figures. Be concrete and \
                calm; no financial advice, no recommendations to buy or sell anything.
                """,
            prompt: """
                Account: \(facts.accountName) (\(facts.currencyCode))
                Forecast horizon: \(facts.horizonDays) days
                Balance today: \(facts.openingBalance)
                Projected balance at end: \(facts.closingBalance)
                Change over the forecast horizon: \(facts.closingBalance - facts.openingBalance)
                Lowest projected balance: \(facts.lowestBalance)\(lowest)
                Average monthly net income recently: \(facts.recentMonthlyNet)
                Scheduled movements:
                \(upcoming.isEmpty ? "(none)" : upcoming)
                """,
            generating: ModelOutlook.self
        )
        return ForecastInsights(headline: model.headline, insights: model.insights)
    }

    /// The scheduled movements the model is shown: the next twelve. One
    /// definition, so the prompt and the check cannot disagree about which.
    static func shownMovements(of facts: ForecastFacts) -> ArraySlice<(Date, String, Decimal)> {
        facts.upcoming.prefix(12)
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

    /// Whether every number and date in `text` is one the forecast contains.
    static func isGrounded(_ text: String, facts: ForecastFacts,
                           locale: Locale = LanguageModels.personLocale) -> Bool {
        let movements = shownMovements(of: facts)
        return FigureGrounding.isGrounded(
            text,
            facts: FigureGrounding.Facts(
                // The change is given to the model as a figure of its own:
                // it wants to say how far the balance moves, and left to
                // subtract it wrote 135 for 1,351.
                figures: [facts.openingBalance, facts.closingBalance, facts.lowestBalance,
                          facts.closingBalance - facts.openingBalance,
                          facts.recentMonthlyNet] + movements.map(\.2),
                // The horizon, and how many movements were listed.
                counts: horizonCounts(days: facts.horizonDays) + Array(0...movements.count),
                quotableText: labels(of: facts),
                dates: (facts.lowestBalanceDate.map { [$0] } ?? []) + movements.map(\.0),
                currencyCode: facts.currencyCode),
            locale: locale)
    }
}
