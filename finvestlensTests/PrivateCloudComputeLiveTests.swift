//
//  PrivateCloudComputeLiveTests.swift
//  finvestlensTests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  One request to Apple's Private Cloud Compute, from a build signed for it.
//
//  It lives here because only the app is signed with the entitlement, and a
//  test runs inside the app that hosts it. It asks the cloud model directly —
//  on a session built on that model, so a failure cannot quietly fall back to
//  the device — about a made-up dividend statement: nothing of anyone's book
//  is sent, and the person's choice in Settings is not read or changed.
//  Skipped unless asked for:
//
//      TEST_RUNNER_FL_PCC_LIVE=1 \
//      xcodebuild test -scheme finvestlens -destination 'platform=macOS' \
//        -only-testing:finvestlensTests/PrivateCloudComputeLiveTests \
//        -skipPackagePluginValidation -allowProvisioningUpdates
//
//  Signed, unlike the other live harness: an unsigned build carries no
//  entitlement, and the framework ends the process at the first request
//  (`LanguageModels.privateCloudComputeEnabled`). Xcode needs an account under
//  Settings ▸ Accounts to issue the profile (`docs/provisioning.md`).
//  `xcodebuild` keeps no console log of a hosted run, and the sandboxed app
//  cannot write outside its container — a log path in /tmp is silently not
//  written. The answer and its time go to `pcc-live.log` in the app's own
//  temporary folder:
//  ~/Library/Containers/com.hellotham.finvestlens/Data/tmp/pcc-live.log
//

#if os(macOS)
import Foundation
import Testing
import FoundationModels
@testable import FinvestLensIntelligence

@Suite("Private Cloud Compute, asked for real",
       .enabled(if: ProcessInfo.processInfo.environment["FL_PCC_LIVE"] == "1"))
struct PrivateCloudComputeLiveTests {

    private func log(_ line: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcc-live.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test("A build signed for it reaches Private Cloud Compute, and its answer is read")
    func answers() async throws {
        #expect(LanguageModels.privateCloudComputeEnabled,
                "the build condition and the entitlement, as read from the signature")
        let model = try #require(LanguageModels.privateCloud)
        let availability = LanguageModels.availability(of: .privateCloud)
        log("availability: \(availability)")
        guard availability == .available else {
            Issue.record("Private Cloud Compute is not available: \(availability)")
            return
        }

        // Made up, and round: no one's figures.
        let statement = """
            EXAMPLE PTY LTD — DIVIDEND STATEMENT
            Payment date: 1 July 2026
            Fully franked dividend      100.00
            Franking credits             42.86
            Net payment                 100.00
            """
        let session = LanguageModelSession(profile: LanguageModels.FeatureProfile(
            feature: .dividendExtractor, model: model,
            instructions: "You read dividend statements. Answer with the number asked for and nothing else."))
        let started = ContinuousClock.now
        let answer = try await session.respond(
            to: "\(statement)\n\nWhat are the franking credits on this statement?").content
        log("answer after \(ContinuousClock.now - started): \(answer)")
        #expect(answer.contains("42.86"), "answered: \(answer)")
    }
}
#endif
