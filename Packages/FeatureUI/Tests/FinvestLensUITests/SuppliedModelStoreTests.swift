//
//  SuppliedModelStoreTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A model the person supplies, as Settings sees it: the folder they chose,
//  what in it can be run, the one in use, and what is handed to the model
//  seam. Nothing is run here — the loader is a stand-in — and nothing is
//  handed to the real seam, which is the whole process's.
//

import Foundation
import Synchronization
import Testing
import FoundationModels
import FinvestLensIntelligence
@testable import FinvestLensUI

/// Stands in for MLX: says which architectures it has, and remembers what it
/// was asked to let go of.
private final class StandInLoader: SuppliedModelLoader {
    let runnable: Set<String>
    let reason: String?
    let released = Mutex<[String]>([])

    init(runnable: Set<String> = ["gemma4"], reason: String? = nil) {
        self.runnable = runnable
        self.reason = reason
    }

    var contextSize: Int { 12_345 }
    var needsFieldGuide: Bool { true }
    func canRun(modelType: String) async -> Bool { runnable.contains(modelType) }
    func languageModel(at directory: URL) -> any LanguageModel { SystemLanguageModel.default }
    func unavailabilityReason(at directory: URL, name: String) async -> String? { reason }
    func release(at directory: URL) async { released.withLock { $0.append(directory.lastPathComponent) } }
}

@Suite("A model the person supplies, as Settings sees it")
@MainActor
struct SuppliedModelStoreTests {

    /// What a store handed over, in order: the model's name, or `nil`.
    private final class Handed {
        var models: [LanguageModels.SuppliedModel?] = []
        /// Why there was no model, each time there was none.
        var reasons: [String?] = []
        var offered = 0
        var last: LanguageModels.SuppliedModel? { models.last ?? nil }
    }

    private func defaults() -> UserDefaults {
        let suite = "finvestlens.supplied-store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func store(_ defaults: UserDefaults, _ handed: Handed) -> SuppliedModelStore {
        SuppliedModelStore(defaults: defaults,
                           publish: { model, reason in
                               handed.models.append(model)
                               if model == nil { handed.reasons.append(reason) }
                           },
                           offer: { handed.offered += 1 })
    }

    /// A folder holding plain model folders: a configuration naming the
    /// architecture, and weights.
    private func folder(_ models: [(name: String, type: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "supplied-\(UUID().uuidString)")
        for model in models {
            let directory = root.appending(path: model.name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"model_type": "\#(model.type)"}"#.utf8).write(to: directory.appending(path: "config.json"))
            try Data(count: 2_048).write(to: directory.appending(path: "model.safetensors"))
        }
        return root
    }

    @Test("Until something can run a model, none is offered and nothing is handed over")
    func nothingToRunOne() async {
        let handed = Handed()
        let store = store(defaults(), handed)
        #expect(!store.isOffered)
        await store.refresh()
        #expect(store.models.isEmpty)
        #expect(handed.offered == 0)
        #expect(handed.last == nil)
    }

    @Test("A folder lists the models that can be run, and only those")
    func listsWhatCanRun() async throws {
        let handed = Handed()
        let store = store(defaults(), handed)
        store.install(StandInLoader())
        #expect(handed.offered == 1)
        let folder = try folder([("alpha-4b", "gemma4"), ("beta-7b", "an-architecture-nobody-has")])
        defer { try? FileManager.default.removeItem(at: folder) }

        store.chooseFolder(folder)
        await store.settling?.value
        #expect(store.models.map(\.name) == ["alpha-4b"])
        // A folder is not a choice of model: nothing is in use, and it says so.
        #expect(store.chosen == nil)
        #expect(handed.last == nil)
        #expect(store.availability == .unavailable(
            reason: "Choose a model of your own in Settings ▸ Apple Intelligence."))
    }

    @Test("Choosing a model makes it the model for everything, at once, and remembers it")
    func choosing() async throws {
        let handed = Handed()
        let defaults = defaults()
        let store = store(defaults, handed)
        store.install(StandInLoader())
        let folder = try folder([("alpha-4b", "gemma4")])
        defer { try? FileManager.default.removeItem(at: folder) }
        store.chooseFolder(folder)
        await store.settling?.value
        let model = try #require(store.models.first)

        store.use(model)
        // Before the loader has been asked anything: a request made now must
        // already go to this model.
        #expect(handed.last?.name == "alpha-4b")
        #expect(handed.last?.availability == .available)
        #expect(defaults.string(forKey: LanguageModels.choiceDefaultsKey) == ModelChoice.supplied.rawValue)

        await store.settling?.value
        #expect(store.chosen == model)
        #expect(store.availability == .available)
        #expect(handed.last?.contextSize == 12_345)
        #expect(handed.last?.needsFieldGuide == true)

        // The next launch: the folder and the model are still the person's.
        let relaunched = Handed()
        let again = self.store(defaults, relaunched)
        again.install(StandInLoader())
        await again.settling?.value
        #expect(again.folder?.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(again.chosen?.name == "alpha-4b")
        #expect(relaunched.last?.name == "alpha-4b")
    }

    @Test("A model that cannot run now is handed over saying why, and a model that has gone is not handed over")
    func cannotRun() async throws {
        let handed = Handed()
        let store = store(defaults(), handed)
        store.install(StandInLoader(reason: "Not now."))
        let folder = try folder([("alpha-4b", "gemma4")])
        defer { try? FileManager.default.removeItem(at: folder) }
        store.chooseFolder(folder)
        await store.settling?.value
        store.use(try #require(store.models.first))
        await store.settling?.value
        #expect(store.availability == .unavailable(reason: "Not now."))
        #expect(handed.last?.availability == .unavailable(reason: "Not now."))

        // The folder is emptied behind the app's back.
        try FileManager.default.removeItem(at: folder.appending(path: "alpha-4b"))
        await store.refresh()
        #expect(store.chosen == nil)
        #expect(store.chosenID != nil)
        #expect(handed.last == nil)
        let gone = "The model you chose isn’t in the models folder any more. Choose another in Settings ▸ Apple Intelligence."
        #expect(store.availability == .unavailable(reason: gone))
        // And the reason goes with the nothing that is handed over, so that
        // a button elsewhere says what happened and not "choose a model".
        #expect(handed.reasons.last == gone)
    }

    @Test("A model whose weights may be loaded is let go of when it leaves the folder, and when the folder is changed")
    func letGoOfWhatLeft() async throws {
        let handed = Handed()
        let loader = StandInLoader()
        let store = store(defaults(), handed)
        store.install(loader)
        let folder = try folder([("alpha-4b", "gemma4")])
        defer { try? FileManager.default.removeItem(at: folder) }
        store.chooseFolder(folder)
        await store.settling?.value
        store.use(try #require(store.models.first))
        await store.settling?.value

        // It is deleted behind the app's back: nothing in the list names it
        // any more, and its weights are still what has to be let go of.
        try FileManager.default.removeItem(at: folder.appending(path: "alpha-4b"))
        await store.refresh()
        #expect(loader.released.withLock { $0 } == ["alpha-4b"])
        // Going back to Apple's model now has nothing left to let go of.
        store.letGo()
        await store.settling?.value
        #expect(loader.released.withLock { $0 } == ["alpha-4b"])

        // Another folder, with a model of the same name: MLX knows a model
        // by the last two parts of its path, so the first is let go of
        // before the second can be mistaken for it.
        let first = try self.folder([("gamma-9b", "gemma4")])
        let second = try self.folder([("gamma-9b", "gemma4")])
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        store.chooseFolder(first)
        await store.settling?.value
        store.use(try #require(store.models.first))
        await store.settling?.value
        store.chooseFolder(second)
        await store.settling?.value
        #expect(loader.released.withLock { $0 } == ["alpha-4b", "gamma-9b"])
        #expect(store.chosen == nil)
        #expect(handed.last == nil)
    }

    @Test("An answer about a folder since replaced is dropped where it lands")
    func staleFolder() async throws {
        let handed = Handed()
        let store = store(defaults(), handed)
        store.install(StandInLoader())
        let old = try folder([("old-model", "gemma4")])
        let new = try folder([("new-model", "gemma4")])
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: new) }
        store.chooseFolder(old)
        let reading = store.settling          // the old folder's reading, still in flight
        store.chooseFolder(new)
        await reading?.value
        await store.settling?.value
        #expect(store.models.map(\.name) == ["new-model"])
    }

    @Test("Changing model lets go of the one before: one model's weights at a time")
    func oneAtATime() async throws {
        let handed = Handed()
        let loader = StandInLoader()
        let store = store(defaults(), handed)
        store.install(loader)
        let folder = try folder([("alpha-4b", "gemma4"), ("gamma-9b", "gemma4")])
        defer { try? FileManager.default.removeItem(at: folder) }
        store.chooseFolder(folder)
        await store.settling?.value
        let alpha = try #require(store.models.first { $0.name == "alpha-4b" })
        let gamma = try #require(store.models.first { $0.name == "gamma-9b" })

        store.use(alpha)
        await store.settling?.value
        #expect(loader.released.withLock { $0 }.isEmpty)
        store.use(gamma)
        await store.settling?.value
        #expect(loader.released.withLock { $0 } == ["alpha-4b"])
        #expect(handed.last?.name == "gamma-9b")
        // Choosing the model already in use lets go of nothing.
        store.use(gamma)
        await store.settling?.value
        #expect(loader.released.withLock { $0 } == ["alpha-4b"])
        // Going back to Apple's model lets go of the weights and keeps the
        // choice of which model was theirs.
        store.letGo()
        await store.settling?.value
        #expect(loader.released.withLock { $0 } == ["alpha-4b", "gamma-9b"])
        #expect(store.chosen == gamma)
    }

    @Test("A model that outweighs its share of memory is cautioned about, not refused")
    func sizeCaution() {
        let memory: UInt64 = 16 * 1_073_741_824
        let share = SuppliedModelStore.memoryShare
        let under = Int64(Double(memory) * share) - 1
        let over = Int64(Double(memory) * share) + 1
        #expect(SuppliedModelStore.sizeCaution(name: "m", bytes: under, memory: memory) == nil)
        let caution = SuppliedModelStore.sizeCaution(name: "big-model", bytes: over, memory: memory)
        #expect(caution?.contains("big-model") == true)
    }
}
