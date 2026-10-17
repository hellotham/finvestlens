//
//  FigureAttributionTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Two kinds of sentence again, and the comments say which.
//
//  "The model wrote": the macOS 27 on-device model wrote it from the
//  synthetic figures in `Fixtures`, in the survey of 12 October 2026, and
//  the number check accepted it — every number in it is one of the facts.
//  Recovered from that survey's output on 17 October 2026.
//
//  "Built": a sentence in the same construction, written to say what the
//  check reads in a language the model was not caught in, or what it must
//  leave alone.
//

import Foundation
import Testing
@testable import FinvestLensIntelligence

@Suite("A number that is one of the facts, said of the wrong thing")
struct FigureAttributionTests {

    private func misattributes(_ text: String, _ identifier: String, falling: Bool = false) -> Bool {
        let facts = falling ? Fixtures.fallingForecast : Fixtures.forecast
        let locale = Locale(identifier: identifier)
        #expect(ForecastNarrator.isGrounded(text, facts: facts, locale: locale),
                "every number in it has to be one of the forecast's for this to test anything: \(text)")
        return ForecastNarrator.misattributes(text, facts: facts, locale: locale)
    }

    // MARK: - A level given as the size of a change

    @Test("A balance given as the size of the rise is declined", arguments: [
        // The model wrote: the closing balance, 9,420, as how far it rises.
        ("El saldo final proyectado supera el saldo inicial en 9420 AUD tras 90 días.", "es_ES"),
        ("El saldo final es esperado que supere el saldo inicial en 9420 AUD tras el periodo de 90 días.", "es_ES"),
        ("Il saldo previsto per la fine del periodo è superiore di 9420 rispetto al saldo iniziale.", "it_IT"),
        ("Il saldo previsto per la fine del periodo è superiore di 9420 rispetto al saldo iniziale, con una variazione netta di 1351.", "it_IT"),
        // Built: the same mistake in the other six languages.
        ("The Everyday balance is expected to end higher by 9,420 AUD.", "en_AU"),
        ("The Everyday balance will end 9,420 AUD higher than today.", "en_AU"),
        ("Der Kontostand von Everyday steigt in 90 Tagen um 9.420 AUD.", "de_DE"),
        ("Le solde du compte Everyday devrait augmenter de 9 420 AUD sur 90 jours.", "fr_FR"),
        ("O saldo final do Everyday é maior em 9.420 AUD do que o saldo atual.", "pt_BR"),
        ("日常口座の残高は90日で9420の増加が見込まれる。", "ja_JP"),
        ("日常账户90天内预计增长9420。", "zh_Hans_CN"),
    ])
    func levelAsChange(text: String, identifier: String) {
        #expect(misattributes(text, identifier))
    }

    @Test("A change said as a change, a level reached, or a range, is not declined", arguments: [
        // The model wrote each of these, and each is true.
        ("Everyday account balance is projected to rise by 1351 over the next 90 days, reaching 9420 by the end of the forecast.", "en_AU", false),
        ("The Everyday account balance is expected to decline by 3315 over the next 90 days, with a projected end balance of 6105 AUD.", "en_AU", true),
        ("Das Konto Everyday weist einen Rückgang von 3315 auf 6105 aus.", "de_DE", true),
        ("Das Konto Everyday (AUD) zeigt eine positive Entwicklung mit einem prognostizierten Endstand von 9420 nach einem aktuellen Stand von 8069.", "de_DE", false),
        ("Das Konto Everyday verzeichnet ein Wachstum von 1351 AUD über 90 Tage.", "de_DE", false),
        ("Le solde attendu dépasse le solde actuel de 1351 unités.", "fr_FR", false),
        ("Le solde du compte Everyday diminuera de 3315 AUD sur une période de 90 jours.", "fr_FR", true),
        ("El saldo proyectado aumenta a 9420 AUD tras recibir el salario el 15 de agosto.", "es_ES", false),
        ("El saldo final en la cuenta Everyday caerá 3315 AUD durante el próximo periodo de 90 días.", "es_ES", true),
        ("El saldo final es menor que el inicial, con un mínimo proyectado en 2480 AUD.", "es_ES", true),
        ("El saldo esperado alcanza los 9420 AUD tras una variación de 1351 durante los próximos 90 días.", "es_ES", false),
        ("Il saldo finale per Everyday (AUD) è previsto a 9420 dopo un aumento di 1351 rispetto al saldo iniziale.", "it_IT", false),
        ("Il saldo previsto per la fine del periodo è superiore al saldo iniziale di 1351 unità.", "it_IT", false),
        ("Il saldo medio è in calo, con un minimo previsto di 2480 AUD entro il 21 agosto.", "it_IT", true),
        ("Saldo projetado em Everyday (AUD) cai de 9420 para 6105 em 90 dias.", "pt_BR", true),
        ("Saldo projetado para o Everyday em 90 dias é menor em 3315 AUD do que o saldo atual.", "pt_BR", true),
        ("Saldo projetado aumenta para 9420 em 90 dias, com variação positiva de 1351.", "pt_BR", false),
        ("日常口座の90日間の予測で、最終的な残高は8069から9420に増加する見込みです。", "ja_JP", false),
        (" everyday アカウントの90日間の予測で、開始時の8069から終了時の9420へと1351の増加が見込まれる。", "ja_JP", false),
        ("日常口座の残高は90日で3315ドル減少する見込みです。", "ja_JP", true),
        ("日常账户90天内预计增长至9420，最低点为3105。", "zh_Hans_CN", false),
        ("日常账户90天内预计余额下降3315，最低点为2480。", "zh_Hans_CN", true),
    ])
    func changeAsChange(text: String, identifier: String, falling: Bool) {
        #expect(!misattributes(text, identifier, falling: falling))
    }

    @Test("A movement or the monthly net is a change, and may be said as one")
    func otherChanges() {
        // Built: the rent and the average month are changes, not levels.
        #expect(!misattributes("The balance drops by 2,600 AUD when rent is paid on 1 Aug.", "en_AU"))
        #expect(!misattributes("Der Saldo wächst monatlich um 450 AUD.", "de_DE"))
    }

    // MARK: - A negative balance that is not

    @Test("A negative balance, in a forecast whose balance stays above zero, is declined")
    func negativeBalance() {
        // The model wrote it: the lowest point of this forecast is 2,480.
        #expect(misattributes("Das Konto Everyday weist einen negativen Saldo aus und ein niedrigstes Niveau von 2480 AUD am 21. Aug. auf.",
                              "de_DE", falling: true))
        // The model wrote it too, and it is true: the change is negative.
        #expect(!misattributes("Das Konto Everyday weist einen negativen Saldoänderungstrend auf, wobei der niedrigste Stand von 2480 am 21. Aug. erwartet wird.",
                               "de_DE", falling: true))
        // Built: saying the balance stays above zero is the true thing to say.
        #expect(!misattributes("The balance never falls below zero; its lowest point is 2,480 AUD.", "en_AU", falling: true))
        #expect(!misattributes("Der Saldo wird nicht negativ.", "de_DE", falling: true))
        #expect(misattributes("El saldo será negativo a finales de agosto.", "es_ES", falling: true))
        #expect(misattributes("残高がマイナスになる見込みです。", "ja_JP", falling: true))
    }

    @Test("A negative balance is not declined where the forecast does go below zero")
    func negativeBalanceThatIs() {
        var facts = Fixtures.fallingForecast
        facts.lowestBalance = -480
        #expect(!ForecastNarrator.misattributes("The balance turns negative on 21 Aug, at -480 AUD.", facts: facts,
                                                locale: Locale(identifier: "en_AU")))
    }

    // MARK: - A comparison its own figures contradict

    private func comparesFalsely(_ text: String, _ identifier: String) -> Bool {
        let story = ReviewSlideStory(headline: "", insight: text)
        let locale = Locale(identifier: identifier)
        #expect(ReviewStoryValidator.isGrounded(story, facts: Fixtures.highlights, locale: locale),
                "every number in it has to be one of the slide's for this to test anything: \(text)")
        return ReviewStoryValidator.misattributes(story, facts: Fixtures.highlights, locale: locale)
    }

    @Test("Two of the slide's figures compared the wrong way round are declined", arguments: [
        // The model wrote these: expenses of 66.6k above an opening net worth
        // of 381.2k — or above themselves.
        ("As despesas totalizaram 66.6k AUD, acima do valor inicial de 381.2k AUD.", "pt_BR"),
        ("As despesas totalizaram 66,6 mil AUD, acima do valor inicial de 381,2 mil AUD.", "pt_BR"),
        ("As despesas totalizaram 66.6 mil AUD, acima do valor inicial de 66.6 mil AUD.", "pt_BR"),
        // Built: the same sentence in the other languages.
        ("Expenses were 66.6k AUD, above the opening net worth of 381.2k AUD.", "en_AU"),
        ("Die Ausgaben betrugen 66,6 Tsd. AUD, über dem Anfangsvermögen von 381,2 Tsd. AUD.", "de_DE"),
        ("Les dépenses s'élèvent à 66 611 AUD, au-dessus de la valeur nette d'ouverture de 381 200 AUD.", "fr_FR"),
        ("Los gastos fueron de 66.611 AUD, por encima del patrimonio inicial de 381.200 AUD.", "es_ES"),
        ("Le spese sono state di 66.611 AUD, al di sopra del patrimonio iniziale di 381.200 AUD.", "it_IT"),
        ("支出は66,611ドルで、期首の純資産381,200ドルを上回った。", "ja_JP"),
        ("支出为66,611澳元，高于期初净资产381,200澳元。", "zh_Hans_CN"),
        ("Net worth of 381.2k AUD was below expenses of 66.6k AUD.", "en_AU"),
    ])
    func falseComparison(text: String, identifier: String) {
        #expect(comparesFalsely(text, identifier))
    }

    @Test("A true comparison, or one that is not between the two figures, is not declined")
    func trueOrNotAComparison() {
        // Built: true.
        #expect(!comparesFalsely("Net worth of 412.4k AUD is above the opening 381.2k AUD.", "en_AU"))
        #expect(!comparesFalsely("O patrimônio líquido de 412,4 mil AUD ficou acima do valor inicial de 381,2 mil AUD.", "pt_BR"))
        #expect(!comparesFalsely("Income of 90.6k AUD exceeded expenses of 66.6k AUD.", "en_AU"))
        #expect(!comparesFalsely("支出为66,611澳元，低于收入90,644澳元。", "zh_Hans_CN"))
        // The size of a difference, right beside "above": not a claim that
        // 31.2k is more than 381.2k.
        #expect(!comparesFalsely("Net worth ended 31.2k AUD above the opening 381.2k AUD.", "en_AU"))
        // A change is not what is compared, and nor is a difference after "by".
        #expect(!comparesFalsely("Net worth rose by 31.1k AUD, above the opening 381.2k AUD.", "en_AU"))
        #expect(!comparesFalsely("Income of 90.6k AUD exceeded expenses by 24.0k AUD.", "en_AU"))
        // A fraction or a multiple of the second, and a negation.
        #expect(!comparesFalsely("Expenses of 66.6k AUD were more than a sixth of the opening 381.2k AUD.", "en_AU"))
        #expect(!comparesFalsely("Expenses of 66.6k AUD were not above the opening net worth of 381.2k AUD.", "en_AU"))
        // Two sentences: nothing compares one with the other.
        #expect(!comparesFalsely("Expenses were 66.6k AUD. Above all, the opening net worth of 381.2k AUD held.", "en_AU"))
    }

    @Test("Report notes and forecast outlooks are read for the same comparison")
    func otherNarrators() {
        let english = Locale(identifier: "en_AU")
        // Built.
        #expect(!ReportNarrator.isSound("Income of 90,643.50 AUD was below expenses of 66,610.82 AUD.",
                                        facts: Fixtures.income, locale: english))
        #expect(ReportNarrator.isSound("Income of 90,643.50 AUD exceeded expenses of 66,610.82 AUD.",
                                       facts: Fixtures.income, locale: english))
        #expect(misattributes("The lowest point, 3,105 AUD, is above today's 8,069 AUD.", "en_AU"))
        #expect(!misattributes("The lowest point, 3,105 AUD, is below today's 8,069 AUD.", "en_AU"))
    }

    // MARK: - The numbers the number check read

    @Test("A number read as the number check read it: split at a separator, or written across 万")
    func readAsTheNumberCheckReadIt() {
        // Built. The Chinese comma makes "9420，8" one run; the number check
        // takes it apart into the closing balance and the month, and so must
        // this — the 17 October review found the date hid the "增长".
        #expect(misattributes("日常账户90天内预计增长9420，8月15日收到工资。", "zh_Hans_CN"))
        // "6万6611" and "38万1200" are 66,611 and 381,200, as the number
        // check reads them — not four numbers, two of them no figure at all.
        #expect(comparesFalsely("支出为6万6611澳元，高于期初净资产38万1200澳元。", "zh_Hans_CN"))
        // "TAUD" is thousands of AUD, which the number check knows; the
        // comparison after it is read.
        #expect(comparesFalsely("Die Ausgaben betrugen 66,6 TAUD, über dem Anfangsvermögen von 381,2 TAUD.", "de_DE"))
        // A range with "A$" in it is still a range: 9,420 is where the
        // falling balance starts.
        #expect(!misattributes("Der Saldo zeigt einen Rückgang von A$ 9.420 auf A$ 6.105.", "de_DE", falling: true))
    }

    @Test("Japanese: the second order, where the first figure is what the second is measured against")
    func japaneseSubjectOrder() {
        // The model wrote it, in all four drafts of the opening slide
        // (17 October 2026): expenses above income.
        #expect(comparesFalsely("純資産は31,150.4 AUD増加し、収入90,643.5 AUDに対し支出66,610.82 AUDが上回った。", "ja_JP"))
        #expect(comparesFalsely("収益90,643.5 AUDに対して費用66,610.82 AUDが上回る構造となった。", "ja_JP"))
        // Built: the true way round, and the first order still read.
        #expect(!comparesFalsely("収入90,643.5 AUDに対し支出66,610.82 AUDが下回った。", "ja_JP"))
        #expect(comparesFalsely("支出は66,611ドルで、期首の純資産381,200ドルを上回った。", "ja_JP"))
    }

    @Test("A slide's balance given as the size of a difference is declined")
    func slideBalanceAsDifference() {
        // The model wrote it on the bridge slide (17 October 2026): the
        // opening net worth as how far the total exceeded it.
        let story = ReviewSlideStory(headline: "",
                                     insight: "O valor total superou o início do período em 381.200 AUD.")
        let portuguese = Locale(identifier: "pt_BR")
        #expect(ReviewStoryValidator.isGrounded(story, facts: Fixtures.bridge, locale: portuguese))
        #expect(ReviewStoryValidator.misattributes(story, facts: Fixtures.bridge, locale: portuguese))
        // The change, said as a change, is the change.
        #expect(!ReviewStoryValidator.misattributes(
            ReviewSlideStory(headline: "", insight: "O patrimônio líquido aumentou em 31.150,4 AUD."),
            facts: Fixtures.bridge, locale: portuguese))
    }

    // MARK: - A change said the other way

    @Test("A change said to go the other way from the one it quotes is declined")
    func changeTheWrongWay() {
        // The model wrote it on the bridge slide (17 October 2026): net
        // worth rose by 31,150.4, and the draft calls that a decrease.
        let spanish = Locale(identifier: "es_ES")
        let story = ReviewSlideStory(headline: "", insight:
            "El patrimonio neto alcanzó 412.350,4 AUD, tras una disminución de 31.150,4 AUD respecto al periodo anterior.")
        #expect(ReviewStoryValidator.isGrounded(story, facts: Fixtures.bridge, locale: spanish))
        #expect(ReviewStoryValidator.misattributes(story, facts: Fixtures.bridge, locale: spanish))
        // Built: a forecast's change the wrong way round, either way.
        #expect(misattributes("The balance rises by 3315 AUD over 90 days.", "en_AU", falling: true))
        #expect(misattributes("Le solde diminuera de 1351 AUD sur 90 jours.", "fr_FR"))
        #expect(misattributes("日常账户90天内预计余额下降1351澳元。", "zh_Hans_CN"))
        // The way it went, and money out said as going down, are left alone —
        // and so is a comparative, which measures a difference, not a change
        // of direction. The model wrote this one, and it is true.
        #expect(!misattributes("平均して毎月の支出が収入を1100 AUD上回っています。", "ja_JP", falling: true))
        #expect(!misattributes("The balance drops by 2,600 AUD when rent is paid on 1 Aug.", "en_AU"))
        #expect(!misattributes("Le solde diminuera de 3315 AUD sur 90 jours.", "fr_FR", falling: true))
        #expect(!ReviewStoryValidator.misattributes(
            ReviewSlideStory(headline: "", insight: "Expenses brought a reduction of 66,610.82 AUD in net worth."),
            facts: Fixtures.bridge, locale: Locale(identifier: "en_AU")))
    }

    // MARK: - The prompts

    @Test("The forecast reaches the model with its directions in words, and no minus sign")
    func forecastPrompt() {
        LanguageModels.$localeOverride.withValue(Locale(identifier: "en_AU")) {
            let rising = ForecastNarrator.prompt(for: Fixtures.forecast)
            #expect(rising.contains("Projected balance at the end: 9420 AUD — up 1351 AUD on today's balance"))
            #expect(rising.contains("income exceeded spending by 450 AUD a month"))
            #expect(rising.contains("Rent — 2600 AUD out"))
            #expect(rising.contains("Salary — 5200 AUD in"))
            let falling = ForecastNarrator.prompt(for: Fixtures.fallingForecast)
            #expect(falling.contains("— down 3315 AUD on today's balance"))
            #expect(falling.contains("spending exceeded income by 1100 AUD a month"))
            for prompt in [rising, falling] {
                #expect(prompt.range(of: #"-\d"#, options: .regularExpression) == nil, "a minus sign: \(prompt)")
            }
        }
    }

    @Test("A figure that is one of the others less another says so; roles go on their lines")
    func relationsAndRoles() {
        let highlights = ReviewNarrator.prompt(for: Fixtures.highlights)
        #expect(highlights.contains("- Net surplus: 24032.68 AUD — Income less Expenses"))
        #expect(highlights.contains("- Change in net worth: 31150.4 AUD — the change over the period; Net worth less Opening net worth"))
        #expect(highlights.contains("- Expenses: 66610.82 AUD — money out over the period\n"),
                "expenses are not also 'Income less Net surplus'")
        #expect(highlights.contains("- Net worth: 412350.4 AUD — as at the end of the period; up 8.2% on the prior period"))
        let bridge = ReviewNarrator.prompt(for: Fixtures.bridge)
        #expect(bridge.contains("- Opening net worth: 381200 AUD — as at the start of the period\n"))
        #expect(bridge.contains("- Valuation and currency movement: 7117.72 AUD — value added over the period, not money in"))
        #expect(bridge.contains("- Change in net worth: 31150.4 AUD — the change over the period; Closing net worth less Opening net worth"))
        let report = ReportNarrator.prompt(for: Fixtures.income)
        #expect(report.contains("- Net income: 24032.68 AUD — Income less Expenses"))
        #expect(report.contains("- Expenses: 66610.82 AUD — money out over the period\n"))
        #expect(report.contains("- Expenses:Housing: 25680 AUD — money out over the period"))
        // No role word that reads as a name, and no word of the period in the
        // instructions every slide shares: the investment slides' money in is
        // a lifetime total (17 October review).
        for prompt in [highlights, bridge, report] { #expect(!prompt.contains("a balance")) }
        #expect(!ReviewNarrator.instructions.contains("totals for the period"))
    }

    @Test("A relation is the one the slide gives, whatever the sizes")
    func relationsAreGiven() {
        // Built: a savings rate over a half, where the old rule — the
        // smaller of two — called expenses "Income less Net surplus".
        let thrifty = ReviewSlideFacts(
            kicker: "Highlights", periodLabel: "FY 2025–26", currencyCode: "AUD",
            figures: [("Income", 100_000), ("Expenses", 30_000), ("Net surplus", 70_000)],
            roles: ["Income": .inflow, "Expenses": .outflow],
            relations: ["Net surplus": FigureRelation("Income", less: "Expenses")])
        let prompt = ReviewNarrator.prompt(for: thrifty)
        #expect(prompt.contains("- Net surplus: 70000 AUD — Income less Expenses"))
        #expect(prompt.contains("- Expenses: 30000 AUD — money out over the period\n"))
        let english = Locale(identifier: "en_AU")
        #expect(ReviewStoryValidator.misattributes(ReviewSlideStory(headline: "", insight: "The net surplus fell by 70,000 AUD."),
                                                   facts: thrifty, locale: english))
        // A balance sheet: equity is assets less liabilities, and either may
        // be said as the other's distance from assets — neither rises.
        let position = ReviewSlideFacts(
            kicker: "Financial position", periodLabel: "FY 2025–26", currencyCode: "AUD",
            figures: [("Assets", 1_000_000), ("Liabilities", 200_000), ("Net worth", 800_000)],
            roles: ["Assets": .balance, "Liabilities": .balance, "Net worth": .balance],
            relations: ["Net worth": FigureRelation("Assets", less: "Liabilities")])
        #expect(ReviewNarrator.prompt(for: position).contains("- Net worth: 800000 AUD — as at the end of the period; Assets less Liabilities"))
        #expect(!ReviewStoryValidator.misattributes(
            ReviewSlideStory(headline: "", insight: "Net worth is 800,000 AUD, 200,000 AUD less than assets of 1,000,000 AUD."),
            facts: position, locale: english))
        #expect(ReviewStoryValidator.misattributes(
            ReviewSlideStory(headline: "", insight: "Net worth rose by 1,000,000 AUD."), facts: position, locale: english))
    }

    @Test("The forecast gives each movement's balance and the horizon's totals")
    func forecastBalances() {
        LanguageModels.$localeOverride.withValue(Locale(identifier: "en_AU")) {
            let prompt = ForecastNarrator.prompt(for: Fixtures.forecast)
            #expect(prompt.contains("Rent — 2600 AUD out, leaving 5469 AUD"))
            #expect(prompt.contains("Salary — 5200 AUD in, leaving 8305 AUD"))
            #expect(prompt.contains("Scheduled over the horizon: 6315 AUD in, 4964 AUD out"))
        }
        // The model worked these out for itself on 17 October; now they are
        // the forecast's own figures, and a balance reached is a level.
        #expect(!misattributes("Rent on 1 Aug reduces the balance to 5,469 AUD.", "en_AU"))
        #expect(!misattributes("Scheduled spending totals 4,964 AUD over the horizon.", "en_AU"))
        #expect(misattributes("The balance rises by 5,469 AUD after rent.", "en_AU"))
    }

    // MARK: - The 17 October review's sentences

    // Built, each from a probe of the review: one sentence the check read
    // wrongly, and beside it the control it read rightly.

    @Test("A negation counts in its own language, and only as a word")
    func negationsAsWords() {
        // Characters of a negation that negate nothing.
        #expect(misattributes("日常账户未来90天余额为负。", "zh_Hans_CN", falling: true))
        #expect(misattributes("余额不断下降，8月21日余额为负。", "zh_Hans_CN", falling: true))
        #expect(misattributes("8月21日には残高がマイナスになるはずです。", "ja_JP", falling: true))
        #expect(misattributes("まず、残高が一時マイナスになる見込みです。", "ja_JP", falling: true))
        #expect(misattributes("残高がわずかにマイナスになる見込みです。", "ja_JP", falling: true))
        // English "no" is not Portuguese "no" (em + o).
        #expect(misattributes("O saldo será negativo no final de agosto.", "pt_BR", falling: true))
        #expect(misattributes("O saldo ficará no vermelho em agosto.", "pt_BR", falling: true))
        // Negations that do negate.
        #expect(!misattributes("余额不会为负。", "zh_Hans_CN", falling: true))
        #expect(!misattributes("不会出现负余额。", "zh_Hans_CN", falling: true))
        #expect(!misattributes("残高がマイナスになることはない見込みです。", "ja_JP", falling: true))
        #expect(!misattributes("O saldo nunca fica no vermelho.", "pt_BR", falling: true))
        // The apostrophe either way.
        #expect(!misattributes("The balance won’t fall below zero; its lowest point is 3,105 AUD.", "en_AU"))
        #expect(!misattributes("The balance doesn’t go into the red.", "en_AU"))
    }

    @Test("A change and where it ends is not a range; nor is a figure and a date")
    func byAndTo() {
        // A level as the change, with its end after it.
        #expect(misattributes("The balance rises by 8,069 AUD to 9,420 AUD over 90 days.", "en_AU"))
        #expect(misattributes("Der Saldo steigt um 8.069 AUD auf 9.420 AUD.", "de_DE"))
        #expect(misattributes("日常账户余额增长8069澳元至9420澳元。", "zh_Hans_CN"))
        // A change the wrong way, with its end after it.
        #expect(misattributes("The balance falls by 1,351 AUD to 9,420 AUD.", "en_AU"))
        #expect(misattributes("Der Saldo sinkt um 1.351 AUD auf 9.420 AUD.", "de_DE"))
        #expect(misattributes("El saldo disminuye en 1.351 AUD hasta 9.420 AUD.", "es_ES"))
        #expect(misattributes("日常账户余额下降1351澳元至9420澳元。", "zh_Hans_CN"))
        // A date is not the other end of a range.
        #expect(misattributes("El saldo final supera al inicial en 9420 AUD a 15 de agosto.", "es_ES"))
        // True: the change and its end.
        #expect(!misattributes("The balance rises by 1,351 AUD to 9,420 AUD.", "en_AU"))
        #expect(!misattributes("Der Saldo steigt um 1.351 AUD auf 9.420 AUD.", "de_DE"))
        #expect(!misattributes("El saldo pasa de 8069 AUD a 9420 AUD.", "es_ES"))
    }

    @Test("Words of direction in the forms a forecast uses")
    func directionForms() {
        #expect(misattributes("The balance is expected to fall by 1,351 AUD over 90 days.", "en_AU"))
        #expect(misattributes("The balance will decline by 1,351 AUD.", "en_AU"))
        #expect(misattributes("The balance is down by 1,351 AUD.", "en_AU"))
        #expect(misattributes("The balance is projected to rise by 3,315 AUD.", "en_AU", falling: true))
        // French "bas", masculine as "solde" is.
        #expect(misattributes("Le solde final sera plus bas de 6 105 AUD que le solde actuel.", "fr_FR", falling: true))
    }

    @Test("A superlative, or a second clause, is not a change")
    func notChanges() {
        #expect(!misattributes("El saldo alcanzará su punto más bajo en 3105 AUD el 2 de agosto.", "es_ES"))
        #expect(!misattributes("O saldo atingirá seu ponto mais baixo em 3.105 AUD em 2 de agosto.", "pt_BR"))
        #expect(!misattributes("El saldo final supera al inicial y se sitúa en 9420 AUD.", "es_ES"))
        #expect(!misattributes("O saldo final supera o inicial e fica em 9.420 AUD.", "pt_BR"))
        // The construction the list is for is still read.
        #expect(misattributes("El saldo final proyectado supera el saldo inicial en 9420 AUD tras 90 días.", "es_ES"))
    }

    @Test("The unit after a number is stepped over as the number check reads it")
    func unitsAfterNumbers() {
        #expect(comparesFalsely("Die Ausgaben betrugen 66,6 Tsd. A$, über dem Anfangsvermögen von 381,2 Tsd. A$.", "de_DE"))
        #expect(comparesFalsely("Die Ausgaben betrugen 0,07 Millionen AUD, über dem Anfangsvermögen von 0,38 Millionen AUD.", "de_DE"))
        #expect(comparesFalsely("Los gastos fueron de 0,07 millones de AUD, por encima del patrimonio inicial de 0,38 millones de AUD.", "es_ES"))
        #expect(comparesFalsely("Les dépenses s'élèvent à 66\u{2009}611\u{2009}AUD, au-dessus de la valeur nette d'ouverture de 381\u{2009}200\u{2009}AUD.", "fr_FR"))
        #expect(!misattributes("Rückgang von 9.420 A$ auf 6.105 A$.", "de_DE", falling: true))
    }

    @Test("Japanese より少ない, and a multiplier only as a word")
    func japaneseAndMultipliers() {
        #expect(comparesFalsely("純資産は412,350.4ドルで、支出66,611ドルより少ない。", "ja_JP"))
        #expect(comparesFalsely("純資産は412,350.4ドルで、支出66,611ドルより少なかった。", "ja_JP"))
        #expect(!comparesFalsely("支出は66,611ドルで、収入90,644ドルより少ない。", "ja_JP"))
        #expect(!comparesFalsely("支出は66,611ドルで、収入90,644ドルより少なくない。", "ja_JP"))
        #expect(comparesFalsely("Expenses were 66.6k AUD, above the quarterly figure of 381.2k AUD.", "en_AU"))
        #expect(comparesFalsely("上半期の支出は66,611ドルで、期首の純資産381,200ドルを上回った。", "ja_JP"))
    }

    @Test("A sentence ends after a month only in a date")
    func sentenceEnds() {
        #expect(misattributes("No other bills go out. The balance turns negative on 2 Aug.", "en_AU"))
        #expect(!comparesFalsely("Expenses were 66.6k AUD\r\nabove all, the opening net worth of 381.2k AUD held.", "en_AU"))
    }

    @Test("Chinese comparisons in their own order, and figures in brackets")
    func chineseAndBrackets() {
        #expect(comparesFalsely("支出66,610.82澳元高于收入90,643.5澳元。", "zh_Hans_CN"))
        #expect(comparesFalsely("支出66,610.82澳元超过了收入90,643.5澳元。", "zh_Hans_CN"))
        #expect(comparesFalsely("支出66,610.82澳元比收入90,643.5澳元多。", "zh_Hans_CN"))
        #expect(!comparesFalsely("支出66,610.82澳元比收入90,643.5澳元少。", "zh_Hans_CN"))
        #expect(!comparesFalsely("支出66,610.82澳元低于收入90,643.5澳元。", "zh_Hans_CN"))
        #expect(comparesFalsely("Expenses (66,610.82 AUD) exceeded income (90,643.50 AUD).", "en_AU"))
        #expect(!comparesFalsely("Income (90,643.50 AUD) exceeded expenses (66,610.82 AUD).", "en_AU"))
        #expect(comparesFalsely("支出（66,611ドル）は収入（90,644ドル）を上回った。", "ja_JP"))
    }

    @Test("A flow said to be negative is not a balance below zero")
    func negativeFlows() {
        #expect(!misattributes("Las salidas superan a las entradas: un saldo negativo de 1100 AUD al mes.", "es_ES", falling: true))
        #expect(!misattributes("Il saldo mensile è in negativo di 1.100 AUD.", "it_IT", falling: true))
        #expect(!misattributes("Una variazione in negativo di 3.315 AUD.", "it_IT", falling: true))
        #expect(misattributes("El saldo será negativo a finales de agosto.", "es_ES", falling: true))
    }

    @Test("A figure written with a minus sign is compared as negative")
    func signedComparison() {
        var facts = Fixtures.fallingForecast
        facts.lowestBalance = -480
        facts.openingBalance = 300
        let english = Locale(identifier: "en_AU")
        #expect(!ForecastNarrator.misattributes("The lowest point, -480 AUD, is below today's 300 AUD.",
                                                facts: facts, locale: english))
        #expect(ForecastNarrator.misattributes("The lowest point, -480 AUD, is above today's 300 AUD.",
                                               facts: facts, locale: english))
    }
}
