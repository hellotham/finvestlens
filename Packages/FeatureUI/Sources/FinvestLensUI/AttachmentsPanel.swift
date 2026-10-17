//
//  AttachmentsPanel.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import QuickLook
import FinvestLensEngine
import FinvestLensIntelligence
#if os(macOS)
import AppKit
import Quartz
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#endif

/// A trailing sidebar for the register showing the selected transaction's
/// document link (`assoc_uri`, FR-AI-08). The attachment previews inline the
/// moment its transaction is selected; the actions (open, reveal, replace,
/// remove, web link) sit at the bottom. Links are stored relative to the
/// document folder (Settings ▸ Documents) when the file lives inside it.
/// The draggable seam between the register and the attachments panel.
///
/// It writes the same stored width the panel reads, so the two stay one
/// setting rather than two that can disagree. Drawn as a hairline, hit as a
/// 10pt band, because a divider you can see is not automatically a divider you
/// can grab — which is the mistake the register's own column rulers made.
struct AttachmentsSplitter: View {
    @AppStorage(AttachmentsPanel.widthKey) private var storedWidth = 290.0
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    // AppKit-only: iPadOS has no pointer-shape API here, and
                    // the drag works the same without one.
                    #if os(macOS)
                    .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                    #endif
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = startWidth ?? storedWidth
                                if startWidth == nil { startWidth = base }
                                storedWidth = min(max(base - value.translation.width,
                                                      AttachmentsPanel.minWidth),
                                                  AttachmentsPanel.maxWidth)
                            }
                            .onEnded { _ in startWidth = nil })
                    .accessibilityLabel("Resize attachments panel")
                    .accessibilityHidden(false)
                    // A divider that only a drag can move is a control only a
                    // mouse can reach. `adjustable` is what VoiceOver and Full
                    // Keyboard Access drive a continuous value with — the same
                    // gesture as a slider — so the pane is resizable without a
                    // pointer at all.
                    .accessibilityValue(Text("\(Int(storedWidth)) points"))
                    .accessibilityAdjustableAction { direction in
                        let step = 24.0
                        switch direction {
                        case .increment:
                            storedWidth = min(storedWidth + step, AttachmentsPanel.maxWidth)
                        case .decrement:
                            storedWidth = max(storedWidth - step, AttachmentsPanel.minWidth)
                        @unknown default: break
                        }
                    }
            }
    }
}

struct AttachmentsPanel: View {
    @Bindable var model: AppModel
    /// What the register can spare. The panel takes the smaller of this and the
    /// width the user dragged, so a narrow window shrinks the pane rather than
    /// pushing the ledger off its own leading edge.
    var available: CGFloat = .greatestFiniteMagnitude
    /// Persisted so the pane is the width you left it at, the way a Finder
    /// sidebar is. Clamped on read, so a value dragged on a wide display can
    /// never strand the panel off the side of a narrow one.
    @AppStorage(AttachmentsPanel.widthKey) private var storedWidth = 290.0
    static let widthKey = "finvestlens.attachmentsPanelWidth"
    static let minWidth = 210.0
    static let maxWidth = 520.0
    var width: CGFloat { min(max(storedWidth, Self.minWidth), Self.maxWidth) }

    /// Drag the divider on the panel's leading edge.
    func resize(by delta: CGFloat) {
        storedWidth = min(max(width - delta, Self.minWidth), Self.maxWidth)
    }

    @State private var webLinkText = ""
    @State private var webFieldShown = false
    /// Bumped when the app comes to the front, or a cloud download lands, so
    /// the panel looks for the file again at once — it may have been put in
    /// place, or taken away, in the Finder.
    @State private var lookAgain = 0
    @Environment(\.scenePhase) private var scenePhase
    /// Full-window Quick Look (the expand button) — non-nil presents it.
    @State private var previewURL: URL?
    @Environment(\.openURL) private var openURL
    /// iPad's stand-in for the macOS file panel (F22).
    @State private var linkFileImporterShown = false
    @State private var categorising = false
    @State private var categorySuggestion: AppModel.AttachmentCategorySuggestion?
    @State private var categoriseError: String?
    /// Where the selected transaction's file is, and whether it is there —
    /// looked for off the main actor by ``watch(_:)``
    /// (``AppModel/locateLinkedDocument(_:)``). The panel used to stat the
    /// candidate paths four times in every body pass, and a pass comes with
    /// every selection, every drag of the divider and every resize of the
    /// window (Performance Review P8a).
    @State private var resolved: (key: LinkKey, location: AppModel.LinkedDocumentLocation)?

    /// What a link is looked for as: the transaction, and the paths its link
    /// could name — the pure half of the resolution, so a change of document
    /// folder is a new key.
    struct LinkKey: Hashable {
        var transactionID: GncGUID
        var link: String
        var candidates: [URL]
    }

    /// What the one task that looks for the file restarts on: a new link, or
    /// a reason to look again now.
    private struct LookFor: Hashable {
        var key: LinkKey?
        var lookAgain: Int
    }

    /// The selected transaction's file link, as it is looked for; `nil` with
    /// no single selection, no link, or a web link — which is not looked for.
    private var linkKey: LinkKey? {
        guard let transactionID, let link = model.documentLink(for: transactionID),
              !AppModel.isWebLink(link) else { return nil }
        return LinkKey(transactionID: transactionID, link: link, candidates: model.linkedDocumentCandidates(for: link))
    }

    /// Where the file for `key` is, once it has been looked for — `nil` while
    /// it is still being looked for, which draws neither a preview nor a
    /// "not found".
    private func found(for key: LinkKey?) -> AppModel.LinkedDocumentLocation? {
        guard let key, resolved?.key == key else { return nil }
        return resolved?.location
    }

    /// Looks for the file for as long as it is selected: now, then again
    /// every few seconds while it is missing — a sync may bring it, or
    /// someone may copy it into the folder — and now and then once it is
    /// there, in case it goes. It used to be looked for once per selection,
    /// so a file put in place stayed "not found" until another transaction
    /// was selected and this one again (17 October review). The state is
    /// written only when what was found changes.
    private func watch(_ key: LinkKey?) async {
        guard let key else { return }
        while !Task.isCancelled {
            let location = await model.locateLinkedDocument(key.candidates)
            guard !Task.isCancelled else { return }
            if resolved?.key != key || resolved?.location != location { resolved = (key, location) }
            try? await Task.sleep(for: .seconds(location.exists ? 30 : 5))
        }
    }


    /// The single selected transaction, if the selection is exactly one.
    private var transactionID: GncGUID? {
        let ids = model.selectedTransactionIDs
        return ids.count == 1 ? ids.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Attachment", systemImage: "paperclip")
                .scaledFont(.headline)
            if let transactionID {
                if let link = model.documentLink(for: transactionID) {
                    let location = found(for: linkKey)
                    linkContent(transactionID: transactionID, link: link, location: location)
                    categoriseControls(transactionID: transactionID, link: link, location: location)
                } else {
                    Text("No attachment on this transaction.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Divider()
                addControls(transactionID: transactionID,
                            replacing: model.documentLink(for: transactionID) != nil)
            } else {
                Text(model.selectedTransactionIDs.isEmpty
                     ? "Select a transaction to see its attachment."
                     : "Select a single transaction.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button("All Linked Documents…", systemImage: "doc.on.doc") {
                model.presentedPanel = .linkedDocuments
            }
            .help("Every attachment in the book, with its transaction")
        }
        .padding(12)
        // The width the user dragged. `maxWidth: 290` pinned this pane — with
        // ideal and max equal there was nothing for a divider to give, so the
        // panel could not be resized at all, on a screen where width is the
        // scarce resource and a long account path is exactly what you want
        // more room for.
        // Capped by what the register can spare. `width` is what the user
        // dragged; `available` is what is actually there, and the smaller wins.
        .frame(width: min(width, max(0, available)), alignment: .topLeading)
        // One size for every control — mixed large/small/icon-only buttons made
        // the panel read as three different UIs.
        .controlSize(.small)
        .quickLookPreview($previewURL)
        // One look for the file, for the panel — on the panel's own stack.
        // On the `Group` that held its rows, it ran once for each of them,
        // four to six stat passes per selection (17 October review).
        .task(id: LookFor(key: linkKey, lookAgain: lookAgain)) { [key = linkKey] in await watch(key) }
        // Back from the Finder, where the file may have been moved: look now.
        .onChange(of: scenePhase) { _, phase in if phase == .active { lookAgain += 1 } }
        .onChange(of: transactionID) {
            categorySuggestion = nil
            categoriseError = nil
            webFieldShown = false
            webLinkText = ""
        }
    }

    // MARK: Categorise from attachment (OCR + on-device model)

    @ViewBuilder
    private func categoriseControls(transactionID: GncGUID, link: String,
                                    location: AppModel.LinkedDocumentLocation?) -> some View {
        let readable = !AppModel.isWebLink(link) && (location?.exists ?? false)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                runCategorise(transactionID)
            } label: {
                if categorising {
                    HStack { ProgressView().controlSize(.small); Text("Reading…") }
                } else {
                    Label("Categorise from Attachment", systemImage: "sparkles")
                }
            }
            .disabled(!readable || categorising || !model.isIntelligenceAvailable(for: .attachmentInsight))
            // A `Text` either way: `reason ?? "literal"` is a `String`, which
            // `.help` shows as written — in English, in every language.
            .help(model.intelligenceUnavailableReason(for: .attachmentInsight).map { Text(verbatim: $0) }
                  ?? Text("Read the attachment (OCR) and suggest a category for this transaction"))
            // The category is chosen on this device, but the attachment is
            // also read as an invoice and as a dividend statement, and those
            // follow the person's choice — so this says so before the press.
            IntelligenceRunsNote(.categoriseFromAttachment)
            if let suggestion = categorySuggestion {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Label(suggestion.accountName, systemImage: "arrow.right.circle")
                            .scaledFont(.callout)
                            .lineLimit(2)
                        Spacer()
                        Button("Apply") {
                            if model.applyAttachmentSuggestion(suggestion, to: transactionID) {
                                categorySuggestion = nil
                            } else {
                                // The inspector was removed; ⌘E now opens the
                                // row out in the register itself.
                                categoriseError = String(localized: "Couldn’t apply — press ⌘E to open the row out and edit its splits there.")
                            }
                        }
                        .controlSize(.small)
                    }
                    if let friendly = suggestion.friendlyDescription {
                        Text("Rename to “\(friendly)” — bank text kept in the memo")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // A multi-item invoice: one leg per line item.
                    if let lines = suggestion.lines {
                        ForEach(lines) { line in
                            HStack(spacing: 4) {
                                Text("→ \(line.accountName)")
                                    .scaledFont(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(line.memo)
                                Spacer()
                                Text(AmountFormat.string(line.value, code: suggestion.currencyCode))
                                    .scaledFont(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let categoriseError {
                Text(categoriseError)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func runCategorise(_ transactionID: GncGUID) {
        categorising = true
        categoriseError = nil
        categorySuggestion = nil
        Task {
            defer { categorising = false }
            do {
                if let result = try await model.suggestCategoryFromAttachment(for: transactionID) {
                    categorySuggestion = result
                } else {
                    categoriseError = String(localized: "No confident suggestion from the attachment.")
                }
            } catch {
                categoriseError = error.localizedDescription
            }
        }
    }

    // MARK: Link display

    @ViewBuilder
    private func linkContent(transactionID: GncGUID, link: String,
                             location: AppModel.LinkedDocumentLocation?) -> some View {
        let isWeb = AppModel.isWebLink(link)
        let url = isWeb ? nil : location?.url
        let exists = isWeb ? true : (location?.exists ?? false)
        let inCloud = !isWeb && (location?.inCloud ?? false)
        // Still looking: neither a preview nor a "not found" yet.
        let settled = isWeb || location != nil

        // The preview fills the panel; details and actions sit under it.
        if !isWeb, exists, let url {
            #if os(macOS)
            EmbeddedQuickLook(url: url)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            #else
            Button {
                previewURL = url
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            Spacer()
            #endif
        } else {
            Spacer()
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isWeb ? "link" : "doc")
                    .foregroundStyle(.secondary)
                // While the file is still being looked for, the name its first
                // candidate path gives — decoded, and the same name in the
                // common case — so nothing changes when the look lands.
                Text(model.linkedDocumentName(for: link, at: url))
                    .scaledFont(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("Copy Name") {
                            GeneralPasteboard.copy(isWeb ? link : (url?.lastPathComponent ?? link))
                        }
                        Button(isWeb ? "Copy Link" : "Copy Full Path") {
                            GeneralPasteboard.copy(isWeb ? link : (url?.path ?? link))
                        }
                        if !isWeb {
                            Button("Copy Stored Link") { GeneralPasteboard.copy(link) }
                        }
                    }
            }
            // The raw stored link — the relative path is the durable fact.
            Text(link)
                .scaledFont(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if inCloud, let url {
                Label("Stored in the cloud — downloading…",
                      systemImage: "icloud.and.arrow.down")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .task(id: url) {
                        // Ask the cloud for it once, and look again when it
                        // lands. Looking again whatever happened replaced
                        // this label, which started another download and
                        // another wait, for as long as the file stayed in the
                        // cloud (17 October review).
                        if await model.ensureLocalFile(url) { lookAgain += 1 }
                    }
            } else if settled, !isWeb, !exists {
                Label("File not found under the document folder.",
                      systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
            }
        }

        HStack(spacing: 6) {
            if isWeb {
                Button {
                    // `openURL` works on every platform — NSWorkspace made
                    // this button a silent no-op on iPad (F22).
                    if let webURL = URL(string: link) { openURL(webURL) }
                } label: {
                    Label("Open", systemImage: "safari")
                }
            } else {
                Button {
                    if !isWeb, exists, let url { previewURL = url }
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .disabled(!exists)
                .help("Open the full Quick Look window")
                Button {
                    model.openLinkedDocument(for: transactionID)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .disabled(!exists)
                .help("Open in its application")
                #if os(macOS)
                if let url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .disabled(!exists)
                    .help("Reveal in Finder")
                }
                #endif
            }
            Spacer()
        }
    }

    // MARK: Add / replace

    @ViewBuilder
    private func addControls(transactionID: GncGUID, replacing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(replacing ? "Replace with File…" : "Link File…",
                   systemImage: "doc.badge.plus") {
                #if os(macOS)
                if let url = MacFilePanel.open(types: [.item],
                                               title: "Choose a file to link") {
                    model.linkDocument(at: url, to: transactionID)
                }
                #else
                linkFileImporterShown = true
                #endif
            }
            .help("Opens a file dialog — the chosen file is linked in place, stored relative to the document folder (Settings ▸ Documents) when inside it")
            .fileImporter(isPresented: $linkFileImporterShown,
                          allowedContentTypes: [.item]) { result in
                // The iPad path (F22): same linking, via the system picker.
                if case let .success(url) = result {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    model.linkDocument(at: url, to: transactionID)
                }
            }
            // The URL field only appears on demand: a permanently visible blank
            // field read like the replace control.
            if webFieldShown {
                HStack(spacing: 6) {
                    TextField("https://…", text: $webLinkText)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.callout)
                        .onSubmit { setWebLink(transactionID: transactionID) }
                    Button("Set") { setWebLink(transactionID: transactionID) }
                        .disabled(!AppModel.isWebLink(webLinkText))
                    Button {
                        webFieldShown = false
                        webLinkText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel web link")
                }
            } else {
                Button(replacing ? "Replace with Web Link…" : "Add Web Link…",
                       systemImage: "link") {
                    webFieldShown = true
                }
            }
            if replacing {
                Button(role: .destructive) {
                    model.setDocumentLink(nil, for: transactionID)
                } label: {
                    Label("Remove Link", systemImage: "trash")
                }
                .help("Removes the link only — the file stays where it is")
            }
        }
    }

    private func setWebLink(transactionID: GncGUID) {
        let trimmed = webLinkText.trimmingCharacters(in: .whitespaces)
        guard AppModel.isWebLink(trimmed) else { return }
        model.setDocumentLink(trimmed, for: transactionID)
        webLinkText = ""
        webFieldShown = false
    }
}
