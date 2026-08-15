//
//  WindowPeriodTests.swift
//  FinvestLens — FeatureUI
//
//  P12/N5 — one timescale, everywhere (`FR-NAV-11`).
//
//  There used to be two, and the failure was that nothing on screen said so:
//  the dashboard kept a period under its own `UserDefaults` key while reports
//  opened on the book's default, so Overview and Reports could sit on
//  different months and agree in appearance.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

@MainActor
@Suite("The window's period")
struct WindowPeriodTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
    }

    private func periodKey(_ url: URL) -> String {
        "session.period:\(url.standardizedFileURL.path)"
    }

    /// Untouched, the window follows the book's own setting — so changing the
    /// default in Settings takes effect for anyone who has not moved the
    /// selector, rather than being shadowed by a stale copy.
    @Test("An untouched window follows the book's default")
    func defaultsToTheBookSetting() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(model.period == model.defaultReportPeriod)

        var settings = model.reportSettings
        settings.defaultPeriod = .previousCalendarYear
        model.updateReportSettings(settings)
        #expect(model.period == .previousCalendarYear)
    }

    /// The point of the phase: a report opens on the period the window is
    /// showing, not on a second default of its own.
    @Test("A fresh report opens on the window's period")
    func reportsOpenOnTheWindowPeriod() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        defer { UserDefaults.standard.removeObject(forKey: periodKey(url)) }

        model.period = .last12Months
        let configuration = ReportKind.incomeStatement.defaultConfiguration(for: model)
        #expect(configuration.period == .last12Months)
    }

    /// A custom range has to survive the round trip as well as a named period —
    /// it is the case JSON storage exists for.
    @Test("A custom range survives a reopen")
    func customRangeRoundTrips() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        defer { UserDefaults.standard.removeObject(forKey: periodKey(url)) }

        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_800_000_000)

        let first = AppModel()
        try first.newDocument(at: url)
        first.period = .custom(from: from, to: to)
        try first.save()
        first.close()

        let second = AppModel()
        await second.openBook(at: url)
        #expect(second.period == .custom(from: from, to: to))
        second.close()
    }

    /// The dashboard's old private key is read once, so a board left on "Last
    /// 12 months" keeps that timescale when it becomes the whole window's
    /// rather than silently reverting to the book default.
    @Test("The dashboard's old period migrates to the window")
    func migratesTheDashboardKey() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        defer {
            UserDefaults.standard.removeObject(forKey: periodKey(url))
            UserDefaults.standard.removeObject(forKey: "session.dashboardPeriod")
        }

        let seed = AppModel()
        try seed.newDocument(at: url)
        try seed.save()
        seed.close()

        UserDefaults.standard.removeObject(forKey: periodKey(url))
        UserDefaults.standard.set(try? JSONEncoder().encode(ReportPeriod.last12Months),
                                  forKey: "session.dashboardPeriod")

        let model = AppModel()
        await model.openBook(at: url)
        #expect(model.period == .last12Months)
        model.close()
    }

    /// Closing forgets it, like every other piece of desk state — one book's
    /// timescale must not open on top of the next one's.
    @Test("Closing the book forgets the period")
    func closeForgets() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        defer { UserDefaults.standard.removeObject(forKey: periodKey(url)) }

        model.period = .previousMonth
        model.close()
        #expect(model.windowPeriod == nil)
    }
}
