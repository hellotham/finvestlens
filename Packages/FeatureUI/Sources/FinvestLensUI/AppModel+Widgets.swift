//
//  AppModel+Widgets.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensShared
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The tail of the widget-write chain — extensions cannot hold stored
/// properties, so it lives at file scope. Main-actor confined: only
/// `publish(_:)` reads or replaces it.
@MainActor private var widgetPublishTail: Task<Void, Never>?

@MainActor
extension AppModel {

    /// Publishes the App Group snapshot the WidgetKit and Quick Look extensions
    /// read, and reconciles alert notifications (`FR-PLT-03`, `FR-PLAN-05`).
    ///
    /// Built from the **live in-memory book** — never re-reading the document —
    /// so it is cheap enough to call on save / open / close. It is deliberately
    /// *not* wired into `refreshAll()` (every edit), because the widget only
    /// needs the persisted picture.
    /// Writes the snapshot off the main actor, then refreshes the widgets.
    ///
    /// The write goes to the App Group container, and that `open(2)` can block
    /// in the kernel indefinitely when `containermanagerd` is wedged — the same
    /// hazard that makes the Shared package's round-trip test hang. On the main
    /// actor it froze the whole app mid-open, with the progress bar full and
    /// nothing left to do: the book had loaded, and the last act of loading it
    /// was a file write that never returned.
    ///
    /// Detached tasks have no order between them, so each publish chains on
    /// the one before it — a close-then-open (placeholder, then real book)
    /// must never leave the older snapshot as the last rename to land.
    private func publish(_ snapshot: WidgetSnapshot) {
        let previous = widgetPublishTail
        widgetPublishTail = Task.detached(priority: .utility) {
            await previous?.value
            snapshot.write()
            #if canImport(WidgetKit)
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
            #endif
        }
    }

    public func publishWidgetData() {
        // Test processes have no app bundle: WidgetKit/UNUserNotificationCenter
        // throw NSExceptions there ("bundleProxyForCurrentProcess is nil") and
        // kill the whole suite mid-run. A missing bundle identifier is the
        // reliable tell across XCTest and swift-testing runners.
        guard Bundle.main.bundleIdentifier != nil else { return }
        // A book the user has put behind Face/Touch ID must not have its net
        // worth and bill amounts rendered on the Lock Screen, pushed as
        // notification bodies, or returned to Spotlight. The lock gate covers
        // the window; these surfaces are outside it, so they need the same
        // check. Publishing the placeholder (rather than returning early)
        // also clears any snapshot written before the book was locked.
        guard let book, !requireAuthentication || !isLocked else {
            publish(.placeholder)
            Task { await AlertNotificationScheduler.cancelAll() }
            return
        }
        let currency = reportCurrency
        let now = Date()

        let netWorth = FinancialReports.netWorthSeries(book, dates: [now], currency: currency)
            .last?.netWorth ?? 0

        let bills = FinancialReports.billReminders(
            book, scheduled: scheduledTransactions,
            from: now.addingTimeInterval(-30 * 86_400),
            to: now.addingTimeInterval(60 * 86_400), asOf: now
        ).filter { $0.status != .paid }
        let billsLine: String
        if bills.isEmpty {
            billsLine = String(localized: "No upcoming bills")
        } else {
            let total = bills.reduce(Decimal(0)) { $0 + $1.amount }
            let amount = AmountFormat.string(total, code: currency.mnemonic)
            // Localized here in the app, not in the widget: the widget target
            // has its own bundle, and this line is written into the shared
            // snapshot the widget only renders.
            billsLine = String(localized: "\(bills.count) bills due · \(amount)")
        }

        // Computed once on the main actor and reused for both the snapshot and
        // the notifications, so the non-`Sendable` book never crosses actors.
        let allAlerts = alerts(asOf: now)
        let alertItems = allAlerts.prefix(5).map {
            WidgetSnapshot.Alert(title: $0.title, message: $0.message, severity: $0.severity.rawValue)
        }

        let name = documentURL?.deletingPathExtension().lastPathComponent ?? "FinvestLens"

        let snapshot = WidgetSnapshot(
            bookName: name,
            netWorth: AmountFormat.string(netWorth, code: currency.mnemonic),
            upcomingBills: billsLine,
            alerts: Array(alertItems),
            updatedAt: now
        )
        publish(snapshot)

        Task { await AlertNotificationScheduler.sync(alerts: allAlerts, asOf: now) }
    }
}
