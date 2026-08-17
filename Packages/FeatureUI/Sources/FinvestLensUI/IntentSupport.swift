//
//  IntentSupport.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensPersistence
import FinvestLensReports
import FinvestLensShared
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Read-only summaries for App Intents / Shortcuts / widgets, driven by the
/// last-opened book (`FR-PLT-03`). Loading uses the store directly (no lock /
/// working copy) since these are read-only.
public enum IntentSupport {

    static func lastBook() -> Book? {
        guard let path = UserDefaults.standard.string(forKey: "finvestlens.lastBookPath"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        // **Read-only**, which is what every caller here is. The read-write
        // initialiser runs the migrator, so a Spotlight or Siri query would
        // `ALTER TABLE` the user's live shared book — uncoordinated, holding no
        // lock, while the app has it open. That changes the file's bytes, so
        // the app's next save compares against a fingerprint that no longer
        // matches and throws `DocumentError.conflict`, and the external-change
        // watcher starts offering to reload the user's own edits away. The
        // v5_invoice_kvp migration made this reachable rather than theoretical.
        guard let book = try? SQLiteDocumentStore(readOnlyPath: path).read() else { return nil }
        // A book behind Face/Touch ID (`NFR-07`) stays behind it here too.
        // These entry points answer Spotlight, Shortcuts and Siri without any
        // window, so nothing else would ever put the lock in front of them —
        // account names and balances would have been readable from the Lock
        // Screen on a book the user explicitly gated.
        guard !requiresAuthentication(book) else { return nil }
        return book
    }

    /// Whether the book's own KVP asks for authentication — the same key
    /// `AppModel.requireAuthentication` reads, checked here without an
    /// `AppModel` because these entry points run outside the app's UI.
    static func requiresAuthentication(_ book: Book) -> Bool {
        if case let .int64(v)? = book.kvp["finvestlens/requireAuth"] { return v != 0 }
        return false
    }

    static func baseCurrency(_ book: Book) -> Commodity {
        book.baseCurrency
    }

    private static func decodeScheduled(_ book: Book) -> [ScheduledTransaction] {
        guard case let .string(json)? = book.kvp[BookKvpKeys.scheduledTransactions],
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ScheduledTransaction].self, from: data)) ?? []
    }

    private static func money(_ value: Decimal, _ currency: Commodity) -> String {
        AmountFormat.string(value, code: currency.mnemonic)
    }

    /// "Your net worth is $X."
    public static func netWorthSummary() -> String {
        guard let book = lastBook() else { return "No FinvestLens book has been opened yet." }
        let currency = baseCurrency(book)
        let value = FinancialReports.netWorthSeries(book, dates: [Date()], currency: currency).last?.netWorth ?? 0
        return "Your net worth is \(money(value, currency))."
    }

    /// "You have N upcoming bills totalling $X."
    public static func upcomingBillsSummary() -> String {
        guard let book = lastBook() else { return "No FinvestLens book has been opened yet." }
        let currency = baseCurrency(book)
        let now = Date()
        let bills = FinancialReports.billReminders(
            book, scheduled: decodeScheduled(book),
            from: now.addingTimeInterval(-30 * 86_400),
            to: now.addingTimeInterval(60 * 86_400), asOf: now
        ).filter { $0.status != .paid }
        guard !bills.isEmpty else { return String(localized: "You have no upcoming bills.") }
        let total = bills.reduce(Decimal(0)) { $0 + $1.amount }
        let amount = money(total, currency)
        return String(localized: "You have \(bills.count) upcoming bills totalling \(amount).")
    }

    // MARK: - Accounts (App Entity / Spotlight)

    /// A postable account exposed to App Intents / Spotlight.
    public struct AccountInfo: Sendable, Identifiable {
        public let id: String       // account GUID hex
        public let name: String     // full colon-path name
        public let balance: String  // formatted in the account's own commodity
    }

    /// Every non-placeholder account, for `AppEntity` suggestions and Spotlight
    /// indexing. Balances are in each account's own commodity.
    public static func accounts() -> [AccountInfo] {
        guard let book = lastBook() else { return [] }
        // One walk for every balance, not one walk per account. `balance(of:)`
        // scans the whole book each time it is called, so asking it for all of
        // them is accounts × transactions — on the reference book 559 × 46,553
        // splits, and Spotlight calls this while the user is still typing.
        // `balancesByAccount` exists for exactly this shape and matches it
        // exactly: own balance, no descendants, every split.
        let balances = book.balancesByAccount()
        return book.accounts
            .filter { !$0.isPlaceholder }
            .map { account in
                let amount = balances[ObjectIdentifier(account)] ?? 0
                return AccountInfo(id: account.guid.hexString, name: account.fullName,
                                   balance: Money(amount, account.commodity).formatted())
            }
    }

    /// A single account's formatted balance, by GUID hex — for a parameterized
    /// "account balance" intent.
    public static func accountBalance(id: String) -> String? {
        guard let book = lastBook(),
              let account = book.accounts.first(where: { $0.guid.hexString == id })
        else { return nil }
        return Money(book.balance(of: account).amount, account.commodity).formatted()
    }

    /// The current alerts as a spoken/short summary.
    public static func alertsSummary() -> String {
        guard let book = lastBook() else { return "No FinvestLens book has been opened yet." }
        let currency = baseCurrency(book)
        let alerts = FinancialReports.alerts(book, scheduled: decodeScheduled(book),
                                             currency: currency)
        guard !alerts.isEmpty else { return "Nothing needs your attention." }
        let top = alerts.prefix(3).map(\.title).joined(separator: "; ")
        return alerts.count <= 3 ? top : "\(top); and \(alerts.count - 3) more."
    }

    // MARK: - Widget / Quick Look snapshot (FR-PLT-03)

    /// Builds the small snapshot the app publishes to the App Group container
    /// for its WidgetKit and Quick Look extensions. Returns a neutral
    /// placeholder when no book has been opened.
    public static func snapshot() -> WidgetSnapshot {
        guard let book = lastBook() else { return .placeholder }
        let currency = baseCurrency(book)
        let scheduled = decodeScheduled(book)
        let now = Date()

        let netWorth = FinancialReports.netWorthSeries(book, dates: [now], currency: currency)
            .last?.netWorth ?? 0

        let bills = FinancialReports.billReminders(
            book, scheduled: scheduled,
            from: now.addingTimeInterval(-30 * 86_400),
            to: now.addingTimeInterval(60 * 86_400), asOf: now
        ).filter { $0.status != .paid }
        let billsLine: String
        if bills.isEmpty {
            billsLine = String(localized: "No upcoming bills")
        } else {
            let total = bills.reduce(Decimal(0)) { $0 + $1.amount }
            let amount = money(total, currency)
            billsLine = String(localized: "\(bills.count) bills due · \(amount)")
        }

        let alerts = FinancialReports.alerts(book, scheduled: scheduled, currency: currency)
            .prefix(5)
            .map { WidgetSnapshot.Alert(title: $0.title, message: $0.message, severity: $0.severity.rawValue) }

        let name = UserDefaults.standard.string(forKey: "finvestlens.lastBookPath")
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "FinvestLens"

        return WidgetSnapshot(
            bookName: name,
            netWorth: money(netWorth, currency),
            upcomingBills: billsLine,
            alerts: Array(alerts),
            updatedAt: now
        )
    }

}
