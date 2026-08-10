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
    /// Bumped when a cloud download completes, so the panel re-checks the file.
    @State private var cloudRefresh = 0
    /// Full-window Quick Look (the expand button) — non-nil presents it.
    @State private var previewURL: URL?
    @Environment(\.openURL) private var openURL
    /// iPad's stand-in for the macOS file panel (F22).
    @State private var linkFileImporterShown = false
    @State private var categorising = false
    @State private var categorySuggestion: AppModel.AttachmentCategorySuggestion?
    @State private var categoriseError: String?

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
                    linkContent(transactionID: transactionID, link: link)
                    categoriseControls(transactionID: transactionID, link: link)
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
        .frame(width: width, alignment: .topLeading)
        // One size for every control — mixed large/small/icon-only buttons made
        // the panel read as three different UIs.
        .controlSize(.small)
        .quickLookPreview($previewURL)
        .onChange(of: transactionID) {
            categorySuggestion = nil
            categoriseError = nil
            webFieldShown = false
            webLinkText = ""
        }
    }

    // MARK: Categorise from attachment (OCR + on-device model)

    @ViewBuilder
    private func categoriseControls(transactionID: GncGUID, link: String) -> some View {
        let isWeb = link.hasPrefix("http://") || link.hasPrefix("https://")
        let readable = !isWeb && (model.linkedDocumentURL(for: transactionID)
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false)

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
            .disabled(!readable || categorising || !model.isIntelligenceAvailable)
            .help(model.intelligenceUnavailableReason
                  ?? "Read the attachment (OCR) and suggest a category for this transaction")
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
    private func linkContent(transactionID: GncGUID, link: String) -> some View {
        let _ = cloudRefresh   // re-evaluate after a cloud download lands
        let isWeb = link.hasPrefix("http://") || link.hasPrefix("https://")
        let url = isWeb ? nil : model.linkedDocumentURL(for: transactionID)
        let exists = isWeb ? true
            : (url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        let inCloud = !isWeb && !exists
            && (url.map { AppModel.cloudPlaceholderExists($0) } ?? false)

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
                Text(isWeb ? link : (url?.lastPathComponent ?? link))
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
                        // Ask the cloud for it, wait, then re-render.
                        _ = await model.ensureLocalFile(url)
                        cloudRefresh += 1
                    }
            } else if !isWeb, !exists {
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
                        .disabled(!(webLinkText.hasPrefix("http://")
                                    || webLinkText.hasPrefix("https://")))
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
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return }
        model.setDocumentLink(trimmed, for: transactionID)
        webLinkText = ""
        webFieldShown = false
    }
}
