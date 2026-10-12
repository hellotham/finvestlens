//
//  OwnModelWordingTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing

/// A person can have a model of their own do everything Apple Intelligence
/// does here. Every sentence that says Apple Intelligence *did* or *will do*
/// something was written when nothing else could, and beside another model
/// it puts Apple's name to that model's work — to a reading Apple never
/// made, or a refusal it never gave.
///
/// So each sentence in the source that names Apple Intelligence is one of
/// two things, and is listed as which:
///
/// - **about Apple Intelligence itself** — the Settings pane's name, why
///   Apple's model is unavailable, a sentence shown only with Private Cloud
///   Compute — and true whichever model answers; or
/// - **about who is doing the work**, in which case it has a second wording
///   for a model the person supplied, and both are in the source.
///
/// A new sentence that names Apple Intelligence is in neither list, and
/// fails here until someone decides which it is.
///
/// What this cannot see: that the right wording is *chosen* at each place
/// (`Text(for:apple:own:)`, `LanguageModels.speaksOfOwnModel`) — only that
/// both exist. It reads source text.
@Suite("Apple's name is not put to another model's work")
struct OwnModelWordingTests {

    private static let packages = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The three places a sentence can be said from: the two packages that
    /// speak of a model, and the app target.
    private static let roots = [
        packages.appendingPathComponent("FeatureUI/Sources/FinvestLensUI"),
        packages.appendingPathComponent("Intelligence/Sources/FinvestLensIntelligence"),
        packages.deletingLastPathComponent().appendingPathComponent("finvestlens"),
    ]

    /// Every line of code, comments taken out, with the file it is in.
    private static let lines: [(file: String, text: String)] = roots.flatMap { root -> [(String, String)] in
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }.flatMap { url -> [(String, String)] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                (url.lastPathComponent, line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line))
            }
        }
    }

    /// The sentences on a line that name Apple Intelligence: each string
    /// literal that does, or — inside a multi-line literal, where a line
    /// has no quotes of its own — the line.
    private static func sentences(naming name: String, on line: String) -> [String] {
        guard line.contains(name) else { return [] }
        let literals = line.matches(of: /"((?:[^"\\]|\\.)*)"/).map { String($0.1) }.filter { $0.contains(name) }
        return literals.isEmpty ? [line.trimmingCharacters(in: .whitespaces)] : literals
    }

    /// True whichever model answers.
    private static let aboutAppleIntelligence: Set<String> = [
        // The pane, its tab and its section, and the way to it.
        "Apple Intelligence",
        "Choose a model of your own in Settings ▸ Apple Intelligence.",
        "The model you chose isn’t in the models folder any more. Choose another in Settings ▸ Apple Intelligence.",
        #"\(name) isn’t in the models folder any more. Choose another in Settings ▸ Apple Intelligence."#,
        "Settings ▸ Apple Intelligence can use an open model you already have in \\",
        // Why Apple's own model cannot answer.
        "This device does not support Apple Intelligence.",
        #"Turn on Apple Intelligence in \(Self.settingsName) to use this feature."#,
        "Apple Intelligence is not available on this device.",
        "Apple Intelligence is unavailable.",
        "The Apple Intelligence model is still downloading. Try again shortly.",
        #"Private Cloud Compute isn’t ready yet. Check that Apple Intelligence is on in \(Self.settingsName), then try again."#,
        // Shown only while requests go to Private Cloud Compute, which is Apple's.
        "Read statements with Apple Intelligence",
        "The period as a results deck — one message per slide, charts, callouts, insights from Apple Intelligence",
        // Says what a supplied model stands in for, and names both.
        "Runs on this device, on the model you chose, for everything Apple Intelligence does here. Your books and documents never leave it. FinvestLens doesn’t provide the model or download it: it is yours, in a folder you pointed to.",
        "**Suggest Budget** proposes monthly figures from six months of spending, using Apple Intelligence — or a model of your own — on this device.",
        "under Where it runs. It does everything here that Apple Intelligence \\",
        // The help topic's title: the name of the feature, as the menu has it.
        "Reading PDFs with Apple Intelligence",
    ]

    /// About who is doing the work: Apple Intelligence's wording, and the
    /// wording for a model the person supplied.
    private static let twoWordings: [String: String] = [
        "Apple Intelligence declined to process this content (safety guardrails). Enter the details manually instead.":
            "Your model declined to process this content. Enter the details manually instead.",
        #"Apple Intelligence declined this request: \(explanation)"#: #"Your model declined this request: \(explanation)"#,
        "This document is too long for Apple Intelligence to read in one piece.":
            "This document is too long for your model to read in one piece.",
        "Apple Intelligence doesn’t support this language yet.": "Your model doesn’t support this language.",
        "Apple Intelligence is busy right now. Try again in a moment.": "Your model is busy right now. Try again in a moment.",
        "Apple Intelligence took too long to answer. Try again.": "Your model took too long to answer. Try again.",
        #"Apple Intelligence could not process this request: \(detail)"#: #"Your model could not process this request: \(detail)"#,
        "Apple Intelligence had nothing to say about this report.": "Your model had nothing to say about this report.",
        "Budgeted from your monthly averages over the observed period. Apple Intelligence didn’t refine this plan, so no trims were applied.":
            "Budgeted from your monthly averages over the observed period. Your model didn’t refine this plan, so no trims were applied.",
        "Let Apple Intelligence propose a category for each transaction": "Let your model propose a category for each transaction",
        "Reading statement with Apple Intelligence…": "Reading statement with your model…",
        "Reading statement with Apple Intelligence": "Reading statement with your model",
        "Analysing six months of spending with Apple Intelligence…": "Analysing six months of spending with your model…",
        "This invoice is longer than Apple Intelligence can read at once, so only its first part was read. Line items further down are missing.":
            "This invoice is longer than your model can read at once, so only its first part was read. Line items further down are missing.",
        "Bank statements, dividend statements and invoices are read on-device by Apple Intelligence and turned into transactions to review — nothing leaves this device.":
            "Bank statements, dividend statements and invoices are read on this device by your own model and turned into transactions to review — nothing leaves this device.",
        "Let Apple Intelligence propose a destination account for each row": "Let your model propose a destination account for each row",
        "Propose a monthly budget from your spending with Apple Intelligence":
            "Propose a monthly budget from your spending with your model",
    ]

    @Test("Every sentence that names Apple Intelligence is either about it, or has a wording for another model")
    func everySentenceIsAccountedFor() {
        #expect(Self.lines.count > 10_000, "the sources were not found: \(Self.lines.count) lines")
        var named = Set<String>()
        for line in Self.lines {
            for sentence in Self.sentences(naming: "Apple Intelligence", on: line.text) {
                named.insert(sentence)
                #expect(Self.aboutAppleIntelligence.contains(sentence) || Self.twoWordings[sentence] != nil,
                        "\(line.file) names Apple Intelligence in a sentence with no decision about another model: “\(sentence)”")
            }
        }
        // And the lists hold nothing that is no longer said — a list that
        // outlives its sentences stops being read.
        for listed in Self.aboutAppleIntelligence.union(Self.twoWordings.keys) {
            #expect(named.contains(listed), "listed but no longer in the source: “\(listed)”")
        }
    }

    @Test("Each such sentence's other wording is in the source, and does not name Apple")
    func theOtherWordingExists() {
        let code = Self.lines.map(\.text).joined(separator: "\n")
        for (apple, own) in Self.twoWordings {
            #expect(code.contains("\"\(own)\""), "no wording for a supplied model beside “\(apple)”")
            #expect(!own.contains("Apple"))
        }
    }
}
