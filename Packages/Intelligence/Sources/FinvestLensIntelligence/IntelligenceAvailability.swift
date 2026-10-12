//
//  IntelligenceAvailability.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FoundationModels

/// Whether Apple Intelligence features can run on this device, and if not, why.
///
/// The on-device model requires Apple silicon with
/// Apple Intelligence enabled in System Settings. Callers use this to hide or
/// disable AI features rather than surfacing errors after the fact.
public enum IntelligenceAvailability: Sendable, Equatable {
    case available
    /// A short, user-presentable explanation (device, OS, or setting).
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }

    /// The device's own model. Cheap enough to call whenever a menu is
    /// built. Whether a particular *feature* can run is
    /// ``LanguageModels/availability(for:)``, which asks about the model
    /// that feature would use.
    public static func current() -> IntelligenceAvailability {
        LanguageModels.availability(of: .onDevice)
    }

    /// Where the person turns Apple Intelligence on, named the way their
    /// platform names it. Telling an iPad user to open System Settings sends
    /// them looking for an app they do not have — which this did until
    /// 12 October 2026.
    static var settingsName: String {
        #if os(macOS)
        String(localized: "System Settings")
        #else
        String(localized: "Settings")
        #endif
    }
}

extension IntelligenceAvailability {
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(.deviceNotEligible):
            self = .unavailable(reason: String(localized: "This device does not support Apple Intelligence."))
        case .unavailable(.appleIntelligenceNotEnabled):
            self = .unavailable(reason: String(localized: "Turn on Apple Intelligence in \(Self.settingsName) to use this feature."))
        case .unavailable(.modelNotReady):
            self = .unavailable(reason: Self.modelStillDownloading)
        case .unavailable:
            self = .unavailable(reason: String(localized: "Apple Intelligence is not available on this device."))
        }
    }

    init(_ availability: PrivateCloudComputeLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(.deviceNotEligible):
            self = .unavailable(reason: String(localized: "Private Cloud Compute isn’t available on this device."))
        case .unavailable(.systemNotReady):
            self = .unavailable(reason: String(localized: "Private Cloud Compute isn’t ready yet. Check that Apple Intelligence is on in \(Self.settingsName), then try again."))
        case .unavailable:
            self = .unavailable(reason: Self.privateCloudUnavailable)
        }
    }

    /// Said of the model while it downloads, and of its assets when a
    /// request finds them missing — one sentence, so one catalog key.
    static var modelStillDownloading: String {
        String(localized: "The Apple Intelligence model is still downloading. Try again shortly.")
    }

    static var privateCloudUnavailable: String {
        String(localized: "Private Cloud Compute is unavailable right now.")
    }
}

/// Errors surfaced by Intelligence features.
public enum IntelligenceError: LocalizedError {
    case unavailable(String)
    case emptyDocument
    /// A safety guardrail stopped the request, or the model refused it and
    /// gave no reason.
    case guardrailDeclined
    /// The model refused and said why (`LanguageModelError.Refusal.explanation`,
    /// new in Foundation Models 27). The text is the model's own.
    case refused(String)
    /// Instructions + prompt + generated output did not fit the model's
    /// context window. Distinguished from a general failure because it is the
    /// one failure a caller can *act* on: send less text (see
    /// ``StatementExtractor``, which halves and retries on exactly this).
    case contextOverflow
    /// The system's text recogniser itself failed — not "no text on the
    /// page" (that is ``emptyDocument``) but the engine refusing to run.
    /// Seen 12 Oct 2026 on a virtual Mac, where Vision threw its own
    /// `CRImageReaderError` ("e5rt_e5_compiler_compile call failed") and the
    /// raw error reached callers that only know this type. The associated
    /// value is the engine's own description, for the log.
    case recognitionFailed(String)
    /// The model does not read or write this language
    /// (`LanguageModelError.unsupportedLanguageOrLocale`, or the app's
    /// language failing `supportsLocale` before a prose request).
    case unsupportedLanguage
    /// Rate limited: nothing is wrong with the request, and asking again
    /// shortly is the remedy. The system limits an app that is not in front,
    /// so every request that follows will be limited too.
    case busy
    /// One request ran out of time. Unlike ``busy`` this is about the
    /// request — a statement slice the model wandered off on once ran for
    /// 56 seconds — and the next one may be answered in ten.
    case timedOut
    /// Today's Private Cloud Compute allowance is used up.
    case quotaReached(resetDate: Date?)
    /// Private Cloud Compute could not be reached, and the device's own model
    /// could not stand in.
    case networkUnavailable
    case modelFailure(String)

    /// Whether this is a failure of the model or the service rather than of
    /// what was asked — so that asking again with other text, or for another
    /// draft, would fail the same way. A statement read slice by slice stops
    /// here instead of reporting the pages it got as the whole statement.
    public var endsABatch: Bool {
        switch self {
        case .unavailable, .busy, .quotaReached, .networkUnavailable: true
        case .emptyDocument, .guardrailDeclined, .refused, .contextOverflow, .recognitionFailed,
             .unsupportedLanguage, .timedOut, .modelFailure: false
        }
    }

    /// Whether the model was reached and would not, or could not, do *this*:
    /// it declined the content, or does not write the language. Asking it
    /// for something simpler may then succeed where asking again will not.
    var isAboutTheRequest: Bool {
        switch self {
        case .guardrailDeclined, .refused, .unsupportedLanguage: true
        case .unavailable, .emptyDocument, .contextOverflow, .recognitionFailed, .busy, .timedOut,
             .quotaReached, .networkUnavailable, .modelFailure: false
        }
    }

    /// The failure in words — which say whose model it was. A person who
    /// brought their own is not told that Apple Intelligence declined
    /// something it was never shown (``LanguageModels/speaksOfOwnModel``).
    public var errorDescription: String? {
        description(ofOwnModel: LanguageModels.speaksOfOwnModel)
    }

    /// - Parameter ownModel: whether the model that was asked is one the
    ///   person supplied.
    func description(ofOwnModel ownModel: Bool) -> String {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyDocument:
            return String(localized: "No readable text was found in the document.")
        case .guardrailDeclined:
            return ownModel
                ? String(localized: "Your model declined to process this content. Enter the details manually instead.")
                : String(localized: "Apple Intelligence declined to process this content (safety guardrails). Enter the details manually instead.")
        case .refused(let explanation):
            return ownModel
                ? String(localized: "Your model declined this request: \(explanation)")
                : String(localized: "Apple Intelligence declined this request: \(explanation)")
        case .contextOverflow:
            return ownModel
                ? String(localized: "This document is too long for your model to read in one piece.")
                : String(localized: "This document is too long for Apple Intelligence to read in one piece.")
        case .recognitionFailed:
            return String(localized: "The text in this document could not be read on this device. Enter the details manually instead.")
        case .unsupportedLanguage:
            return ownModel
                ? String(localized: "Your model doesn’t support this language.")
                : String(localized: "Apple Intelligence doesn’t support this language yet.")
        case .busy:
            return ownModel
                ? String(localized: "Your model is busy right now. Try again in a moment.")
                : String(localized: "Apple Intelligence is busy right now. Try again in a moment.")
        case .timedOut:
            return ownModel
                ? String(localized: "Your model took too long to answer. Try again.")
                : String(localized: "Apple Intelligence took too long to answer. Try again.")
        case .quotaReached(let resetDate):
            if let resetDate {
                return String(localized: "You’ve reached today’s Private Cloud Compute limit. It resets \(resetDate.formatted(.relative(presentation: .named))).")
            }
            return String(localized: "You’ve reached today’s Private Cloud Compute limit.")
        case .networkUnavailable:
            return String(localized: "Couldn’t reach Private Cloud Compute. Check your internet connection.")
        case .modelFailure(let detail):
            return ownModel
                ? String(localized: "Your model could not process this request: \(detail)")
                : String(localized: "Apple Intelligence could not process this request: \(detail)")
        }
    }

    /// Wraps a Foundation Models error, keeping IntelligenceErrors as-is and
    /// translating every failure a caller or a person can act on.
    ///
    /// Foundation Models 27 split what was one `GenerationError` into
    /// `LanguageModelError` for any model's refusals and limits,
    /// `SystemLanguageModel.Error` for the on-device model's assets,
    /// `PrivateCloudComputeLanguageModel.Error` for the cloud model's quota
    /// and network, `LanguageModelSession.Error` for misuse of a session, and
    /// `GeneratedContent.ParsingError` for an answer that will not decode.
    /// The old type is deprecated and the 27 runtime no longer throws it.
    static func wrap(_ error: any Error) -> IntelligenceError {
        if let error = error as? IntelligenceError { return error }
        if let model = error as? LanguageModelError {
            switch model {
            case .guardrailViolation, .refusal:
                return .guardrailDeclined
            case .contextSizeExceeded:
                return .contextOverflow
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage
            case .rateLimited:
                return .busy
            case .timeout:
                return .timedOut
            case .unsupportedCapability, .unsupportedGenerationGuide, .unsupportedTranscriptContent:
                // Ours to fix, not the person's: a request this build should
                // not have made of this model.
                return .modelFailure(model.localizedDescription)
            @unknown default:
                return .modelFailure(model.localizedDescription)
            }
        }
        if error is SystemLanguageModel.Error {
            // `.assetsUnavailable`: the model is installed but its assets are
            // not on the device right now — the same remedy as `.modelNotReady`.
            return .unavailable(IntelligenceAvailability.modelStillDownloading)
        }
        if let cloud = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloud {
            case .quotaLimitReached(let limit):
                return .quotaReached(resetDate: limit.resetDate)
            case .networkFailure:
                return .networkUnavailable
            case .serviceUnavailable:
                return .unavailable(IntelligenceAvailability.privateCloudUnavailable)
            @unknown default:
                return .modelFailure(cloud.localizedDescription)
            }
        }
        // What is left is ours to fix, and is reported in the framework's
        // own words: `LanguageModelSession.Error` (two requests on one
        // session, or its transcript changed under a request — every feature
        // here makes a session per request), `GeneratedContent.ParsingError`
        // (an answer that will not decode), and anything not yet named.
        return .modelFailure(error.localizedDescription)
    }

    /// ``wrap(_:)``, and for a refusal the model's own explanation of it.
    ///
    /// Apple ("Improving the safety of generative model output"): guided
    /// generation has no placeholder for a refusal message, so the model
    /// throws `LanguageModelError.refusal` — "ask the model to generate a
    /// string refusal message … Display the explanation in your app". The
    /// request for it can itself fail, in which case the generic sentence
    /// stands.
    ///
    /// **What comes back is model output, and is shown only if it is an
    /// explanation.** Asked why it had refused a synthetic dividend
    /// statement, the macOS 27 model returned the extraction itself — a JSON
    /// object with the security, the dates and every amount on the
    /// statement (12 October 2026). An error message is no place for a
    /// document's figures, so anything that is not a short sentence is
    /// dropped for the generic one (``isExplanation(_:)``).
    static func describing(_ error: any Error) async throws -> IntelligenceError {
        guard let model = error as? LanguageModelError, case .refusal(let refusal) = model else {
            return wrap(error)
        }
        do {
            let explanation = try await refusal.explanation.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return isExplanation(explanation) ? .refused(explanation) : .guardrailDeclined
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .guardrailDeclined
        }
    }

    /// Whether `text` is something to show a person as the model's reason:
    /// a sentence or two of prose, with no structure in it and no figures.
    static func isExplanation(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 240 else { return false }
        guard !text.contains(where: { "{}[]<>\"=".contains($0) }) else { return false }
        return text.filter(\.isNumber).count <= 4
    }
}
