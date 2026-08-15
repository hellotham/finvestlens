//
//  AppModel+Session.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Session restoration (F18): where you were survives relaunch. The mode and
//  *each mode's* destination — including the selected account — are stored per
//  book (keyed by file path) and re-applied when that book finishes opening.
//  Held in UserDefaults, not the book: where you were looking is desk state,
//  not accounting data, and must not dirty the document (the same reasoning as
//  the per-account register sort/filter state).
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    /// Desk state as stored. A dictionary rather than one value since P12:
    /// each mode remembers its own destination (`FR-NAV-03`).
    ///
    /// Decoded field by field rather than by the synthesised initialiser, which
    /// throws on a key that is merely *absent*. This state grows — N3 adds each
    /// mode's open tabs to it — and a decode that throws does not degrade, it
    /// discards: the user reopens at Overview having lost every mode's place.
    /// Missing means default, in both directions.
    private struct SessionNavigation: Codable {
        var mode: String
        /// Mode raw value → encoded ``SidebarSelection``.
        var selections: [String: String]

        init(mode: String, selections: [String: String]) {
            self.mode = mode
            self.selections = selections
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = try container.decodeIfPresent(String.self, forKey: .mode)
                ?? AppMode.overview.rawValue
            selections = try container.decodeIfPresent([String: String].self, forKey: .selections)
                ?? [:]
        }
    }

    private var sessionNavigationKey: String? {
        documentURL.map { "session.navigation:\($0.standardizedFileURL.path)" }
    }

    /// The pre-P12 key: one flat destination for the whole window. Still read
    /// once, so a book last open before the navigation redesign reopens where it
    /// was rather than at Overview.
    private var legacySelectionKey: String? {
        documentURL.map { "session.sidebarSelection:\($0.standardizedFileURL.path)" }
    }

    /// Called from every navigation — the stored destination for this book
    /// follows the window.
    func persistSessionSelection() {
        guard isOpen, let key = sessionNavigationKey else { return }
        let (mode, selections) = navigationSnapshot
        let stored = SessionNavigation(
            mode: mode.rawValue,
            selections: Dictionary(uniqueKeysWithValues:
                selections.map { ($0.key.rawValue, Self.encode($0.value)) }))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: key)
    }

    /// Re-applies the stored desk state once a book is open. An account that no
    /// longer exists (deleted, or the file changed outside the app) drops back
    /// to its mode's home rather than leaving a dead selection.
    func restoreSessionSelection() {
        guard let (mode, selections) = readStoredNavigation() else { return }
        let live = selections.filter { _, selection in
            guard case .account(let id) = selection else { return true }
            return book?.account(with: id) != nil
        }
        restoreNavigation(mode: mode, selections: live)
    }

    /// Reads the current format, falling back to the pre-P12 flat value.
    private func readStoredNavigation() -> (AppMode, [AppMode: SidebarSelection])? {
        if let key = sessionNavigationKey,
           let raw = UserDefaults.standard.string(forKey: key),
           let stored = try? JSONDecoder().decode(SessionNavigation.self, from: Data(raw.utf8)) {
            var selections: [AppMode: SidebarSelection] = [:]
            for (rawMode, rawSelection) in stored.selections {
                guard let mode = AppMode(rawValue: rawMode),
                      let selection = Self.decodeSelection(rawSelection) else { continue }
                selections[mode] = selection
            }
            return (AppMode(rawValue: stored.mode) ?? .overview, selections)
        }
        // Migration. The old value named a destination with no mode attached, so
        // the mode is derived from the destination — a book last left on Budgets
        // reopens in Planning, on Budgets, which is where the user was.
        guard let legacyKey = legacySelectionKey,
              let raw = UserDefaults.standard.string(forKey: legacyKey),
              let selection = Self.decodeSelection(raw) else { return nil }
        let mode = AppMode(hosting: selection)
        return (mode, [mode: selection])
    }

    private static func encode(_ selection: SidebarSelection) -> String {
        switch selection {
        case .dashboard: "dashboard"
        case .account(let id): "account:\(id.hexString)"
        case .reports: "reports"
        case .generalLedger: "generalLedger"
        case .budgets: "budgets"
        case .scheduled: "scheduled"
        case .rules: "rules"
        case .goals: "goals"
        case .investments: "investments"
        case .business: "business"
        case .timeMileage: "timeMileage"
        case .planner: "planner"
        case .emergencyRecords: "emergencyRecords"
        case .auditLog: "auditLog"
        case .budget(let id): "budget:\(id.hexString)"
        case .goal(let id): "goal:\(id.hexString)"
        case .scheduledTransaction(let id): "scheduledTransaction:\(id.hexString)"
        case .invoice(let id): "invoice:\(id.hexString)"
        case .customer(let id): "customer:\(id.hexString)"
        case .vendor(let id): "vendor:\(id.hexString)"
        case .job(let id): "job:\(id.hexString)"
        case .employee(let id): "employee:\(id.hexString)"
        case .ruleGroup(let id): "ruleGroup:\(id.uuidString)"
        case .emergencyRecord(let id): "emergencyRecord:\(id.uuidString)"
        case .savedReport(let id): "savedReport:\(id.uuidString)"
        case .security(let key): "security:\(key)"
        case .report(let kind): "report:\(kind.rawValue)"
        }
    }

    /// GUID-keyed instance destinations, by prefix.
    private static let guidCases: [(String, (GncGUID) -> SidebarSelection)] = [
        ("account:", SidebarSelection.account),
        ("budget:", SidebarSelection.budget),
        ("goal:", SidebarSelection.goal),
        ("scheduledTransaction:", SidebarSelection.scheduledTransaction),
        ("invoice:", SidebarSelection.invoice),
        ("customer:", SidebarSelection.customer),
        ("vendor:", SidebarSelection.vendor),
        ("job:", SidebarSelection.job),
        ("employee:", SidebarSelection.employee),
    ]

    /// UUID-keyed instance destinations — the collections that live outside the
    /// engine and so carry Foundation UUIDs rather than GnuCash GUIDs.
    private static let uuidCases: [(String, (UUID) -> SidebarSelection)] = [
        ("ruleGroup:", SidebarSelection.ruleGroup),
        ("emergencyRecord:", SidebarSelection.emergencyRecord),
        ("savedReport:", SidebarSelection.savedReport),
    ]

    private static func decodeSelection(_ raw: String) -> SidebarSelection? {
        for (prefix, make) in guidCases where raw.hasPrefix(prefix) {
            return GncGUID(hex: String(raw.dropFirst(prefix.count))).map(make)
        }
        for (prefix, make) in uuidCases where raw.hasPrefix(prefix) {
            return UUID(uuidString: String(raw.dropFirst(prefix.count))).map(make)
        }
        if raw.hasPrefix("security:") {
            return .security(String(raw.dropFirst("security:".count)))
        }
        if raw.hasPrefix("report:") {
            return ReportKind(rawValue: String(raw.dropFirst("report:".count)))
                .map(SidebarSelection.report)
        }
        switch raw {
        case "dashboard": return .dashboard
        case "reports": return .reports
        case "generalLedger": return .generalLedger
        case "budgets": return .budgets
        case "scheduled": return .scheduled
        case "rules": return .rules
        case "planner": return .planner
        case "emergencyRecords": return .emergencyRecords
        case "goals": return .goals
        // "prices" is the pre-P11 spelling: a saved session must still
        // restore rather than silently dropping the user back to the dashboard.
        case "investments", "prices": return .investments
        case "business": return .business
        case "timeMileage": return .timeMileage
        default: return nil
        }
    }
}
