//
//  FigureGroundingTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Two kinds of sentence are quoted here, and the comments say which.
//
//  "The model wrote": the macOS 27 on-device model did write it, from the
//  synthetic figures in `Fixtures`, on 12 October 2026 — the run that showed
//  the check read only English and that two of the three narrators were not
//  checked at all.
//
//  "Invented": nobody was given the number in it. These came from the review
//  of the first shared check the same day, which ran each one against the
//  code and found that it passed. Each is here as the sentence that passed
//  and must not.
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensIntelligence

private let english = Fixtures.english, german = Fixtures.german, french = Fixtures.french
private let spanish = Fixtures.spanish, japanese = Fixtures.japanese, chinese = Fixtures.chinese

private func slide(_ text: String, _ locale: Locale) -> Bool {
    ReviewStoryValidator.isGrounded(ReviewSlideStory(headline: text, insight: ""),
                                    facts: Fixtures.spending, locale: locale)
}

private func note(_ text: String, _ locale: Locale) -> Bool {
    ReportNarrator.isGrounded(text, facts: Fixtures.income, locale: locale)
}

private func outlook(_ text: String, _ locale: Locale) -> Bool {
    ForecastNarrator.isGrounded(text, facts: Fixtures.forecast, locale: locale)
}

@Suite("Finding numbers, and reading them the way each language writes them")
struct NumberReadingTests {

    private func runs(_ text: String) -> [String] {
        FigureGrounding.runs(in: text, currencyCode: "AUD").map(\.text)
    }

    private func units(_ text: String) -> [FigureGrounding.Unit] {
        FigureGrounding.runs(in: text, currencyCode: "AUD").map(\.unit)
    }

    private func values(_ run: String, continental: Bool) -> [Decimal] {
        FigureGrounding.readings(of: run, continental: continental).map(\.value)
    }

    @Test("English: comma groups of three, and a point before the decimals")
    func englishReading() {
        #expect(runs("66,610.82 AUD and 8.4%") == ["66,610.82", "8.4"])
        #expect(values("66,610.82", continental: false) == [Decimal(string: "66610.82")!])
        #expect(values("8.4", continental: false) == [Decimal(string: "8.4")!])
    }

    @Test("A language that writes a decimal comma gets both readings of an ambiguous figure")
    func continentalReading() {
        // "66.611" is 66.611 in English and 66,611 in Spanish; "12,481" is
        // 12,481 in English and 12.481 in French.
        #expect(values("66.611", continental: true) == [Decimal(string: "66.611")!, 66_611])
        #expect(values("12,481", continental: true) == [12_481, Decimal(string: "12.481")!])
        #expect(values("66.610,82", continental: true) == [Decimal(string: "66610.82")!])
        #expect(values("8,4", continental: true) == [Decimal(string: "8.4")!])
    }

    @Test("A separator that does not mark off groups of three is not a thousands separator")
    func groupsAreOfThree() {
        // Each of these read as a whole number once: 26, 12, 84.
        #expect(values("2,6", continental: false).isEmpty)
        #expect(values("1.2", continental: true) == [Decimal(string: "1.2")!])
        #expect(values("8,4", continental: false).isEmpty)
        #expect(values("1234,567", continental: false).isEmpty)
        #expect(values("1,234,567", continental: false) == [1_234_567])
    }

    @Test("A number that is not written any known way has no reading")
    func unreadable() {
        #expect(values("24.000,98", continental: false).isEmpty)
        #expect(values("1.234.567", continental: false).isEmpty)
        #expect(values("1.234.567", continental: true) == [1_234_567])
    }

    @Test("A space or an apostrophe between groups of three is a thousands separator", arguments: [
        "66 611 AUD", "66\u{00A0}611 AUD", "66\u{202F}611 AUD", "66’611 AUD",
    ])
    func spaceGrouping(text: String) {
        let found = FigureGrounding.runs(in: text, currencyCode: "AUD")
        #expect(found.count == 1)
        #expect(values(found[0].text, continental: true) == [66_611])
        #expect(found[0].unit == .currency)
    }

    @Test("Space groups take either decimal mark")
    func spaceGroupsWithDecimals() {
        #expect(values("66 610,82", continental: true) == [Decimal(string: "66610.82")!])
        #expect(values("66’610.82", continental: false) == [Decimal(string: "66610.82")!])
    }

    @Test("An ordinary space joins only a group of one to three digits to a group of exactly three")
    func separateNumbersStaySeparate() {
        // Adjacent, with nothing but the space between them.
        #expect(runs("In 2025 150 AUD went to dining") == ["2025", "150"])
        #expect(runs("in 2025 1000 items") == ["2025", "1000"])
        #expect(runs("1 240 000 AUD") == ["1 240 000"])
        #expect(runs("90 days, 5200 AUD") == ["90", "5200"])
    }

    @Test("A sentence's own full stop or comma is not part of the number before it")
    func trailingPunctuation() {
        #expect(runs("The total was 66611.") == ["66611"])
        #expect(runs("Le total est de 25680, environ.") == ["25680"])
        #expect(runs("am 2. August") == ["2"])
    }

    @Test("Full-width digits are digits")
    func fullWidth() {
        #expect(runs("総支出は６６，６１１ AUD") == ["66,611"])
    }

    @Test("A number is read with the unit it carries")
    func unitsAreRead() {
        #expect(units("8.4%") == [.percent])
        #expect(units("8,4 %") == [.percent])
        #expect(units("8.4 Prozent") == [.percent])
        #expect(units("8.4 per cent") == [.percent])
        #expect(units("占总收入的98.4%") == [.percent])
        #expect(units("百分之8.4") == [.percent])
        #expect(units("66.6k AUD") == [.thousands])
        #expect(units("1.2M") == [.millions])
        #expect(units("66,6 mil AUD") == [.thousands])
        #expect(units("1,2 millones") == [.millions])
        #expect(units("6.66万 AUD") == [.myriads])
        #expect(units("1.2億") == [.hundredMillions])
        #expect(units("8月15日") == [.month, .day])
        #expect(units("2026年") == [.year])
        #expect(units("5200 AUD") == [.currency])
        #expect(units("AUD 5200") == [.currency])
        #expect(units("$5,200") == [.currency])
        #expect(units("5200澳元") == [.currency])
        // The first letter of a word is not a unit.
        #expect(units("3 months") == [.none])
        #expect(units("5 km") == [.none])
        #expect(units("90 days") == [.none])
    }

    @Test("German accounts count thousands with a capital T before the currency")
    func germanThousands() {
        #expect(units("66.61 T$") == [.thousands])
        #expect(units("66,6 T€") == [.thousands])
        #expect(units("250 TEUR") == [.thousands])
        #expect(units("66,6 TAUD") == [.thousands])
        // A German word that begins with a T is a word.
        #expect(units("90 Tage") == [.none])
        #expect(units("3 Tonnen") == [.none])
        #expect(units("5 tage") == [.none])
        // In a book kept in paʻanga, T$ is the currency and nothing more.
        #expect(FigureGrounding.runs(in: "66.61 T$", currencyCode: "TOP").map(\.unit) != [.thousands])
    }

    @Test("The German slides the check wrongly declined are grounded")
    func germanSurveyDrafts() {
        // Two drafts of eight, 12 October 2026: true figures, in thousands,
        // in a form the check did not know.
        let german = Locale(identifier: "de_DE")
        #expect(ReviewStoryValidator.isGrounded(ReviewSlideStory(
            headline: "Gesamtausgaben FY 2025–26 stabil bei 66.61 T$",
            insight: "Die Gesamtausgaben belaufen sich auf 66.61 T$, wobei die Ausgaben für Wohnen mit 25.68 T$ den höchsten Anteil haben. Die Gesamtzahl blieb im Vergleich zum Vorjahr nahezu unverändert."),
            facts: Fixtures.spending, locale: german))
        #expect(ReviewStoryValidator.isGrounded(ReviewSlideStory(
            headline: "Gesamtausgaben FY 2025–26 bei 66.61 T$",
            insight: "Die Gesamtausgaben betragen 66.61 T$, wobei die Ausgaben für Wohnen mit 25.68 T$ den höchsten Anteil haben. Der Gesamtbetrag verzeichnet einen Rückgang von 8,4% gegenüber dem vorherigen Zeitraum."),
            facts: Fixtures.spending, locale: german))
        // The form does not make a wrong figure right: housing is 25.68.
        #expect(!ReviewStoryValidator.isGrounded(ReviewSlideStory(
            headline: "Gesamtausgaben bei 66.61 T$", insight: "Wohnen liegt bei 26.8 T$."),
            facts: Fixtures.spending, locale: german))
    }

    @Test("Unit words in katakana survive the folding of full-width digits")
    func katakanaUnits() {
        // Foundation's width transform halves katakana too, after which
        // "パーセント" was no longer the word looked for.
        #expect(units("支出の６７パーセントは住宅です。") == [.percent])
        #expect(units("残高は5200ドルです。") == [.currency])
        #expect(runs("支出の６７パーセント") == ["67"])
    }

    @Test("Prose in a language that writes a decimal comma is read that way wherever its reader lives")
    func decimalCommaFollowsTheLanguage() {
        for identifier in ["de_DE", "de_CH", "fr_FR", "fr_CH", "it_CH", "es_ES", "es_MX", "es_US", "pt_BR"] {
            #expect(FigureGrounding.writesDecimalComma(Locale(identifier: identifier)), "\(identifier)")
        }
        for identifier in ["en_AU", "en_US", "ja_JP", "zh_Hans_CN"] {
            #expect(!FigureGrounding.writesDecimalComma(Locale(identifier: identifier)), "\(identifier)")
        }
    }
}

@Suite("A narrator's numbers must be numbers it was given")
struct GroundingTests {

    // MARK: What the model wrote, and is true

    @Test("The review slides the model wrote in French and Spanish are grounded")
    func continentalReviewSlides() {
        let frenchStory = ReviewSlideStory(
            headline: "La dépense totale s'élève à 66 611 AUD pour l'exercice 2025-26.",
            insight: "La dépense totale atteint 66 611 AUD, avec les catégories d'épicerie à 12 481 AUD et le logement à 25 680 AUD. La dépense totale a diminué de 8,4 % par rapport à la période précédente.")
        #expect(ReviewStoryValidator.isGrounded(frenchStory, facts: Fixtures.spending, locale: french))

        let spanishStory = ReviewSlideStory(
            headline: "El gasto total alcanzó 66.611 AUD en el período FY 2025–26.",
            insight: "El gasto en vivienda representó 25.680 AUD, el componente más alto. El gasto total mostró una disminución del 8,4% respecto al período anterior.")
        #expect(ReviewStoryValidator.isGrounded(spanishStory, facts: Fixtures.spending, locale: spanish))
    }

    @Test("The same slides in German and Japanese stay grounded")
    func otherLanguages() {
        let germanStory = ReviewSlideStory(
            headline: "Gesamtausgaben FY 2025–26 bei 66.6k AUD",
            insight: "Die Gesamtausgaben belaufen sich auf 66.6k AUD, wobei die Ausgaben für Wohnen mit 25.7k AUD den höchsten Anteil haben. Die Gesamtausgaben verringerten sich im Vergleich zum Vorjahr um 8.4 Prozent.")
        #expect(ReviewStoryValidator.isGrounded(germanStory, facts: Fixtures.spending, locale: german))
        let japaneseStory = ReviewSlideStory(
            headline: "FY 2025–26の総支出は66,611 AUD",
            insight: "総支出は66,611 AUDで、食料品が12,481 AUD、住宅が25,680 AUDで占めている。")
        #expect(ReviewStoryValidator.isGrounded(japaneseStory, facts: Fixtures.spending, locale: japanese))
    }

    @Test("A lone k before a Chinese or Japanese word is thousands")
    func thousandsBeforeCJK() {
        // The model wrote it on the bridge slide, 17 October 2026.
        let story = ReviewSlideStory(headline: "期末純資産は31.1k増加",
                                     insight: "期末純資産は412350.4 AUDで、期首の381200 AUDから31150.4 AUD増。")
        #expect(ReviewStoryValidator.isGrounded(story, facts: Fixtures.bridge, locale: Locale(identifier: "ja_JP")))
        // Still not the first letter of a word: read as thousands, 90.6 would
        // be the income of 90,643.50 cut off at its place.
        #expect(!note("We drove 90.6 kilometres.", english))
    }

    @Test("A period label's short year, written before 年, is the label's")
    func labelYearBeforeNian() {
        // The model wrote it in the survey of 17 October 2026, in four of the
        // Chinese report notes: the period "FY 2025–26" as "2025–26年度".
        let chinese = Locale(identifier: "zh_Hans_CN")
        #expect(note("2025–26年度收入为90643.5澳元，主要来自工资89400澳元。", chinese))
        // A year the label does not name is not thereby one.
        #expect(!note("2023年度收入为90643.5澳元。", chinese))
    }

    @Test("Report notes: the figure the model made up is caught, the real ones pass")
    func reportNotes() {
        // What it wrote in English, unchecked, for a net income of 24,032.68.
        #expect(!note("Income exceeds expenses by 24,000.98 AUD.", english))
        #expect(note("Net income reflects a surplus of 24,032.68 AUD after all expenses.", english))
        #expect(note("Salary is the largest income line item at 89,400 AUD.", english))
        // Shares it worked out for itself, in Chinese.
        #expect(!note("薪资是收入最大项，占总收入的98.4%。", chinese))
        #expect(note("收入（90643.5澳元）超过支出（66610.82澳元），显示出正的财务余量。", chinese))
        // German, localised by the model.
        #expect(note("Das Einkommen von 90.643,5 AUD übersteigt die Ausgaben von 66.610,82 AUD deutlich.", german))
        // A note with no numbers has nothing to check.
        #expect(note("Housing is the largest expense.", english))
    }

    @Test("Forecast: days and months must be the forecast's own")
    func forecastDates() {
        // What the model wrote before the dates were given to it in Japanese.
        #expect(!outlook("15月15日に給与として5200の入金がある。", japanese))
        #expect(!outlook("1月1日に家賃として2600の支出が見込まれている。", japanese))
        #expect(outlook("8月15日に給与として5200の入金がある。", japanese))
        #expect(outlook("Lowest projected balance of 3105 expected on 2 Aug.", english))
        #expect(outlook("Der niedrigste voraussichtliche Kontostand liegt bei 3105 AUD am 2. August.", german))
        #expect(outlook("Balance starting at 8069, with a projected end balance of 9420 over 90 days.", english))
        #expect(!outlook("The balance will dip to 2,400 on 2 Aug.", english))
        // The change is a figure the model is given, so it may say it.
        #expect(outlook("The balance is projected to rise by 1351 AUD.", english))
        #expect(!outlook("Le solde devrait augmenter de 135 AUD.", french))
    }

    // MARK: Invented, in a format the first check could not read

    @Test("A number the check cannot read is not thereby true")
    func unreadableIsUngrounded() {
        // The figure this file's header records as invented, written the
        // continental way for an English reader: there is no English reading,
        // and the first check skipped what it could not read.
        #expect(!note("Income exceeds expenses by 24.000,98 AUD.", english))
        #expect(!note("Assets of 1.234.567 AUD dominate.", english))
        // German prose for a Swiss reader, whose region writes neither mark.
        #expect(!note("Das Einkommen von 71.250,99 AUD übersteigt die Ausgaben von 12.345,67 AUD.",
                      Locale(identifier: "de_CH")))
        #expect(note("Das Einkommen von 90.643,5 AUD übersteigt die Ausgaben von 66.610,82 AUD deutlich.",
                     Locale(identifier: "de_CH")))
    }

    @Test("An invented figure is rejected in every format")
    func inventedFigures() {
        #expect(!slide("Spending reached 71,250 AUD", english))
        #expect(!slide("Les dépenses atteignent 71 250 AUD", french))
        #expect(!slide("El gasto alcanzó 71.250 AUD", spanish))
        #expect(!slide("Die Ausgaben sanken um 37,5 Prozent", german))
    }

    @Test("A percentage has to be one that was given", arguments: [
        // 66,610.82 is 66.6 thousands; 25,680 is 25.7; the first check tried
        // every scaling on every number, unit or no unit.
        "Housing is 67% of spending", "Groceries are 12% of the total", "Housing took 26 percent",
        // Nothing times a millionth is nearly nothing.
        "Spending changed 0% this year", "Spending changed 0.0% this year",
        // A true figure is not a true percentage.
        "Spending rose 66,611%",
    ])
    func inventedPercentages(text: String) {
        #expect(!slide(text, english))
    }

    @Test("A given percentage passes, rounded or not, in each language's form")
    func givenPercentages() {
        #expect(slide("Spending fell 8.4% on the prior period", english))
        #expect(slide("Spending fell 8% on the prior period", english))
        #expect(slide("Les dépenses ont diminué de 8,4 %", french))
        #expect(slide("总支出下降了百分之8.4", chinese))
        // A decimal comma is not English's.
        #expect(!slide("Spending fell 8,4 per cent", english))
        #expect(slide("Die Ausgaben sanken um 8,4 Prozent", german))
    }

    @Test("A figure cut off at its precision is the figure, as one rounded to it is")
    func cutOffOrRounded() {
        // 31,150.40 — "31.2k" rounded, "31.1k" with the rest dropped. Twelve
        // of forty-eight drafts of one slide were declined for the second.
        let facts = Fixtures.highlights
        func story(_ text: String) -> Bool {
            ReviewStoryValidator.isGrounded(ReviewSlideStory(headline: text, insight: ""),
                                            facts: facts, locale: english)
        }
        #expect(story("Net worth rose by 31.2k AUD"))
        #expect(story("Net worth rose by 31.1k AUD"))
        #expect(story("Net worth rose by 31,150 AUD"))
        #expect(story("Net worth rose by 31,150.4 AUD"))
        // Expenses are 66,610.82: the cents may be dropped or rounded up.
        #expect(story("Expenses of 66,610 AUD"))
        #expect(story("Expenses of 66,611 AUD"))
        // Above what rounding gives, or merely near, is still nobody's figure.
        #expect(!story("Net worth rose by 31.3k AUD"))
        #expect(!story("Net worth rose by 31.0k AUD"))
        #expect(!story("Expenses of 66,612 AUD"))
        #expect(!story("Expenses of 66,609 AUD"))
        #expect(!story("Expenses of 66.62k AUD"))
        // A surplus of 24,032.68 is not "24,000" — that is rounding to a
        // precision the figure does not show.
        #expect(!story("A surplus of 24,000 AUD"))
        #expect(story("A surplus of 24k AUD"))
        // The same for a percentage: 8.2 is "8%", and not "9%" or "8.3%".
        #expect(story("Net worth grew 8%"))
        #expect(!story("Net worth grew 9%"))
        #expect(!story("Net worth grew 8.3%"))
    }

    @Test("A story is known to have quoted the change it was given")
    func quotedChange() {
        func states(_ text: String, _ locale: Locale, _ facts: ReviewSlideFacts = Fixtures.spending) -> Bool {
            ReviewStoryValidator.statesAListedChange(ReviewSlideStory(headline: text, insight: ""),
                                                     facts: facts, locale: locale)
        }
        #expect(states("Total spending down 8.4% as groceries and housing dominate", english))
        #expect(states("Spending fell 8% on the prior period", english))
        #expect(states("Gesamtausgaben sanken um 8,4 % auf 66.611 AUD", german))
        #expect(states("総支出は前年比8.4%減少し、全体で66,611 AUDでした。", japanese))
        #expect(states("总支出下降8.4%：各项开支分布", chinese))
        // The amount is not the percentage, and another percentage is not this one.
        #expect(!states("Total spending at 66610.82 AUD for FY 2025–26", english))
        #expect(!states("Housing is 38.5% of spending", english))
        // A slide that lists no change asks for none.
        #expect(states("Income of 90,643.50 AUD", english,
                       ReviewSlideFacts(kicker: "Income", periodLabel: "FY 2025–26", currencyCode: "AUD",
                                        figures: [("Total", Decimal(string: "90643.50")!)])))
    }

    @Test("A story that calls unchanged what the slide says changed is declined", arguments: [
        // Each as the 27 model wrote it for a slide that listed -8.4%, and
        // as the number check accepted it, 12 October 2026.
        ("Total spending at 66610.82 AUD with stable categories ‖ No change in spending compared to prior period.", "en_AU"),
        ("Total spending remained at 66610.82 AUD ‖ Total spending stood at 66610.82 AUD, with groceries at 12480.55 AUD and housing at 25680 AUD.", "en_AU"),
        ("Gesamtausgaben bei 66610.82 AUD ‖ Die Gesamtsumme blieb unverändert im Vergleich zum Vorjahr.", "de_DE"),
        ("El gasto total se mantuvo estable en 66611 AUD durante el período. ‖ El gasto en comestibles fue de 12481 AUD.", "es_ES"),
        ("Spesa totale stabile a 66.6k AUD nel periodo FY 2025–26 ‖ I dati confermano la stabilità complessiva rispetto al periodo precedente.", "it_IT"),
        ("FY 2025–26の総支出は66,611 AUDで安定 ‖ 総支出の推移は前期と比べて変動なし。", "ja_JP"),
        ("Gastos totais se mantêm estáveis em 66.6k AUD ‖ Não há variação percentual comparativa.", "pt_BR"),
        ("总支出达66610.82澳元，住房占比最高 ‖ 杂货支出12480.55澳元也保持稳定。", "zh_Hans_CN"),
    ])
    func unchangedIsDeclined(text: String, identifier: String) {
        let parts = text.components(separatedBy: " ‖ ")
        let story = ReviewSlideStory(headline: parts[0], insight: parts[1])
        let locale = Locale(identifier: identifier)
        #expect(ReviewStoryValidator.isGrounded(story, facts: Fixtures.spending, locale: locale),
                "the number check accepted this when it was written")
        #expect(ReviewStoryValidator.contradictsAListedChange(story, facts: Fixtures.spending, locale: locale))
    }

    @Test("Saying which way it went, or nothing about it, is not calling it unchanged")
    func changeWithoutContradiction() {
        func contradicts(_ headline: String, _ insight: String, _ locale: Locale,
                         _ facts: ReviewSlideFacts = Fixtures.spending) -> Bool {
            ReviewStoryValidator.contradictsAListedChange(
                ReviewSlideStory(headline: headline, insight: insight), facts: facts, locale: locale)
        }
        #expect(!contradicts("Total spending down 8.4% as groceries and housing dominate",
                             "Total spending decreased by 8.4% on the prior period.", english))
        // Quoting the change excuses an opinion about it.
        #expect(!contradicts("Spending down 8.4%, though broadly stable",
                             "Housing remained the largest category.", english))
        // Silence is not a claim, and neither is the change as an amount.
        #expect(!contradicts("Total spending at 66610.82 AUD for FY 2025–26",
                             "Total spending reached 66610.82 AUD, with groceries at 12480.55 AUD.", english))
        #expect(!contradicts("Net worth increased by 31.1k AUD",
                             "Net worth rose by 31.1k AUD, driven by a surplus of 24.0k AUD.", english,
                             Fixtures.highlights))
        // A slide that lists no change, or one under a percent, has nothing
        // to contradict.
        let noChange = ReviewSlideFacts(kicker: "Income", periodLabel: "FY 2025–26", currencyCode: "AUD",
                                        figures: [("Total", Decimal(string: "90643.50")!)])
        #expect(!contradicts("Income stable at 90.6k AUD", "", english, noChange))
        var slight = Fixtures.spending
        slight.deltaPercents = [("Total spending", Decimal(string: "-0.3")!)]
        #expect(!contradicts("Total spending stable at 66.6k AUD", "", english, slight))
    }

    @Test("A change reaches the model in words, on the line of the figure it is a change in")
    func promptPutsTheChangeWithItsFigure() {
        let spending = ReviewNarrator.prompt(for: Fixtures.spending)
        #expect(spending.contains("- Total spending: 66610.82 AUD — down 8.4% on the prior period"))
        #expect(!spending.contains("Changes:"))
        #expect(!spending.contains("-8.4"))
        // Where what changed is not itself a listed figure, it has a line
        // of its own, in the same words.
        let bridge = ReviewNarrator.prompt(for: Fixtures.bridge)
        #expect(bridge.contains("Changes:\n- Net worth: up 8.2% on the prior period"))
        #expect(bridge.contains("- Closing net worth: 412350.4 AUD"))
        // A ratio keeps its percent sign and a figure with no change says nothing of one.
        let highlights = ReviewNarrator.prompt(for: Fixtures.highlights)
        #expect(highlights.contains("- Net worth: 412350.4 AUD — as at the end of the period; up 8.2% on the prior period"))
        #expect(highlights.contains("- Savings rate: 26.5%"))
        #expect(highlights.contains("- Income: 90643.5 AUD — money in over the period\n"))
    }

    @Test("A separator that is not marking thousands does not make a new number true", arguments: [
        ("une hausse de 2,6 %", "fr_FR"),     // 26 was the label's "26"
        ("une hausse de 6,7 %", "fr_FR"),     // 67 was 66,610.82 in thousands
        ("ein Anstieg um 1.2 Prozent", "de_DE"),  // 12 was 12,480.55 in thousands
    ])
    func separatorsDoNotInventNumbers(text: String, identifier: String) {
        #expect(!slide(text, Locale(identifier: identifier)))
    }

    @Test("Thousands, millions and ten-thousands are read only where the prose says so")
    func scalingNeedsItsUnit() {
        #expect(slide("Total spending of 66.6k AUD", english))
        #expect(slide("Total spending of 66.6 thousand AUD", english))
        #expect(!slide("Total spending of 66.6 AUD", english))
        #expect(!slide("Total spending of 67", english))
        #expect(slide("総支出は6.66万 AUD", japanese))
        #expect(slide("総支出は6万6611 AUD", japanese))
        #expect(!slide("総支出は6万6611万 AUD", japanese))
        // A true figure with the wrong unit is a different, larger number.
        #expect(!slide("総支出は66,611万 AUD", japanese))
    }

    @Test("A day or a month of the forecast is not a percentage or an amount", arguments: [
        "Spending rises 15% by the end",      // the 15th
        "Balance grows 8% over 90 days",      // August; and 8,069 in thousands
        "Balance is up 9 percent",            // 9,420 in thousands
        "A payment of 2027 AUD is due",       // a year, next to the forecast's
        "A payment of 15 AUD is due",
    ])
    func dateNumbersAreNotAmounts(text: String) {
        #expect(!outlook(text, english))
    }

    @Test("What the model made up in the survey stays rejected")
    func surveyInventions() {
        // 3 drafts × 3 narrators × 8 languages, 12 October 2026: every
        // sentence the check rejected, less the three that were its own
        // mistake (the horizon written "90日間").
        #expect(!note("收入为90643.5澳元，占总额的100%，显示收入的绝对规模。", chinese))
        #expect(!note("开支为66610.82澳元，其中住房开支占总开支的38.4%。", chinese))
        // Rent is 2,600.
        #expect(!outlook("La renta de 1800 AUD se realiza el 1 de agosto y el salario de 5200 AUD el 15 de agosto.", spanish))
        // 12,480.55 and 25,680, "rounded" to figures nobody gave.
        #expect(!ReviewStoryValidator.isGrounded(ReviewSlideStory(
            headline: "Gastos totais caíram 8,4% em relação ao período anterior",
            insight: "Os gastos totais foram de 66.611 AUD, com compras de mercearia totalizando 12.501 AUD e despesas com moradia de 25.700 AUD."),
            facts: Fixtures.spending, locale: Locale(identifier: "pt_BR")))
        #expect(!slide("总支出保持稳定，其中住房支出为25680澳元，占总支出约38%。", chinese))
        // 8 review drafts × 8 languages, later the same day: ten declined.
        // Groceries are 12,480.55 — 12.48 in thousands, not 12.49.
        #expect(!ReviewStoryValidator.isGrounded(ReviewSlideStory(
            headline: "El gasto total se situó en 66.61 k AUD para el periodo FY 2025–26.",
            insight: "El gasto en vivienda alcanzó 25.68 k AUD, mientras que los alimentos representaron 12.49 k AUD. El gasto total se mantuvo en 66.61 k AUD."),
            facts: Fixtures.spending, locale: spanish))
        // A share the model worked out for itself, four times of eight.
        #expect(!slide("总支出为 66611 澳元，其中住房支出为 25680 澳元，占总支出的 38.5%。杂货支出为 12480.55 澳元。", chinese))
    }

    // MARK: True, in a form the first check could not read

    @Test("Two numbers with a space between them are two numbers")
    func adjacentNumbers() {
        // "26 450" and "15 450" were each read as one number of five digits.
        let dining = ReportFacts(reportTitle: "Spending", periodLabel: "FY 2025–26", currencyCode: "AUD",
                                 headline: [("Dining out", 450)], lines: [])
        #expect(ReportNarrator.isGrounded("In FY 2025–26 450 AUD went to dining out.",
                                          facts: dining, locale: english))
        #expect(!ReportNarrator.isGrounded("In FY 2025–26 460 AUD went to dining out.",
                                           facts: dining, locale: english))
        #expect(outlook("On Aug 15 450 AUD is the monthly net", english))
        #expect(outlook("In 2026 450 AUD a month is the recent net", english))
    }

    @Test("A Chinese comma between a balance and what follows it is a comma")
    func chineseComma() {
        // The full-width comma folds to an ASCII one, which made "3105，8"
        // the number 31,058 and "8069，90" the number 806,990.
        #expect(outlook("最低余额为3105，8月2日出现。", chinese))
        #expect(outlook("期初余额8069，90天后预计为9420。", chinese))
        #expect(!outlook("最低余额为3105，9月2日出现。", chinese))
    }

    @Test("A German date written with points is a date")
    func germanDates() {
        #expect(outlook("Am 15.08. geht das Gehalt von 5200 AUD ein.", german))
        #expect(outlook("Der niedrigste Stand von 3105 AUD wird am 2.8.2026 erreicht.", german))
        #expect(!outlook("Am 16.08. geht das Gehalt von 5200 AUD ein.", german))
    }

    @Test("A true decimal comma is read for a reader whose region writes a point", arguments: [
        "es_MX", "es_US", "de_CH", "fr_CH",
    ])
    func decimalCommaOutsideItsRegion(identifier: String) {
        #expect(slide("El gasto total disminuyó un 8,4 % respecto al período anterior.",
                      Locale(identifier: identifier)))
    }

    @Test("A ratio the slide states is quotable as a percentage, and a count as a count")
    func ratiosAndCounts() {
        let position = ReviewSlideFacts(
            kicker: "Financial position", periodLabel: "30 June 2026", currencyCode: "AUD",
            figures: [("Assets", 512_000), ("Liabilities", 99_328)],
            ratios: [("Debt to assets", Decimal(string: "19.4")!)],
            counts: [("Disposals", 12)])
        func grounded(_ text: String) -> Bool {
            ReviewStoryValidator.isGrounded(ReviewSlideStory(headline: text, insight: ""),
                                            facts: position, locale: english)
        }
        #expect(grounded("Liabilities are 19.4% of 512,000 AUD in assets"))
        #expect(grounded("Liabilities are 19% of 512k AUD in assets"))
        #expect(grounded("12 disposals in the period"))
        // The ratio is not an amount, and an amount is not a ratio.
        #expect(!grounded("Liabilities of 19.4 AUD"))
        #expect(!grounded("Assets rose 512,000%"))
        #expect(!grounded("Liabilities are 21% of assets"))
    }

    @Test("A number in the request's own words is quotable with the unit it has there")
    func labelsKeepTheirUnits() {
        let holdings = ReportFacts(
            reportTitle: "Holdings", periodLabel: "FY 2025–26", currencyCode: "AUD",
            headline: [("Term Deposit 4.75% Mar 2027", 20_000), ("Fidelity 401k", 31_000)], lines: [])
        func grounded(_ text: String) -> Bool {
            ReportNarrator.isGrounded(text, facts: holdings, locale: english)
        }
        #expect(grounded("Term Deposit 4.75% Mar 2027 holds 20,000 AUD."))
        #expect(grounded("Fidelity 401k holds 31,000 AUD."))
        // The label's "26" is a year's last two digits, not a percentage;
        // its "4.75" is a percentage, not an amount.
        #expect(!grounded("The term deposit is 26% of holdings."))
        #expect(!grounded("The term deposit earned 4.75 AUD."))
    }

    @Test("Days counted with 日 are the horizon, and a horizon may be said in weeks or months")
    func horizon() {
        // 日 marks a day of the month and counts days; the first reading of
        // it knew only the first, and every Japanese headline the model
        // wrote said "90日間".
        #expect(outlook("日常口座の90日間の予測で、最終的な残高は8069から9420に増加する見込みです。", japanese))
        #expect(outlook("未来90日内余额预计升至9420。", chinese))
        #expect(!outlook("今後45日間で残高は9420に増える見込みです。", japanese))
        #expect(outlook("Over the next 3 months the balance grows by 1,351 AUD.", english))
        #expect(outlook("Over about 13 weeks the balance rises to 9,420 AUD.", english))
        #expect(!outlook("Over the next 6 months the balance grows by 1,351 AUD.", english))
        #expect(ForecastNarrator.horizonCounts(days: 90) == [90, 13, 3])
        // Thirty days is a month, and not four weeks.
        #expect(ForecastNarrator.horizonCounts(days: 30) == [30, 1])
        #expect(ForecastNarrator.horizonCounts(days: 28) == [28, 4, 1])
        #expect(ForecastNarrator.horizonCounts(days: 45) == [45])
        #expect(ForecastNarrator.horizonCounts(days: 365) == [365, 52, 12])
    }

    @Test("How many things were listed may be said")
    func counts() {
        #expect(note("The 2 largest line items are salary and housing.", english))
        #expect(outlook("There are 2 scheduled movements in the next 90 days.", english))
        #expect(!outlook("There are 7 scheduled movements in the next 90 days.", english))
    }
}

extension Live {
/// The narrators on the real on-device model, in each language the app is
/// translated into. Apple, "Supporting languages and locales": "thoroughly
/// test your instructions to ensure the model is responding in the way you
/// expect." Synthetic figures throughout.
///
/// What a narrator returns has already passed its own number check, so
/// applying the check again here would assert nothing. What is asserted is
/// what the check cannot guarantee: that the model, in this language, can
/// write *something* the check accepts, and that it comes back in the
/// language asked — judged by an oracle that is not the one the code uses
/// (`Fixtures.reads(_:as:)`).
///
/// A narration is asked for up to three times before either is called a
/// failure, because one narration failing is the contract working:
///
/// - **Nothing sound in three drafts.** The narrator then says so and the
///   slide keeps its own headline. This used to fail the test, and it is
///   not rare: of 64 review drafts on 12 October the check declined ten —
///   four of the eight in Chinese, where the model works out shares it was
///   told not to. Half of all drafts declined is three in a row one
///   narration in eight, so a run of seven languages failed about one time
///   in six with nothing wrong (it did, in German and Japanese, in the
///   sweep before a commit that had not touched this package).
/// - **Sound, in the wrong language.** A narrator that gets three such
///   drafts in a row returns the first of them, by design. In the same
///   day's earlier survey one draft in sixty-three outside English came
///   back in English.
///
/// Nine drafts all declined is a different matter, and still fails.
@Suite("Prose comes back in the person's language", .enabled(if: Fixtures.modelAvailable),
       .timeLimit(.minutes(10)), .serialized)
struct LiveLanguageTests {

    /// `ask`'s answer: the first of up to three narrations that is in the
    /// language. Failing that, the last one that was at least sound — for
    /// the caller's language expectation to fail on, with the text — and
    /// failing that, the narrator's own "nothing sound".
    ///
    /// Only that outcome is asked about again. A model that is unavailable,
    /// busy or refusing is not a draft, and is thrown at once.
    private func narrated<Answer>(in identifier: String, text: (Answer) -> String,
                                  _ ask: () async throws -> Answer) async throws -> Answer {
        try await LanguageModels.$localeOverride.withValue(Locale(identifier: identifier)) {
            var sound: Answer?
            var declined: IntelligenceError?
            for _ in 0..<3 {
                do {
                    let answer = try await ask()
                    if Fixtures.reads(text(answer), as: identifier) { return answer }
                    sound = answer
                } catch let error as IntelligenceError {
                    guard case .modelFailure = error else { throw error }
                    declined = error
                }
            }
            if let sound { return sound }
            throw declined ?? IntelligenceError.modelFailure("no narration")
        }
    }

    @Test("Report notes", arguments: Fixtures.translatedLocales)
    func reportNotes(identifier: String) async throws {
        let notes = try await narrated(in: identifier, text: { $0.joined(separator: " ") }) {
            try await ReportNarrator.narrate(facts: Fixtures.income)
        }
        #expect(!notes.isEmpty)
        #expect(Fixtures.reads(notes.joined(separator: " "), as: identifier), "got \(notes)")
    }

    @Test("A forecast outlook", arguments: Fixtures.translatedLocales)
    func forecastOutlook(identifier: String) async throws {
        let text: (ForecastInsights) -> String = { ([$0.headline] + $0.insights).joined(separator: " ") }
        let result = try await narrated(in: identifier, text: text) {
            try await ForecastNarrator.narrate(facts: Fixtures.forecast)
        }
        #expect(!result.headline.isEmpty)
        #expect(Fixtures.reads(text(result), as: identifier), "got \(text(result))")
    }

    @Test("A review slide", arguments: Fixtures.translatedLocales)
    func reviewSlide(identifier: String) async throws {
        let text: (ReviewSlideStory) -> String = { $0.headline + " " + $0.insight }
        let story = try await narrated(in: identifier, text: text) {
            try await ReviewNarrator.story(facts: Fixtures.spending)
        }
        #expect(Fixtures.reads(text(story), as: identifier), "got \(text(story))")
    }

    @Test("A budget has exactly the categories it was asked about, in the language",
          arguments: ["ja_JP", "fr_FR"])
    func budget(identifier: String) async throws {
        try await LanguageModels.$localeOverride.withValue(Locale(identifier: identifier)) {
            let clock = ContinuousClock()
            var suggestion: BudgetSuggestion?
            let elapsed = try await clock.measure {
                suggestion = try await BudgetAdvisor.suggest(
                    history: Fixtures.spendingHistory(), monthlyIncome: Fixtures.monthlyIncome,
                    currencyCode: "AUD")
            }
            let result = try #require(suggestion)
            // In Japanese this request ran for 221 seconds and overflowed the
            // window before the answer's row count was fixed to the request's.
            #expect(result.lines.count == 2, "got \(result.lines.map(\.fullName))")
            #expect(elapsed < .seconds(60), "took \(elapsed)")
            #expect(Fixtures.reads(result.summary, as: identifier), "got \(result.summary)")
        }
    }
}
}
