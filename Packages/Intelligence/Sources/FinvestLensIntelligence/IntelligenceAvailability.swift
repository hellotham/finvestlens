//
//  IntelligenceAvailability.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

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

    /// Probes the system model. Cheap enough to call whenever a menu is built.
    public static func current() -> IntelligenceAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This device does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings to use this feature.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The Apple Intelligence model is still downloading. Try again shortly.")
        case .unavailable:
            return .unavailable(reason: "Apple Intelligence is not available on this device.")
        }
        #else
        return .unavailable(reason: "Apple Intelligence is not available on this platform.")
        #endif
    }
}

/// Errors surfaced by Intelligence features.
public enum IntelligenceError: LocalizedError {
    case unavailable(String)
    case emptyDocument
    case guardrailDeclined
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
    case modelFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyDocument:
            return "No readable text was found in the document."
        case .guardrailDeclined:
            return "Apple Intelligence declined to process this content (safety guardrails). Enter the details manually instead."
        case .contextOverflow:
            return "This document is too long for Apple Intelligence to read in one piece."
        case .recognitionFailed:
            return "The text in this document could not be read on this device. Enter the details manually instead."
        case .modelFailure(let detail):
            return "Apple Intelligence could not process this request: \(detail)"
        }
    }

    /// Wraps a FoundationModels error, keeping IntelligenceErrors as-is and
    /// translating guardrail refusals and context overflow into cases callers
    /// can branch on.
    ///
    /// Foundation Models 27 split what was one `GenerationError` into three:
    /// `LanguageModelError` for the model's own refusals and limits,
    /// `SystemLanguageModel.Error` for the on-device model's assets, and
    /// `LanguageModelSession.Error` for misuse of a session. Only the first
    /// two carry anything a user can act on.
    static func wrap(_ error: any Error) -> IntelligenceError {
        if let error = error as? IntelligenceError { return error }
        #if canImport(FoundationModels)
        if let model = error as? LanguageModelError {
            switch model {
            case .guardrailViolation, .refusal:
                return .guardrailDeclined
            case .contextSizeExceeded:
                return .contextOverflow
            default:
                return .modelFailure(model.localizedDescription)
            }
        }
        if error is SystemLanguageModel.Error {
            // `.assetsUnavailable`: the model is installed but its assets are
            // not on the device right now — the same remedy as `.modelNotReady`.
            return .unavailable("The Apple Intelligence model is still downloading. Try again shortly.")
        }
        #endif
        return .modelFailure(error.localizedDescription)
    }
}
