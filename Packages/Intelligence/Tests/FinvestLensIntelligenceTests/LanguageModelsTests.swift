//
//  LanguageModelsTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The parts of the Foundation Models 27 seam that need no model to test:
//  how text is budgeted, what the model is told about the person's language,
//  how each of the framework's error types reads in the app's own words, and
//  that Private Cloud Compute cannot be reached by a build that was not made
//  for it.
//

import Foundation
import Testing
import FoundationModels
@testable import FinvestLensIntelligence

/// Synthetic text of each kind the app reads, with what the macOS 27
/// on-device model counted it at on 12 October 2026 (`tokenCount(for:)`).
/// `LiveBudgetTests` asks the model again; these numbers are what the
/// estimate's weights were fitted to, kept so the fit is checked where there
/// is no model to ask.
enum TokenSamples {
    static func digitRows(_ count: Int) -> String {
        (0..<count).map { "\($0) 2026-08-\(($0 % 28) + 1) 4111-1111-1111-\(1000 + $0) 12,345.67 AUD" }
            .joined(separator: "\n")
    }
    static func statementRows(_ count: Int) -> String {
        (0..<count).map {
            "0\($0 % 9 + 1)/08/2026  EFTPOS WOOLWORTHS 1234 SYDNEY AU   \($0 + 10).45   1,2\($0 + 10).09 CR"
        }.joined(separator: "\n")
    }
    static let all: [(name: String, text: String, modelCount: Int)] = [
        ("English prose", String(repeating: "The quarterly statement shows that household spending settled after a busy winter, and savings grew a little. ", count: 20), 382),
        ("rows of digits", digitRows(40), 1_772),
        ("invoice lines", (0..<40).map { "Item \($0)  Widget, blue (large)   Qty 2   Unit 12.50   GST 2.50   Total 27.50" }.joined(separator: "\n"), 1_550),
        ("bank-statement rows", statementRows(40), 1_760),
        ("German prose", String(repeating: "Die Gesamtausgaben belaufen sich in diesem Geschäftsjahr auf einen niedrigeren Betrag als im Vorjahr. ", count: 20), 462),
        ("Japanese", String(repeating: "総支出は前年度より減少し、住宅費が最も大きな支出項目となっています。", count: 20), 361),
        ("Chinese", String(repeating: "本财年的总支出低于上一财年，住房是最大的支出项目。", count: 20), 321),
    ]
}

@Suite("Token budget")
struct TokenBudgetTests {

    @Test("The estimate is never under what the model counted, on any kind of text the app reads",
          arguments: TokenSamples.all.map(\.name))
    func estimateIsNotUnder(name: String) throws {
        let sample = try #require(TokenSamples.all.first { $0.name == name })
        let estimate = TokenBudget.estimate(sample.text)
        #expect(estimate >= sample.modelCount, "\(name): estimated \(estimate), model \(sample.modelCount)")
        // Nor so far over that it is useless: the first version was fitted
        // to prose and came to a third of the count on digits.
        #expect(estimate <= sample.modelCount * 2, "\(name): estimated \(estimate), model \(sample.modelCount)")
    }

    @Test("Nothing is nothing")
    func empty() {
        #expect(TokenBudget.estimate("") == 0)
    }

    @Test("A statement is cut between rows, never through one")
    func cutsOnLines() {
        let rows = (1...60).map { "Row \($0) of the statement with an amount at the end 1,234.56" }
        let text = rows.joined(separator: "\n")
        let cut = TokenBudget.leading(text, characters: 1_000)
        #expect(cut.truncated)
        #expect(cut.text.count <= 1_000)
        // Whatever was kept ends at the end of a whole row.
        let kept = cut.text.trimmingCharacters(in: .newlines).split(separator: "\n").map(String.init)
        #expect(kept.count > 10)
        #expect(kept == Array(rows.prefix(kept.count)))
    }

    @Test("Windows line endings are line endings")
    func carriageReturns() {
        // "\r\n" is one Character in Swift and equal to neither half.
        let rows = (1...60).map { "Row \($0) 1,234.56" }
        let cut = TokenBudget.leading(rows.joined(separator: "\r\n"), characters: 400)
        let kept = cut.text.split(separator: "\r\n").map(String.init)
        #expect(cut.truncated)
        #expect(kept == Array(rows.prefix(kept.count)))
        #expect(cut.text.hasSuffix("\r\n"))
    }

    @Test("A short cover page does not stand in for the invoice behind it")
    func coverPage() {
        // The first cut took "the first chunk" of a packer that flushed at
        // every page break: a 90-character cover, then nothing.
        let cover = String(repeating: "Invoice cover. ", count: 6)
        let body = (0..<400).map { "Line item \($0): 1 x widget at 12.50 = 12.50 AUD" }.joined(separator: "\n")
        let cut = TokenBudget.leading(cover + "\n\n" + body, characters: 5_000)
        #expect(cut.truncated)
        #expect(cut.text.count > 4_000)
        #expect(cut.text.hasPrefix(cover))
    }

    @Test("Prose with no line breaks is cut at a sentence, and one unbroken run mid-run")
    func otherBoundaries() {
        let prose = String(repeating: "A sentence of ordinary length about nothing in particular. ", count: 40)
        let cut = TokenBudget.leading(prose, characters: 500)
        #expect(cut.truncated)
        #expect(cut.text.hasSuffix("."))
        let unbroken = String(repeating: "7", count: 2_000)
        #expect(TokenBudget.leading(unbroken, characters: 500).text.count == 500)
    }

    @Test("Text that fits is returned whole and unmarked")
    func fitsWhole() {
        let cut = TokenBudget.leading("A short invoice.", characters: 100)
        #expect(cut.text == "A short invoice.")
        #expect(!cut.truncated)
        #expect(TokenBudget.leading("", characters: 0).truncated == false)
    }

    @Test("The input budget is what is left of the window, and never negative")
    func inputBudget() {
        // 8,192 − 300 fixed − 2,000 reply − (64 + 409) margin.
        #expect(TokenBudget.inputTokens(context: 8_192, fixed: 300, reply: 2_000) == 5_419)
        #expect(TokenBudget.inputTokens(context: 4_096, fixed: 3_000, reply: 2_000) == 0)
    }
}

@Suite("What the model is told about language")
struct LanguageInstructionTests {

    @Test("U.S. English adds nothing")
    func unitedStates() {
        let result = LanguageModels.instructions("Base.", for: .reviewNarrator,
                                                 locale: Locale(identifier: "en_US"))
        #expect(result == "Base.")
    }

    @Test("Another English locale gets Apple's locale phrase, first, and no language order")
    func australia() {
        let result = LanguageModels.instructions("Base.", for: .reviewNarrator,
                                                 locale: Locale(identifier: "en_AU"))
        #expect(result == "The person's locale is en_AU.\nBase.")
    }

    @Test("Prose in another language is ordered into that language, before the task and after it", arguments: [
        ("de_DE", "German"), ("fr_FR", "French"), ("ja_JP", "Japanese"),
        ("es_ES", "Spanish"), ("it_IT", "Italian"),
    ])
    func prose(identifier: String, language: String) {
        let result = LanguageModels.instructions("Base.", for: .reportNarrator,
                                                 locale: Locale(identifier: identifier))
        #expect(result == "The person's locale is \(identifier).\nYou MUST respond in \(language).\nBase.\nYou MUST respond in \(language).")
    }

    @Test("Regional and script variants are named, not flattened")
    func variants() throws {
        let brazil = try #require(LanguageModels.instructions(
            "Base.", for: .forecastNarrator, locale: Locale(identifier: "pt_BR")))
        #expect(brazil.hasSuffix("You MUST respond in Brazilian Portuguese."))
        let simplified = try #require(LanguageModels.instructions(
            "Base.", for: .budgetAdvisor, locale: Locale(identifier: "zh_Hans_CN")))
        #expect(simplified.hasSuffix("You MUST respond in Simplified Chinese."))
        let traditional = try #require(LanguageModels.instructions(
            "Base.", for: .budgetAdvisor, locale: Locale(identifier: "zh_Hant_TW")))
        #expect(traditional.hasSuffix("You MUST respond in Traditional Chinese."))
    }

    @Test("A feature that extracts figures is told the locale but not a language")
    func extraction() {
        let result = LanguageModels.instructions("Base.", for: .statementExtractor,
                                                 locale: Locale(identifier: "de_DE"))
        #expect(result == "The person's locale is de_DE.\nBase.")
    }

    @Test("Portuguese is Brazilian unless the language itself says otherwise", arguments: [
        ("pt_BR", "Brazilian Portuguese"), ("pt", "Brazilian Portuguese"), ("pt_AU", "Brazilian Portuguese"),
        ("pt-BR_AU", "Brazilian Portuguese"), ("pt_PT", "European Portuguese"),
        ("pt-PT_AU", "European Portuguese"), ("pt_AO", "European Portuguese"),
    ])
    func portuguese(identifier: String, language: String) {
        // The app's one Portuguese catalog is Brazilian, so a Brazilian
        // abroad — "pt" with an Australian region — reads Brazilian
        // everywhere else on the screen.
        #expect(LanguageModels.responseLanguage(for: Locale(identifier: identifier)) == language)
    }

    @Test("The locale is named by language and region, without the keywords an identifier can carry")
    func localeKeywords() {
        let buddhist = LanguageModels.instructions("Base.", for: .invoiceAnalyzer,
                                                   locale: Locale(identifier: "en_AU@calendar=buddhist"))
        #expect(buddhist == "The person's locale is en_AU.\nBase.")
        #expect(LanguageModels.localeName(Locale(identifier: "ja_JP@calendar=japanese")) == "ja_JP")
        // Whatever Foundation calls the locale, less the keywords.
        let simplified = Locale(identifier: "zh_Hans_CN@numbers=hanidec")
        #expect(LanguageModels.localeName(simplified) == Locale(identifier: "zh_Hans_CN").identifier)
    }

    @Test("The language of an answer is checked, since the order is not always obeyed")
    func languageCheck() {
        let french = Fixtures.french, chinese = Fixtures.chinese
        #expect(LanguageModels.isInPersonLanguage(
            "La dépense totale s'élève à 66 611 AUD pour l'exercice.", locale: french))
        #expect(!LanguageModels.isInPersonLanguage(
            "Total spending remains stable at 66610.82 AUD for the year.", locale: french))
        #expect(LanguageModels.isInPersonLanguage("总支出为66610.82澳元，其中住房支出为最高项。", locale: chinese))
        #expect(!LanguageModels.isInPersonLanguage(
            "Total spending remains stable at 66610.82 AUD for the year.", locale: chinese))
        #expect(!LanguageModels.isInPersonLanguage(
            "Total spending remains stable at 66610.82 AUD for the year.", locale: Fixtures.japanese))
        // Nothing to judge is not a reason to ask again.
        #expect(LanguageModels.isInPersonLanguage("9420", locale: french))
    }

    @Test("Where no language was ordered there is nothing to check", arguments: [
        // Each was called another language — Croatian, Romanian, German —
        // by a recogniser asked about the whole text.
        "VAS 41k AUD, VGS 22k AUD, NDQ 9k AUD", "Total 201.51", "FY 2025–26: 66,611 AUD total",
        "Miete, Lebensmittel und Versicherung: 25,680, 12,481 and 3,105 AUD",
    ])
    func englishIsNotChecked(text: String) {
        #expect(LanguageModels.isInPersonLanguage(text, locale: Fixtures.english))
        #expect(LanguageModels.isInPersonLanguage(text, locale: Locale(identifier: "en_US")))
    }

    @Test("A sentence in the person's language is still theirs when it quotes the book's own names")
    func quotedLabelsAreNotTheLanguage() {
        // Each of these was judged English, and cost two more requests.
        #expect(LanguageModels.isInPersonLanguage(
            "総支出は66,611 AUDで、Expenses:Housingが25,680 AUD、Expenses:Food:Groceriesが12,481 AUDを占めています。",
            quoting: "Expenses:Housing Expenses:Food:Groceries", locale: Fixtures.japanese))
        #expect(LanguageModels.isInPersonLanguage(
            "Everyday 账户余额预计在90天内从8069 AUD增至9420 AUD。8月15日Salary入账5200 AUD。",
            quoting: "Everyday Rent Salary", locale: Fixtures.chinese))
        #expect(LanguageModels.isInPersonLanguage(
            "Net worth : 1 240 000 AUD. Assets 1 500 000 AUD, Liabilities 260 000 AUD.",
            quoting: "Net worth Assets Liabilities", locale: Fixtures.french))
        #expect(LanguageModels.isInPersonLanguage(
            "Le poste Expenses:Housing représente la plus grande part des dépenses de l'exercice, devant Expenses:Food:Groceries.",
            quoting: "Expenses:Housing Expenses:Food:Groceries", locale: Fixtures.french))
        // Quoting the labels does not excuse answering in English.
        #expect(!LanguageModels.isInPersonLanguage(
            "Expenses:Housing is the largest share of spending this year, ahead of Expenses:Food:Groceries.",
            quoting: "Expenses:Housing Expenses:Food:Groceries", locale: Fixtures.french))
        #expect(!LanguageModels.isInPersonLanguage(
            "Expenses:Housing is the largest share of spending this year, ahead of groceries.",
            quoting: "Expenses:Housing Expenses:Food:Groceries", locale: Fixtures.japanese))
    }

    @Test("A request sent with no instructions still has none")
    func noInstructionsStaysNone() {
        #expect(LanguageModels.instructions(nil, for: .documentClassifier,
                                            locale: Locale(identifier: "de_DE")) == nil)
    }
}

@Suite("Foundation Models 27 errors, in the app's words")
struct ErrorMappingTests {

    @Test("Model errors a caller or a person can act on each have their own case")
    func languageModelErrors() {
        let overflow = IntelligenceError.wrap(LanguageModelError.contextSizeExceeded(
            .init(contextSize: 8_192, tokenCount: 9_000, debugDescription: "too long")))
        if case .contextOverflow = overflow {} else { Issue.record("overflow became \(overflow)") }

        let guardrail = IntelligenceError.wrap(LanguageModelError.guardrailViolation(
            .init(debugDescription: "sensitive")))
        if case .guardrailDeclined = guardrail {} else { Issue.record("guardrail became \(guardrail)") }

        let refusal = IntelligenceError.wrap(LanguageModelError.refusal(
            .init(explanation: "I can't help with that.", debugDescription: "refused")))
        if case .guardrailDeclined = refusal {} else { Issue.record("refusal became \(refusal)") }

        let language = IntelligenceError.wrap(LanguageModelError.unsupportedLanguageOrLocale(
            .init(languageCode: .welsh, debugDescription: "cy")))
        if case .unsupportedLanguage = language {} else { Issue.record("language became \(language)") }

        let limited = IntelligenceError.wrap(LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "slow down")))
        if case .busy = limited {} else { Issue.record("rate limit became \(limited)") }

        let timeout = IntelligenceError.wrap(LanguageModelError.timeout(
            .init(debugDescription: "timed out")))
        if case .timedOut = timeout {} else { Issue.record("timeout became \(timeout)") }

        let guide = IntelligenceError.wrap(LanguageModelError.unsupportedGenerationGuide(
            .init(schemaName: "ModelPage", debugDescription: "guide")))
        if case .modelFailure = guide {} else { Issue.record("guide became \(guide)") }
    }

    @Test("Prose with the debris of the model's own output format in it is not prose")
    func cleanProse() {
        #expect(LanguageModels.isCleanProse("総支出は66,611 AUDで、食料品が12,481 AUDである。"))
        #expect(LanguageModels.isCleanProse("Spending fell 8.4% (to 66,611 AUD) — housing led.\nGroceries followed."))
        // What the macOS 27 model appended to a Japanese review slide.
        #expect(!LanguageModels.isCleanProse("前年比の減少は8.4%である。」}<ctrl46>```json<ctrl46>{"))
        #expect(!LanguageModels.isCleanProse("前年比の変動はない。」}"))
        #expect(!LanguageModels.isCleanProse("A sound sentence.\u{07}"))
    }

    @Test("A refusal's explanation is shown only when it is one")
    func explanations() {
        #expect(IntelligenceError.isExplanation("This looks like a medical record, not an invoice."))
        // What the model returned when asked why it refused a synthetic
        // dividend statement: the extraction itself.
        #expect(!IntelligenceError.isExplanation(
            #"{"type": "object", "properties": {"security": "HARBOUR HOLDINGS", "netPayment": "217.00"}}"#))
        #expect(!IntelligenceError.isExplanation("The statement shows a net payment of 1,217.00 on 26/03/2026."))
        #expect(!IntelligenceError.isExplanation(String(repeating: "Because. ", count: 40)))
        #expect(!IntelligenceError.isExplanation(""))
    }

    @Test("A failure of the model itself ends a batch; a failure about one piece of text does not")
    func batchEnding() {
        let ending: [IntelligenceError] = [.unavailable("x"), .busy, .quotaReached(resetDate: nil),
                                           .networkUnavailable]
        let passing: [IntelligenceError] = [.emptyDocument, .guardrailDeclined, .refused("why"),
                                            .contextOverflow, .recognitionFailed("engine"),
                                            .unsupportedLanguage, .timedOut, .modelFailure("detail")]
        for error in ending { #expect(error.endsABatch, "\(error)") }
        for error in passing { #expect(!error.endsABatch, "\(error)") }
        // One unreadable block on a statement page is rejected as an
        // unsupported language, and one slice the model wandered off on
        // times out; neither may cost the pages around it.
        #expect(!IntelligenceError.unsupportedLanguage.endsABatch)
        #expect(!IntelligenceError.wrap(LanguageModelError.timeout(.init(debugDescription: "slow"))).endsABatch)
        // A rate limit is the system's, and the next request meets it too.
        #expect(IntelligenceError.wrap(LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "background"))).endsABatch)
    }

    @Test("The budget's floor is for a model that will not write the plan, not one that is not there")
    func aboutTheRequest() {
        #expect(IntelligenceError.guardrailDeclined.isAboutTheRequest)
        #expect(IntelligenceError.refused("why").isAboutTheRequest)
        #expect(IntelligenceError.unsupportedLanguage.isAboutTheRequest)
        for error in [IntelligenceError.unavailable("x"), .busy, .quotaReached(resetDate: nil),
                      .networkUnavailable, .contextOverflow, .modelFailure("detail")] {
            #expect(!error.isAboutTheRequest, "\(error)")
        }
    }

    @Test("The on-device model's missing assets read as still downloading")
    func assets() {
        let error = IntelligenceError.wrap(SystemLanguageModel.Error.assetsUnavailable(
            .init(debugDescription: "assets")))
        if case .unavailable = error {} else { Issue.record("assets became \(error)") }
    }

    @Test("Private Cloud Compute's quota, network and service failures are told apart")
    func privateCloud() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = IntelligenceError.wrap(PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
            .init(resetDate: reset, debugDescription: "quota")))
        if case .quotaReached(let date) = quota { #expect(date == reset) }
        else { Issue.record("quota became \(quota)") }

        let network = IntelligenceError.wrap(PrivateCloudComputeLanguageModel.Error.networkFailure(
            .init(debugDescription: "offline")))
        if case .networkUnavailable = network {} else { Issue.record("network became \(network)") }

        let service = IntelligenceError.wrap(PrivateCloudComputeLanguageModel.Error.serviceUnavailable(
            .init(debugDescription: "down")))
        if case .unavailable = service {} else { Issue.record("service became \(service)") }
    }

    @Test("Misusing a session is reported, not swallowed")
    func sessionMisuse() {
        let error = IntelligenceError.wrap(LanguageModelSession.Error.concurrentRequests)
        if case .modelFailure = error {} else { Issue.record("session error became \(error)") }
    }

    @Test("The package's own errors pass through untouched")
    func passThrough() {
        if case .emptyDocument = IntelligenceError.wrap(IntelligenceError.emptyDocument) {}
        else { Issue.record("emptyDocument was rewrapped") }
    }

    @Test("Every case has something to say")
    func descriptions() {
        let all: [IntelligenceError] = [
            .unavailable("x"), .emptyDocument, .guardrailDeclined, .refused("why"),
            .contextOverflow, .recognitionFailed("engine"), .unsupportedLanguage, .busy, .timedOut,
            .quotaReached(resetDate: nil), .quotaReached(resetDate: Date()),
            .networkUnavailable, .modelFailure("detail"),
        ]
        for error in all { #expect(!(error.errorDescription ?? "").isEmpty) }
    }
}

@Suite("Which model a feature runs on")
struct ModelChoiceTests {

    @Test("A build that was not made for Private Cloud Compute cannot reach it")
    func gateIsClosed() {
        // Nothing in the test process declares the build flag, and the test
        // host holds no entitlement: the model must not even be created,
        // because its first request without the entitlement ends the process.
        #expect(!LanguageModels.privateCloudComputeEnabled)
        #expect(LanguageModels.privateCloud == nil)
        #expect(LanguageModels.offeredChoices == [.onDevice])
        // The default is Private Cloud Compute only where it can be offered.
        #expect(LanguageModels.defaultChoice == .onDevice)
        if case .unavailable = LanguageModels.availability(of: .privateCloud) {}
        else { Issue.record("Private Cloud Compute reads as available in an unentitled build") }
    }

    @Test("Asking for Private Cloud Compute where it is not offered falls back to the device")
    func fallsBackToDevice() {
        LanguageModels.$choiceOverride.withValue(.privateCloud) {
            for feature in IntelligenceFeature.allCases {
                #expect(LanguageModels.choice(for: feature) == .onDevice)
            }
        }
    }

    @Test("Exactly these features may send what they are given off the device")
    func whatFollowsTheChoice() {
        // A privacy tripwire, written out rather than derived: adding a
        // feature to the set that can leave the device should take editing
        // this list and reading why it exists.
        let following = Set(IntelligenceFeature.allCases.filter(\.followsModelChoice))
        #expect(following == [.invoiceAnalyzer, .dividendExtractor,
                              .reviewNarrator, .reportNarrator, .forecastNarrator, .budgetAdvisor])
        // Work done by the hundred stays on the device: a statement is read
        // a thousand characters a request.
        #expect(!IntelligenceFeature.statementExtractor.followsModelChoice)
        #expect(!IntelligenceFeature.transactionCategorizer.followsModelChoice)
    }

    @Test("In this build nothing leaves the device, whatever is asked for")
    func nothingLeavesTheDevice() {
        LanguageModels.$choiceOverride.withValue(.privateCloud) {
            for feature in IntelligenceFeature.allCases {
                #expect(!LanguageModels.leavesDevice(feature))
            }
        }
    }

    @Test("A stored preference this build cannot honour reads as the build's default")
    func storedChoice() {
        #expect(LanguageModels.choice(stored: nil) == .onDevice)
        #expect(LanguageModels.choice(stored: "") == .onDevice)
        #expect(LanguageModels.choice(stored: "onDevice") == .onDevice)
        // Written by an entitled build, read by one that is not.
        #expect(LanguageModels.choice(stored: "privateCloud") == .onDevice)
        #expect(LanguageModels.choice(stored: "something from a later version") == .onDevice)
    }

    @Test("Extractors answer the same way every time; the narrators do not; nobody calls a tool")
    func sampling() {
        for feature in IntelligenceFeature.allCases {
            let options = feature.options
            #expect(options.toolCallingMode == .disallowed, "\(feature)")
            let greedy = options.samplingMode == .greedy
            let narrates = [.reviewNarrator, .reportNarrator, .forecastNarrator].contains(feature)
            #expect(greedy == !narrates, "\(feature)")
        }
    }
}

@Suite("An exact row count is the macro's schema with one number changed")
struct CountedSchemaTests {

    private func json(_ schema: GenerationSchema) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
    }

    private func array(_ schema: GenerationSchema, _ property: String) throws -> [String: Any] {
        let properties = try #require(try json(schema)["properties"] as? [String: Any])
        return try #require(properties[property] as? [String: Any])
    }

    @Test("The budget's lines are fixed at the number of categories asked about")
    func budget() throws {
        let counted = LanguageModels.countedSchema(for: BudgetAdvisor.ModelBudget.self, property: "lines", count: 3)
        let lines = try array(counted, "lines")
        #expect(lines["minItems"] as? Int == 3)
        #expect(lines["maxItems"] as? Int == 3)

        // Everything else is the macro's, to the letter: the property names,
        // their order, their descriptions, the line type.
        var expected = try json(BudgetAdvisor.ModelBudget.generationSchema)
        var properties = try #require(expected["properties"] as? [String: Any])
        var macroLines = try #require(properties["lines"] as? [String: Any])
        #expect(macroLines["maxItems"] as? Int == BudgetAdvisor.categoryLimit)
        macroLines["minItems"] = 3
        macroLines["maxItems"] = 3
        properties["lines"] = macroLines
        expected["properties"] = properties
        #expect(NSDictionary(dictionary: try json(counted)) == NSDictionary(dictionary: expected))
    }

    @Test("The categoriser's answers are fixed at the size of the batch")
    func categoriser() throws {
        for count in [1, 5, TransactionCategorizer.batchSize] {
            let counted = LanguageModels.countedSchema(
                for: TransactionCategorizer.ModelSuggestions.self, property: "suggestions", count: count)
            let suggestions = try array(counted, "suggestions")
            #expect(suggestions["minItems"] as? Int == count)
            #expect(suggestions["maxItems"] as? Int == count)
        }
        let ceiling = try array(TransactionCategorizer.ModelSuggestions.generationSchema, "suggestions")
        #expect(ceiling["maxItems"] as? Int == TransactionCategorizer.batchSize)
    }

    @Test("A property that is not an array of the type leaves the macro's schema as it was")
    func unknownProperty() throws {
        let untouched = LanguageModels.countedSchema(
            for: BudgetAdvisor.ModelBudget.self, property: "summary", count: 3)
        #expect(NSDictionary(dictionary: try json(untouched))
                == NSDictionary(dictionary: try json(BudgetAdvisor.ModelBudget.generationSchema)))
        let missing = LanguageModels.countedSchema(
            for: BudgetAdvisor.ModelBudget.self, property: "rows", count: 3)
        #expect(NSDictionary(dictionary: try json(missing))
                == NSDictionary(dictionary: try json(BudgetAdvisor.ModelBudget.generationSchema)))
    }

    @Test("An answer shaped by the counted schema decodes into the type")
    func decodes() throws {
        let content = try GeneratedContent(
            json: #"{"lines":[{"category":"Groceries","monthlyAmount":"800","rationale":"Near average."}],"summary":"A plan."}"#)
        let budget = try BudgetAdvisor.ModelBudget(content)
        #expect(budget.lines.count == 1)
        #expect(budget.summary == "A plan.")
    }
}

/// The narrators' shared policy, with drafts scripted instead of generated.
@Suite("Drafting prose: which draft is shown")
struct DraftPolicyTests {

    private struct Scripted {
        var steps: [Result<String?, any Error>]
        var asked = 0
        mutating func next() throws -> String? {
            defer { asked += 1 }
            return try steps[min(asked, steps.count - 1)].get()
        }
    }

    private let frenchText = "La dépense totale de l'exercice atteint un niveau inférieur à celui de l'année précédente."
    private let englishText = "Total spending for the year came in below the level of the year before it."

    private func run(_ steps: [Result<String?, any Error>], locale: Locale = Fixtures.french)
        async throws -> (shown: String, asked: Int) {
        var script = Scripted(steps: steps)
        let shown = try await LanguageModels.$localeOverride.withValue(locale) {
            try await LanguageModels.firstSoundDraft(
                text: { $0 }, quoting: "", nothingSound: .modelFailure("nothing sound")
            ) { try script.next() }
        }
        return (shown, script.asked)
    }

    @Test("A sound draft in the person's language is shown at once")
    func firstDraftWins() async throws {
        let result = try await run([.success(frenchText)])
        #expect(result.shown == frenchText)
        #expect(result.asked == 1)
    }

    @Test("A sound draft in the wrong language is kept while the model is asked again")
    func wrongLanguageIsKeptInHand() async throws {
        let better = try await run([.success(englishText), .success(frenchText)])
        #expect(better.shown == frenchText)
        #expect(better.asked == 2)
        let never = try await run([.success(englishText)])
        #expect(never.shown == englishText)
        #expect(never.asked == 3)
    }

    @Test("A later draft that fails does not cost the sound one in hand")
    func failureKeepsTheDraftInHand() async throws {
        // Each narrator had this loop, and each let the second draft's
        // error throw the first draft away.
        let declined = try await run([.success(englishText), .failure(IntelligenceError.guardrailDeclined)])
        #expect(declined.shown == englishText)
        #expect(declined.asked == 3)
        let gone = try await run([.success(englishText), .failure(IntelligenceError.busy)])
        #expect(gone.shown == englishText)
        // No model to ask: the third draft is not attempted.
        #expect(gone.asked == 2)
    }

    @Test("An unsound draft is never shown, and after the last one the reason is given")
    func nothingSound() async {
        await #expect(throws: IntelligenceError.self) {
            _ = try await run([.success(nil)])
        }
        do {
            _ = try await run([.success(nil), .failure(IntelligenceError.guardrailDeclined), .success(nil)])
            Issue.record("an unsound draft was shown")
        } catch {
            // The failure that happened, not the generic sentence.
            if case IntelligenceError.guardrailDeclined = error {} else { Issue.record("threw \(error)") }
        }
    }

    @Test("Cancelling stops the asking")
    func cancellation() async {
        await #expect(throws: CancellationError.self) {
            _ = try await run([.success(englishText), .failure(CancellationError())])
        }
    }

    @Test("In English the first sound draft is the one, whatever a recogniser would call it")
    func englishIsNotAskedAgain() async throws {
        let result = try await run([.success("VAS 41k AUD, VGS 22k AUD, NDQ 9k AUD")], locale: Fixtures.english)
        #expect(result.asked == 1)
    }
}

extension Live {
@Suite("Budgets measured by the model", .enabled(if: Fixtures.modelAvailable), .serialized)
struct LiveBudgetTests {

    @Generable
    struct Probe: DocumentAnswer {
        static let replyReserve = 2_000
        var answer: String
    }

    private let framing: (String) -> String = { "Invoice text:\n\n\($0)" }

    /// What is left for a document in a `Probe` request, by the model's own
    /// count of the instructions and schema.
    private func budget(_ resolved: LanguageModels.Resolved, instructions: String) async throws -> Int {
        let model = SystemLanguageModel.default
        let fixed = try await model.tokenCount(for: Instructions(instructions))
            + model.tokenCount(for: Probe.generationSchema)
        return TokenBudget.inputTokens(context: resolved.contextSize, fixed: fixed, reply: Probe.replyReserve)
    }

    @Test("The model writes every language the app is translated into, wherever its reader lives", arguments: [
        "en_AU", "en_US", "en_SG", "de_DE", "de_CH", "fr_FR", "fr_CH", "es_ES", "es_MX", "it_IT",
        "ja_JP", "pt_BR", "pt_PT", "zh_Hans_CN", "zh_HK",
    ])
    func languagesAreSupported(identifier: String) {
        // A prose feature is refused before any request if this is false,
        // so a language Apple drops would switch four features off.
        #expect(SystemLanguageModel.default.supportsLocale(Locale(identifier: identifier)), "\(identifier)")
    }

    @Test("How far over the model's count the estimate runs", arguments: TokenSamples.all.map(\.name))
    func estimateMargin(name: String) async throws {
        let sample = try #require(TokenSamples.all.first { $0.name == name })
        let counted = try await SystemLanguageModel.default.tokenCount(for: sample.text)
        let ratio = Double(TokenBudget.estimate(sample.text)) / Double(counted)
        print("ESTIMATE \(name): model \(counted), estimate \(TokenBudget.estimate(sample.text)), ratio \(String(format: "%.2f", ratio))")
        #expect(ratio >= 1)
    }

    @Test("The window is asked for, and is what the model says")
    func windowIsAsked() async {
        let size = await LanguageModels.contextSize(of: .onDevice)
        #expect(size == SystemLanguageModel.default.contextSize)
        #expect(size >= 4_096)
    }

    @Test("The estimate is still not under the model's count", arguments: TokenSamples.all.map(\.name))
    func estimateAgainstTheModel(name: String) async throws {
        // The recorded counts in `TokenSamples` are from one model on one
        // day; this asks the model that is here now.
        let sample = try #require(TokenSamples.all.first { $0.name == name })
        let counted = try await SystemLanguageModel.default.tokenCount(for: sample.text)
        #expect(TokenBudget.estimate(sample.text) >= counted,
                "\(name): estimated \(TokenBudget.estimate(sample.text)), model \(counted)")
    }

    @Test("A document is cut to the model's own count, whatever it is made of", arguments: [
        // Rows of digits just over the budget are the case the first cut
        // sent whole: an estimate said they fitted, and they were 1,350
        // tokens over.
        130, 140, 150, 400,
    ])
    func digitsFit(rows: Int) async throws {
        let resolved = try await LanguageModels.resolve(.invoiceAnalyzer)
        let instructions = "You read invoices."
        let allowed = try await budget(resolved, instructions: instructions)
        let document = TokenSamples.digitRows(rows)
        let cut = try await LanguageModels.fit(document, framing: framing, instructions: instructions,
                                               generating: Probe.self, resolved: resolved)
        let measured = try await SystemLanguageModel.default.tokenCount(for: framing(cut.text))
        #expect(measured <= allowed, "\(rows) rows: \(measured) tokens against \(allowed)")
        #expect(cut.truncated == (cut.text.count < document.count))
        // Not timid either: within a tenth of what was allowed, when cut.
        if cut.truncated { #expect(measured * 10 >= allowed * 9, "\(measured) of \(allowed)") }
        // And cut between rows.
        #expect(document.hasPrefix(cut.text))
        if cut.truncated { #expect(cut.text.hasSuffix("\n")) }
    }

    @Test("Prose is given what prose can use")
    func proseFits() async throws {
        let resolved = try await LanguageModels.resolve(.invoiceAnalyzer)
        let instructions = "You read invoices."
        let allowed = try await budget(resolved, instructions: instructions)
        let document = String(repeating: "The quarterly statement shows that household spending settled after a busy winter, and savings grew a little. ", count: 600)
        let cut = try await LanguageModels.fit(document, framing: framing, instructions: instructions,
                                               generating: Probe.self, resolved: resolved)
        let measured = try await SystemLanguageModel.default.tokenCount(for: framing(cut.text))
        #expect(measured <= allowed)
        #expect(cut.truncated)
        #expect(measured * 10 >= allowed * 9, "\(measured) of \(allowed)")
        // Five or six characters a token: far more than the 6,000 characters
        // a hand-sized cut allowed.
        #expect(cut.text.count > 20_000)
    }

    @Test("A document that fits goes in whole")
    func shortDocumentIsWhole() async throws {
        let resolved = try await LanguageModels.resolve(.invoiceAnalyzer)
        let cut = try await LanguageModels.fit(
            "Tax invoice from Sunfield Energy. Total 201.51.", framing: framing,
            instructions: "You read invoices.", generating: Probe.self, resolved: resolved)
        #expect(!cut.truncated)
        #expect(cut.text == "Tax invoice from Sunfield Energy. Total 201.51.")
    }

    @Test("A model with no counter is fitted by the estimate, and a window with no room says so")
    func withoutACounter() async throws {
        let uncounted = LanguageModels.Resolved(choice: .onDevice, model: SystemLanguageModel.default,
                                                contextSize: 8_192, count: nil)
        let allowed = try await budget(uncounted, instructions: "You read invoices.")
        let document = TokenSamples.statementRows(400)
        let cut = try await LanguageModels.fit(document, framing: framing, instructions: "You read invoices.",
                                               generating: Probe.self, resolved: uncounted)
        #expect(cut.truncated)
        #expect(TokenBudget.estimate(framing(cut.text)) <= allowed)
        // The estimate is not under the model's count, so neither is this.
        let measured = try await SystemLanguageModel.default.tokenCount(for: framing(cut.text))
        #expect(measured <= allowed)

        let tiny = LanguageModels.Resolved(choice: .onDevice, model: SystemLanguageModel.default,
                                           contextSize: 2_000, count: nil)
        await #expect(throws: IntelligenceError.self) {
            _ = try await LanguageModels.fit(document, framing: framing, instructions: nil,
                                             generating: Probe.self, resolved: tiny)
        }
    }
}
}
