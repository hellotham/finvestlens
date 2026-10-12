//
//  IntelligenceSettingsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Where Apple Intelligence runs, and what that means for the person's
//  figures. Until this pane the app said so only in its help.
//
//  Apple's Human Interface Guidelines, *Generative AI* ▸ Privacy (read
//  12 October 2026), on any server-based processing: be transparent by
//  "making sure people know their information may be sent to a server".
//  https://developer.apple.com/design/human-interface-guidelines/generative-ai
//  The same paragraph asks that as much as possible be processed locally,
//  which is why the pane also says what never leaves the device.
//
//  The choice is offered only in a build that holds Apple's Private Cloud
//  Compute entitlement (`LanguageModels.privateCloudComputeEnabled`). Without
//  it there is one place Apple Intelligence can run, and the pane says which.
//

import SwiftUI
import FinvestLensIntelligence

/// Says, once at launch, what the app target was built for — a package cannot
/// read the app target's compilation conditions.
public enum IntelligenceBuild {
    /// Call inside `#if PRIVATE_CLOUD_COMPUTE`, and nowhere else. The
    /// condition is added in the same change as the
    /// `com.apple.developer.private-cloud-compute` entitlement, and
    /// `PrivateCloudComputeBuildTests` fails when the two disagree: without
    /// the entitlement the first request to the cloud model ends the process.
    public static func offersPrivateCloudCompute() {
        LanguageModels.declarePrivateCloudComputeBuild()
    }
}

public struct IntelligenceSettingsView: View {
    /// Empty until the person chooses: the default is then the build's own
    /// (`LanguageModels.defaultChoice`), not a value written here on their
    /// behalf.
    @AppStorage(LanguageModels.choiceDefaultsKey) private var stored = ""

    public init() {}

    /// The model the stored preference selects — the package's rule, not a
    /// second copy of it, so this pane cannot show one model while requests
    /// go to another.
    private var choice: ModelChoice { LanguageModels.choice(stored: stored) }

    private var choiceBinding: Binding<String> {
        Binding(get: { choice.rawValue }, set: { stored = $0 })
    }

    public var body: some View {
        let offered = LanguageModels.offeredChoices
        let choice = choice
        Form {
            Section("Apple Intelligence") {
                switch LanguageModels.availability(of: .onDevice) {
                case .available:
                    Label("Available on this device", systemImage: "checkmark.circle")
                case .unavailable(let reason):
                    Label {
                        Text(verbatim: reason)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
            }

            Section("Where it runs") {
                if offered.count > 1 {
                    Picker("Read documents and write summaries", selection: choiceBinding) {
                        ForEach(offered) { option in
                            Text(verbatim: LanguageModels.title(of: option)).tag(option.rawValue)
                        }
                    }
                    if choice == .privateCloud,
                       case .unavailable(let reason) = LanguageModels.availability(of: .privateCloud) {
                        Text(verbatim: reason)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: LanguageModels.privacySummary(of: choice))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if choice == .privateCloud {
                    PrivateCloudQuotaNote()
                }
            }
        }
        .formStyle(.grouped)
        .windowFloor(minWidth: 440, minHeight: 300)
        .navigationTitle("Apple Intelligence")
    }
}

/// Today's Private Cloud Compute allowance, where there is something to say
/// about it: close to the limit, or at it — with the system's own options
/// for more, when it has any.
///
/// Apple, "Adding server-side intelligence with Private Cloud Compute": show
/// the allowance where the feature is, quietly, rather than as an alert. So
/// this is one view, placed beside each feature that can run in the cloud as
/// well as in Settings; it draws nothing in a build that cannot use Private
/// Cloud Compute, and nothing while the allowance is not a concern.
struct PrivateCloudQuotaNote: View {
    var body: some View {
        // Read once per pass: each is a call into the model's usage record.
        if let note = LanguageModels.privateCloudQuotaNote {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: note)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if LanguageModels.canSuggestLimitIncrease {
                    Button("See Options…") { LanguageModels.suggestLimitIncrease() }
                        .scaledFont(.caption)
                }
            }
        }
    }
}

/// One line saying where a command's requests go, shown beside the command.
///
/// Where any of them would go to Private Cloud Compute it says that — the
/// sentence a person needs before they press the button, not after — and the
/// allowance note follows when there is one. On the device it says
/// `onDevice`, where the view has always said something, and nothing where
/// it has not: a build that sends nothing looks as it did.
///
/// It takes commands, not features, on purpose. The command is what grants
/// a feature leave to run off the device (``AppModel/running(_:_:)``), so a
/// note written from the same case cannot describe a different set of
/// requests from the one that is made.
struct IntelligenceRunsNote: View {
    let commands: [IntelligenceCommand]
    let onDevice: LocalizedStringKey?
    /// Read for its side effect: the note is redrawn when the choice is
    /// changed. On the Mac, Settings is another window, and a note that
    /// read the preference only when it was first drawn went on saying "on
    /// this device" beside a button that no longer was.
    @AppStorage(LanguageModels.choiceDefaultsKey) private var stored = ""

    init(_ commands: IntelligenceCommand..., onDevice: LocalizedStringKey? = nil) {
        self.commands = commands
        self.onDevice = onDevice
    }

    var body: some View {
        let _ = stored
        IntelligenceRanNote(offDevice: commands.contains(where: \.leavesDevice), onDevice: onDevice)
    }
}

/// The same line about a request that has already been made: where it *was*
/// sent, which the person may since have changed their mind about.
struct IntelligenceRanNote: View {
    let offDevice: Bool
    let onDevice: LocalizedStringKey?

    var body: some View {
        if offDevice {
            VStack(alignment: .leading, spacing: 4) {
                Text("Uses Apple’s Private Cloud Compute. What it reads is sent to Apple to process; Apple says it isn’t stored or made accessible to Apple.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrivateCloudQuotaNote()
            }
        } else if let onDevice {
            Text(onDevice)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
