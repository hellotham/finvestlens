//
//  AppModel+CSV.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange

/// Which slice of the book a CSV export covers (`FR-XIO-06`).
public enum CSVExportKind: String, Sendable, CaseIterable, Identifiable {
    case accounts, transactions, prices
    public var id: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .accounts: return "Accounts…"
        case .transactions: return "Transactions…"
        case .prices: return "Prices…"
        }
    }

    /// Suggested export filename stem.
    public func filename(book bookName: String) -> String {
        "\(bookName) \(rawValue.capitalized)"
    }
}

/// A saved CSV column-mapping profile for repeat imports (`FR-XIO-08`).
public struct CSVImportProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var dateColumn: Int
    /// A single signed-amount column. Optional because a great many bank
    /// exports have no such column at all — they carry a *pair*
    /// (``debitColumn``/``creditColumn``) instead, and a profile for one of
    /// those files has no amount column to name.
    ///
    /// Widening `Int` to `Int?` is safe for every profile already saved: a
    /// present value still decodes as `.some`. The reverse — adding a
    /// non-optional field — would have failed to decode all of them, which is
    /// why the fields below were optional from the day they were added.
    public var amountColumn: Int?
    /// Added after the first release, so all five decode as absent from a
    /// profile saved before they existed — `nil`/0 is exactly what those
    /// profiles meant.
    public var debitColumn: Int?
    public var creditColumn: Int?
    public var payeeColumn: Int
    public var dateFormat: String
    public var hasHeader: Bool
    public var memoColumn: Int?
    public var referenceColumn: Int?
    public var skipRows: Int?

    public init(id: UUID = UUID(), name: String, dateColumn: Int, amountColumn: Int?,
                payeeColumn: Int, dateFormat: String, hasHeader: Bool,
                debitColumn: Int? = nil, creditColumn: Int? = nil,
                memoColumn: Int? = nil, referenceColumn: Int? = nil, skipRows: Int? = nil) {
        self.id = id
        self.name = name
        self.dateColumn = dateColumn
        self.amountColumn = amountColumn
        self.debitColumn = debitColumn
        self.creditColumn = creditColumn
        self.payeeColumn = payeeColumn
        self.dateFormat = dateFormat
        self.hasHeader = hasHeader
        self.memoColumn = memoColumn
        self.referenceColumn = referenceColumn
        self.skipRows = skipRows
    }

}

@MainActor
extension AppModel {

    private static let csvProfilesKey = "finvestlens.csvImportProfiles"

    /// Saved CSV import profiles (app-wide, since they describe a file format,
    /// not a book). Persisted in `UserDefaults` (`FR-XIO-08`).
    public var csvImportProfiles: [CSVImportProfile] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.csvProfilesKey),
                  let profiles = try? JSONDecoder().decode([CSVImportProfile].self, from: data)
            else { return [] }
            return profiles
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.csvProfilesKey)
        }
    }

    /// Saves (or replaces by name) a CSV import profile.
    public func saveCSVImportProfile(_ profile: CSVImportProfile) {
        var profiles = csvImportProfiles
        profiles.removeAll { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }
        profiles.append(profile)
        csvImportProfiles = profiles.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func deleteCSVImportProfile(_ id: UUID) {
        csvImportProfiles = csvImportProfiles.filter { $0.id != id }
    }

    /// Renders the requested slice of the open book to CSV (`FR-XIO-06`).
    public func csvExport(_ kind: CSVExportKind) -> String {
        guard let book else { return "" }
        switch kind {
        case .accounts:     return CSVExporter.accounts(book)
        case .transactions: return CSVExporter.transactions(book)
        case .prices:       return CSVExporter.prices(book)
        }
    }
}
