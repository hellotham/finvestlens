// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// Captures the App Store screenshot set on whichever simulator runs the test.
///
/// Skips itself unless `FL_SHOT_DIR` names a directory and `FL_SHOT_BOOK` a
/// book — `xcodebuild` forwards both with the `TEST_RUNNER_` prefix:
///
///     TEST_RUNNER_FL_SHOT_DIR=/path/to/shots \
///     TEST_RUNNER_FL_SHOT_BOOK=/path/to/Demo.finvestlens \
///     xcodebuild test -scheme finvestlens \
///         -destination 'platform=iOS Simulator,id=<udid>' \
///         -only-testing:finvestlensUITests/ScreenshotTests
///
/// The book must be the synthetic one (`website/scripts/demo-book`) — never a
/// real book. The test opens a private copy of it, so the original gains no
/// lock and two devices can run from the same file. Nothing is seeded into
/// the simulator: the copy's path and the reporting period reach the app as
/// launch arguments, which `UserDefaults` reads ahead of anything stored —
/// so a reinstall that moves the app's container, or a recents list the app
/// has pruned, cannot leave the run looking at the welcome screen.
///
/// `FL_SHOT_PERIOD` overrides the period (the JSON of a `ReportPeriod`; the
/// default is the previous financial year, which is where the demo book's
/// postings are). `FL_DUMP=1` also writes accessibility dumps. Every capture
/// is the device's full screen at native scale, as App Store Connect wants.
///
/// `FL_AUDIT=1` runs Xcode's accessibility audit on every screen captured —
/// contrast, element detection, hit regions, descriptions, Dynamic Type,
/// clipped text and traits — and writes what it finds to `audit.txt` beside
/// the images, one line per issue, without failing the run: the audit is
/// evidence to read (App Store Connect ▸ App Accessibility asks for it), and a
/// run that stops at its first finding would show only one. Set the
/// simulator's text size and appearance with `xcrun simctl ui <udid>
/// content_size …` and `… appearance …` first; `testAuditWelcome` adds the
/// screen a first launch shows.
final class ScreenshotTests: XCTestCase {
    private var shotDirectory: URL!
    private var bookURL: URL!
    private var compact = false
    /// The app on screen, for the audit `capture` runs.
    private var launched: XCUIApplication?
    private var auditing: Bool { ProcessInfo.processInfo.environment["FL_AUDIT"] != nil }

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dir = environment["FL_SHOT_DIR"], !dir.isEmpty,
              let book = environment["FL_SHOT_BOOK"], !book.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_FL_SHOT_DIR and TEST_RUNNER_FL_SHOT_BOOK to capture screenshots")
        }
        shotDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("FLShots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        bookURL = scratch.appendingPathComponent("Demo.finvestlens")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: book), to: bookURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

        // Keep going after a miss: an absent element costs one screenshot,
        // not the whole set, and the hierarchy dump says what was there.
        continueAfterFailure = true
    }

    /// Launches the app on the private copy of the book and waits for it to
    /// open. Returns `nil` (after failing the test) if it never does.
    @MainActor
    private func launchOnBook() -> XCUIApplication? {
        let app = XCUIApplication()
        let path = bookURL.standardizedFileURL.path
        let period = ProcessInfo.processInfo.environment["FL_SHOT_PERIOD"] ?? #"{"previousFinancialYear":{}}"#
        let periodHex = Data(period.utf8).map { String(format: "%02x", $0) }.joined()
        app.launchArguments += [
            "-finvestlens.recentBookPaths", "(\"\(path)\")",
            "-session.period:\(path)", "<\(periodHex)>",
        ]
        app.launch()
        launched = app
        dismissNotificationPrompt()
        // The book is open once the mode bar — or the phone's tab bar — is on
        // screen.
        guard app.buttons["Dashboard"].firstMatch.waitForExistence(timeout: 60) else {
            dump("no-mode-bar", app)
            capture("00-no-mode-bar")
            XCTFail("the book never opened: no mode bar or tab bar")
            return nil
        }
        compact = app.tabBars.firstMatch.exists
        settle(2)
        return app
    }

    /// Every destination the phone can reach, one capture each, and the
    /// navigation the compact shell promises asserted along the way — the
    /// pass for a change to the compact shell. Not part of the store set, so
    /// it runs only with `FL_TOUR=1`.
    @MainActor
    func testTourCompactDestinations() throws {
        guard ProcessInfo.processInfo.environment["FL_TOUR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_FL_TOUR=1 for the compact tour")
        }
        guard let app = launchOnBook() else { return }
        guard compact else { throw XCTSkip("the tour is for the compact shell") }

        // Search: rows, not a one-column table — and a share purchase opens
        // in the editor with its quantity, which is not its value.
        tapMode("Accounts", app)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("Buy NDQ")
            settle(3)
            capture("tour-search")
            let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Buy NDQ")).firstMatch
            if hit.waitForExistence(timeout: 5) {
                hit.tap()
                settle(2)
                capture("tour-editor-security")
                XCTAssertTrue(app.textFields["Quantity"].firstMatch.exists,
                              "a split on a security account shows its quantity")
                tap("Cancel", in: app)
            } else {
                dump("no-search-hit", app)
                XCTFail("the search listed no row for Buy NDQ")
            }
            if !tap("Cancel", in: app) { tap("Close", in: app) }
        } else {
            dump("no-search-field", app)
        }

        // More: one list, every row one tap from its page, one Back from it.
        app.tabBars.buttons["More"].firstMatch.tap()
        settle(1)
        for row in ["Business", "Time & Mileage", "Planner", "Budgets", "Savings Goals",
                    "Scheduled", "Rules", "Audit Log"] {
            guard tapRow(row, app) else { continue }
            guard !app.navigationBars["More"].exists else {
                dump("not-pushed-\(row)", app)
                XCTFail("\(row) did not push")
                continue
            }
            if row == "Planner" {
                // The Planner's three tools are one page: choosing another
                // must not push a second.
                tap("Lifetime", in: app)
                settle(1)
                tap("Tax Estimate", in: app)
                settle(1)
                capture("tour-more-planner-tax")
            } else {
                capture("tour-more-\(row.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-"))")
            }
            popToRoot(app)
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 3),
                          "one Back from \(row) returns to More")
        }

        // More ▸ Settings: the five panes, each one tap in and one Back out,
        // and Done closes the sheet. Until 12 Oct 2026 nothing on iPhone or
        // iPad presented the panes at all.
        if tapRow("Settings", app) {
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                          "Settings opened as a sheet with its own title")
            capture("tour-settings")
            for pane in ["General", "Appearance", "Pricing", "Documents", "Apple Intelligence"] {
                guard tapRow(pane, app) else { XCTFail("Settings has no \(pane) row"); continue }
                XCTAssertFalse(app.navigationBars["Settings"].exists, "\(pane) did not push")
                capture("tour-settings-\(pane.lowercased().replacingOccurrences(of: " ", with: "-"))")
                if pane == "Apple Intelligence" {
                    XCTAssertTrue(app.staticTexts["Where it runs"].firstMatch.exists
                                  || app.staticTexts["WHERE IT RUNS"].firstMatch.exists,
                                  "the pane says where Apple Intelligence runs")
                }
                popToRoot(app)
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3),
                              "one Back from \(pane) returns to Settings")
            }
            XCTAssertTrue(tap("Done", in: app), "Settings has a Done button")
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 3), "Done closes Settings")
        } else {
            XCTFail("More has no Settings row")
        }
        if tapRow("Help", app) {
            settle(1)
            capture("tour-help")
            // A sheet the tour cannot close hides the tab bar from every
            // step after it, and each of those steps then skips in silence —
            // which is how a tour "passed" having toured half the app.
            XCTAssertTrue(tap("Done", in: app), "Help has a Done button on the phone")
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 3), "Done closes Help")
        } else {
            XCTFail("More has no Help row")
        }

        // Investments: a holding's row opens its page; Back returns to the
        // holdings, and Back again to the list.
        tapMode("Investments", app)
        XCTAssertTrue(app.navigationBars["Investments"].waitForExistence(timeout: 5),
                      "the Investments tab is in front")
        if tapRow("All Holdings", app) {
            capture("tour-holdings")
            // The worklist row above also names VAS; the holding's own row starts with it.
            let holding = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "VAS")).firstMatch
            if holding.waitForExistence(timeout: 5) {
                holding.tap()
                settle(2)
                capture("tour-security")
                XCTAssertTrue(app.navigationBars["VAS"].exists, "the holding's row opened its page")
                popToRoot(app)
                XCTAssertTrue(app.navigationBars["All Holdings"].waitForExistence(timeout: 3),
                              "Back from a holding returns to All Holdings")
            } else {
                dump("no-holding-row", app)
                XCTFail("no holding row to tap")
            }
            popToRoot(app)
            XCTAssertTrue(app.navigationBars["Investments"].waitForExistence(timeout: 3))
        }

        // Accounts: a register, its editor, its row menu.
        tapMode("Accounts", app)
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5),
                      "the Accounts tab is in front")
        let reachedRegister = expandGroup("Assets", app) && expandGroup("Current Assets", app)
        XCTAssertTrue(reachedRegister, "the account tree opens to Current Assets")
        if reachedRegister {
            capture("tour-accounts-expanded")
            let opened = tapRow("Everyday Account", app)
            XCTAssertTrue(opened, "the demo book's Everyday Account opens its register")
            if opened {
                capture("tour-register")
                let posting = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sunfield Energy")).firstMatch
                if posting.waitForExistence(timeout: 5) {
                    posting.tap()
                    settle(2)
                    capture("tour-editor-edit")
                    XCTAssertEqual(app.textFields["Description"].firstMatch.value as? String, "Sunfield Energy",
                                   "the editor opened the posting that was tapped")
                    tap("Cancel", in: app)
                    posting.press(forDuration: 1.2)
                    settle(1)
                    capture("tour-register-menu")
                    // The row's own Auto-Categorise… is about that row, and
                    // leaves it selected behind a list that shows no selection.
                    if tap("Auto-Categorise…", in: app) {
                        settle(2)
                        capture("tour-autocategorise-row")
                        if !tap("Cancel", in: app) { tap("Done", in: app) }
                        settle(1)
                    } else {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
                        settle(1)
                    }
                }
                // The register's Actions menu: reconcile this account, or
                // categorise — everything uncategorised, not the one row a
                // row's menu selected a moment ago.
                let actions = app.navigationBars.buttons["Actions"].firstMatch
                if actions.waitForExistence(timeout: 5) {
                    actions.tap()
                    settle(1)
                    capture("tour-register-actions")
                    XCTAssertTrue(app.buttons["Reconcile Account…"].firstMatch.exists,
                                  "an account's register offers reconciling")
                    XCTAssertFalse(app.buttons["Import Bank File…"].firstMatch.exists,
                                   "importing is not offered on the phone (FR-PLT-06)")
                    if tap("Auto-Categorise…", in: app) {
                        settle(2)
                        capture("tour-autocategorise-all")
                        let scoped = app.staticTexts.matching(
                            NSPredicate(format: "label CONTAINS[c] %@", "selected transaction")).firstMatch
                        XCTAssertFalse(scoped.exists,
                                       "the toolbar's Auto-Categorise is not scoped to a selection nobody can see")
                        if !tap("Cancel", in: app) { tap("Done", in: app) }
                        settle(1)
                    } else {
                        XCTFail("the Actions menu has no Auto-Categorise…")
                    }
                    actions.tap()
                    settle(1)
                    if tap("Reconcile Account…", in: app) {
                        settle(2)
                        capture("tour-reconcile")
                        if !tap("Cancel", in: app) { tap("Close", in: app) }
                        settle(1)
                    } else {
                        XCTFail("the Actions menu has no Reconcile Account…")
                    }
                } else {
                    dump("no-actions-menu", app)
                    XCTFail("the register has no Actions menu")
                }
                popToRoot(app)
                XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 3))
            }
        }
        for item in ["New Transaction…", "New Account…", "New Security…"] {
            let new = app.navigationBars.buttons["New"].firstMatch
            guard new.waitForExistence(timeout: 5) else { dump("missing-new", app); break }
            new.tap()
            settle(1)
            guard tap(item, in: app) else { dump("missing-\(item)", app); break }
            settle(2)
            capture("tour-\(item.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: " ", with: "-"))")
            if !tap("Cancel", in: app) { dump("no-cancel-\(item)", app) }
        }
    }

    /// The regular shell's Settings and Help — the iPad's, reached from the
    /// foot of its sidebar. Both are sheets there, so each has to open, show
    /// what it should, and close again. Runs with `FL_TOUR=1`, on an iPad.
    @MainActor
    func testRegularSettingsAndHelp() throws {
        guard ProcessInfo.processInfo.environment["FL_TOUR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_FL_TOUR=1 for the settings tour")
        }
        guard let app = launchOnBook() else { return }
        guard !compact else { throw XCTSkip("this tour is for the regular shell") }

        capture("regular-sidebar-footer")
        XCTAssertTrue(tap("Settings", in: app), "the sidebar's foot has a Settings button")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings opened")
        capture("regular-settings")
        for pane in ["General", "Appearance", "Pricing", "Documents", "Apple Intelligence"] {
            guard tapRow(pane, app) else { XCTFail("Settings has no \(pane) row"); continue }
            capture("regular-settings-\(pane.lowercased().replacingOccurrences(of: " ", with: "-"))")
            popToRoot(app)
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3),
                          "one Back from \(pane) returns to Settings")
        }
        XCTAssertTrue(tap("Done", in: app), "Settings has a Done button")
        settle(1)
        XCTAssertFalse(app.navigationBars["Settings"].exists, "Done closes Settings")

        XCTAssertTrue(tap("Help", in: app), "the sidebar's foot has a Help button")
        settle(2)
        capture("regular-help")
        XCTAssertEqual(app.buttons.matching(identifier: "Done").count, 1,
                       "Help shows one Done button, not one per column")
        XCTAssertTrue(tap("Done", in: app), "Help has a Done button")
        settle(1)
        XCTAssertTrue(app.buttons["Settings"].firstMatch.isHittable, "Done closes Help")
    }

    /// The welcome screen — what a first launch shows, with no book open and
    /// none remembered. Runs with `FL_AUDIT=1`.
    @MainActor
    func testAuditWelcome() throws {
        guard auditing else { throw XCTSkip("Set TEST_RUNNER_FL_AUDIT=1 for the accessibility audit") }
        let app = XCUIApplication()
        app.launchArguments += ["-finvestlens.recentBookPaths", "()",
                                "-finvestlens.reopenLastBook", "NO"]
        app.launch()
        launched = app
        dismissNotificationPrompt()
        guard app.buttons["New Book"].firstMatch.waitForExistence(timeout: 30) else {
            dump("no-welcome", app)
            return XCTFail("the welcome screen never showed")
        }
        settle(2)
        capture("00-welcome")
    }

    /// Taps a button by name if there is one. Returns whether it did.
    @MainActor
    @discardableResult
    private func tap(_ name: String, in app: XCUIApplication) -> Bool {
        let button = app.buttons[name].firstMatch
        guard button.waitForExistence(timeout: 3) else { return false }
        button.tap()
        settle(1)
        return true
    }

    @MainActor
    func testCaptureStoreScreenshots() throws {
        guard let app = launchOnBook() else { return }
        capture("01-dashboard")

        tapMode("Accounts", app)
        capture("02-accounts")
        if ProcessInfo.processInfo.environment["FL_DUMP"] != nil { dump("accounts", app) }
        // The phone's Accounts root is the account list; the journal is a
        // row on it. The iPad lands on the journal already.
        if compact, tapRow("All Transactions", app) {
            capture("02b-all-transactions")
            popToRoot(app)
        }

        tapMode("Investments", app)
        capture("03-investments")

        tapMode("Reports", app)
        capture("04-reports")
        for (index, report) in ["Balance Sheet", "Income Statement", "Net Worth", "Income & Expense"].enumerated() {
            if openReport(report, app) {
                capture("0\(5 + index)-\(report.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-"))")
            }
        }

        // The iPad has a mode per area; the phone keeps Business, Planning
        // and Records as the sections of its More tab.
        if compact {
            app.tabBars.buttons["More"].firstMatch.tap()
            settle(2)
            capture("09-more")
            captureCompactDestinations(app)
        } else {
            tapMode("Planning", app)
            capture("09-planning")
        }
    }

    // MARK: - Driving

    /// Taps a mode: its button on the mode bar, or its tab on the phone.
    @MainActor
    private func tapMode(_ name: String, _ app: XCUIApplication) {
        let button = (compact ? app.tabBars.buttons[name] : app.buttons[name]).firstMatch
        guard button.waitForExistence(timeout: 10) else {
            dump("missing-mode-\(name)", app)
            return XCTFail("no mode button \(name)")
        }
        if !button.isHittable { app.swipeLeft() }
        button.tap()
        settle(2)
    }

    /// Opens a disclosure row by its chevron — the row's own text is a link
    /// to that account's register, so tapping the name would navigate.
    @MainActor
    private func expandGroup(_ name: String, _ app: XCUIApplication) -> Bool {
        let row = app.buttons[name].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            dump("missing-group-\(name)", app)
            return false
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        settle(1)
        return true
    }

    /// Opens a report: from the sidebar where there is one, and on the phone
    /// from the gallery — back to it first if a report is already showing.
    @MainActor
    private func openReport(_ name: String, _ app: XCUIApplication) -> Bool {
        if compact {
            let back = app.buttons["All Reports"].firstMatch
            if back.exists { back.tap(); settle(1) }
        }
        return tapRow(name, app)
    }

    /// Taps a row or card by its text, scrolling a little to find one that a
    /// lazy container has not built yet. Returns `false` (after dumping the
    /// hierarchy) when nothing by that name turns up.
    ///
    /// Every query here is a fresh accessibility snapshot of the whole app,
    /// and a register with hundreds of rows makes each one slow — so there
    /// are two candidates, not a ladder, and no separate hittability probe.
    @MainActor
    private func tapRow(_ text: String, _ app: XCUIApplication) -> Bool {
        for attempt in 0..<3 {
            // Buttons first: a phone's row is a link, and a section header
            // above it can carry the same words as plain text.
            for candidate in [app.buttons[text].firstMatch, app.staticTexts[text].firstMatch]
            where candidate.waitForExistence(timeout: attempt == 0 ? 3 : 1) {
                candidate.tap()
                settle(2)
                return true
            }
            app.swipeUp()
        }
        dump("missing-row-\(text)", app)
        return false
    }

    /// The phone's pushed screens, which the mode roots alone never show:
    /// the holdings page, an account register, the editor sheet, a search,
    /// and a destination reached from More.
    @MainActor
    private func captureCompactDestinations(_ app: XCUIApplication) {
        if tapRow("Budgets", app) {
            capture("10-budgets")
            popToRoot(app)
        }
        tapMode("Investments", app)
        if tapRow("All Holdings", app) {
            capture("11-holdings")
            popToRoot(app)
        }
        tapMode("Accounts", app)
        if expandGroup("Assets", app), expandGroup("Current Assets", app),
           tapRow("Everyday Account", app) {
            capture("12-register")
            let posting = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sunfield Energy")).firstMatch
            if posting.waitForExistence(timeout: 5) {
                posting.tap()
                settle(2)
                capture("13-editor")
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.exists { cancel.tap(); settle(1) }
            } else {
                dump("missing-posting", app)
            }
            popToRoot(app)
        }
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("Greenway")
            settle(3)
            capture("14-search")
        }
    }

    @MainActor
    private func popToRoot(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap(); settle(1) }
    }

    /// The local-notification permission prompt comes from SpringBoard, not the
    /// app, so it is found through SpringBoard's own hierarchy. Declined: a
    /// screenshot run grants nothing.
    @MainActor
    private func dismissNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 8) else { return }
        let decline = alert.buttons.element(boundBy: 0)
        if decline.exists { decline.tap() }
        settle(1)
    }

    // MARK: - Capturing

    @MainActor
    private func capture(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = shotDirectory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)")
        }
        if auditing { audit(name) }
    }

    /// Appends what the accessibility audit finds on the screen now showing
    /// to `audit.txt` — every issue handled here, so none fails the run.
    @MainActor
    private func audit(_ name: String) {
        guard let app = launched else { return }
        var lines: [String] = []
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                var element = "-"
                if let target = issue.element, target.exists {
                    element = "\(target.elementType.rawValue) “\(target.label)” id “\(target.identifier)”"
                }
                lines.append([name, "type \(issue.auditType.rawValue)", issue.compactDescription,
                              element, issue.detailedDescription.replacingOccurrences(of: "\n", with: " ")]
                    .joined(separator: "\t"))
                return true
            }
        } catch {
            lines.append("\(name)\taudit did not run: \(error)")
        }
        // The audit tries other text sizes on the app and puts its own back;
        // the redraw that follows swallowed the tour's next tap — a menu that
        // never opened failed two assertions on 18 Oct 2026 that the same
        // tour, run without the audit, passes. Let it settle first.
        settle(3)
        if lines.isEmpty { lines.append("\(name)\tno issues") }
        let url = shotDirectory.appendingPathComponent("audit.txt")
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Writes the accessibility hierarchy beside the screenshots so a miss can
    /// be diagnosed without another run.
    @MainActor
    private func dump(_ name: String, _ app: XCUIApplication) {
        let url = shotDirectory.appendingPathComponent("hierarchy-\(name).txt")
        try? app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
