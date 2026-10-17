//
//  ContentView.swift
//  finvestlens
//
//  Created by Chris Tham on 12/7/2026.
//
//  This file is part of FinvestLens.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  FinvestLens is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  FinvestLens is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FinvestLens.  If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensUI

/// Hosts either the welcome screen or an open document, and surfaces
/// document-operation errors (with stale-lock recovery) and confirmations.
struct RootHost: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    #if os(macOS)
    /// Whether this window has been on screen yet. A book that fails to open
    /// at launch — locked, missing, not a book — fails within milliseconds,
    /// and an alert asked for before its window is up leaves the window
    /// *never* shown: the app sat in the Dock with nothing on screen and the
    /// question unasked until it was clicked a second time (reproduced
    /// 12 Oct 2026 with a lock beside the book). The alert waits for the
    /// window to be *visible* — not key: an app opened in the background, or
    /// a save that fails as the session logs out, must still say why.
    @State private var windowHasAppeared = false
    #endif

    private var canPresentDocumentError: Bool {
        #if os(macOS)
        windowHasAppeared
        #else
        true
        #endif
    }

    static var documentType: UTType {
        UTType(exportedAs: "com.hellotham.finvestlens.document", conformingTo: .database)
    }

    var body: some View {
        Group {
            if let openingURL = model.openingURL {
                OpeningBookView(url: openingURL, progress: model.loadProgress,
                                boxPhase: model.boxOpenPhase,
                                onCancel: { model.cancelBoxOpen() })
            } else if let importingURL = model.importingURL {
                ImportingBookView(url: importingURL, progress: model.loadProgress)
            } else if model.isOpen && model.isLocked {
                LockView(model: model)
            } else if model.isOpen, let url = model.documentURL {
                FinvestLensRootView(model: model)
                    // HIG: name the window after the open document, with a
                    // titlebar proxy icon (drag / reveal-in-Finder).
                    .navigationDocument(url)
            } else {
                WelcomeView(model: model, onNew: newBook, onOpen: openBook)
            }
        }
        // The status chip and toasts where no book view carries them: while a
        // book opens or imports — "opened the copy on this device" is said
        // then — and over the welcome screen, where an upload to Box carries
        // on after its book closes. Never over the lock screen.
        .overlay(alignment: .bottom) {
            if model.openingURL != nil || model.importingURL != nil || !model.isOpen {
                StatusOverlay(model: model)
            }
        }
        #if os(macOS)
        // Quitting while Box work finishes: said, with a way to stop waiting,
        // and nothing else can be started meanwhile.
        .overlay {
            if model.isFinishingBoxWorkBeforeQuit {
                FinishingBoxWorkView(model: model)
            }
        }
        #endif
        .onAppear { model.undoManager = undoManager }
        // Box books saved while there was no connection, or before the last
        // quit finished uploading, go up now.
        .task { if !TestHost.isActive { model.resumeBoxUploads() } }
        #if os(iOS) || os(visionOS)
        // iOS — and visionOS, which the app target also lists — can end a
        // suspended app without asking, so leaving the screen is the last
        // moment to keep changes, and to send them to Box.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.saveBeforeSuspension()
            case .active: model.resumeBoxUploads()
            default: break
            }
        }
        #endif
        #if os(macOS)
        .background { WindowOnScreen(hasAppeared: $windowHasAppeared) }
        #endif
        .onChange(of: undoManager == nil) { model.undoManager = undoManager }
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.documentType, .data]) { result in
            if case .success(let url) = result { Task { await model.openBook(at: url) } }
        }
        // Check & Repair review (offered after GnuCash import, or from the
        // Book menu). Anchored on a background view so it can't clobber the
        // fileImporter's presentation slot.
        .background {
            Color.clear.sheet(item: $model.pendingCleanup) { proposal in
                CheckRepairSheet(model: model, proposal: proposal)
            }
        }
        // File ▸ Open from Box…, on its own anchor for the same reason.
        .background {
            Color.clear.sheet(isPresented: $model.boxBrowserRequested) {
                BoxBrowserSheet(model: model)
                    .finvestLensAppearance()
            }
        }
        // A Box book whose changes Box refused: the person decides, and
        // nothing is lost while they don't.
        .alert(model.boxConflict?.title ?? "",
               isPresented: Binding(get: { model.boxConflict != nil && canPresentDocumentError },
                                    set: { if !$0 { model.boxConflict = nil } }),
               presenting: model.boxConflict) { conflict in
            Button(conflict.actionTitle) { Task { await model.resolveBoxConflict(conflict) } }
            Button("Not Now", role: .cancel) {}
        } message: { conflict in
            Text(verbatim: conflict.message)
        }
        .alert(model.documentError?.lockedImportSource != nil ? "Couldn’t import" : "Couldn’t open book",
               isPresented: Binding(get: { model.documentError != nil && canPresentDocumentError },
                                    set: { if !$0 { model.documentError = nil } }),
               presenting: model.documentError) { error in
            if let source = error.lockedImportSource, let destination = error.lockedURL {
                Button("Break Lock and Import") {
                    Task { await model.importGnuCashBook(from: source, saveAs: destination, breakStaleLock: true) }
                }
                Button("Cancel", role: .cancel) {}
            } else if let lockedURL = error.lockedURL {
                Button("Open Read-Only") {
                    Task { await model.openReadOnly(at: lockedURL) }
                }
                Button("Break Lock and Open") {
                    Task { await model.openBook(at: lockedURL, breakStaleLock: true) }
                }
                Button("Cancel", role: .cancel) {}
            } else if let source = error.gnuCashImportURL {
                #if os(macOS)
                Button("Import…") { Task { await DocumentDialogs.importGnuCash(model, source: source) } }
                Button("Cancel", role: .cancel) {}
                #else
                Button("OK", role: .cancel) {}
                #endif
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { error in
            Text(error.message)
        }
        .alert("Import Complete",
               isPresented: Binding(get: { model.infoMessage != nil },
                                    set: { if !$0 { model.infoMessage = nil } })) {
            Button("OK", role: .cancel) { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
    }

    private func newBook() {
        #if os(macOS)
        DocumentDialogs.newBook(model)
        #else
        // Documents, not tmp: iOS purges the temporary directory, silently
        // destroying books created there. Documents is user-visible in the
        // Files app ("On My iPhone > finvestlens") since the app declares
        // UISupportsDocumentBrowser.
        model.newBook(at: AppModel.newBookURL(in: URL.documentsDirectory))
        #endif
    }

    private func openBook() {
        #if os(macOS)
        Task { await DocumentDialogs.openBook(model) }
        #else
        importing = true
        #endif
    }
}

#if os(macOS)
/// Latches `hasAppeared` the first time the window holding it is on screen.
private struct WindowOnScreen: NSViewRepresentable {
    @Binding var hasAppeared: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onVisible = { if !hasAppeared { hasAppeared = true } }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        var onVisible: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving a window arrives here too, with `window == nil` — which is
            // where the observation ends; there is no `deinit` to do it in.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        /// A turn of the run loop later, so the state is never written while
        /// AppKit is still putting the window up.
        private func report() {
            guard window?.isVisible == true else { return }
            DispatchQueue.main.async { [weak self] in self?.onVisible?() }
        }
    }
}
#endif

#if os(macOS)
/// Covers the window while quitting waits for Box: a book opened now would be
/// lost when the app goes.
private struct FinishingBoxWorkView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Finishing the upload to Box…")
                    .scaledFont(.title3, weight: .semibold)
                Text("FinvestLens quits as soon as Box has your book, or in half a minute. What isn’t uploaded by then is kept on this Mac and goes the next time FinvestLens opens.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Quit Now") { model.stopWaitingForBox() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        // It covers the window at a moment nobody asked for anything on
        // screen: VoiceOver says why, rather than leave its user on an
        // element now hidden beneath it.
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "Finishing the upload to Box…")).post()
        }
    }
}
#endif
