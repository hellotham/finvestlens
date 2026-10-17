//
//  OffDeviceQuestionTests.swift
//  FinvestLens — FeatureUI
//
//  The owner's decision of 17 Oct 2026: before the first request that would
//  leave the device, ask once — and keep the answer as the person's choice.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensIntelligence
@testable import FinvestLensUI

@MainActor
@Suite("Asking once before anything leaves the device", .serialized)
struct OffDeviceQuestionTests {

    /// Runs `body` as a build that offers Private Cloud Compute, with no
    /// choice stored, putting both back afterwards.
    private func withQuestionOpen(_ body: (OffDeviceQuestion) async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: LanguageModels.choiceDefaultsKey)
        defaults.removeObject(forKey: LanguageModels.choiceDefaultsKey)
        let question = OffDeviceQuestion.shared
        question.offeredOverride = true
        question.leavesDeviceOverride = true
        defer {
            question.offeredOverride = nil
            question.leavesDeviceOverride = nil
            if let saved { defaults.set(saved, forKey: LanguageModels.choiceDefaultsKey) }
            else { defaults.removeObject(forKey: LanguageModels.choiceDefaultsKey) }
        }
        try await body(question)
    }

    /// Lets the waiting command reach its wait.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("A command waits for the answer, and the answer is kept as the choice")
    func waitsAndKeepsTheAnswer() async throws {
        try await withQuestionOpen { question in
            let model = AppModel()
            var ran = false
            let command = Task { @MainActor in
                await model.running(.budget) { ran = true }
            }
            await settle()
            #expect(question.isAsking)
            #expect(!ran, "nothing runs before the person answers")

            question.answer(usePrivateCloud: true)
            await command.value
            #expect(ran)
            #expect(!question.isAsking)
            #expect(UserDefaults.standard.string(forKey: LanguageModels.choiceDefaultsKey)
                    == ModelChoice.privateCloud.rawValue)
            #expect(!question.needsAnswer, "asked once")
        }
    }

    @Test("Keeping everything on the device is an answer too")
    func keepOnDevice() async throws {
        try await withQuestionOpen { question in
            let model = AppModel()
            let command = Task { @MainActor in await model.running(.reviewStory) {} }
            await settle()
            question.answer(usePrivateCloud: false)
            await command.value
            #expect(UserDefaults.standard.string(forKey: LanguageModels.choiceDefaultsKey)
                    == ModelChoice.onDevice.rawValue)
        }
    }

    @Test("A command whose sheet closes stops waiting, and leaves the question open")
    func cancellationReleases() async throws {
        try await withQuestionOpen { question in
            let model = AppModel()
            var ran = false
            let command = Task { @MainActor in await model.running(.invoice) { ran = true } }
            await settle()
            #expect(question.isAsking)
            command.cancel()
            await command.value
            await settle()
            #expect(ran, "it ran — on this device, with nothing granted")
            #expect(!question.isAsking)
            #expect(question.needsAnswer, "no answer was invented")
        }
    }

    @Test("A choice already made, here or in Settings, means no question")
    func choiceAlreadyMade() async throws {
        try await withQuestionOpen { question in
            UserDefaults.standard.set(ModelChoice.onDevice.rawValue, forKey: LanguageModels.choiceDefaultsKey)
            let model = AppModel()
            var ran = false
            await model.running(.forecast) { ran = true }
            #expect(ran)
            #expect(!question.isAsking)
        }
    }
}
