//
//  AcknowledgementsTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

/// The MIT and Apache-2.0 licences ask that their notice goes wherever a
/// copy of the software goes, and a copy from the App Store has only the
/// app. So what the project resolves and what the app acknowledges are held
/// together: a package added to the project is in one of two lists here, or
/// this fails.
@Suite("What the app links is what it acknowledges")
struct AcknowledgementsTests {

    /// The identities the app's project resolves, from the file Xcode keeps.
    private static func resolved() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("finvestlens.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        struct Resolved: Decodable {
            struct Pin: Decodable { let identity: String }
            let pins: [Pin]
        }
        return Set(try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: url)).pins.map(\.identity))
    }

    @Test("Every package the project resolves is acknowledged, or named as a build tool that is not shipped")
    func everyPackageIsAccountedFor() throws {
        let resolved = try Self.resolved()
        #expect(resolved.count >= 10, "Package.resolved was not read: \(resolved)")
        let acknowledged = Set(Acknowledgements.linked.map(\.identity))
        for identity in resolved.sorted() {
            #expect(acknowledged.contains(identity) || Acknowledgements.buildOnly.contains(identity),
                    "\(identity) is resolved by the project and neither acknowledged nor named as build-only")
        }
        // And nothing is acknowledged, or excused, that the project no longer has.
        for identity in acknowledged.union(Acknowledgements.buildOnly).sorted() {
            #expect(resolved.contains(identity), "\(identity) is listed and no longer resolved")
        }
        #expect(acknowledged.isDisjoint(with: Acknowledgements.buildOnly))
    }

    /// The texts are gathered by `scripts/build-third-party-licenses.py`
    /// from the package checkouts, which a package's tests cannot see; what
    /// can be held here is that the file the app ships is there and speaks
    /// of everything the pane lists.
    @Test("The licence texts the app ships name every package acknowledged, and are the licences' own words")
    func theTextsAreShipped() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("finvestlens/ThirdPartyLicenses.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        for package in Acknowledgements.linked {
            #expect(text.contains(package.name), "\(package.name) has no licence text in the app")
        }
        // Each licence's own operative words, not a summary of them.
        #expect(text.contains("Permission is hereby granted, free of charge"))
        #expect(text.contains("Apache License") && text.contains("Version 2.0, January 2004"))
        // And the works carried inside the packages, which have authors of their own.
        for carried in ["{fmt}", "JSON for Modern C++", "metal-cpp", "XGrammar"] {
            #expect(text.contains(carried), "\(carried) has no licence text in the app")
        }
    }

    @Test("Each acknowledgement says its licence and where the work is")
    func eachIsComplete() {
        #expect(Set(Acknowledgements.linked.map(\.identity)).count == Acknowledgements.linked.count)
        for package in Acknowledgements.linked {
            #expect(["MIT", "Apache-2.0"].contains(package.license), "\(package.name): \(package.license)")
            #expect(package.url.scheme == "https" && package.url.host() == "github.com", "\(package.name)")
            #expect(!package.name.isEmpty)
        }
    }
}
