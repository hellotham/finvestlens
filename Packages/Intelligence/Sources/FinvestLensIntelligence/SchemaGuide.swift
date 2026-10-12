//
//  SchemaGuide.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  An answer's schema, written out for a model that is held to the answer's
//  shape and never shown what the shape means.
//
//  Apple's models are given a request's schema with the request: the
//  `@Guide` on each property is read by the model. MLX, which runs a model
//  the person supplies, uses the schema as a grammar and nothing else — its
//  adapter turns a session's transcript into a system message and a user
//  message, compiles the schema into a constraint on the tokens that may
//  come next, and never puts the schema in front of the model
//  (`MLXFoundationModels/TranscriptConverter.swift` and
//  `runSchemaGeneration`, read 12 October 2026). So the model writes a JSON
//  object with the right keys knowing them only by name.
//
//  That is not a small loss here. The guides are where a feature says most
//  of what it wants: that a date is `yyyy-MM-dd`, that money out is
//  negative, that a reference is empty when the page shows none. So for a
//  supplied model the schema goes into the instructions.
//
//  **As JSON Schema, and not as a list in words.** The first version of this
//  file wrote "- total: Grand total of the invoice as printed", one line a
//  field, and on the first page it was tried on it looked like the fix. A
//  survey said otherwise (12 October 2026: five synthetic invoices and three
//  statement pages, 44 things to get right, Gemma 4 26B at 4 bits):
//
//      no guide                         35 of 44
//      a list in words, after           31 of 44
//      a list in words, before          27 of 44   one answer ran 3 minutes
//      the schema as encoded, after     43 of 44
//      the schema in declared order     44 of 44   before or after
//
//  A list of `name: meaning` lines reads to the model as the *form of the
//  answer*: it wrote `vendor: ` and `lineItems: [` into string values while
//  the grammar forced JSON around them — worse than saying nothing. JSON
//  Schema says the same things in the notation the model is being held to.
//  Qwen 3.8 27B, asked the same, is in `docs/intelligence-prompts.md`.
//
//  The text is the schema's own encoding (`GenerationSchema` is `Codable`,
//  as JSON Schema) with two changes. Properties are written in the order the
//  type declares them, which is the order the grammar makes the model write
//  them in — the encoder's own order is a dictionary's, different on every
//  launch, and a prompt that changes between launches cannot be measured.
//  And three keys that tell a reader nothing are left out: `x-order` (said by
//  the order), `title` (the Swift type's name) and `additionalProperties`
//  (the grammar's business).
//

import Foundation
import FoundationModels

enum SchemaGuide {

    static let preamble =
        "Answer with one JSON object that matches this JSON Schema. Each description says what its field must hold:"

    /// `schema` as the instructions say it, or `nil` if it encodes in a way
    /// this cannot read — in which case the request is made as it would
    /// have been.
    static func text(for schema: GenerationSchema) -> String? {
        guard let json = json(for: schema) else { return nil }
        return "\(preamble)\n\(json)"
    }

    /// The schema itself: compact, in declared order, without the noise.
    static func json(for schema: GenerationSchema) -> String? {
        guard let data = try? JSONEncoder().encode(schema),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["properties"] is [String: Any]
        else { return nil }
        return write(root)
    }

    /// Keys that say nothing to a reader of the schema.
    private static let unsaid: Set<String> = ["x-order", "title", "additionalProperties"]

    /// The order an object's own keys are written in: what it is, what it
    /// means, what it may be, and then what it is made of. Anything not
    /// named here follows, alphabetically, so nothing is ever left out for
    /// being unexpected.
    private static let reading = [
        "type", "description", "enum", "const", "anyOf", "minimum", "maximum", "pattern",
        "minItems", "maxItems", "items", "properties", "required", "$ref", "$defs",
    ]

    /// - Parameter declared: for a `properties` object, the order its type
    ///   declares them in.
    private static func write(_ value: Any, declared: [String]? = nil) -> String {
        switch value {
        case let object as [String: Any]:
            let keys: [String]
            if let declared {
                keys = declared.filter { object[$0] != nil } + object.keys.filter { !declared.contains($0) }.sorted()
            } else {
                let said = object.keys.filter { !unsaid.contains($0) }
                keys = reading.filter(said.contains) + said.filter { !reading.contains($0) }.sorted()
            }
            let order = object["x-order"] as? [String]
            let members = keys.compactMap { key -> String? in
                guard let member = object[key] else { return nil }
                let written = key == "properties" ? write(member, declared: order ?? []) : write(member)
                return "\(quoted(key)):\(written)"
            }
            return "{" + members.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map { write($0) }.joined(separator: ",") + "]"
        case let string as String:
            return quoted(string)
        case let number as NSNumber:
            // `JSONSerialization` reads `true` and `1` as the same class.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            return "null"
        }
    }

    private static func quoted(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
