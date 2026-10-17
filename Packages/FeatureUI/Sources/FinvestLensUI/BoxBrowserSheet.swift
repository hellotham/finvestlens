//
//  BoxBrowserSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  File ▸ Open from Box…: the person's Box, a folder at a time, showing the
//  folders and the books in it. Until 17 Oct 2026 the model could download
//  and open a Box book but nothing called it — Settings could connect to Box
//  and then there was nowhere to go.
//

import SwiftUI
import FinvestLensCloud

/// A Box folder as the browser navigates to it.
struct BoxFolder: Hashable {
    let id: String
    let name: String

    static var top: BoxFolder { BoxFolder(id: "0", name: String(localized: "All Files")) }
}

/// The books and folders in the person's Box, one folder at a time.
public struct BoxBrowserSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [BoxFolder] = []
    /// Whether the sheet opened on a Box that is not set up. Decided once:
    /// the set-up page must not turn into the sign-in page the moment both
    /// fields have a character in them.
    @State private var startedUnconfigured: Bool?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationStack(path: $path) {
            page(for: .top)
                .navigationDestination(for: BoxFolder.self) { page(for: $0) }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 520)
        #endif
    }

    @ViewBuilder
    private func page(for folder: BoxFolder) -> some View {
        Group {
            if model.isBoxSignedIn {
                BoxFolderPage(model: model, folder: folder, path: $path, dismiss: { dismiss() })
            } else if startedUnconfigured ?? !model.isBoxConfigured {
                BoxSetUpPage(model: model, dismiss: { dismiss() })
            } else {
                BoxSignInPage(model: model, dismiss: { dismiss() })
            }
        }
        .onAppear { if startedUnconfigured == nil { startedUnconfigured = !model.isBoxConfigured } }
    }
}

// MARK: - A folder

private struct BoxFolderPage: View {
    @Bindable var model: AppModel
    let folder: BoxFolder
    @Binding var path: [BoxFolder]
    let dismiss: () -> Void

    private enum Phase {
        case loading
        case loaded(BoxFolderContents)
        case failed(String)
    }
    @State private var phase: Phase = .loading
    @State private var selection: String?
    @State private var reloads = 0
    @State private var removalFailure: String?

    private var contents: BoxFolderContents? {
        if case .loaded(let contents) = phase { return contents }
        return nil
    }

    private var selectedItem: BoxItem? {
        guard let selection, let contents else { return nil }
        return (contents.folders + contents.books).first { $0.id == selection }
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Reading “\(folder.name)”…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn’t Read This Folder", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") { reloads += 1 }
                }
            case .loaded(let contents) where contents.folders.isEmpty && contents.books.isEmpty:
                ContentUnavailableView {
                    Label("No Books Here", systemImage: "folder")
                } description: {
                    Text(contents.otherFileCount == 0
                         ? "This folder is empty."
                         : "This folder has no FinvestLens books or folders — only other files.")
                }
            case .loaded(let contents):
                list(contents)
            }
        }
        .navigationTitle(folder.name)
        .task(id: reloads) { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: dismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(selectedItem?.kind == .folder ? "Show" : "Open") { activate(selection) }
                    .disabled(selectedItem == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reloads += 1
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read this folder from Box again")
            }
        }
    }

    private func list(_ contents: BoxFolderContents) -> some View {
        List(selection: $selection) {
            if !contents.folders.isEmpty {
                Section("Folders") {
                    ForEach(contents.folders) { item in
                        BoxFolderRow(item: item).tag(item.id)
                    }
                }
            }
            if !contents.books.isEmpty {
                Section("Books") {
                    ForEach(contents.books) { item in
                        let state = model.boxCopyState(of: item)
                        BoxBookRow(item: item, state: state).tag(item.id)
                            // The context menu's one action, for VoiceOver.
                            .accessibilityActions {
                                if state == .onThisDevice {
                                    Button("Remove Copy from This Device") { removeCopy(item) }
                                }
                            }
                    }
                }
            }
        }
        // Double-click on the Mac, a tap on iPhone and iPad: into a folder,
        // or open a book.
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, ids.count == 1,
               let book = contents.books.first(where: { $0.id == id }),
               model.boxCopyState(of: book) == .onThisDevice {
                Button("Remove Copy from This Device", role: .destructive) { removeCopy(book) }
            }
        } primaryAction: { ids in
            activate(ids.first)
        }
        #if os(macOS)
        // …and for the keyboard: Delete removes the selected book's copy, as
        // it would anything selected in a Mac list.
        .onDeleteCommand {
            guard let book = contents.books.first(where: { $0.id == selection }),
                  model.boxCopyState(of: book) == .onThisDevice else { return }
            removeCopy(book)
        }
        #endif
        .alert("Couldn’t Remove the Copy", isPresented: Binding(
            get: { removalFailure != nil }, set: { if !$0 { removalFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: removalFailure ?? "")
        }
        #if os(iOS)
        // The list stays while it refreshes: swapping it for a spinner tears
        // down the view that owns the refresh, which cancels it.
        .refreshable { await load(showingProgress: false) }
        #endif
    }

    private func load(showingProgress: Bool = true) async {
        if showingProgress { phase = .loading }
        do {
            phase = .loaded(try await model.boxFolderContents(folder.id))
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Removes this device's copy of a book Box already has; what stops it
    /// is said in the alert.
    private func removeCopy(_ book: BoxItem) {
        Task {
            do { try await model.removeBoxCopy(of: book) }
            catch { removalFailure = error.localizedDescription }
        }
    }

    private func activate(_ id: String?) {
        guard let id, let contents else { return }
        if let folder = contents.folders.first(where: { $0.id == id }) {
            path.append(BoxFolder(id: folder.id, name: folder.name))
        } else if let book = contents.books.first(where: { $0.id == id }) {
            // The sheet goes at once: the window behind it is where the book
            // opens, and where "Downloading from Box" is shown while it does.
            dismiss()
            let folderID = self.folder.id
            Task { await model.openBoxBook(book, inFolder: folderID) }
        }
    }
}

private struct BoxFolderRow: View {
    let item: BoxItem

    var body: some View {
        HStack {
            Label {
                Text(verbatim: item.name)
            } icon: {
                Image(systemName: "folder").foregroundStyle(.tint)
            }
            Spacer(minLength: 8)
            #if os(iOS)
            Image(systemName: "chevron.forward")
                .foregroundStyle(.tertiary)
                .scaledFont(.caption)
                .accessibilityHidden(true)
            #endif
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.name), folder"))
        .accessibilityAddTraits(.isButton)
    }
}

private struct BoxBookRow: View {
    let item: BoxItem
    let state: BoxCopyState
    @Environment(\.appDateFormat) private var dateFormat

    private var name: String { (item.name as NSString).deletingPathExtension }

    /// "Modified 17 October 2026 · 68.7 MB", as much of it as Box said.
    private var details: String {
        var parts: [String] = []
        if let modified = item.modifiedAt {
            parts.append(String(localized: "Modified \(dateFormat.long(modified))"))
        }
        if let size = item.size {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    private var status: (words: LocalizedStringKey, symbol: String)? {
        switch state {
        case .notOnThisDevice: nil
        case .onThisDevice: ("On this device", "checkmark.circle")
        case .changesToUpload: ("Changes on this device not yet on Box", "arrow.up.circle")
        case .conflicted: ("Changed on Box and on this device", "exclamationmark.triangle")
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                if !details.isEmpty {
                    Text(verbatim: details)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if let status {
                    // The words stay secondary — orange text on white is below
                    // the contrast small text needs; the symbol carries the
                    // colour, where 3:1 is enough.
                    Label {
                        Text(status.words).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: status.symbol)
                            .foregroundStyle(state == .conflicted ? AnyShapeStyle(.red)
                                             : state == .onThisDevice ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.tint))
                    }
                    .scaledFont(.caption)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Not connected, not set up

private struct BoxSignInPage: View {
    @Bindable var model: AppModel
    let dismiss: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Not Connected to Box", systemImage: "cloud")
        } description: {
            Text("Sign in on Box’s own page to see your books there. FinvestLens never sees your Box password.")
        } actions: {
            BoxConnectButton(model: model, prominent: true)
        }
        .navigationTitle("Box")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
        }
    }
}

/// Connect to Box…, with what went wrong said beside it — the one control,
/// in Settings and in the browser.
struct BoxConnectButton: View {
    @Bindable var model: AppModel
    var prominent = false
    @State private var connecting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: prominent ? .center : .leading, spacing: 6) {
            Group {
                if prominent {
                    Button("Connect to Box…", action: connect).buttonStyle(.borderedProminent)
                } else {
                    Button("Connect to Box…", action: connect)
                }
            }
            .disabled(connecting || !model.isBoxConfigured)
            if let failure {
                // Red words in a caption fall short of the contrast small text
                // needs (system red on white is about 3.6:1); the symbol
                // carries the colour, as the book rows' status does.
                Label {
                    Text(verbatim: failure)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(prominent ? .center : .leading)
            }
        }
    }

    private func connect() {
        Task {
            connecting = true
            defer { connecting = false }
            do {
                try await model.signInToBox()
                failure = nil
            } catch {
                failure = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
        }
    }
}

private struct BoxSetUpPage: View {
    @Bindable var model: AppModel
    let dismiss: () -> Void

    var body: some View {
        Form {
            Section {
                Text("FinvestLens reaches Box through a Box app of your own, so no one else’s app ever stands between you and your files. Create one at developer.box.com, then enter its client ID and secret here — they are the same ones Settings ▸ General ▸ Box keeps.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }
            BoxSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .navigationTitle("Set Up Box")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
        }
    }
}

// MARK: - Settings

/// The Box app's client ID and secret, and the connection — in Settings, and
/// in the browser when Box is not set up yet.
struct BoxSettingsSection: View {
    @Bindable var model: AppModel
    /// The field's own text, written to the model — and so to the Keychain —
    /// only when it differs from what is stored.
    @State private var secret = ""

    var body: some View {
        Section("Box") {
            TextField("Box client ID", text: Binding(get: { model.boxClientID },
                                                    set: { model.boxClientID = $0 }))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            // SecureField, and it goes to the Keychain rather than
            // @AppStorage: Box has no PKCE, so the token exchange needs a
            // real secret.
            SecureField("Box client secret", text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.boxClientSecret = secret }
                .onChange(of: secret) { model.boxClientSecret = secret }
            HStack {
                if model.isBoxSignedIn {
                    Button("Disconnect") { model.disconnectBox() }
                    Text("Connected").scaledFont(.caption).foregroundStyle(.secondary)
                } else {
                    BoxConnectButton(model: model)
                }
            }
            Text("Create an app at developer.box.com (User Authentication, OAuth 2.0) with redirect URI \(AppModel.boxRedirectURI), then paste its client ID and secret here. Box does not support PKCE, so the secret is required; it is kept in the Keychain, not in preferences. Sign-in happens on Box’s own page — this app never sees your Box password, and the tokens are kept in the Keychain too.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            Text("Open a book with Open from Box…, in the File menu or on the welcome screen. It is kept on this device while you work on it — a book is a database, which can’t run over a web connection — and goes up to Box as a new version when you save with ⌘S, close the book, switch books or quit; autosave keeps your work on this device until then. A version another device saved is never replaced: you’re asked what to keep.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        // The secret lives in the Keychain, not in the view: without this the
        // field was empty every time Settings opened, and Connect stayed
        // disabled until the secret was typed again.
        .task { if secret.isEmpty { secret = model.boxClientSecret } }
    }
}
