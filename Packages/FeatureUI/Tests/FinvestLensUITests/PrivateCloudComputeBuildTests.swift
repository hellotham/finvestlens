//
//  PrivateCloudComputeBuildTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing

@Suite("Private Cloud Compute is built in only with its entitlement")
struct PrivateCloudComputeBuildTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("The build condition and the entitlement are set together, or not at all")
    func flagAndEntitlementAgree() throws {
        let project = try String(contentsOf: Self.root
            .appendingPathComponent("finvestlens.xcodeproj/project.pbxproj"), encoding: .utf8)
        let entitlements = try String(contentsOf: Self.root
            .appendingPathComponent("finvestlens/finvestlens.entitlements"), encoding: .utf8)
        let condition = project.contains("PRIVATE_CLOUD_COMPUTE")
        let entitlement = entitlements.contains("com.apple.developer.private-cloud-compute")
        // One without the other is the dangerous state: with the condition
        // and no entitlement, the framework reports the cloud model as
        // available and the first request to it ends the process.
        #expect(condition == entitlement,
                "PRIVATE_CLOUD_COMPUTE condition: \(condition); entitlement: \(entitlement)")
    }

    /// The sentences that are true only while nothing leaves the device.
    ///
    /// The app's own captions follow the build by themselves
    /// (`LanguageModels.leavesDevice`). These cannot: the help is one text for
    /// every build and is published as the website's manual, and the privacy
    /// policy is a page. So adding the build condition is not one change, and
    /// this is what makes that a failing test instead of something to
    /// remember: the entitlement cannot land while the help still promises
    /// that nothing is sent anywhere, or the policy says nothing of Apple's
    /// servers.
    @Test("With the build condition set, the help and the privacy policy say where requests go")
    func copyFollowsTheBuild() throws {
        let project = try String(contentsOf: Self.root
            .appendingPathComponent("finvestlens.xcodeproj/project.pbxproj"), encoding: .utf8)
        let help = try String(contentsOf: Self.root.appendingPathComponent(
            "Packages/FeatureUI/Sources/FinvestLensUI/HelpContent.swift"), encoding: .utf8)
        let policy = try String(contentsOf: Self.root
            .appendingPathComponent("website/src/pages/privacy.astro"), encoding: .utf8)
        if project.contains("PRIVATE_CLOUD_COMPUTE") {
            #expect(!help.contains("Nothing is sent anywhere"),
                    "Smart Import's help still says nothing is sent anywhere")
            #expect(!help.contains("using Apple Intelligence on this device"),
                    "Suggest Budget's help still says it runs on this device")
            #expect(help.contains("Private Cloud Compute"), "the help does not mention Private Cloud Compute")
            #expect(policy.contains("Private Cloud Compute"),
                    "the privacy policy does not mention Private Cloud Compute")
        } else {
            // And the other way about: a build that cannot use it does not
            // describe it as something the app does.
            #expect(!help.contains("Private Cloud Compute"))
        }
    }
}
