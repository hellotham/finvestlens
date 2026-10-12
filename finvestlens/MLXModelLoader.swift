//
//  MLXModelLoader.swift
//  FinvestLens
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  What runs a model the person supplies: MLX, in this process, on this
//  device, from a folder they pointed the app at.
//
//  It is here, in the app target, and not in a package, because MLX needs a
//  Metal library that only Xcode builds: a package that linked it could not
//  be built or tested with `swift build`. The packages know a supplied model
//  only as a Foundation Models `LanguageModel` (`SuppliedModelLoader`).
//
//  **Nothing is fetched.** The publisher provides no model, no key and no
//  endpoint (the owner's rule, 12 October 2026). A model is loaded from the
//  directory it is in, and the one adapter that could download — the loader's
//  `Downloader` — is one that refuses (`NoDownloads`). It is never called for
//  a model given by its directory; if a later version of the library calls it
//  anyway, the request fails rather than reaching the network.
//
//  The tokenizer bridge mirrors HelloNotes'. mlx-swift-lm ships it as macros
//  (`#huggingFaceTokenizerLoader`), and a package macro is a compiler plugin
//  that Xcode will not run until someone has clicked "Trust & Enable" — which
//  a CI runner and a release archive cannot do. Written out by hand it is
//  forty lines, and can be diffed against the macro's expansion when the
//  package moves.
//

import Foundation
import FoundationModels
import FinvestLensUI
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Tokenizers

struct MLXModelLoader: SuppliedModelLoader {

    /// Tokens of context a supplied model is planned against.
    ///
    /// Models accept far more (32,768 and up is ordinary), but the key-value
    /// cache costs memory for every token, and a model the person chose may
    /// already be most of what the device has. So the window the app uses is
    /// set by the device, not by the model.
    var contextSize: Int {
        #if os(macOS)
        16_384
        #else
        8_192
        #endif
    }

    /// MLX compiles an answer's schema into a constraint on the tokens the
    /// model may write, and that is all it does with it: the model is sent
    /// the instructions and the prompt (`TranscriptConverter`), never the
    /// schema. So what each field means has to be said in the instructions.
    var needsFieldGuide: Bool { true }

    func canRun(modelType: String) async -> Bool {
        await LLMTypeRegistry.shared.contains(modelType)
    }

    func languageModel(at directory: URL) -> any FoundationModels.LanguageModel {
        model(at: directory)
    }

    /// Guided generation and nothing more: every request the app makes of a
    /// supplied model is one typed answer. It is not shown pictures and is
    /// offered no tools.
    private func model(at directory: URL) -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: ModelConfiguration(directory: directory),
            capabilities: [.guidedGeneration],
            weightsLocation: { _ in directory },
            load: { configuration, progress in
                try await loadModelContainer(
                    from: NoDownloads(),
                    using: TransformersTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: progress)
            })
    }

    func unavailabilityReason(at directory: URL, name: String) async -> String? {
        #if targetEnvironment(simulator)
        // MLX needs a real Metal GPU; the simulator's cannot run its kernels.
        // Said to whoever is running a simulator, which is a developer: not
        // a sentence anyone using the app can meet, so not one to translate.
        return String("A model of your own runs on a Mac, iPhone or iPad — not in the simulator.")
        #else
        switch await model(at: directory).availability {
        // "Downloading" is MLX's word for *a load is in flight*: the first
        // request to a model reads its weights off the disk, and for as
        // long as that takes this is what it reports
        // (`ModelCache.isDownloading`). Nothing is being downloaded — the
        // downloader this loader is given refuses — and a model that is
        // loading is one that is about to answer. Taken as "cannot be
        // used", opening Settings during a model's first request sent
        // every request after it to Apple's model.
        case .available, .downloading:
            return nil
        case .unavailable(.deviceNotCapable):
            return String(localized: "This device can’t run a model of your own.")
        case .unavailable(.modelNotDownloaded):
            return String(localized: "\(name) isn’t in the models folder any more. Choose another in Settings ▸ Apple Intelligence.")
        default:
            return String(localized: "\(name) can’t be used right now.")
        }
        #endif
    }

    func release(at directory: URL) async {
        await model(at: directory).evict()
    }
}

/// The downloader the loader is given: one that does not download.
private struct NoDownloads: MLXLMCommon.Downloader {
    struct Refused: LocalizedError {
        let id: String
        var errorDescription: String? {
            String(localized: "FinvestLens doesn’t download models. “\(id)” has to be in your models folder.")
        }
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw Refused(id: id)
    }
}

/// Loads a model's tokenizer with swift-transformers.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

/// swift-transformers' tokenizer, spoken in MLXLMCommon's vocabulary.
private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names this `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
