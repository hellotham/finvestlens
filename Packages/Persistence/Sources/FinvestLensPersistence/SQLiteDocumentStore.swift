//
//  SQLiteDocumentStore.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import FinvestLensEngine

/// The native `.finvestlens` document store — a single SQLite database managed
/// by GRDB (Architecture ADR-2).
///
/// The in-memory ``Book`` is the source of truth; this store snapshots it to
/// SQLite (`write`) and materialises it back (`read`). Snapshot semantics match
/// the document model: load into memory, edit, write back on explicit save.
/// GUIDs and KVP slots are persisted for GnuCash round-trip fidelity.
/// `@unchecked Sendable` so a staged save can carry the store to a background
/// thread (``FinvestLensDocument/commitStaged(_:progress:)``): the connection
/// is a GRDB `DatabaseQueue`, which serialises every access, and the only
/// mutable state — ``changeCounter`` and ``lastLoadWarnings`` — is touched
/// inside the queue's write closure or on the loading actor before any save
/// can exist. Two saves never overlap: the document holds a lock around them.
public final class SQLiteDocumentStore: @unchecked Sendable {

    private let dbQueue: DatabaseQueue

    /// The current change counter, bumped on every ``write(_:)``. Used by the
    /// document layer for conflict detection on write-back (`FR-DAT-08`).
    public private(set) var changeCounter: Int64 = 0

    /// Opens (creating if needed) a store at `path` and migrates its schema.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.requireOwnSchema(dbQueue)
        try Self.migrator.migrate(dbQueue)
        changeCounter = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'changeCounter'")
                .flatMap { $0 } ?? 0
        }
    }

    /// Read-only access for tools (the `finlens` CLI, ADR-L2): the SQLite
    /// connection refuses every write, no migration runs, and the caller
    /// never takes the advisory lock — safe against a book the app has open.
    /// Fails if the on-disk schema is newer than expected only at `read()`
    /// time, like any read of an incompatible file.
    public init(readOnlyPath path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try Self.requireOwnSchema(dbQueue)
        changeCounter = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'changeCounter'")
                .flatMap { $0 } ?? 0
        }
    }

    // MARK: Schema

    /// Refuses a database populated with someone else's tables — notably a
    /// GnuCash SQLite-backend book, which `migrate` would otherwise graft our
    /// schema onto and then read back as an empty book. A database with no
    /// tables at all (empty file) is ours to migrate.
    private static func requireOwnSchema(_ dbQueue: DatabaseQueue) throws {
        let tables = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        guard !tables.isEmpty, !tables.contains("meta") else { return }
        let looksLikeGnuCash = tables.contains("gnclock")
            || (tables.contains("splits") && tables.contains("slots"))
        throw FinvestLensDocument.DocumentError.notAFinvestLensBook(
            looksLikeGnuCash ? .gnuCashSQLite : .unrecognized)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
            try db.create(table: "commodity") { t in
                t.column("namespace", .text).notNull()
                t.column("mnemonic", .text).notNull()
                t.column("fullName", .text).notNull()
                t.column("smallestFraction", .integer).notNull()
                t.column("roundingMode", .text).notNull()
                t.primaryKey(["namespace", "mnemonic"])
            }
            try db.create(table: "account") { t in
                t.primaryKey("guid", .text)
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("code", .text).notNull().defaults(to: "")
                t.column("accountDescription", .text).notNull().defaults(to: "")
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("commodityNamespace", .text).notNull()
                t.column("commodityMnemonic", .text).notNull()
                t.column("placeholder", .boolean).notNull().defaults(to: false)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("parentGuid", .text)
                t.column("kvp", .text)
            }
            try db.create(table: "txn") { t in
                t.primaryKey("guid", .text)
                t.column("currencyNamespace", .text).notNull()
                t.column("currencyMnemonic", .text).notNull()
                t.column("datePosted", .datetime).notNull()
                t.column("dateEntered", .datetime).notNull()
                t.column("num", .text).notNull().defaults(to: "")
                t.column("transactionDescription", .text).notNull().defaults(to: "")
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("kvp", .text)
            }
            try db.create(table: "split") { t in
                t.primaryKey("guid", .text)
                t.column("txnGuid", .text).notNull()
                    .references("txn", column: "guid", onDelete: .cascade)
                t.column("accountGuid", .text)
                t.column("value", .text).notNull()
                t.column("quantity", .text).notNull()
                t.column("reconcileState", .text).notNull()
                t.column("reconcileDate", .datetime)
                t.column("memo", .text).notNull().defaults(to: "")
                t.column("action", .text).notNull().defaults(to: "")
                t.column("kvp", .text)
            }
            try db.create(index: "split_by_account", on: "split", columns: ["accountGuid"])
            try db.create(index: "split_by_txn", on: "split", columns: ["txnGuid"])
        }
        migrator.registerMigration("v2_prices") { db in
            try db.create(table: "price") { t in
                t.primaryKey("guid", .text)
                t.column("commodityNamespace", .text).notNull()
                t.column("commodityMnemonic", .text).notNull()
                t.column("currencyNamespace", .text).notNull()
                t.column("currencyMnemonic", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("value", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "")
                t.column("type", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v2-commodity-fidelity") { db in
            try db.alter(table: "commodity") { t in
                t.add(column: "exchangeCode", .text)
                t.add(column: "getQuotes", .boolean).notNull().defaults(to: false)
                t.add(column: "quoteSource", .text)
                t.add(column: "quoteTimezone", .text)
                t.add(column: "kvp", .text)
            }
        }
        migrator.registerMigration("v3_business") { db in
            try db.create(table: "billterm") { t in
                t.primaryKey("guid", .text)
                t.column("name", .text).notNull()
                t.column("termDescription", .text).notNull().defaults(to: "")
                t.column("kind", .text).notNull()
                t.column("dueDays", .integer).notNull().defaults(to: 0)
                t.column("discountDays", .integer).notNull().defaults(to: 0)
                t.column("discountPercent", .text).notNull().defaults(to: "0")
                t.column("active", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "taxtable") { t in
                t.primaryKey("guid", .text)
                t.column("name", .text).notNull()
                t.column("active", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "taxtable_entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taxtableGuid", .text).notNull()
                    .references("taxtable", column: "guid", onDelete: .cascade)
                t.column("accountGuid", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("amount", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            // Customers, vendors, employees share most columns; one table each.
            for owner in ["customer", "vendor"] {
                try db.create(table: owner) { t in
                    t.primaryKey("guid", .text)
                    t.column("id", .text).notNull().defaults(to: "")
                    t.column("name", .text).notNull()
                    t.column("address", .text)         // JSON
                    t.column("notes", .text).notNull().defaults(to: "")
                    t.column("active", .boolean).notNull().defaults(to: true)
                    t.column("currencyNamespace", .text).notNull()
                    t.column("currencyMnemonic", .text).notNull()
                    t.column("termsGuid", .text)
                    t.column("taxTableGuid", .text)
                    t.column("taxTableOverride", .boolean).notNull().defaults(to: false)
                    t.column("taxIncluded", .boolean).notNull().defaults(to: false)
                    t.column("discountPercent", .text).notNull().defaults(to: "0")
                    t.column("creditLimit", .text).notNull().defaults(to: "0")
                }
            }
            try db.create(table: "employee") { t in
                t.primaryKey("guid", .text)
                t.column("id", .text).notNull().defaults(to: "")
                t.column("username", .text).notNull()
                t.column("address", .text)
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("active", .boolean).notNull().defaults(to: true)
                t.column("currencyNamespace", .text).notNull()
                t.column("currencyMnemonic", .text).notNull()
                t.column("hourlyRate", .text).notNull().defaults(to: "0")
                t.column("creditAccountGuid", .text)
            }
            try db.create(table: "job") { t in
                t.primaryKey("guid", .text)
                t.column("id", .text).notNull().defaults(to: "")
                t.column("name", .text).notNull()
                t.column("reference", .text).notNull().defaults(to: "")
                t.column("active", .boolean).notNull().defaults(to: true)
                t.column("ownerType", .text).notNull()
                t.column("ownerGuid", .text).notNull()
            }
            try db.create(table: "lot") { t in
                t.primaryKey("guid", .text)
                t.column("accountGuid", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("isClosed", .boolean).notNull().defaults(to: false)
                t.column("kvp", .text)
            }
            try db.create(table: "lot_split") { t in
                t.column("lotGuid", .text).notNull()
                    .references("lot", column: "guid", onDelete: .cascade)
                t.column("splitGuid", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "invoice") { t in
                t.primaryKey("guid", .text)
                t.column("id", .text).notNull().defaults(to: "")
                t.column("kind", .text).notNull()
                t.column("ownerType", .text).notNull()
                t.column("ownerGuid", .text).notNull()
                t.column("dateOpened", .datetime).notNull()
                t.column("datePosted", .datetime)
                t.column("dueDate", .datetime)
                t.column("termsGuid", .text)
                t.column("billingID", .text).notNull().defaults(to: "")
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("currencyNamespace", .text).notNull()
                t.column("currencyMnemonic", .text).notNull()
                t.column("postedAccountGuid", .text)
                t.column("postedTxnGuid", .text)
                t.column("postedLotGuid", .text)
                t.column("active", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "invoice_entry") { t in
                t.primaryKey("guid", .text)
                t.column("invoiceGuid", .text).notNull()
                    .references("invoice", column: "guid", onDelete: .cascade)
                t.column("date", .datetime).notNull()
                t.column("entryDescription", .text).notNull().defaults(to: "")
                t.column("action", .text).notNull().defaults(to: "")
                t.column("accountGuid", .text)
                t.column("quantity", .text).notNull().defaults(to: "0")
                t.column("price", .text).notNull().defaults(to: "0")
                t.column("discount", .text).notNull().defaults(to: "0")
                t.column("discountType", .text).notNull()
                t.column("taxable", .boolean).notNull().defaults(to: false)
                t.column("taxIncluded", .boolean).notNull().defaults(to: false)
                t.column("taxTableGuid", .text)
                t.column("position", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v3_billterm_cutoff") { db in
            try db.alter(table: "billterm") { t in
                t.add(column: "cutoff", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v3_entry_disc_how") { db in
            try db.alter(table: "invoice_entry") { t in
                t.add(column: "discountHow", .text).notNull().defaults(to: "pretax")
            }
        }
        migrator.registerMigration("v4_credit_note_entered") { db in
            try db.alter(table: "invoice") { t in
                t.add(column: "isCreditNote", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "invoice_entry") { t in
                t.add(column: "entered", .datetime)
            }
        }
        // Invoice slots this app has no column for — GnuCash's document links
        // and any slot a user added. The importer used to read them and drop
        // them, so they vanished on the next export; now they are carried, and
        // carrying them through a *save* needs somewhere to put them.
        migrator.registerMigration("v5_invoice_kvp") { db in
            try db.alter(table: "invoice") { t in
                t.add(column: "kvp", .text)
            }
        }
        return migrator
    }

    // MARK: Write (snapshot the book)

    /// Replaces the entire database contents with a snapshot of `book` and bumps
    /// the change counter, in a single transaction.
    ///
    /// `progress`, if given, is called as the write runs — the counterpart to
    /// ``read(progress:)``'s ``BookLoadProgress``, so a GnuCash import (which
    /// writes a freshly-parsed book that can run to hundreds of thousands of
    /// rows) can show a bar instead of a frozen window. Called from whatever
    /// thread `write` runs on; the caller hops to the main actor inside it.
    public func write(_ book: Book, progress: (@Sendable (BookLoadProgress) -> Void)? = nil) throws {
        try write(BookSnapshot(book), progress: progress)
    }

    /// The same write from a ``BookSnapshot`` — the half of a save that needs
    /// no `Book`, and so may run on any thread (Performance Review 2, R1). The
    /// SQL and the argument order are exactly those the snapshot was taken
    /// with, so the bytes landing in the file are unchanged.
    public func write(_ snapshot: BookSnapshot,
                      progress: (@Sendable (BookLoadProgress) -> Void)? = nil) throws {
        try dbQueue.write { db in
            for table in ["split", "txn", "account", "commodity", "price",
                          "invoice_entry", "invoice", "lot_split", "lot", "job",
                          "customer", "vendor", "employee",
                          "taxtable_entry", "taxtable", "billterm"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }

            var reporter: WriteReporter?
            if let progress {
                reporter = WriteReporter(transactionCount: snapshot.transactionCount,
                                         splitCount: snapshot.splitCount,
                                         priceCount: snapshot.priceCount, emit: progress)
            }
            reporter?.startingAccounts()

            // Prepared once, reused per row. `db.execute(sql:arguments:)`
            // compiles its SQL on every call — it hands the string to an
            // `SQLStatementCursor`, which builds a fresh `Statement` each time
            // (GRDB 7, `Database+Statements.swift:324`). The rows below are the
            // whole book: on the reference book that is 559 accounts, 46,553
            // transactions, ~100,000 splits and 30,000 prices, so every save
            // was compiling well over a hundred thousand identical statements.
            // The arguments still change per row; only the compilation is
            // hoisted.
            let commodityInsert = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO commodity
                (namespace, mnemonic, fullName, smallestFraction, roundingMode,
                 exchangeCode, getQuotes, quoteSource, quoteTimezone, kvp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for row in snapshot.commodities {
                try commodityInsert.execute(arguments: row.arguments)
            }

            let accountInsert = try db.makeStatement(sql: """
                INSERT INTO account
                (guid, name, type, code, accountDescription, notes,
                 commodityNamespace, commodityMnemonic, placeholder, hidden, parentGuid, kvp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for row in snapshot.accounts {
                try accountInsert.execute(arguments: row.arguments)
            }

            reporter?.startTransactions()
            var splitsWritten = 0
            let txnInsert = try db.makeStatement(sql: """
                INSERT INTO txn
                (guid, currencyNamespace, currencyMnemonic, datePosted, dateEntered,
                 num, transactionDescription, notes, kvp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let splitInsert = try db.makeStatement(sql: """
                INSERT INTO split
                (guid, txnGuid, accountGuid, value, quantity,
                 reconcileState, reconcileDate, memo, action, kvp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for (txnIndex, txn) in snapshot.transactions.enumerated() {
                try txnInsert.execute(arguments: txn.values.arguments)
                for split in txn.splits {
                    try splitInsert.execute(arguments: split.arguments)
                }
                splitsWritten += txn.splits.count
                reporter?.builtTransactions(txnIndex + 1, splitsCompleted: splitsWritten)
            }

            reporter?.startPrices()
            let priceInsert = try db.makeStatement(sql: """
                INSERT INTO price
                (guid, commodityNamespace, commodityMnemonic, currencyNamespace, currencyMnemonic,
                 date, value, source, type)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for (priceIndex, row) in snapshot.prices.enumerated() {
                try priceInsert.execute(arguments: row.arguments)
                reporter?.builtPrices(priceIndex + 1)
            }

            try Self.writeBusiness(snapshot, into: db)

            changeCounter += 1
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('changeCounter', ?)",
                           arguments: [changeCounter])
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('bookGuid', ?)",
                           arguments: [snapshot.bookGuid])
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('bookKvp', ?)",
                           arguments: [snapshot.bookKvp])
            reporter?.finished()
        }
    }

    // MARK: Read (materialise the book)

    /// Reconstructs the in-memory ``Book`` from the database.
    ///
    /// `progress`, if given, is called as the load runs — see ``BookLoadProgress``
    /// for the stage weights and why they are what they are. It is called from
    /// whatever thread `read` runs on (in the app, the `DocumentLoader` actor),
    /// so it must be safe to call from anywhere; the app hops to the main actor
    /// inside it.
    ///
    /// Reporting is throttled to whole percents. Calling out per row would mean
    /// ~250,000 hops for a bar with 100 visible states, and the reporting would
    /// cost more than the work it reports on.
    /// What the last `read` had to default — nil before any read.
    public private(set) var lastLoadWarnings: LoadWarnings?

    public func read(progress: (@Sendable (BookLoadProgress) -> Void)? = nil) throws -> Book {
        let warnings = LoadWarnings()
        defer { lastLoadWarnings = warnings }
        return try LoadWarnings.$current.withValue(warnings) {
        try dbQueue.read { db in
            // Sizing the bar needs the row counts up front, which costs ~0.19s
            // on this book — 3% of a debug load. Skipped entirely when nobody is
            // watching, so an unobserved read (tests, import, revert) pays
            // nothing for a bar that is not on screen.
            var reporter: LoadReporter?
            if let progress {
                reporter = try LoadReporter(db: db, emit: progress)
            }

            reporter?.startingAccounts()

            // Commodities, keyed for lookup.
            var commodityByKey: [String: Commodity] = [:]
            var commodities: [Commodity] = []
            for row in try Row.fetchAll(db, sql: "SELECT * FROM commodity") {
                let commodity = Commodity(
                    namespace: Serialize.parseNamespace(row["namespace"]),
                    mnemonic: row["mnemonic"],
                    fullName: row["fullName"],
                    smallestFraction: row["smallestFraction"],
                    roundingMode: MoneyRoundingMode(rawValue: row["roundingMode"]) ?? .plain,
                    exchangeCode: row["exchangeCode"],
                    getQuotes: row["getQuotes"] ?? false,
                    quoteSource: row["quoteSource"],
                    quoteTimezone: row["quoteTimezone"],
                    kvp: Serialize.parseKvp(row["kvp"])
                )
                commodities.append(commodity)
                commodityByKey[Serialize.commodityKey(commodity)] = commodity
            }
            func commodity(_ namespace: String, _ mnemonic: String) -> Commodity {
                commodityByKey["\(namespace)|\(mnemonic)"]
                    ?? Commodity(namespace: Serialize.parseNamespace(namespace),
                                 mnemonic: mnemonic, fullName: mnemonic, smallestFraction: 100)
            }

            // Accounts.
            var accountsByGUID: [GncGUID: Account] = [:]
            var parentByGUID: [GncGUID: GncGUID] = [:]
            var order: [GncGUID] = []
            var root: Account?
            for row in try Row.fetchAll(db, sql: "SELECT * FROM account") {
                // A corrupt GUID must not vanish the whole account (and dangle
                // every split pointing at it) — mint a counted random identity
                // so the row survives, like the split-level policy.
                let guid = Serialize.parseGUID(row["guid"])
                let account = Account(
                    guid: guid,
                    name: row["name"],
                    type: AccountType(rawValue: row["type"]) ?? .asset,
                    commodity: commodity(row["commodityNamespace"], row["commodityMnemonic"]),
                    code: row["code"],
                    description: row["accountDescription"],
                    notes: row["notes"],
                    isPlaceholder: row["placeholder"],
                    isHidden: row["hidden"],
                    kvp: Serialize.parseKvp(row["kvp"])
                )
                accountsByGUID[guid] = account
                order.append(guid)
                if account.type == .root {
                    root = account
                } else if let parentHex: String = row["parentGuid"], let parent = GncGUID(hex: parentHex) {
                    parentByGUID[guid] = parent
                }
            }

            let rootAccount = root ?? Account(name: "Root Account", type: .root, commodity: .aud)
            let bookGuid = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'bookGuid'")
                .flatMap { $0 }.flatMap { GncGUID(hex: $0) } ?? {
                    LoadWarnings.current?.note(\.guids)
                    return .random()
                }()
            let book = Book(guid: bookGuid, rootAccount: rootAccount)
            for commodity in commodities { book.registerCommodity(commodity) }
            if let bookKvp = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'bookKvp'")
                .flatMap({ $0 }) {
                book.kvp = Serialize.parseKvp(bookKvp)
            }

            for guid in order {
                guard let account = accountsByGUID[guid], account.type != .root else { continue }
                if let parent = parentByGUID[guid], let parentAccount = accountsByGUID[parent] {
                    parentAccount.addChild(account)
                } else {
                    rootAccount.addChild(account)
                }
            }

            // Transactions and their splits.
            var splitsByGUID: [GncGUID: Split] = [:]
            var splitsByTxn: [String: [Row]] = [:]
            var groupedSplits = 0
            for row in try Row.fetchAll(db, sql: "SELECT * FROM split") {
                splitsByTxn[row["txnGuid"], default: []].append(row)
                groupedSplits += 1
                reporter?.groupedSplits(groupedSplits)
            }

            reporter?.startTransactions()
            var builtTxns = 0
            for row in try Row.fetchAll(db, sql: "SELECT * FROM txn") {
                // Never silently drop a transaction (and all its splits) over a
                // corrupt GUID — mint a counted random identity; money survives.
                let guid = Serialize.parseGUID(row["guid"])
                let txn = Transaction(
                    guid: guid,
                    currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                    datePosted: row["datePosted"],
                    dateEntered: row["dateEntered"],
                    number: row["num"],
                    description: row["transactionDescription"],
                    notes: row["notes"],
                    kvp: Serialize.parseKvp(row["kvp"])
                )
                for splitRow in splitsByTxn[row["guid"]] ?? [] {
                    let split = Split(
                        guid: Serialize.parseGUID(splitRow["guid"]),
                        account: (splitRow["accountGuid"] as String?).flatMap { GncGUID(hex: $0) }
                            .flatMap { accountsByGUID[$0] },
                        value: Serialize.parseDecimal(splitRow["value"]),
                        quantity: Serialize.parseDecimal(splitRow["quantity"]),
                        reconcileState: ReconcileState(rawValue: splitRow["reconcileState"]) ?? .notReconciled,
                        reconcileDate: splitRow["reconcileDate"],
                        memo: splitRow["memo"],
                        action: splitRow["action"],
                        kvp: Serialize.parseKvp(splitRow["kvp"])
                    )
                    txn.addSplit(split)
                    splitsByGUID[split.guid] = split
                }
                book.addTransaction(txn)
                builtTxns += 1
                reporter?.builtTransactions(builtTxns)
            }

            reporter?.startPrices()
            var builtPrices = 0
            // Prices.
            for row in try Row.fetchAll(db, sql: "SELECT * FROM price") {
                // Same open-what-you-can policy as accounts/transactions.
                let guid = Serialize.parseGUID(row["guid"])
                book.addPrice(Price(
                    guid: guid,
                    commodity: commodity(row["commodityNamespace"], row["commodityMnemonic"]),
                    currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                    date: row["date"],
                    value: Serialize.parseDecimal(row["value"]),
                    source: row["source"],
                    type: row["type"],
                    // Loading is not creating. Without this the memberwise
                    // initialiser's day-neutral normalisation would restamp
                    // every price on every read — the stored timestamps would
                    // silently change on the next save, with no migration ever
                    // run and nothing to show what moved. It also defeated the
                    // GnuCash importer's own `preservingTime`, since a book
                    // survives only as long as it stays in memory.
                    preservingTime: true
                ))
                builtPrices += 1
                reporter?.builtPrices(builtPrices)
            }

            try Self.readBusiness(into: book, db: db, accounts: accountsByGUID,
                                  splits: splitsByGUID, commodity: commodity)

            reporter?.finished()
            return book
        }
        }
    }
}

extension SQLiteDocumentStore {
    /// Test-only: damage one split's value and GUID the way external tools
    /// might, so the load-warning counters can be exercised.
    public func corruptForTesting() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE split SET value = 'garbage', guid = 'nothex' "
                + "WHERE rowid = (SELECT MIN(rowid) FROM split)")
        }
    }
}
