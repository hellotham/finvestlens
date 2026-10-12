//
//  Fixtures.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The facts the narrators are tested with, in one place.
//
//  **Every figure here is invented.** They are small, and chosen so that the
//  ways a number check can be fooled are all on the table at once: a total
//  whose thousands round to a plausible percentage (66,610.82 → "67%"), a
//  period label with a two-digit year in it ("FY 2025–26"), a forecast whose
//  dates fall on days that are also believable percentages (the 1st, 2nd and
//  15th of August). Nothing in this target may come from a real book.
//

import Foundation
import NaturalLanguage
import FinvestLensEngine
@testable import FinvestLensIntelligence

enum Fixtures {

    /// Whether the device's own model can answer — the gate for every suite
    /// that asks it something.
    static let modelAvailable = LanguageModels.availability(of: .onDevice).isAvailable

    static let english = Locale(identifier: "en_AU")
    static let german = Locale(identifier: "de_DE")
    static let french = Locale(identifier: "fr_FR")
    static let spanish = Locale(identifier: "es_ES")
    static let japanese = Locale(identifier: "ja_JP")
    static let chinese = Locale(identifier: "zh_Hans_CN")

    /// The seven languages the app is translated into besides English.
    static let translatedLocales = ["de_DE", "fr_FR", "es_ES", "it_IT", "ja_JP", "pt_BR", "zh_Hans_CN"]

    /// A review slide: three figures and one change.
    static let spending = ReviewSlideFacts(
        kicker: "Spending", periodLabel: "FY 2025–26", currencyCode: "AUD",
        figures: [("Total spending", Decimal(string: "66610.82")!),
                  ("Groceries", Decimal(string: "12480.55")!),
                  ("Housing", Decimal(string: "25680.00")!)],
        deltaPercents: [("Total spending", Decimal(string: "-8.4")!)])

    /// The deck's opening slide: a change in something that is itself listed
    /// (net worth), and a ratio. The figures add up, and agree with
    /// ``income``.
    static let highlights = ReviewSlideFacts(
        kicker: "Highlights", periodLabel: "FY 2025–26", currencyCode: "AUD",
        figures: [("Net worth", Decimal(string: "412350.40")!),
                  ("Net surplus", Decimal(string: "24032.68")!),
                  ("Income", Decimal(string: "90643.50")!),
                  ("Expenses", Decimal(string: "66610.82")!),
                  ("Opening net worth", Decimal(string: "381200.00")!),
                  ("Change in net worth", Decimal(string: "31150.40")!)],
        ratios: [("Savings rate", Decimal(string: "26.5")!)],
        deltaPercents: [("Net worth", Decimal(string: "8.2")!)])

    /// The net-worth bridge: a change in something that is *not* listed
    /// under that name, so it goes to the model on a line of its own.
    static let bridge = ReviewSlideFacts(
        kicker: "Net worth bridge", periodLabel: "FY 2025–26", currencyCode: "AUD",
        figures: [("Opening net worth", Decimal(string: "381200.00")!),
                  ("Income", Decimal(string: "90643.50")!),
                  ("Expenses", Decimal(string: "66610.82")!),
                  ("Valuation and currency movement", Decimal(string: "7117.72")!),
                  ("Change in net worth", Decimal(string: "31150.40")!),
                  ("Closing net worth", Decimal(string: "412350.40")!)],
        deltaPercents: [("Net worth", Decimal(string: "8.2")!)])

    /// The review slides the survey asks about, by name.
    static let slides: [(name: String, facts: ReviewSlideFacts)] = [
        ("spending", spending), ("highlights", highlights), ("bridge", bridge),
    ]

    /// An income statement: three headline figures that add up, two lines.
    static let income = ReportFacts(
        reportTitle: "Income Statement", periodLabel: "FY 2025–26", currencyCode: "AUD",
        headline: [("Income", Decimal(string: "90643.50")!), ("Expenses", Decimal(string: "66610.82")!),
                   ("Net income", Decimal(string: "24032.68")!)],
        lines: [("Income:Salary", Decimal(string: "89400.00")!),
                ("Expenses:Housing", Decimal(string: "25680.00")!)])

    /// Noon on a day, in the zone the narrator prints and checks dates in.
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// A ninety-day forecast: rent on the 1st, the low point on the 2nd,
    /// salary on the 15th, all in August.
    static let forecast = ForecastFacts(
        currencyCode: "AUD", accountName: "Everyday", horizonDays: 90,
        openingBalance: 8069, closingBalance: 9420, lowestBalance: 3105,
        lowestBalanceDate: day(2026, 8, 2),
        upcoming: [(day(2026, 8, 1), "Rent", -2600), (day(2026, 8, 15), "Salary", 5200)],
        recentMonthlyNet: 450)

    /// The same account running down: the outlook a person most needs to be
    /// told straight, and the one whose change goes to the model as a
    /// negative number.
    static let fallingForecast = ForecastFacts(
        currencyCode: "AUD", accountName: "Everyday", horizonDays: 90,
        openingBalance: 9420, closingBalance: 6105, lowestBalance: 2480,
        lowestBalanceDate: day(2026, 8, 21),
        upcoming: [(day(2026, 8, 1), "Rent", -2600), (day(2026, 8, 15), "Salary", 5200),
                   (day(2026, 8, 20), "Car repair", -3400)],
        recentMonthlyNet: -1100)

    /// Two spending categories and an income to budget them from.
    static func spendingHistory() -> [SpendingHistory] {
        [SpendingHistory(categoryID: .random(), fullName: "Expenses:Food:Groceries",
                         monthlyAverage: 820, monthlyMinimum: 760, monthlyMaximum: 905),
         SpendingHistory(categoryID: .random(), fullName: "Expenses:Food:Dining Out",
                         monthlyAverage: 460, monthlyMinimum: 300, monthlyMaximum: 640)]
    }
    static let monthlyIncome: Decimal = 7800

    // MARK: - Which language a text is in, asked independently

    /// A handful of the commonest function words of each language written in
    /// Latin script — the words a sentence cannot avoid and a list of account
    /// names does not contain.
    private static let functionWords: [String: Set<String>] = [
        "en": ["the", "and", "of", "is", "with", "for", "at", "by", "from", "to", "in", "was", "are"],
        "de": ["der", "die", "das", "und", "ist", "mit", "für", "von", "den", "auf", "im", "bei", "beträgt", "ein", "eine"],
        "fr": ["le", "la", "les", "et", "est", "des", "du", "pour", "avec", "une", "un", "à", "sur", "au", "en"],
        "es": ["el", "la", "los", "las", "y", "es", "del", "con", "para", "una", "un", "en", "por", "se"],
        "it": ["il", "la", "le", "e", "è", "di", "del", "con", "per", "una", "un", "della", "che", "sono", "gli"],
        "pt": ["o", "a", "os", "as", "e", "é", "de", "do", "da", "com", "para", "uma", "um", "em", "que", "não"],
    ]

    /// Whether `text` is written in the language of `identifier`, judged
    /// without the recogniser the code under test uses: by script for
    /// Japanese and Chinese, and for the rest by whose function words the
    /// sentence is made of.
    static func reads(_ text: String, as identifier: String) -> Bool {
        let language = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
        let scalars = text.unicodeScalars
        let kana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        let ideographs = scalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        switch language {
        case "ja": return kana
        case "zh": return ideographs && !kana
        default:
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            func hits(_ code: String) -> Int {
                let list = functionWords[code] ?? []
                return words.filter(list.contains).count
            }
            let wanted = hits(language)
            return wanted >= 2 && wanted > hits("en")
        }
    }
}
