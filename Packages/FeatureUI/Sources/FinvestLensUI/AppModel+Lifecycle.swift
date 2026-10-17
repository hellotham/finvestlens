//
//  AppModel+Lifecycle.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit

@MainActor
extension AppModel {

    /// iOS may end a suspended app without warning, so leaving the screen is
    /// the last moment changes can be kept. A save already writing is let
    /// finish — the first version returned at once when one was, and ended
    /// the background allowance while that save was still being written —
    /// then the book is saved, and a book from Box goes up (leaving the app
    /// is one of the explicit saves), for as long as iOS allows. A chunked
    /// upload cut off here goes on from its last part next time.
    public func saveBeforeSuspension() {
        let allowance = BackgroundAllowance(name: "Save book")
        Task {
            await waitForSaveToFinish()
            if hasUnsavedChanges, !isReadOnly { await saveWithStatus(interactive: false) }
            requestUploadOfOpenBoxBook(announce: false)
            await finishBoxWork(within: .seconds(25))
            allowance.end()
        }
    }
}

/// The time iOS grants an app to finish work after it leaves the screen,
/// ended exactly once — by the work finishing, or by iOS running out.
@MainActor
final class BackgroundAllowance {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
