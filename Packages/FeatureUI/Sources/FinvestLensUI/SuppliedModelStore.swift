//
//  SuppliedModelStore.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A model the person supplies, as Settings sees it: the folder they pointed
//  at, the models in it that can be run, and the one they chose.
//
//  The publisher provides no model, no key and no endpoint, and the app
//  fetches nothing: everything here is the person's (the owner's rule,
//  12 October 2026). So there is one place for models — a folder they
//  choose, normally the Hugging Face cache other MLX tools already keep
//  theirs in — and the app only reads it. The sandbox lets it read nothing
//  it has not been given, so the folder is granted once and kept as a
//  security-scoped bookmark.
//
//  What *runs* a model is not here. MLX cannot be built by `swift build`
//  (its Metal library needs Xcode), so it is linked by the app target, which
//  hands this store a ``SuppliedModelLoader`` at launch. Without one — the
//  package's tests, `finlab` — nothing is offered.
//
//  The shape follows HelloNotes: nothing about a model is remembered, and
//  what it is and whether it can run are asked each time.
//

import Foundation
import FoundationModels
import Observation
import FinvestLensIntelligence

/// What runs a model the person supplies.
public protocol SuppliedModelLoader: Sendable {
    /// Whether there is an architecture for models of this type —
    /// `model_type` in a model's `config.json`.
    func canRun(modelType: String) async -> Bool
    /// The model in `directory` as a language model. Loads nothing: weights
    /// are read on the first request.
    func languageModel(at directory: URL) -> any LanguageModel
    /// Why the model in `directory` cannot run now, in words for the person
    /// — or `nil` if it can.
    func unavailabilityReason(at directory: URL, name: String) async -> String?
    /// Tokens of context a supplied model is planned against on this device.
    var contextSize: Int { get }
    /// Whether a model run this way has to be told in words what an answer's
    /// fields hold, because it is held to a schema it is never shown.
    var needsFieldGuide: Bool { get }
    /// Lets go of the model in `directory`, if it is loaded.
    func release(at directory: URL) async
}

@MainActor
@Observable
public final class SuppliedModelStore {

    public static let shared = SuppliedModelStore()

    enum Keys {
        /// The model in use, by its directory.
        static let model = "intelligence.suppliedModel"
        /// The models folder, as a security-scoped bookmark.
        static let folder = "intelligence.suppliedFolderBookmark"
    }

    /// The share of this device's memory a model may occupy before the app
    /// says so. iOS is stricter: the system ends a foreground app that grows
    /// too large, without asking.
    static var memoryShare: Double {
        #if os(macOS)
        0.40
        #else
        0.25
        #endif
    }

    /// The folder the person chose, if they have chosen one.
    public private(set) var folder: URL?
    /// The models in it that the loader can run, by name.
    public private(set) var models: [SuppliedModelFile] = []
    public private(set) var chosenID: String?
    /// Whether the chosen model can run, as last asked.
    public private(set) var availability: IntelligenceAvailability =
        .unavailable(reason: String(localized: "Choose a model of your own in Settings ▸ Apple Intelligence."))
    public private(set) var lastError: String?

    private var loader: (any SuppliedModelLoader)?
    private var scopeOpen = false
    private let defaults: UserDefaults
    /// Where the chosen model is handed over, and where it is said that
    /// one can be chosen at all. The model seam's, except under test: these
    /// are the whole process's, and a test that set them would be choosing
    /// a model for every other test running beside it.
    private let publish: @MainActor (LanguageModels.SuppliedModel?, String?) -> Void
    private let offer: @MainActor () -> Void
    /// The directory of the model last handed over — the one whose weights
    /// may be loaded. Kept apart from the choice: a model can leave the
    /// folder, or the folder be changed, while its weights are in memory,
    /// and then there is nothing in `models` to say what to let go of.
    private var handedOver: URL?

    init(defaults: UserDefaults = .standard,
         publish: @escaping @MainActor (LanguageModels.SuppliedModel?, String?) -> Void
             = { LanguageModels.supply($0, because: $1) },
         offer: @escaping @MainActor () -> Void = { LanguageModels.offerSuppliedModels() }) {
        self.defaults = defaults
        self.publish = publish
        self.offer = offer
        chosenID = defaults.string(forKey: Keys.model)
    }

    /// Says what runs a supplied model, and so that one can be offered.
    /// Called once at launch, by the app target.
    public func install(_ loader: any SuppliedModelLoader) {
        self.loader = loader
        offer()
        if let data = defaults.data(forKey: Keys.folder), let resolved = ScopedBookmark.resolve(data) {
            // The scope first: a bookmark that carries one can only be made
            // again while the access it grants is open.
            scopeOpen = resolved.url.startAccessingSecurityScopedResource()
            if resolved.stale, let fresh = ScopedBookmark.make(resolved.url) {
                defaults.set(fresh, forKey: Keys.folder)
            }
            folder = resolved.url
        }
        settling = Task { await refresh() }
    }

    /// The reading of the folder, or the asking after a model, that the last
    /// change set off. Awaited by tests; nothing else needs to.
    private(set) var settling: Task<Void, Never>?

    /// Whether this app can run a supplied model at all.
    public var isOffered: Bool { loader != nil }

    /// Counts every change to which model answers: one handed over, one
    /// taken away, one let go of. Not derived from anything — choosing the
    /// model that was already chosen, after a spell on Apple's, changes no
    /// other property here and changes the answer all the same.
    private var revision = 0

    /// Read for its side effect, by a view that asks `LanguageModels` what
    /// can run or whose model would answer: `LanguageModels` is not
    /// observable, and the answer changes when the folder has been read,
    /// when the chosen model has gone, and when the person picks between
    /// their model and Apple's in a Settings window that is not this view's.
    /// Without it a button drawn before any of those stayed as it was.
    public func observe() {
        _ = revision
    }

    /// The model in use, if it is in the folder.
    public var chosen: SuppliedModelFile? { models.first { $0.id == chosenID } }

    /// Said when the model in use weighs more than a share of this device's
    /// memory. Not a refusal: the person chose it, and only they know what
    /// else they are running.
    public var sizeCaution: String? {
        chosen.flatMap {
            Self.sizeCaution(name: $0.name, bytes: $0.bytes, memory: ProcessInfo.processInfo.physicalMemory)
        }
    }

    static func sizeCaution(name: String, bytes: Int64, memory: UInt64) -> String? {
        guard Double(bytes) > Double(memory) * memoryShare else { return nil }
        let size = bytes.formatted(.byteCount(style: .file))
        let total = Int64(memory).formatted(.byteCount(style: .file))
        return String(localized: "\(name)’s weights are \(size), on a device with \(total) of memory. It may fail to load, or be stopped while it runs.")
    }

    // MARK: Choosing

    /// Make `url` the models folder, keeping access to it across launches.
    public func chooseFolder(_ url: URL) {
        let opened = url.startAccessingSecurityScopedResource()
        guard let bookmark = ScopedBookmark.make(url) else {
            if opened { url.stopAccessingSecurityScopedResource() }
            lastError = String(localized: "FinvestLens couldn’t keep access to “\(url.lastPathComponent)”. Choose the folder again.")
            return
        }
        // What was loaded from the old folder is let go of while that folder
        // can still be read: MLX knows a model by the last two parts of its
        // path, so a model of the same name in the new folder would
        // otherwise be answered by the old one's weights.
        let before = handedOver
        handedOver = nil
        if scopeOpen { folder?.stopAccessingSecurityScopedResource() }
        folder = url
        scopeOpen = opened
        defaults.set(bookmark, forKey: Keys.folder)
        lastError = nil
        settling = Task {
            if let before { await loader?.release(at: before) }
            await refresh()
        }
    }

    /// Use `model` — for everything Apple Intelligence does here.
    public func use(_ model: SuppliedModelFile) {
        let before = handedOver
        chosenID = model.id
        defaults.set(model.id, forKey: Keys.model)
        defaults.set(ModelChoice.supplied.rawValue, forKey: LanguageModels.choiceDefaultsKey)
        lastError = nil
        // Handed over now, as the folder showed it: asking the loader takes
        // a moment, and a request made in that moment must not go to the
        // model that was chosen before.
        if let loader {
            availability = .available
            hand(over: model, to: loader)
        }
        revision += 1
        settling = Task {
            // One model's weights at a time.
            if let before, before != model.directory { await loader?.release(at: before) }
            await refreshAvailability()
        }
    }

    /// Let go of the weights of the model that was in use, because the
    /// person has chosen Apple's model instead. The choice of *which* model
    /// of theirs is kept: going back to it is one pick, and it loads again
    /// when first asked. Without this a model once used stayed in memory —
    /// fourteen gigabytes of it, for the one tried — until the app was quit.
    public func letGo() {
        revision += 1
        guard let loader, let directory = handedOver else { return }
        settling = Task { await loader.release(at: directory) }
    }

    private func hand(over model: SuppliedModelFile, to loader: any SuppliedModelLoader) {
        let directory = model.directory
        handedOver = directory
        publish(LanguageModels.SuppliedModel(
            name: model.name, contextSize: loader.contextSize, availability: availability,
            needsFieldGuide: loader.needsFieldGuide,
            make: { loader.languageModel(at: directory) }), nil)
        revision += 1
    }

    /// Says there is no model to hand over, and why; and lets go of the one
    /// that was, if its weights may still be loaded.
    private func handNothing(because reason: String?) async {
        publish(nil, reason)
        revision += 1
        if let before = handedOver {
            handedOver = nil
            await loader?.release(at: before)
        }
    }

    /// Read the folder, and keep the models the loader can run.
    ///
    /// Each of these waits — on the disk, on the loader — and the person can
    /// choose another folder or another model while it does. What is found
    /// is kept only if it is still what was asked about; an answer about a
    /// folder since replaced, or a model since changed, is dropped where it
    /// lands and not written over the newer one.
    public func refresh() async {
        guard let loader, let folder else {
            models = []
            await refreshAvailability()
            return
        }
        let found = await Task.detached { SuppliedModelFolder.models(in: folder) }.value
        var runnable: [String: Bool] = [:]
        for type in Set(found.compactMap(\.modelType)) {
            runnable[type] = await loader.canRun(modelType: type)
        }
        guard self.folder == folder else { return }
        models = found.filter { model in model.modelType.flatMap { runnable[$0] } ?? false }
        await refreshAvailability()
    }

    /// Ask whether the chosen model can run, and tell the model seam.
    public func refreshAvailability() async {
        guard let loader else {
            await handNothing(because: nil)
            return
        }
        guard let chosen else {
            let reason = chosenID == nil
                ? String(localized: "Choose a model of your own in Settings ▸ Apple Intelligence.")
                : String(localized: "The model you chose isn’t in the models folder any more. Choose another in Settings ▸ Apple Intelligence.")
            availability = .unavailable(reason: reason)
            await handNothing(because: reason)
            return
        }
        let directory = chosen.directory
        let found: IntelligenceAvailability
        if let missing = await Task.detached(operation: { SuppliedModelFolder.firstFileNotOnDevice(in: directory) }).value {
            found = .unavailable(reason: String(localized: "“\(missing)” in \(chosen.name) hasn’t downloaded to this device yet."))
        } else {
            found = await loader.unavailabilityReason(at: directory, name: chosen.name)
                .map { .unavailable(reason: $0) } ?? .available
        }
        guard self.chosen?.id == chosen.id else { return }
        availability = found
        hand(over: chosen, to: loader)
    }
}
