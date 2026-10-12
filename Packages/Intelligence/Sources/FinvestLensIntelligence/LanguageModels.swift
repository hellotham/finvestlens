//
//  LanguageModels.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The one place a request becomes a model, a session and an answer.
//
//  Foundation Models 27 made the model a parameter: `LanguageModelSession`
//  takes `some LanguageModel`, and both Apple's on-device model and its
//  Private Cloud Compute model conform. Until 12 October 2026 every feature
//  here built its own `LanguageModelSession(instructions:)`, which hard-wires
//  the on-device model in ten places and leaves nowhere to ask the two
//  questions the 27 framework wants asked of the model rather than assumed:
//  how much it can read (`contextSize`) and what it can do (`capabilities`).
//
//  Everything a feature needs is asked here, once:
//    • which model — the person's choice, for the features that follow it;
//    • whether it can run, in a sentence that says what to do about it;
//    • how many tokens are left for the document after instructions, the
//      answer's schema and the answer itself — counted by the model where the
//      model will count (`SystemLanguageModel.tokenCount(for:)`);
//    • and what went wrong, in `IntelligenceError`'s words.
//
//  The shape follows HelloNotes' `LanguageModels` (15 September 2026), which
//  is this publisher's other app on the same framework.
//

import Foundation
import FoundationModels
import NaturalLanguage
import Synchronization
#if os(macOS)
import Security
#endif

/// Where a request runs.
public enum ModelChoice: String, Sendable, CaseIterable, Identifiable {
    /// Apple's on-device model. Nothing leaves the device.
    case onDevice
    /// Apple Foundation Models on Private Cloud Compute: a 32K-token window
    /// and reasoning, in exchange for the request leaving the device. Offered
    /// only in a build that holds Apple's managed entitlement — see
    /// ``LanguageModels/privateCloudComputeEnabled``.
    case privateCloud

    public var id: String { rawValue }
}

/// What a request is for.
public enum IntelligenceFeature: String, Sendable, CaseIterable {
    case documentClassifier
    case transactionCategorizer
    case attachmentInsight
    case statementExtractor
    case invoiceAnalyzer
    case dividendExtractor
    case reviewNarrator
    case reportNarrator
    case forecastNarrator
    case budgetAdvisor

    /// Whether this feature runs on the model the person chose, or always on
    /// the device.
    ///
    /// Reading one document and writing about a year's figures are where a
    /// larger window and reasoning earn their place. Work done by the
    /// hundred is not: an import categorises its rows eight at a time, and a
    /// statement is read a thousand characters at a time so that no row is
    /// dropped — dozens of requests for one file, against an allowance
    /// Private Cloud Compute counts per day. So the features that work that
    /// way stay on the device whatever is chosen, and Settings says so.
    public var followsModelChoice: Bool {
        switch self {
        case .documentClassifier, .transactionCategorizer, .attachmentInsight, .statementExtractor: false
        case .invoiceAnalyzer, .dividendExtractor,
             .reviewNarrator, .reportNarrator, .forecastNarrator, .budgetAdvisor: true
        }
    }

    /// Whether a person reads the answer as prose — which is what decides
    /// that it must come back in their language. No `default`: a feature
    /// added later has to say which it is.
    var answersInProse: Bool {
        switch self {
        case .reviewNarrator, .reportNarrator, .forecastNarrator, .budgetAdvisor: true
        case .documentClassifier, .transactionCategorizer, .attachmentInsight,
             .statementExtractor, .invoiceAnalyzer, .dividendExtractor: false
        }
    }

    /// How the model picks its words. Everything that reads, sorts or fills
    /// in a table wants the single most likely answer — greedy, the same
    /// every time. The three narrators write commentary, which reads better
    /// with the model's own sampling and has always been asked for that way;
    /// it is also what makes asking them again worth anything.
    var samplingMode: GenerationOptions.SamplingMode? {
        switch self {
        case .reviewNarrator, .reportNarrator, .forecastNarrator:
            nil
        case .documentClassifier, .transactionCategorizer, .attachmentInsight,
             .statementExtractor, .invoiceAnalyzer, .dividendExtractor, .budgetAdvisor:
            .greedy
        }
    }

    /// No feature registers a tool — every request is one guided generation
    /// — so the 27 tool-calling mode is stated rather than left to its
    /// default of `allowed`.
    var toolCallingMode: GenerationOptions.ToolCallingMode { .disallowed }

    /// The same two values as a request's options, for one made outside the
    /// seam — the surveys, which build their own sessions to move the
    /// language order about. A request made through the seam takes them
    /// from its session's profile (``LanguageModels/FeatureProfile``).
    var options: GenerationOptions {
        var options = GenerationOptions(samplingMode: samplingMode)
        options.toolCallingMode = toolCallingMode
        return options
    }
}

/// An answer read out of a document, which is cut to fit the model's window
/// with room kept back for the answer itself.
protocol DocumentAnswer: Generable {
    /// Tokens kept back for the reply: the type's own ceiling — the array
    /// caps in its guides — priced generously, because the context window
    /// counts generated tokens alongside the prompt. It lives beside the
    /// schema it prices so that raising a cap and raising this are one edit.
    static var replyReserve: Int { get }
}

public enum LanguageModels {

    // MARK: - The models

    static let onDevice = SystemLanguageModel.default

    /// Set by the app target, and only inside `#if PRIVATE_CLOUD_COMPUTE`.
    private static let buildOffersPrivateCloud = Mutex(false)

    /// Says that this build was compiled with the `PRIVATE_CLOUD_COMPUTE`
    /// condition. A package cannot see the app target's compilation
    /// conditions, so the app says so once at launch — and must only ever say
    /// so in the same change that adds the entitlement.
    public static func declarePrivateCloudComputeBuild() {
        buildOffersPrivateCloud.withLock { $0 = true }
    }

    /// Whether this build holds Apple's managed Private Cloud Compute
    /// entitlement.
    ///
    /// **The framework will not tell you, and guessing is fatal.** Without the
    /// entitlement `PrivateCloudComputeLanguageModel.availability` still
    /// reports `.available` — it did from an unsigned probe on this Mac on
    /// 12 October 2026 — and HelloNotes measured what happens next in a signed
    /// app: the first request ends the process with
    /// `fatalError("Missing entitlement: com.apple.developer.private-cloud-compute")`.
    ///
    /// So it is decided at build time, by the flag above, and then checked
    /// against what was actually signed wherever that can be read.
    public static var privateCloudComputeEnabled: Bool {
        buildOffersPrivateCloud.withLock { $0 } && signedWithPrivateCloudCompute
    }

    /// Read once: an entitlement cannot change under a running process.
    ///
    /// On the Mac the signature is asked, because a Developer ID export can
    /// be signed without an entitlement the App Store profile carries. iOS,
    /// iPadOS and visionOS give an app no public way to read its own
    /// entitlements; there a device will not install a build whose
    /// entitlements its provisioning profile does not grant, so the build
    /// flag — held to the entitlements file by `PrivateCloudComputeBuildTests`
    /// — is the check. The Simulator installs anything, so it is never
    /// offered there.
    private static let signedWithPrivateCloudCompute: Bool = {
        #if targetEnvironment(simulator)
        return false
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.private-cloud-compute" as CFString, nil)
        else { return false }
        return (value as? Bool) == true
        #else
        return true
        #endif
    }()

    private static let privateCloudStorage = Mutex<PrivateCloudComputeLanguageModel?>(nil)

    /// `nil` unless this build may use Private Cloud Compute. Not merely
    /// unused when it may not: never created, so nothing reaches it by
    /// accident.
    static var privateCloud: PrivateCloudComputeLanguageModel? {
        guard privateCloudComputeEnabled else { return nil }
        return privateCloudStorage.withLock { stored in
            if stored == nil { stored = PrivateCloudComputeLanguageModel() }
            return stored
        }
    }

    // MARK: - The person's choice

    /// The `UserDefaults` key Settings writes the choice under.
    public static let choiceDefaultsKey = "intelligence.modelChoice"

    /// A choice for the current task only — tests, and nothing else.
    @TaskLocal static var choiceOverride: ModelChoice?

    /// The choices this build can offer. Private Cloud Compute is left out
    /// rather than shown as unavailable: a choice that can never work in this
    /// build is not a choice.
    public static var offeredChoices: [ModelChoice] {
        privateCloudComputeEnabled ? ModelChoice.allCases : [.onDevice]
    }

    /// What a stored preference means in this build: the model it names if
    /// this build offers it, and the build's default otherwise — so a
    /// setting made in an entitled build never strands a later one that is
    /// not, and nothing is written on the person's behalf until they choose.
    ///
    /// The one rule for which model a preference selects; Settings shows the
    /// result of this and nothing of its own.
    public static func choice(stored: String?) -> ModelChoice {
        if let chosen = stored.flatMap(ModelChoice.init(rawValue:)), offeredChoices.contains(chosen) {
            return chosen
        }
        return defaultChoice
    }

    /// The model the person chose — or, where they have chosen nothing, the
    /// default for this build.
    public static var preferredChoice: ModelChoice {
        choice(stored: UserDefaults.standard.string(forKey: choiceDefaultsKey))
    }

    /// What a person who has chosen nothing gets: Private Cloud Compute
    /// wherever the build can offer it, the device otherwise (the owner's
    /// decision, 12 October 2026).
    public static var defaultChoice: ModelChoice {
        privateCloudComputeEnabled ? .privateCloud : .onDevice
    }

    /// The model `feature` runs on when the command asking has said it may
    /// (``permittingOffDevice(_:operation:)``) — what the person's
    /// choice means for this feature, and so what a view says before the
    /// button is pressed. A request no command has spoken for runs on the
    /// device whatever this returns.
    public static func choice(for feature: IntelligenceFeature) -> ModelChoice {
        route(feature, wanted: choiceOverride ?? preferredChoice, permitted: [feature],
              privateCloudServes: availability(of: .privateCloud).isAvailable)
    }

    /// The model a request for `feature` made *now, in this task* is sent
    /// to: ``choice(for:)`` if the command in progress has named the
    /// feature, and the device if it has not.
    ///
    /// - Parameter privateCloudServes: asked of the model itself, except by
    ///   the tests, which have no other way to stand where a build with the
    ///   entitlement stands.
    static func requestRoute(
        for feature: IntelligenceFeature,
        privateCloudServes: @autoclosure () -> Bool = availability(of: .privateCloud).isAvailable
    ) -> ModelChoice {
        route(feature, wanted: choiceOverride ?? preferredChoice, permitted: permittedOffDevice ?? [],
              privateCloudServes: privateCloudServes())
    }

    // MARK: - What a command may send

    /// The features the current task may run off this device, or `nil`
    /// outside any command — which permits none.
    ///
    /// Where a request runs used to be the feature's business alone, while
    /// the app told people about it command by command: a gate, a line of
    /// help, a sentence in Settings. Two lists, and they drifted. Categorise
    /// from Attachment checked and described "attachment insight", which
    /// stays on the device, and then read the same attachment as a dividend
    /// statement and as an invoice, which follow the person's choice — so
    /// with Private Cloud Compute chosen, a document left the device from a
    /// command that Settings said never sent one (found by the review of
    /// 73b2bd6, 12 October 2026; no build could reach Private Cloud Compute
    /// then, so nothing was sent).
    ///
    /// So leaving the device is something a command grants, by naming the
    /// features, from the same list its view reads to say where it runs. The
    /// failure left over is the private one: a path that names nothing stays
    /// on the device.
    @TaskLocal static var permittedOffDevice: Set<IntelligenceFeature>?

    /// Runs `operation` as a command that has told the person `features` may
    /// run where they chose. Every other feature it reaches — and every
    /// feature reached from outside such a command — runs on this device.
    ///
    /// Inside another command it can only narrow: what the person was told
    /// is what the outer command told them.
    nonisolated(nonsending) public static func permittingOffDevice<Result>(
        _ features: Set<IntelligenceFeature>,
        operation: nonisolated(nonsending) () async throws -> Result
    ) async rethrows -> Result {
        let granted = permittedOffDevice.map { $0.intersection(features) } ?? features
        return try await $permittedOffDevice.withValue(granted, operation: operation)
    }

    /// Where a request runs — the whole rule, reading nothing from the
    /// process, so that it is tested in builds that cannot reach Private
    /// Cloud Compute at all (which, until Apple assigns the entitlement, is
    /// every build).
    ///
    /// Private Cloud Compute that cannot serve right now falls back to the
    /// device rather than failing: the fallback is the more private of the
    /// two, so nothing a person chose is exceeded by it.
    static func route(
        _ feature: IntelligenceFeature, wanted: ModelChoice,
        permitted: Set<IntelligenceFeature>, privateCloudServes: @autoclosure () -> Bool
    ) -> ModelChoice {
        switch wanted {
        case .onDevice:
            return .onDevice
        case .privateCloud:
            guard feature.followsModelChoice, permitted.contains(feature), privateCloudServes()
            else { return .onDevice }
            return .privateCloud
        }
    }

    // MARK: - Describing

    public static func availability(of choice: ModelChoice) -> IntelligenceAvailability {
        switch choice {
        case .onDevice:
            IntelligenceAvailability(onDevice.availability)
        case .privateCloud:
            privateCloud.map { IntelligenceAvailability($0.availability) }
                ?? .unavailable(reason: String(localized: "Private Cloud Compute isn’t available in this version of FinvestLens."))
        }
    }

    /// Whether `feature` can run now, on the model it would run on — the
    /// question a menu or a button asks. A feature that follows the person's
    /// choice can run on Private Cloud Compute while the device's own model
    /// is still downloading, which asking about the device alone gets wrong.
    public static func availability(for feature: IntelligenceFeature) -> IntelligenceAvailability {
        availability(of: choice(for: feature))
    }

    /// Whether `feature` would send what it is given off this device now,
    /// from a command that permits it.
    public static func leavesDevice(_ feature: IntelligenceFeature) -> Bool {
        choice(for: feature) != .onDevice
    }

    public static func title(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice: String(localized: "On This Device")
        case .privateCloud: String(localized: "Private Cloud Compute")
        }
    }

    /// Where the figures go, in one sentence. People must be able to tell
    /// whether a feature sends their data to a server.
    ///
    /// Everything in it is named by command, not by kind of document or
    /// kind of work, because that is how the routing is decided
    /// (``permittedOffDevice``). Two earlier wordings were not, and each
    /// promised something a command did not keep: "Categorising … always
    /// run[s] on this device", when Categorise from Attachment also reads
    /// its attachment as an invoice and as a dividend statement; and then
    /// "Bank statements are always read on this device", when a statement
    /// picked in Match Attachments, or attached to a transaction, is read
    /// as an invoice like any other file.
    ///
    /// What happens to a request on Private Cloud Compute is Apple's to say,
    /// and the sentence says it is Apple saying it. "Apple Intelligence &
    /// Privacy" (apple.com/legal/privacy/data/en/intelligence-engine, dated
    /// 14 September 2026, read 12 October 2026): the data processed there
    /// "is not stored or made accessible to Apple".
    public static func privacySummary(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice:
            String(localized: "Runs on this device. Your books and documents never leave it.")
        case .privateCloud:
            String(localized: "Match Attachments, Categorise from Attachment and Split from Invoice send the documents they read to Apple’s Private Cloud Compute to process. Smart Import sends the invoices and dividend statements it finds, and commentary on reports and reviews, budget suggestions and the forecast outlook send the figures they are written from. Apple says what is sent there isn’t stored or made accessible to Apple. A PDF imported as a bank statement is read on this device, and Auto-Categorise and an import’s category suggestions always run on it.")
        }
    }

    /// A line about today's Private Cloud Compute allowance, or `nil` while
    /// there is nothing to say. Persistent and quiet by design — Apple's
    /// guidance is to show the quota where the feature is, not as an alert.
    public static var privateCloudQuotaNote: String? {
        guard let usage = privateCloud?.quotaUsage else { return nil }
        switch usage.status {
        case .belowLimit(let below):
            return below.isApproachingLimit
                ? String(localized: "You’re close to today’s Private Cloud Compute limit.")
                : nil
        case .limitReached:
            return IntelligenceError.quotaReached(resetDate: usage.resetDate).errorDescription
        @unknown default:
            return nil
        }
    }

    /// Whether the system has a way to raise the limit to offer.
    public static var canSuggestLimitIncrease: Bool {
        privateCloud?.quotaUsage.limitIncreaseSuggestion != nil
    }

    /// Presents the system's own options for more Private Cloud Compute.
    public static func suggestLimitIncrease() {
        privateCloud?.quotaUsage.limitIncreaseSuggestion?.show()
    }

    // MARK: - Resolving a model for one request

    /// A model resolved for one request: everything later steps ask of it,
    /// asked once, so a request is planned and run against the same model.
    struct Resolved: Sendable {
        let choice: ModelChoice
        let model: any LanguageModel
        /// Tokens the model can hold — instructions, schema, document and
        /// reply.
        let contextSize: Int
        /// The model's own token count for a prompt, where it offers one.
        /// The on-device model does; Private Cloud Compute has a window and
        /// no counter, and ``TokenBudget/estimate(_:)`` stands in.
        let count: (@Sendable (String) async -> Int?)?
    }

    private static let privateCloudContext = Mutex<Int?>(nil)

    /// Tokens the model can hold — instructions, schema, document and reply.
    public static func contextSize(of choice: ModelChoice) async -> Int {
        switch choice {
        case .onDevice:
            return onDevice.contextSize
        case .privateCloud:
            if let known = privateCloudContext.withLock({ $0 }) { return known }
            guard let privateCloud else { return onDevice.contextSize }
            // 32,768 is what Apple's article gives; used only if the model
            // will not answer, and never remembered.
            guard let size = try? await privateCloud.contextSize else { return 32_768 }
            privateCloudContext.withLock { $0 = size }
            return size
        }
    }

    private static var deviceModel: Resolved {
        Resolved(choice: .onDevice, model: onDevice, contextSize: onDevice.contextSize,
                 count: { try? await onDevice.tokenCount(for: $0) })
    }

    /// The model this request runs on: the person's choice where the command
    /// in progress has named the feature (``permittedOffDevice``), and the
    /// device otherwise.
    static func resolve(_ feature: IntelligenceFeature) async throws -> Resolved {
        try await resolve(feature, as: requestRoute(for: feature))
    }

    private static func resolve(_ feature: IntelligenceFeature, as choice: ModelChoice) async throws -> Resolved {
        if case .unavailable(let reason) = availability(of: choice) {
            throw IntelligenceError.unavailable(reason)
        }
        switch choice {
        case .onDevice:
            // Prose is read by a person, so it has to come back in a
            // language the model can write. Apple: "verify that the current
            // language setting of your app is supported before you call the
            // model."
            if feature.answersInProse, !onDevice.supportsLocale(personLocale) {
                throw IntelligenceError.unsupportedLanguage
            }
            return deviceModel
        case .privateCloud:
            guard let privateCloud else {
                throw IntelligenceError.unavailable(
                    String(localized: "Private Cloud Compute isn’t available in this version of FinvestLens."))
            }
            // The same question as on the device, asked of this model. An
            // answer that cannot be had (it is asked over the network) is
            // not a "no".
            if feature.answersInProse, (try? await privateCloud.supportsLocale(personLocale)) == false {
                throw IntelligenceError.unsupportedLanguage
            }
            return Resolved(choice: .privateCloud, model: privateCloud,
                            contextSize: await contextSize(of: .privateCloud), count: nil)
        }
    }

    // MARK: - Fitting a document

    /// What the instructions and the answer's schema cost on the device's
    /// model, by what they are. Both are constants of a feature — the
    /// dividend extractor's never change, the attachment reader's change
    /// only with the category list — so a batch of fifty documents asks
    /// once, not fifty times.
    private static let measuredFixedTokens = Mutex<[String: Int]>([:])

    /// Tokens spent before the document: the instructions as they will be
    /// sent, and the answer's schema.
    private static func fixedTokens<Output: Generable>(
        instructions: String?, generating: Output.Type, resolved: Resolved
    ) async -> Int {
        // 400 is above every schema in this package as the model counts them
        // (the largest, an invoice with its line items, is 282).
        let estimate = (instructions.map(TokenBudget.estimate) ?? 0) + 400
        guard resolved.choice == .onDevice else { return estimate }
        let key = "\(Output.self)\u{0}\(instructions ?? "")"
        if let known = measuredFixedTokens.withLock({ $0[key] }) { return known }
        async let schema = try? onDevice.tokenCount(for: Output.generationSchema)
        var instructionTokens: Int? = 0
        if let instructions {
            instructionTokens = try? await onDevice.tokenCount(for: Instructions(instructions))
        }
        guard let instructionTokens, let schemaTokens = await schema else { return estimate }
        let measured = instructionTokens + schemaTokens
        measuredFixedTokens.withLock { $0[key] = measured }
        return measured
    }

    /// The longest leading part of `document` that fits `resolved`'s window
    /// beside the instructions, the schema and the reply — and whether
    /// anything was cut.
    ///
    /// **The model's count decides, not an estimate.** The piece is measured
    /// as it will be sent (`framing` wraps it into the prompt), cut in
    /// proportion to how far over it came, and measured again: characters a
    /// token are constant enough *within* one document that this lands in
    /// one or two passes, where a fixed rate across documents is out by a
    /// factor of five between an English letter and a bank statement
    /// (``TokenBudget``). The first version cut by an estimate and measured
    /// only to shrink the estimate's allowance, which never reached a
    /// document the estimate already thought fitted: a statement-like
    /// invoice went out 1,350 tokens over a 5,386-token budget, reported as
    /// uncut (12 October 2026).
    ///
    /// Where the model offers no count, the estimate is measured against in
    /// the same loop.
    ///
    /// - Throws: ``IntelligenceError/contextOverflow`` if the instructions,
    ///   schema and reply leave no room for any document at all.
    static func fit<Output: DocumentAnswer>(
        _ document: String, framing: (String) -> String, instructions: String?,
        generating: Output.Type, resolved: Resolved
    ) async throws -> (text: String, truncated: Bool) {
        let fixed = await fixedTokens(instructions: instructions, generating: generating, resolved: resolved)
        let budget = TokenBudget.inputTokens(context: resolved.contextSize, fixed: fixed,
                                             reply: Output.replyReserve)
        guard budget > 0 else { throw IntelligenceError.contextOverflow }
        func tokens(_ text: String) async -> Int {
            let prompt = framing(text)
            if let count = resolved.count, let measured = await count(prompt) { return measured }
            return TokenBudget.estimate(prompt)
        }
        // No text measured here reaches six characters a token, so nothing
        // longer than that can fit — which bounds what is handed to the
        // counter when someone attaches a three-hundred-page PDF.
        var cut = TokenBudget.leading(document, characters: budget * 6)
        for _ in 0..<8 {
            let measured = await tokens(cut.text)
            if measured <= budget { return cut }
            // 3% under the proportional cut: the last few characters of a
            // piece are not always worth what its average was.
            let proportional = Double(cut.text.count) * Double(budget) / Double(measured) * 0.97
            cut = TokenBudget.leading(document, characters: max(1, min(Int(proportional), cut.text.count - 1)))
            if cut.text.count <= 1 { break }
        }
        return cut
    }

    // MARK: - Running a request

    /// One guided request for `feature`: resolves its model, runs it, and
    /// puts any failure in ``IntelligenceError``'s words.
    ///
    /// - Parameter exactly: how many elements the answer's array property
    ///   named `property` must have — see ``countedSchema(for:property:count:)``.
    static func respond<Output: Generable>(
        _ feature: IntelligenceFeature, instructions: String? = nil, prompt: String,
        generating type: Output.Type = Output.self,
        exactly count: Int? = nil, of property: String? = nil
    ) async throws -> Output {
        try await perform(feature, instructions: instructions, explainRefusal: false) { _, session, _ in
            if let count, let property {
                let content = try await session.respond(
                    to: prompt, schema: countedSchema(for: type, property: property, count: count)).content
                return try Output(content)
            }
            return try await session.respond(to: prompt, generating: type).content
        }
    }

    /// One guided request about a document: the document is cut to what the
    /// resolved model can read beside everything else in the request, the
    /// request is made, and the answer comes back with whether the whole
    /// document was read.
    ///
    /// Planning and running are one operation on purpose. They were two —
    /// `fit`, then `respond` — and each resolved the model for itself, so a
    /// document cut for one model could be sent to another: a Settings
    /// change between the two calls, or the network fallback below, which
    /// re-sent a prompt cut for Private Cloud Compute's 32K window to the
    /// device's 8K one. Here the fallback fits again.
    ///
    /// - Parameters:
    ///   - framing: the prompt around the document, as a function of it — so
    ///     what is measured is what is sent.
    ///   - explainRefusal: ask the model why, if it refuses. That is a
    ///     second request, worth making only where one document is being
    ///     read and a person is waiting to see the reason; a caller that
    ///     tries the next document instead leaves this off.
    static func respond<Output: DocumentAnswer>(
        _ feature: IntelligenceFeature, instructions: String? = nil,
        document: String, framing: (String) -> String,
        generating type: Output.Type = Output.self, explainRefusal: Bool = false
    ) async throws -> (answer: Output, truncated: Bool) {
        try await perform(feature, instructions: instructions, explainRefusal: explainRefusal) {
            resolved, session, sent in
            let fitted = try await fit(document, framing: framing, instructions: sent,
                                       generating: type, resolved: resolved)
            let answer = try await session.respond(to: framing(fitted.text), generating: type).content
            return (answer, fitted.truncated)
        }
    }

    /// `Output`'s own schema with its array property `property` fixed at
    /// exactly `count` elements — which is how a feature says how many rows
    /// its answer has.
    ///
    /// A `@Guide(.maximumCount(40))` is a ceiling written before the request
    /// exists. Asked in Japanese for a budget over two categories, the 27
    /// model filled the other thirty-eight slots with categories of its own
    /// until the context window overflowed, three and a half minutes later
    /// (12 October 2026; in English it happened to stop at two). A count
    /// taken from the request leaves nothing to fill.
    ///
    /// The schema is the macro's, re-read with the one number changed —
    /// `GenerationSchema` is `Codable`, and encodes as JSON Schema — rather
    /// than a second schema written out by hand, so a property's name, its
    /// description and its order have one source: the `@Generable` type.
    /// `LanguageModelsTests` holds the encoding in place; if it ever stops
    /// reading this way, the request falls back to the macro's ceiling
    /// rather than failing.
    static func countedSchema<Output: Generable>(
        for type: Output.Type, property: String, count: Int
    ) -> GenerationSchema {
        guard let data = try? JSONEncoder().encode(Output.generationSchema),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var properties = root["properties"] as? [String: Any],
              var array = properties[property] as? [String: Any],
              array["type"] as? String == "array"
        else { return Output.generationSchema }
        array["minItems"] = count
        array["maxItems"] = count
        properties[property] = array
        root["properties"] = properties
        guard let patched = try? JSONSerialization.data(withJSONObject: root),
              let schema = try? JSONDecoder().decode(GenerationSchema.self, from: patched)
        else { return Output.generationSchema }
        return schema
    }

    /// Resolves the model, runs `request` on a session for it, and — for
    /// Private Cloud Compute only — runs it again on the device if the
    /// network is what failed.
    ///
    /// - Parameter request: given the model it is running on, a session for
    ///   it, and the instructions as that session was given them.
    private static func perform<Output>(
        _ feature: IntelligenceFeature, instructions: String?, explainRefusal: Bool,
        _ request: (Resolved, LanguageModelSession, String?) async throws -> Output
    ) async throws -> Output {
        let resolved = try await resolve(feature)
        func attempt(on resolved: Resolved) async throws -> Output {
            let sent = Self.instructions(instructions, for: feature)
            let session = LanguageModelSession(profile: FeatureProfile(
                feature: feature, model: resolved.model, instructions: sent))
            do {
                return try await request(resolved, session, sent)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard explainRefusal else { throw IntelligenceError.wrap(error) }
                throw try await IntelligenceError.describing(error)
            }
        }
        do {
            return try await attempt(on: resolved)
        } catch IntelligenceError.networkUnavailable where resolved.choice == .privateCloud {
            // Apple's guidance for Private Cloud Compute: "if the request
            // fails because the network connection is unavailable, retry the
            // request using the on-device model." The whole request is run
            // again, so a document is cut again for the smaller window.
            guard let device = try? await resolve(feature, as: .onDevice) else {
                throw IntelligenceError.networkUnavailable
            }
            return try await attempt(on: device)
        }
    }

    // MARK: - Sessions

    /// A feature's session, as 27 declares one: the model, how it picks its
    /// words, whether it may call a tool and what it is told to be, in one
    /// place (`LanguageModelSession.DynamicProfile`) instead of spread over
    /// the session's initialiser and every request's options.
    ///
    /// A session is made for one request and let go. Keeping one for a
    /// batch — a statement's slices, an import's rows, which all share
    /// their instructions — was built and measured, and is not here: the
    /// model's prefix cache does engage (381 of about 670 prompt tokens on
    /// every request after the first, by the Foundation Models instrument,
    /// 12 October 2026), and it takes the 455 ms a request spends before
    /// generating down to about 440, on a request that then generates for
    /// 2.3 seconds. Six categoriser requests took 16.80 s one way and 16.78
    /// the other. See docs/intelligence-prompts.md.
    struct FeatureProfile: LanguageModelSession.DynamicProfile {
        let feature: IntelligenceFeature
        let model: any LanguageModel
        let instructions: String?

        var body: some LanguageModelSession.DynamicProfile {
            LanguageModelSession.Profile {
                if let instructions { Instructions(instructions) }
            }
            .model(model)
            .samplingMode(feature.samplingMode)
            .toolCallingMode(feature.toolCallingMode)
        }
    }

    // MARK: - Drafting prose

    /// The narrators' one policy for a draft that may be wrong: up to
    /// `attempts` drafts, and the first that is sound and in the person's
    /// language wins.
    ///
    /// - A draft that is not sound (`draft` returns `nil` — a number that is
    ///   not a fact, nothing written at all) is never shown.
    /// - A sound draft in the wrong language is kept in hand while the model
    ///   is asked again, and shown if nothing better arrives — which is what
    ///   every reader got before the language was asked for at all.
    /// - A draft that *fails* does not cost the one in hand. A failure that
    ///   another draft cannot change — no model, no allowance, no network —
    ///   ends the asking; any other is one draft lost.
    ///
    /// This was written out three times, once in each narrator, and all
    /// three let a failed second draft throw away a sound first.
    ///
    /// - Parameters:
    ///   - text: the draft's prose, for the language check.
    ///   - labels: the request's own words, which the prose may repeat in
    ///     the language they were given in.
    ///   - nothingSound: what to say when every draft was unsound.
    static func firstSoundDraft<Draft>(
        attempts: Int = 3, text: (Draft) -> String, quoting labels: String,
        nothingSound: @autoclosure () -> IntelligenceError,
        draft: () async throws -> Draft?
    ) async throws -> Draft {
        var inHand: Draft?
        var failure: IntelligenceError?
        for _ in 0..<attempts {
            do {
                guard let candidate = try await draft() else { continue }
                if isInPersonLanguage(text(candidate), quoting: labels) { return candidate }
                inHand = inHand ?? candidate
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let wrapped = IntelligenceError.wrap(error)
                failure = failure ?? wrapped
                if wrapped.endsABatch { break }
            }
        }
        if let inHand { return inHand }
        throw failure ?? nothingSound()
    }

    /// Whether `text` is prose and nothing else.
    ///
    /// Guided generation should make this unnecessary, and in English it has
    /// been. Asked for a review slide in Japanese, the macOS 27 model twice
    /// ended an otherwise sound insight with the debris of its own output
    /// format — a closing bracket, "<ctrl46>", a code fence and the start of
    /// a second JSON object (12 October 2026). The number check caught those
    /// two only because the debris happened to have a number in it.
    static func isCleanProse(_ text: String) -> Bool {
        !text.contains("```") && !text.contains("<ctrl")
            && !text.contains(where: { "{}".contains($0) })
            && !text.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" }
    }

    // MARK: - Language

    /// A locale for the current task only — tests, and nothing else.
    @TaskLocal static var localeOverride: Locale?

    /// The person's locale as the app sees it: `Locale.current` already
    /// accounts for a language chosen for this app alone in Settings.
    static var personLocale: Locale { localeOverride ?? .current }

    /// `base` with what the model needs to know about the person's language.
    ///
    /// Two sentences, both Apple's ("Supporting languages and locales with
    /// Foundation Models"). The first is the exact phrase the model was
    /// trained on — "The person's locale is en_AU." — which Apple says reduces
    /// hallucination outside U.S. English, and which for this app also tells
    /// the model how a date like 03/04/2026 reads. The second is only for
    /// prose: the prompts here are written in English, so without it a
    /// German reader gets an English paragraph.
    ///
    /// **The phrase goes first, and that is measured, not style.** Apple's
    /// article says "Start with the exact phrase". Appended to the end of the
    /// dividend extractor's instructions instead, it made the macOS 27 model
    /// refuse the synthetic dividend statement outright — three runs in
    /// three, 12 October 2026 — where the same phrase at the start passed
    /// three in three, with every other live test, and no phrase at all
    /// passed too. `LiveModelTests` is what holds this in place.
    ///
    /// The locale is named by language and region alone. A calendar or
    /// numbering preference rides on the identifier as a keyword
    /// ("en_AU@calendar=buddhist"), and that is not a phrase the model was
    /// trained on.
    ///
    /// **The language order is given twice, and that is measured too** — the
    /// table is in `docs/intelligence-prompts.md` (224 drafts, judged by an
    /// oracle that is not this file's own check). With no order, nothing
    /// came back in the language at all. Given once it was followed well in
    /// some languages and badly in others, differently at the start than at
    /// the end. Given at both ends, six of the seven languages came back in
    /// the language asked eight times in eight; French five in eight — which
    /// is why the narrators also check the language of what comes back
    /// (``isInPersonLanguage(_:quoting:locale:)``) rather than trust that
    /// the order was followed. What French is waiting for is the facts in
    /// French: sixteen in sixteen once the slide's labels were.
    ///
    /// A feature that sends no instructions keeps sending none: the document
    /// classifier does that deliberately (any instructions at all tripped the
    /// 27 guardrail on an invoice), and this does not undo it.
    static func instructions(_ base: String?, for feature: IntelligenceFeature,
                             locale: Locale = personLocale) -> String? {
        guard let base else { return nil }
        var parts: [String] = []
        if !Locale.Language(identifier: "en_US").isEquivalent(to: locale.language) {
            parts.append("The person's locale is \(localeName(locale)).")
        }
        let order = feature.answersInProse
            ? responseLanguage(for: locale).map { "You MUST respond in \($0)." } : nil
        if let order { parts.append(order) }
        parts.append(base)
        if let order { parts.append(order) }
        return parts.joined(separator: "\n")
    }

    /// `locale` as language and region — "en_AU", "zh_Hans_CN" — without the
    /// keywords an identifier can carry after "@".
    static func localeName(_ locale: Locale) -> String {
        String(locale.identifier.prefix { $0 != "@" })
    }

    /// Whether `text` reads as the person's language — the check behind the
    /// order, since the order is not always obeyed.
    ///
    /// Where no language was ordered (English), there is nothing to check.
    /// Where the language has a script of its own, the script is the answer:
    /// Japanese prose has kana in it, Chinese has ideographs, Korean has
    /// Hangul, whatever else the sentence quotes. Otherwise the system's
    /// recogniser is asked — about the words the model *chose*, not the ones
    /// it was handed: account names and figure labels reach the model in the
    /// language the book is kept in, and a French sentence that repeats
    /// "Expenses:Housing" and "Net worth" beside three amounts is still
    /// French. The recogniser is also told the answer is one of two
    /// languages, which is all it can be.
    ///
    /// The first version asked the recogniser about the whole text and
    /// believed it. Run on the model's own kind of output (12 October 2026)
    /// it called Japanese and Chinese sentences English when they carried
    /// account names, a French slide English when it was mostly labels, and
    /// English "Romanian" and "Croatian" when it was mostly figures — each
    /// of which cost two more requests and changed nothing.
    ///
    /// Too little of the model's own wording to judge passes: this is for
    /// asking again, never for throwing an answer away.
    ///
    /// - Parameter labels: the request's own words, which the prose may
    ///   repeat as given.
    static func isInPersonLanguage(_ text: String, quoting labels: String = "",
                                   locale: Locale = personLocale) -> Bool {
        guard responseLanguage(for: locale) != nil,
              let wanted = locale.language.languageCode else { return true }
        // The model's own words: letters only, less every word it was given.
        func words(_ string: String) -> [String] {
            string.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        let given = Set(words(labels))
        let own = words(text).filter { !given.contains($0) }
        func has(_ ranges: ClosedRange<UInt32>...) -> Bool {
            own.contains { word in
                word.unicodeScalars.contains { scalar in ranges.contains { $0.contains(scalar.value) } }
            }
        }
        // Too little of its own wording to call, in any script.
        guard own.joined().count >= 16 || has(0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF) else {
            return true
        }
        switch wanted {
        case .japanese: return has(0x3040...0x30FF)
        case .chinese: return has(0x3400...0x4DBF, 0x4E00...0x9FFF)
        case .korean: return has(0xAC00...0xD7AF)
        default: break
        }
        let recogniser = NLLanguageRecognizer()
        let target = NLLanguage(rawValue: wanted.identifier)
        recogniser.languageConstraints = [.english, target]
        recogniser.processString(own.joined(separator: " "))
        guard let found = recogniser.dominantLanguage, found != .undetermined else { return true }
        return found == target
    }

    /// The language to order prose into, in English, or `nil` for English —
    /// where the prompts' own language already decides it.
    ///
    /// Chinese is named by script and Portuguese by country, because the
    /// bare language name loses exactly what the app's two catalogs for them
    /// distinguish (Simplified Chinese; Brazilian Portuguese). Portuguese
    /// with no region, or a region that is neither Portugal's nor one of the
    /// countries that write it Portugal's way, is Brazilian: that is the
    /// catalog the app has, so it is the Portuguese the rest of the screen is
    /// in.
    static func responseLanguage(for locale: Locale) -> String? {
        guard let code = locale.language.languageCode, code != .english else { return nil }
        if code == .chinese {
            let script = locale.language.script
                ?? Locale.Language(identifier: locale.language.maximalIdentifier).script
            return script == .hanTraditional ? "Traditional Chinese" : "Simplified Chinese"
        }
        if code == .portuguese {
            let european: Set<String> = ["PT", "AO", "MZ", "CV", "GW", "ST", "TL", "MO"]
            let region = (locale.language.region ?? locale.region)?.identifier
            return region.map(european.contains) == true ? "European Portuguese" : "Brazilian Portuguese"
        }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code.identifier)
    }
}
