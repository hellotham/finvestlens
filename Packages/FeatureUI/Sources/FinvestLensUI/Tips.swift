//
//  Tips.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  In-context feature discovery (TipKit). Tips are rule-based and
//  frequency-capped by the system, and their dismissal syncs across a user's
//  devices — better than a static onboarding wall for a feature-dense app.
//

import SwiftUI
import TipKit
import FinvestLensIntelligence

/// Reconciling an account against a bank/broker statement.
struct ReconcileTip: Tip {
    var title: Text { Text("Reconcile against your statement") }
    var message: Text? {
        Text("Enter the statement's closing balance and date — FinvestLens auto-clears the matching transactions and shows any difference left to chase.")
    }
    var image: Image? { Image(systemName: "checkmark.seal") }
}

/// PDF reading with Apple Intelligence — and where it happens, which is the
/// point of the tip. Bank statements are always read on the device; invoices
/// and dividend statements follow the choice in Settings, so in a build that
/// offers Private Cloud Compute the tip says that instead of promising that
/// nothing leaves.
struct SmartImportTip: Tip {
    private var usesPrivateCloud: Bool {
        IntelligenceCommand.invoice.leavesDevice || IntelligenceCommand.dividendStatement.leavesDevice
    }

    var title: Text {
        usesPrivateCloud ? Text("Read statements with Apple Intelligence") : Text("Read statements on device")
    }
    var message: Text? {
        usesPrivateCloud
            ? Text("Bank statements are read on this device and turned into transactions to review. Invoices and dividend statements are read with Apple’s Private Cloud Compute — you can keep them on this device in Settings.")
            : Text("Bank statements, dividend statements and invoices are read on-device by Apple Intelligence and turned into transactions to review — nothing leaves this device.")
    }
    var image: Image? { Image(systemName: "doc.viewfinder") }
}

