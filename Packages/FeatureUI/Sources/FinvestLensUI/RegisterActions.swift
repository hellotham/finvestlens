//
//  RegisterActions.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Everything that can be done to a register, as the buttons of a menu.
//
//  One definition for the two menus that offer them: the regular shell's
//  Actions pull-down and the phone register's. They were two lists, and the
//  phone's was missing an action from the day it was written — which is how
//  the phone came to have no way to reconcile from an account. What a shell
//  leaves out is now a stated `Scope`, not an omission.
//

import SwiftUI

struct RegisterActions: View {

    /// Which shell is asking, and so which actions make sense there.
    enum Scope: Equatable {
        /// The regular-width shell: everything.
        case regular
        /// The phone. No importing (`FR-PLT-06` keeps import and export off
        /// the iPhone), and nothing that works on a multiple selection or a
        /// picked batch of files — Bulk Edit, Match Attachments — because
        /// the phone's list offers neither. Reconciling is offered for an
        /// account's register, not for the journal.
        case phone(account: Bool)
    }

    @Bindable var model: AppModel
    let scope: Scope
    @Environment(\.openWindow) private var openWindow

    private var isRegular: Bool { scope == .regular }

    private var offersReconcile: Bool {
        switch scope {
        case .regular: true
        case .phone(let account): account
        }
    }

    var body: some View {
        if offersReconcile {
            Button("Reconcile Account…", systemImage: "checkmark.seal") {
                #if os(macOS)
                if let id = model.selectedAccountID { openWindow(id: "reconcile", value: id) }
                #else
                model.presentedPanel = .reconcile
                #endif
            }
            .disabled(model.selectedAccountID == nil)
        }
        if isRegular {
            Button("Bulk Edit…", systemImage: "square.and.pencil") {
                model.presentedPanel = .bulkEdit
            }
            .disabled(model.selectedTransactionIDs.count < 2)
            Divider()
            Button("Import Bank File…", systemImage: "square.and.arrow.down.on.square") {
                model.bankImportRequested = true
            }
            Button("Smart Import PDFs…", systemImage: "doc.viewfinder") {
                model.smartImportRequested = true
            }
            .disabled(model.smartImportUnavailableReason != nil)
            // A `Text` either way: `reason ?? "literal"` is a `String`, which
            // `.help` shows as written — in English, in every language.
            .help(model.smartImportUnavailableReason.map { Text(verbatim: $0) }
                  ?? Text("Import bank statements, dividend statements, and invoices — each PDF is identified and handled automatically"))
        }
        Button("Auto-Categorise…", systemImage: "sparkles") {
            // The sheet categorises the selection when there is one. The
            // phone's list shows no selection, but a row's own menu leaves
            // one behind — so from here, on the phone, it would silently
            // offer that one forgotten row and nothing else.
            if !isRegular { model.selectedSplitIDs = [] }
            model.presentedPanel = .autoCategorize
        }
        .help("Assign categories to uncategorised transactions")
        if isRegular {
            Button("Match Attachments…", systemImage: "paperclip.badge.ellipsis") {
                model.presentedPanel = .matchAttachments
            }
            .disabled(model.matchAttachmentsUnavailableReason != nil)
            .help(model.matchAttachmentsUnavailableReason.map { Text(verbatim: $0) }
                  ?? Text("Pick receipts and statements — each is matched to its transaction, linked, and categorised"))
        }
    }
}
