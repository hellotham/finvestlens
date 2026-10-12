//
//  SchemaGuideTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  What a model that is not shown a request's schema is told about it
//  instead. No model is asked anything here; `SuppliedModelLiveTests`, in
//  the app's own test target, asks a real one.
//

import Foundation
import Testing
import FoundationModels
@testable import FinvestLensIntelligence

@Suite("An answer's schema, written into the instructions")
struct SchemaGuideTests {

    /// The whole text, so that a change to it is a change someone made on
    /// purpose: its form was chosen by a survey (see `SchemaGuide`), and a
    /// form that reads as well to a person scored worse than no guide.
    @Test("A statement page: the schema in the order declared, every guide in it, nothing else")
    func statementPage() throws {
        let guide = try #require(SchemaGuide.text(for: StatementExtractor.ModelPage.generationSchema))
        #expect(guide == """
            Answer with one JSON object that matches this JSON Schema. Each description says what its field must hold:
            {"type":"object","properties":{"openingBalance":{"type":"string","description":"Opening or brought-forward balance printed on this page, empty if none"},"transactions":{"type":"array","description":"Every transaction row on this statement page. Exclude opening/closing balance lines, subtotals, and marketing text.","maxItems":20,"items":{"$ref":"#/$defs/ModelTransaction"}}},"required":["openingBalance","transactions"],"$defs":{"ModelTransaction":{"type":"object","properties":{"date":{"type":"string","description":"Transaction date in yyyy-MM-dd format"},"amount":{"type":"string","description":"Signed amount: negative for money out (withdrawals, purchases, fees, amounts in a Debit column), positive for money in (deposits, salary, refunds, amounts in a Credit column)"},"payee":{"type":"string","description":"Merchant or payee name, cleaned up"},"reference":{"type":"string","description":"Reference or receipt number if shown, else empty"},"balanceAfter":{"type":"string","description":"The running balance printed at the end of this row, empty if the statement has no balance column"}},"required":["date","amount","payee","reference","balanceAfter"]}}}
            """)
    }

    /// The encoder writes a schema's keys in a dictionary's order, which
    /// differs between launches. A prompt that changes between launches
    /// cannot be measured, and MLX can reuse nothing it computed for it.
    @Test("The same schema is written the same way every time")
    func stable() throws {
        let written = Set((0..<20).compactMap { _ in
            SchemaGuide.json(for: InvoiceAnalyzer.ModelInvoice.generationSchema)
        })
        #expect(written.count == 1)
    }

    @Test("What is written is itself JSON, and still the schema: same fields, same guides, same limits")
    func stillTheSchema() throws {
        for schema in Self.everyAnswer.map(\.1) {
            let written = try #require(SchemaGuide.json(for: schema))
            let read = try #require(
                try JSONSerialization.jsonObject(with: Data(written.utf8)) as? NSDictionary)
            let encoded = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? NSDictionary)
            #expect(read == Self.withoutNoise(encoded) as NSDictionary)
        }
    }

    /// `object` without the three keys the guide leaves out, at any depth.
    private static func withoutNoise(_ object: NSDictionary) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in object {
            guard let key = key as? String, !["x-order", "title", "additionalProperties"].contains(key)
            else { continue }
            result[key] = strip(value)
        }
        return result
    }

    private static func strip(_ value: Any) -> Any {
        if let dictionary = value as? NSDictionary { return withoutNoise(dictionary) }
        if let array = value as? [Any] { return array.map(strip) }
        return value
    }

    @Test("A list whose length the request fixes is written with that length")
    func counted() throws {
        let schema = LanguageModels.countedSchema(
            for: BudgetAdvisor.ModelBudget.self, property: "lines", count: 2)
        let guide = try #require(SchemaGuide.text(for: schema))
        #expect(guide.contains(#""minItems":2,"maxItems":2"#))
    }

    @Test("A field limited to a set of answers lists them")
    func choices() throws {
        let guide = try #require(SchemaGuide.text(for: DocumentClassifier.ModelKind.generationSchema))
        for kind in ["bank statement", "dividend statement", "invoice or receipt", "something else"] {
            #expect(guide.contains("\"\(kind)\""), "\(kind) missing from: \(guide)")
        }
    }

    /// Every answer type a feature asks for. A new one that this cannot
    /// write would go to a supplied model with its guides unread, which is
    /// the defect the guide exists to close.
    static let everyAnswer: [(String, GenerationSchema)] = [
        ("statement", StatementExtractor.ModelPage.generationSchema),
        ("invoice", InvoiceAnalyzer.ModelInvoice.generationSchema),
        ("pictured invoice", InvoiceAnalyzer.ModelPicturedInvoice.generationSchema),
        ("dividend", DividendExtractor.ModelDividend.generationSchema),
        ("attachment", AttachmentInsight.ModelAnswer.generationSchema),
        ("budget", BudgetAdvisor.ModelBudget.generationSchema),
        ("kind", DocumentClassifier.ModelKind.generationSchema),
        ("outlook", ForecastNarrator.ModelOutlook.generationSchema),
        ("notes", ReportNarrator.ModelNotes.generationSchema),
        ("story", ReviewNarrator.ModelStory.generationSchema),
        ("suggestions", TransactionCategorizer.ModelSuggestions.generationSchema),
    ]

    @Test("Every answer a feature asks for can be written, with every guide in it and its fields in order")
    func everyAnswerIsWritten() throws {
        for (name, schema) in Self.everyAnswer {
            let guide = try #require(SchemaGuide.text(for: schema), "no guide for \(name)")
            let data = try JSONEncoder().encode(schema)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            // Every description the schema carries is in the guide, word for word.
            let text = String(decoding: data, as: UTF8.self)
            for match in text.matches(of: /"description"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
                let description = try JSONDecoder().decode(String.self, from: Data("\"\(match.1)\"".utf8))
                let written = String(decoding: try JSONSerialization.data(
                    withJSONObject: description, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
                #expect(guide.contains(written), "\(name): guide “\(description)” was not carried over")
            }
            // The root's fields come in the order the type declares.
            let order = try #require(root["x-order"] as? [String], "\(name) declares no order")
            let positions = order.compactMap { guide.range(of: "\"\($0)\":{")?.lowerBound }
            #expect(positions.count == order.count, "\(name): a field is missing")
            #expect(positions == positions.sorted(), "\(name): fields out of order in \(guide)")
            #expect(!guide.contains("x-order") && !guide.contains("additionalProperties"))
        }
    }

    /// The order of a supplied model's instructions was chosen by a survey
    /// (`LanguageModels.suppliedInstructions`): Apple's locale phrase said
    /// first, as Apple's own model needs it, cost another model its answers.
    @Test("For a supplied model: the feature's instructions, the schema, then the locale — and the schema alone where there are none")
    func placement() throws {
        let schema = StatementExtractor.ModelPage.generationSchema
        let guide = try #require(SchemaGuide.text(for: schema))
        let australia = Locale(identifier: "en_AU")

        #expect(LanguageModels.suppliedInstructions("Read the page.", for: .statementExtractor,
                                                    schema: schema, locale: australia)
                == "Read the page.\n\n\(guide)\n\nThe person's locale is en_AU.")
        // U.S. English is the language the prompts are written in: no phrase.
        #expect(LanguageModels.suppliedInstructions("Read the page.", for: .statementExtractor,
                                                    schema: schema, locale: Locale(identifier: "en_US"))
                == "Read the page.\n\n\(guide)")
        // The classifier sends Apple's model no instructions; a supplied one
        // still has to be told what the answer's one field may be.
        let kind = DocumentClassifier.ModelKind.generationSchema
        #expect(LanguageModels.suppliedInstructions(nil, for: .documentClassifier, schema: kind,
                                                    locale: Locale(identifier: "en_US"))
                == SchemaGuide.text(for: kind))
        // Apple's model is still told its phrase first, and no schema.
        #expect(LanguageModels.instructions("Read the page.", for: .statementExtractor, locale: australia)
                == "The person's locale is en_AU.\nRead the page.")
    }

    @Test("For a supplied model writing prose, the language is ordered at both ends, as it is for Apple's")
    func proseOrder() throws {
        let schema = ReviewNarrator.ModelStory.generationSchema
        let guide = try #require(SchemaGuide.text(for: schema))
        #expect(LanguageModels.suppliedInstructions("Write one slide.", for: .reviewNarrator,
                                                    schema: schema, locale: Locale(identifier: "de_DE"))
                == """
                You MUST respond in German.
                Write one slide.

                \(guide)

                The person's locale is de_DE.
                You MUST respond in German.
                """)
    }

    @Test("Only a model that is not shown the schema is told it: Apple's are, a supplied one says")
    func whoIsTold() async throws {
        let device = try? await LanguageModels.resolve(.reviewNarrator)
        if let device { #expect(!device.needsFieldGuide) }
        #expect(LanguageModels.SuppliedModel(
            name: "m", contextSize: 8_192, availability: .available,
            make: { SystemLanguageModel.default }).needsFieldGuide)
    }

    @Test("A supplied model's answer has a ceiling for every feature, with room above what the feature asks for")
    func ceilings() {
        for feature in IntelligenceFeature.allCases {
            #expect(feature.suppliedAnswerCeiling >= 128, "\(feature)")
            #expect(feature.suppliedAnswerCeiling <= 4_096, "\(feature)")
        }
        // MLX steers an answer to its close with a quarter of the ceiling
        // left, so three quarters of it has to hold the largest real answer:
        // what a document reader keeps back for its reply.
        #expect(IntelligenceFeature.invoiceAnalyzer.suppliedAnswerCeiling * 3 / 4
                >= InvoiceAnalyzer.ModelInvoice.replyReserve)
        #expect(IntelligenceFeature.dividendExtractor.suppliedAnswerCeiling * 3 / 4
                >= DividendExtractor.ModelDividend.replyReserve)
        #expect(IntelligenceFeature.attachmentInsight.suppliedAnswerCeiling * 3 / 4
                >= AttachmentInsight.ModelAnswer.replyReserve)
    }
}
