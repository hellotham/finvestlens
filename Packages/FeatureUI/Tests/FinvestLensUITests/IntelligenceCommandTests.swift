//
//  IntelligenceCommandTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensIntelligence
@testable import FinvestLensUI

/// A command grants its features leave to run off the device
/// (`AppModel.running`), and its view says where it runs
/// (`IntelligenceRunsNote`). Both read one list, `IntelligenceCommand`; what
/// a list cannot do is make sure both are *there*. These do.
///
/// Why it is held this firmly: the review of 73b2bd6 (12 October 2026) found
/// Categorise from Attachment described, gated and disclosed as a feature
/// that stays on the device while it also ran two that do not.
///
/// What these can and cannot see. They read source text: that the file
/// which starts a command also shows that command's note, that every grant
/// goes through `running`, and that nothing else grants. They cannot see
/// *where on the screen* a note is, or whether it is drawn before the
/// request is made — three commands start when their sheet opens, and that
/// is recorded in `docs/deferred.md` §3a as the owner's decision, held by
/// `PrivateCloudComputeBuildTests`.
@Suite("What a command may send is what its view says")
struct IntelligenceCommandTests {

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/FinvestLensUI")

    /// Each source file's code with its comments taken out: a doc comment
    /// that names a command is not a use of one. (A `//` inside a string
    /// literal cuts the rest of that line too — nine lines today, all URL
    /// prefixes; a call hidden that way would fail these tests, not pass.)
    private static let files: [String: String] = {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil)) ?? []
        var files: [String: String] = [:]
        for url in urls where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files[url.lastPathComponent] = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
        }
        return files
    }()

    private static func found(_ pattern: String, in code: String) -> Bool {
        code.range(of: pattern, options: .regularExpression) != nil
    }

    private static func shows(_ command: IntelligenceCommand, in code: String) -> Bool {
        found(#"IntelligenceRunsNote\([^)]*\.\#(command.rawValue)\b"#, in: code)
    }

    /// The model's entry points that run a command, and the command each
    /// runs. `adoptDocument` is here although it grants nothing itself: it
    /// calls `suggestCategoryFromAttachment`, so a view that calls it starts
    /// that command as surely as the Attachments panel's button does.
    /// `recordCashPurchase` does the same and has no caller in this package
    /// (finlab, which is never built for Private Cloud Compute).
    private static let entryPoints: [(method: String, command: IntelligenceCommand)] = [
        ("analyzeInvoicePDF", .invoice),
        ("extractDividendStatement", .dividendStatement),
        ("matchAttachments", .matchAttachments),
        ("suggestCategoryFromAttachment", .categoriseFromAttachment),
        ("adoptDocument", .categoriseFromAttachment),
        ("suggestBudget", .budget),
        ("forecastInsights", .forecast),
        ("reportCommentary", .reportCommentary),
        ("reviewStory", .reviewStory),
    ]

    /// The files that are the model rather than a view of it.
    private static func isModel(_ name: String) -> Bool { name.hasPrefix("AppModel") || name == "FinancialReview.swift" }

    @Test("The sources were read")
    func sourcesWereRead() {
        // Everything below passes vacuously on nothing.
        #expect(Self.files.count > 50)
        #expect(Self.files["AppModel+Intelligence.swift"]?.contains("enum IntelligenceCommand") == true)
        #expect(Self.files["IntelligenceSettingsView.swift"]?.contains("struct IntelligenceRunsNote") == true)
    }

    @Test("A command names only features that can leave the device, and at least one",
          arguments: IntelligenceCommand.allCases)
    func namesWhatCanLeave(_ command: IntelligenceCommand) {
        #expect(!command.features.isEmpty)
        // Outside the macro: `#expect` cannot see that `allSatisfy` over a
        // key path does not throw.
        let allFollow = command.features.allSatisfy { $0.followsModelChoice }
        #expect(allFollow, "\(command.features)")
    }

    @Test("Every feature that can leave the device belongs to a command")
    func everyFeatureHasACommand() {
        // One that did not could never run where the person chose — the
        // private failure, and still a sign the two lists have parted.
        let named = IntelligenceCommand.allCases.reduce(into: Set<IntelligenceFeature>()) {
            $0.formUnion($1.features)
        }
        #expect(named == Set(IntelligenceFeature.allCases.filter(\.followsModelChoice)))
    }

    @Test("Every command has an entry point, and every entry point runs its command")
    func entryPointsCoverTheCommands() {
        #expect(Set(Self.entryPoints.map(\.command)) == Set(IntelligenceCommand.allCases))
        let model = Self.files.filter { Self.isModel($0.key) }.values.joined(separator: "\n")
        for command in IntelligenceCommand.allCases {
            #expect(Self.found(#"\brunning\(\.\#(command.rawValue)\)"#, in: model),
                    "nothing runs as .\(command.rawValue), so nothing it names can use the person's choice")
        }
        for entry in Self.entryPoints {
            #expect(Self.found(#"func \#(entry.method)\("#, in: model), "\(entry.method) is gone or renamed")
        }
    }

    @Test("A view that starts a command shows where that command runs",
          arguments: Self.entryPoints.map(\.method))
    func callerShowsTheNote(method: String) throws {
        let entry = try #require(Self.entryPoints.first { $0.method == method })
        let callers = Self.files.filter { name, code in
            !Self.isModel(name) && Self.found(#"\.\#(method)\("#, in: code)
        }
        #expect(!callers.isEmpty, "no view calls \(method)")
        for (name, code) in callers {
            #expect(Self.shows(entry.command, in: code),
                    "\(name) calls \(method) and shows no IntelligenceRunsNote for .\(entry.command.rawValue)")
        }
    }

    @Test("Leave to run off the device is granted in one place")
    func oneGrant() {
        // `permittingOffDevice` has to be public for this package to call
        // it. That it is called once — by `running`, which takes a command —
        // is what makes the command list the only way in.
        let grants = Self.files.filter { $0.value.contains("permittingOffDevice(") }.keys.sorted()
        #expect(grants == ["AppModel+Intelligence.swift"])
        let occurrences = Self.files["AppModel+Intelligence.swift"]?
            .components(separatedBy: "permittingOffDevice(").count ?? 0
        #expect(occurrences == 2, "expected exactly one call")
        let runners = Self.files.filter { Self.found(#"\brunning\(\."#, in: $0.value) }.keys.sorted()
        #expect(runners == ["AppModel+Intelligence.swift", "FinancialReview.swift"])
    }

    @Test("In this build no command sends anything off the device")
    func nothingLeavesInThisBuild() {
        for command in IntelligenceCommand.allCases {
            #expect(!command.leavesDevice, "\(command)")
        }
    }
}
