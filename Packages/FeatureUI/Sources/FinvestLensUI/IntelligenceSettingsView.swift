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
//  Private Cloud Compute is offered only in a build that holds Apple's
//  entitlement (`LanguageModels.privateCloudComputeEnabled`). A model the
//  person supplies is offered wherever the app can run one: they choose a
//  folder of models here, and each model in it is an entry in the same
//  picker, so "which model" is one decision (`SuppliedModelStore`). With
//  neither there is one place Apple Intelligence can run, and the pane says
//  which.
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
    @State private var choosingFolder = false

    public init() {}

    private var supplied: SuppliedModelStore { .shared }

    /// The model the stored preference selects — the package's rule, not a
    /// second copy of it, so this pane cannot show one model while requests
    /// go to another.
    private var choice: ModelChoice { LanguageModels.choice(stored: stored) }

    /// One entry in the picker. Apple's models are entries by where they
    /// run; a model the person supplies is an entry by *which* model, one
    /// for each in their folder — so that "which model" is one decision in
    /// one control, and not a second one made somewhere else (HelloNotes
    /// tried a single "MLX" entry with the model chosen below it, and a
    /// model picked there while the control said "System" ran nothing).
    private enum Option: Hashable {
        case onDevice, privateCloud
        /// By ``SuppliedModelFile/id``.
        case supplied(String)
    }

    private var options: [Option] {
        var options: [Option] = [.onDevice]
        if LanguageModels.offeredChoices.contains(.privateCloud) { options.append(.privateCloud) }
        if supplied.isOffered {
            options += supplied.models.map { .supplied($0.id) }
            // A choice still on a model the folder no longer holds stays in
            // the list, named for what it is, rather than the control
            // showing something else as selected.
            if choice == .supplied, supplied.chosen == nil { options.append(.supplied(supplied.chosenID ?? "")) }
        }
        return options
    }

    private var selection: Binding<Option> {
        Binding(
            get: {
                switch choice {
                case .onDevice: .onDevice
                case .privateCloud: .privateCloud
                case .supplied: .supplied(supplied.chosenID ?? "")
                }
            },
            set: { option in
                switch option {
                case .onDevice:
                    stored = ModelChoice.onDevice.rawValue
                    supplied.letGo()
                case .privateCloud:
                    stored = ModelChoice.privateCloud.rawValue
                    supplied.letGo()
                case .supplied(let id):
                    if let model = supplied.models.first(where: { $0.id == id }) { supplied.use(model) }
                }
            })
    }

    private func title(of option: Option) -> String {
        switch option {
        case .onDevice: LanguageModels.title(of: .onDevice)
        case .privateCloud: LanguageModels.title(of: .privateCloud)
        case .supplied(let id):
            supplied.models.first { $0.id == id }.map { String(localized: "Your Own Model · \($0.name)") }
                ?? String(localized: "Your Own Model · not in the models folder")
        }
    }

    /// Why the chosen model cannot serve now, if it cannot. For the
    /// person's own model the store is asked, not the model seam: the store
    /// is observable, so the line is drawn again when the answer arrives —
    /// which is after the model was picked, because asking takes a moment.
    private func unavailableReason(of choice: ModelChoice) -> String? {
        let availability: IntelligenceAvailability = switch choice {
        case .onDevice: .available
        case .privateCloud: LanguageModels.availability(of: .privateCloud)
        case .supplied: supplied.availability
        }
        if case .unavailable(let reason) = availability { return reason }
        return nil
    }

    public var body: some View {
        let options = options
        let choice = choice
        withModelsFolderPanel(Form {
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
                if options.count > 1 {
                    Picker("Read documents and write summaries", selection: selection) {
                        ForEach(options, id: \.self) { option in
                            Text(verbatim: title(of: option)).tag(option)
                        }
                    }
                    if let reason = unavailableReason(of: choice) {
                        Text(verbatim: reason)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

            if supplied.isOffered {
                suppliedSection
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { supplied.chooseFolder(url) }
        })
        .windowFloor(minWidth: 440, minHeight: 300)
        .navigationTitle("Apple Intelligence")
        // The folder is other tools' too: a model fetched since launch is
        // listed when the pane is next opened, not at the next launch.
        .task { await supplied.refresh() }
        // The failure is drawn in the pane, below where the person was
        // looking when they chose the folder; VoiceOver is told as well.
        .onChange(of: supplied.lastError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
    }

    // MARK: A model the person supplies

    /// The folder of models, and what is in it. Choosing *which* model is
    /// the picker's job above; this says where they come from.
    private var suppliedSection: some View {
        Section {
            LabeledContent("Models folder") {
                HStack(spacing: 8) {
                    if let folder = supplied.folder {
                        Text(verbatim: folder.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // Two `Text`s, not a ternary of literals: that would be
                    // a `String`, and never localized.
                    Button {
                        choosingFolder = true
                    } label: {
                        supplied.folder == nil ? Text("Choose Folder…") : Text("Change…")
                    }
                }
            }
            ForEach(supplied.models) { model in
                LabeledContent {
                    Text(verbatim: model.bytes.formatted(.byteCount(style: .file)))
                } label: {
                    Text(verbatim: model.name)
                }
            }
            if supplied.folder != nil, supplied.models.isEmpty {
                Text("No models in this folder that FinvestLens can run.")
                    .foregroundStyle(.secondary)
            }
            if choice == .supplied, let caution = supplied.sizeCaution {
                Label {
                    Text(verbatim: caution).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .scaledFont(.caption)
            }
            if let error = supplied.lastError {
                Text(verbatim: error)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Your Own Model")
        } footer: {
            // Where a folder of models is found differs: a Mac has the cache
            // other MLX tools share, an iPhone or iPad has Files.
            #if os(macOS)
            Text("Bring your own model. FinvestLens doesn’t provide one, recommend one or download one: point it at a folder of MLX models — other MLX tools keep theirs in ~/.cache/huggingface/hub — and choose one under Where it runs. It runs on this device.")
            #else
            Text("Bring your own model. FinvestLens doesn’t provide one, recommend one or download one: point it at a folder of MLX models in Files, and choose one under Where it runs. It runs on this device.")
            #endif
        }
    }

    #if os(macOS)
    /// The folder panel opens where other MLX tools keep their models, and
    /// says what granting it means. It runs outside the sandbox, so it can
    /// show a folder the app cannot yet read.
    ///
    /// This wraps the `fileImporter` and does not sit inside it: the
    /// importer reads these from its own environment, which flows inward —
    /// applied to the form with the importer attached outside it, the panel
    /// opened wherever the app's last one had (found in HelloNotes).
    private func withModelsFolderPanel(_ presenter: some View) -> some View {
        presenter
            .fileDialogDefaultDirectory(Self.huggingFaceCache)
            .fileDialogMessage("Choose the folder your MLX models are in. Click Open to let FinvestLens read them.")
    }

    /// `~/.cache/huggingface/hub` in the person's real home — the sandbox
    /// gives the app a home of its own.
    private static var huggingFaceCache: URL? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home)).appending(path: ".cache/huggingface/hub")
    }
    #else
    /// No shared cache on iPhone or iPad to start in: the picker opens where
    /// Files does.
    private func withModelsFolderPanel(_ presenter: some View) -> some View { presenter }
    #endif
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

extension Text {
    /// One sentence in two wordings: of Apple Intelligence, and of a model
    /// the person supplied — whichever would answer `feature` now.
    ///
    /// Every sentence that names Apple Intelligence as the one doing the
    /// work was written when nothing else could be. Beside a model the
    /// person got from somewhere else it would put Apple's name to that
    /// model's reading, so each such sentence has a second wording and this
    /// chooses between them. Both are literals at the call site, typed as
    /// keys, so both are extracted and translated.
    @MainActor
    init(for feature: IntelligenceFeature, apple: LocalizedStringKey, own: LocalizedStringKey) {
        SuppliedModelStore.shared.observe()
        self = LanguageModels.usesOwnModel(for: feature) ? Text(own) : Text(apple)
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
        let offDevice = commands.contains(where: \.leavesDevice)
        // The one time a command waits on the person: asked here, where the
        // command is, rather than in an alert a sheet would hide.
        if offDevice, OffDeviceQuestion.shared.isAsking {
            OffDeviceQuestionCard()
        } else {
            IntelligenceRanNote(offDevice: offDevice, onDevice: onDevice)
        }
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
