//
//  StoreListingTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The App Store copy in `docs/app-store-listing.md`, held to App Store
//  Connect's limits and to the code, before anything is pasted.
//
//  A field over its limit is refused at the moment of pasting, which is a
//  bad moment to rewrite a promotional line. And three things about the copy
//  are facts about the code, each of which the first draft had wrong while
//  saying it had been checked: which price providers the app contacts, what
//  the iPhone does not do, and where Apple Intelligence runs.
//

import Foundation
import Testing
import FinvestLensQuotes

@Suite("App Store listing copy")
struct StoreListingTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func listing() throws -> String {
        try String(contentsOf: root.appendingPathComponent("docs/app-store-listing.md"), encoding: .utf8)
    }

    /// The fenced block that follows the first line containing `label`.
    private static func block(after label: String, in text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains(label) }, "no field labelled \(label)")
        let open = try #require(lines[start...].firstIndex { $0.hasPrefix("```") }, "no block after \(label)")
        let close = try #require(lines[(open + 1)...].firstIndex { $0.hasPrefix("```") }, "unclosed block after \(label)")
        return lines[(open + 1)..<close].joined(separator: "\n")
    }

    /// Every block of copy that is pasted into App Store Connect.
    private static func copy(in text: String) throws -> [String: String] {
        try [
            "subtitle": block(after: "**Subtitle**", in: text),
            "promotional text": block(after: "**Promotional text**", in: text),
            "keywords": block(after: "**Keywords**", in: text),
            "what's new": block(after: "**Version** — What's New", in: text),
            "iPhone and iPad description": block(after: "**Description** — iPhone and iPad", in: text),
            "Mac description": block(after: "**Description** — Mac", in: text),
            "reviewer notes": block(after: "## Notes to reviewer", in: text),
        ]
    }

    @Test("Every field fits App Store Connect's limit")
    func limits() throws {
        let copy = try Self.copy(in: Self.listing())
        let limits = ["subtitle": 30, "promotional text": 170, "keywords": 100, "what's new": 4_000,
                      "iPhone and iPad description": 4_000, "Mac description": 4_000,
                      "reviewer notes": 4_000]
        for (field, limit) in limits {
            let text = try #require(copy[field])
            #expect(!text.isEmpty, "\(field) is empty")
            #expect(text.count <= limit, "\(field) is \(text.count) characters; the limit is \(limit)")
        }
    }

    @Test("Keywords are a comma-separated list with no wasted characters")
    func keywords() throws {
        let keywords = try #require(try Self.copy(in: Self.listing())["keywords"])
        #expect(!keywords.contains(", "), "a space after a comma is a character spent on nothing")
        #expect(!keywords.contains("\n"))
        let terms = keywords.split(separator: ",").map(String.init)
        #expect(Set(terms).count == terms.count, "a keyword is repeated")
        // The app's own name is indexed already.
        #expect(!terms.contains { $0.lowercased().contains("finvestlens") })
    }

    @Test("The reviewer notes name every price provider the app can contact")
    func providers() throws {
        let notes = try #require(try Self.copy(in: Self.listing())["reviewer notes"])
        for provider in QuoteProviderKind.allCases {
            #expect(notes.contains(provider.displayName),
                    "the reviewer notes do not mention \(provider.displayName)")
        }
        // And say truthfully which of them need a key.
        let sentence = try #require(notes.components(separatedBy: "\n").first { $0.hasPrefix("NETWORK.") })
        let keyless = try #require(sentence.range(of: "need no key")).lowerBound
        for provider in QuoteProviderKind.allCases {
            let named = try #require(sentence.range(of: provider.displayName)).lowerBound
            #expect((named < keyless) == !provider.requiresAPIKey,
                    "\(provider.displayName) is on the wrong side of “need no key”")
        }
    }

    @Test("Both descriptions carry the privacy policy link, and the iPhone one says what it does not do")
    func descriptions() throws {
        let copy = try Self.copy(in: Self.listing())
        let phone = try #require(copy["iPhone and iPad description"])
        let mac = try #require(copy["Mac description"])
        for description in [phone, mac] {
            #expect(description.contains("https://hellotham.com/finvestlens/privacy/"))
        }
        // FR-PLT-06: import and export are not offered on iPhone, and the
        // copy for iPhone must not promise them.
        #expect(phone.contains("Importing bank files and exporting are done on iPad or Mac"))
        for promise in ["CSV, QIF, OFX", "exported as PDF", "Import a GnuCash file"] {
            #expect(!phone.contains(promise), "the iPhone description promises: \(promise)")
        }
    }

    @Test("The copy mentions Private Cloud Compute exactly when the build can offer it")
    func privateCloudCompute() throws {
        let copy = try Self.copy(in: Self.listing())
        let project = try String(contentsOf: Self.root
            .appendingPathComponent("finvestlens.xcodeproj/project.pbxproj"), encoding: .utf8)
        let offered = project.contains("PRIVATE_CLOUD_COMPUTE")
        for (field, text) in copy where field != "reviewer notes" {
            #expect(text.contains("Private Cloud Compute") == false || offered,
                    "\(field) mentions Private Cloud Compute, which this build cannot offer")
            if offered {
                // Then nothing may go on promising that figures stay put.
                #expect(!text.contains("not sent to us or to anyone else"),
                        "\(field) still says figures are not sent to anyone")
            }
        }
    }
}
