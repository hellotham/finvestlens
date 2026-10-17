//
//  OffDeviceQuestion.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensIntelligence

/// The question asked once, before the first request that would leave the
/// device: use Apple's Private Cloud Compute, or keep everything here.
///
/// Private Cloud Compute is the default where a build offers it (the owner's
/// decision, 12 Oct 2026). Three commands start reading as soon as their sheet
/// opens — Smart Import, Suggest Budget, a review deck — so without this the
/// first request would have left the device before anything on screen said
/// so. The owner chose, on 17 Oct 2026, to ask once: the answer is kept as the
/// person's choice in Settings ▸ Apple Intelligence, which already settles it
/// for every later request, and choosing there first answers it too.
///
/// The question is asked where the command is: ``IntelligenceRunsNote``, which
/// every command's view shows beside its button or in its sheet, turns into
/// it while a command waits. A command whose wait ends without an answer — its
/// sheet was closed — runs on this device (``AppModel/running(_:_:)``).
@MainActor
@Observable
final class OffDeviceQuestion {
    static let shared = OffDeviceQuestion()

    /// Whether a command is waiting for the answer now.
    private(set) var isAsking = false
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Stand in for "this build offers Private Cloud Compute" and "this
    /// command would use it", which no test process can say yes to.
    @ObservationIgnored var offeredOverride: Bool?
    @ObservationIgnored var leavesDeviceOverride: Bool?

    /// Whether the question is still to be asked: the build offers Private
    /// Cloud Compute and the person has made no choice yet.
    var needsAnswer: Bool {
        let offered = offeredOverride ?? LanguageModels.privateCloudComputeEnabled
        return offered && (UserDefaults.standard.string(forKey: LanguageModels.choiceDefaultsKey) ?? "").isEmpty
    }

    /// Waits for the answer when `command` would leave the device and nobody
    /// has been asked yet. Returns at once otherwise — and on cancellation,
    /// with the question still open.
    func waitForAnswer(before command: IntelligenceCommand) async {
        guard needsAnswer, leavesDeviceOverride ?? command.leavesDevice else { return }
        let ticket = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiting[ticket] = continuation
                isAsking = true
            }
        } onCancel: {
            Task { @MainActor in self.release(ticket) }
        }
    }

    /// The person's answer, kept as their choice in Settings.
    func answer(usePrivateCloud: Bool) {
        let choice: ModelChoice = usePrivateCloud ? .privateCloud : .onDevice
        UserDefaults.standard.set(choice.rawValue, forKey: LanguageModels.choiceDefaultsKey)
        isAsking = false
        let resumed = waiting
        waiting = [:]
        resumed.values.forEach { $0.resume() }
    }

    private func release(_ ticket: UUID) {
        waiting.removeValue(forKey: ticket)?.resume()
        if waiting.isEmpty { isAsking = false }
    }
}

/// The question itself, drawn where the command's note would be.
struct OffDeviceQuestionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use Private Cloud Compute?")
                .scaledFont(.callout)
                .bold()
                .accessibilityAddTraits(.isHeader)
            Text("This can be done with Apple’s Private Cloud Compute, where larger models run on Apple’s servers: what it reads is sent to Apple to process, and Apple says it isn’t stored or made accessible to Apple. Or everything can stay on this device. You can change this at any time in Settings ▸ Apple Intelligence.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep on This Device") { OffDeviceQuestion.shared.answer(usePrivateCloud: false) }
                Button("Use Private Cloud Compute") { OffDeviceQuestion.shared.answer(usePrivateCloud: true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Spoken when it appears: the command the person just started is
        // waiting on it, and nothing else on screen says so.
        .onAppear {
            AccessibilityNotification.Announcement(
                String(localized: "Use Private Cloud Compute? The command is waiting for your answer.")).post()
        }
    }
}
