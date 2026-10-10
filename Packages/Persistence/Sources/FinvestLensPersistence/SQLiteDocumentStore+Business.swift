//
//  SQLiteDocumentStore+Business.swift
//  FinvestLens — Persistence
//
//  Snapshotting the business object graph (`FR-BUS-*`) to/from SQLite. GUIDs
//  carry every cross-reference so the graph rebuilds by identity on read.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import FinvestLensEngine

extension SQLiteDocumentStore {

    // MARK: - Write

    static func writeBusiness(_ snapshot: BookSnapshot, into db: Database) throws {
        let termInsert = try db.makeStatement(sql: """
            INSERT INTO billterm (guid, name, termDescription, kind, dueDays,
                discountDays, cutoff, discountPercent, active) VALUES (?,?,?,?,?,?,?,?,?)
            """)
        for row in snapshot.billTerms {
            try termInsert.execute(arguments: row.arguments)
        }
        let taxTableInsert = try db.makeStatement(
            sql: "INSERT INTO taxtable (guid, name, active) VALUES (?,?,?)")
        let taxEntryInsert = try db.makeStatement(sql: """
            INSERT INTO taxtable_entry (taxtableGuid, accountGuid, kind, amount, position)
            VALUES (?,?,?,?,?)
            """)
        for table in snapshot.taxTables {
            try taxTableInsert.execute(arguments: table.values.arguments)
            for entry in table.entries {
                try taxEntryInsert.execute(arguments: entry.arguments)
            }
        }
        let customerInsert = try db.makeStatement(sql: """
            INSERT INTO customer (guid, id, name, address, notes, active,
                currencyNamespace, currencyMnemonic, termsGuid, taxTableGuid,
                taxTableOverride, taxIncluded, discountPercent, creditLimit)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        for row in snapshot.customers {
            try customerInsert.execute(arguments: row.arguments)
        }
        let vendorInsert = try db.makeStatement(sql: """
            INSERT INTO vendor (guid, id, name, address, notes, active,
                currencyNamespace, currencyMnemonic, termsGuid, taxTableGuid,
                taxTableOverride, taxIncluded, discountPercent, creditLimit)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        for row in snapshot.vendors {
            try vendorInsert.execute(arguments: row.arguments)
        }
        let employeeInsert = try db.makeStatement(sql: """
            INSERT INTO employee (guid, id, username, address, notes, active,
                currencyNamespace, currencyMnemonic, hourlyRate, creditAccountGuid)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """)
        for row in snapshot.employees {
            try employeeInsert.execute(arguments: row.arguments)
        }
        let jobInsert = try db.makeStatement(sql: """
            INSERT INTO job (guid, id, name, reference, active, ownerType, ownerGuid)
            VALUES (?,?,?,?,?,?,?)
            """)
        for row in snapshot.jobs {
            try jobInsert.execute(arguments: row.arguments)
        }
        let lotInsert = try db.makeStatement(sql: """
            INSERT INTO lot (guid, accountGuid, title, notes, isClosed, kvp)
            VALUES (?,?,?,?,?,?)
            """)
        let lotSplitInsert = try db.makeStatement(
            sql: "INSERT INTO lot_split (lotGuid, splitGuid, position) VALUES (?,?,?)")
        for lot in snapshot.lots {
            try lotInsert.execute(arguments: lot.values.arguments)
            for split in lot.splits {
                try lotSplitInsert.execute(arguments: split.arguments)
            }
        }
        let invoiceInsert = try db.makeStatement(sql: """
            INSERT INTO invoice (guid, id, kind, isCreditNote, ownerType, ownerGuid, dateOpened,
                datePosted, dueDate, termsGuid, billingID, notes, currencyNamespace,
                currencyMnemonic, postedAccountGuid, postedTxnGuid, postedLotGuid, active, kvp)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        let entryInsert = try db.makeStatement(sql: """
            INSERT INTO invoice_entry (guid, invoiceGuid, date, entered, entryDescription,
                action, accountGuid, quantity, price, discount, discountType,
                discountHow, taxable, taxIncluded, taxTableGuid, position)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        for invoice in snapshot.invoices {
            try invoiceInsert.execute(arguments: invoice.values.arguments)
            for entry in invoice.entries {
                try entryInsert.execute(arguments: entry.arguments)
            }
        }
    }

    // MARK: - Read

    static func readBusiness(into book: Book, db: Database,
                             accounts: [GncGUID: Account], splits: [GncGUID: Split],
                             commodity: (String, String) -> Commodity) throws {
        func acct(_ hex: String?) -> Account? { hex.flatMap { GncGUID(hex: $0) }.flatMap { accounts[$0] } }

        /// Rows of `table`, or none when the table is not in this schema.
        ///
        /// A read-only connection runs no migration (see
        /// ``SQLiteDocumentStore/init(readOnlyPath:)``), and the app migrates
        /// only its working copy — so the shared file keeps its old schema
        /// until the first save. `finlens` opening a book written by an earlier
        /// version therefore met `no such table: billterm` after loading every
        /// account, transaction and price, and failed the whole command.
        func rows(_ table: String, orderedBy order: String? = nil) throws -> [Row] {
            guard try db.tableExists(table) else { return [] }
            let clause = order.map { " ORDER BY \($0)" } ?? ""
            return try Row.fetchAll(db, sql: "SELECT * FROM \(table)\(clause)")
        }

        var termsByGUID: [GncGUID: BillTerm] = [:]
        for row in try rows("billterm") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let term = BillTerm(guid: guid, name: row["name"], termDescription: row["termDescription"],
                kind: BillTerm.Kind(rawValue: row["kind"]) ?? .days, dueDays: row["dueDays"],
                // `cutoff` arrived in a later migration than the table itself,
                // and `BillTerm.cutoff` is non-optional — GRDB's non-optional
                // subscript traps on a missing column, so a book on the schema
                // window between the two crashed rather than degraded.
                discountDays: row["discountDays"], cutoff: (row["cutoff"] as Int?) ?? 0,
                discountPercent: Serialize.parseDecimal(row["discountPercent"]), active: row["active"])
            termsByGUID[guid] = term
            book.addBillTerm(term)
        }

        var tablesByGUID: [GncGUID: TaxTable] = [:]
        var entryRows: [String: [Row]] = [:]
        for row in try rows("taxtable_entry", orderedBy: "position") {
            entryRows[row["taxtableGuid"], default: []].append(row)
        }
        for row in try rows("taxtable") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let entries: [TaxTableEntry] = (entryRows[row["guid"]] ?? []).compactMap { e in
                guard let account = acct(e["accountGuid"]) else { return nil }
                return TaxTableEntry(account: account,
                    kind: TaxTableEntry.Kind(rawValue: e["kind"]) ?? .percentage,
                    amount: Serialize.parseDecimal(e["amount"]))
            }
            let table = TaxTable(guid: guid, name: row["name"], entries: entries, active: row["active"])
            tablesByGUID[guid] = table
            book.addTaxTable(table)
        }
        func table(_ hex: String?) -> TaxTable? { hex.flatMap { GncGUID(hex: $0) }.flatMap { tablesByGUID[$0] } }
        func term(_ hex: String?) -> BillTerm? { hex.flatMap { GncGUID(hex: $0) }.flatMap { termsByGUID[$0] } }

        var customersByGUID: [GncGUID: Customer] = [:]
        for row in try rows("customer") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let customer = Customer(guid: guid, id: row["id"], name: row["name"],
                address: decodeAddress(row["address"]), notes: row["notes"], active: row["active"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                terms: term(row["termsGuid"]), taxTable: table(row["taxTableGuid"]),
                taxTableOverride: row["taxTableOverride"], taxIncluded: row["taxIncluded"],
                discountPercent: Serialize.parseDecimal(row["discountPercent"]),
                creditLimit: Serialize.parseDecimal(row["creditLimit"]))
            customersByGUID[guid] = customer
            book.addCustomer(customer)
        }
        var vendorsByGUID: [GncGUID: Vendor] = [:]
        for row in try rows("vendor") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let vendor = Vendor(guid: guid, id: row["id"], name: row["name"],
                address: decodeAddress(row["address"]), notes: row["notes"], active: row["active"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                terms: term(row["termsGuid"]), taxTable: table(row["taxTableGuid"]),
                taxTableOverride: row["taxTableOverride"], taxIncluded: row["taxIncluded"])
            vendorsByGUID[guid] = vendor
            book.addVendor(vendor)
        }
        var employeesByGUID: [GncGUID: Employee] = [:]
        for row in try rows("employee") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let employee = Employee(guid: guid, id: row["id"], username: row["username"],
                address: decodeAddress(row["address"]), notes: row["notes"], active: row["active"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                hourlyRate: Serialize.parseDecimal(row["hourlyRate"]),
                creditAccount: acct(row["creditAccountGuid"]))
            employeesByGUID[guid] = employee
            book.addEmployee(employee)
        }
        // Jobs: resolve owner (customer or vendor).
        var jobsByGUID: [GncGUID: Job] = [:]
        for row in try rows("job") {
            guard let guid = GncGUID(hex: row["guid"]),
                  let ownerGuid = GncGUID(hex: row["ownerGuid"]),
                  let owner = owner(type: row["ownerType"], guid: ownerGuid,
                                    customersByGUID, vendorsByGUID, employeesByGUID, [:])
            else { continue }
            let job = Job(guid: guid, id: row["id"], name: row["name"],
                          reference: row["reference"], active: row["active"], owner: owner)
            jobsByGUID[guid] = job
            book.addJob(job)
        }

        // Lots, with their split membership.
        var lotSplitRows: [String: [Row]] = [:]
        for row in try rows("lot_split", orderedBy: "position") {
            lotSplitRows[row["lotGuid"], default: []].append(row)
        }
        var lotsByGUID: [GncGUID: Lot] = [:]
        for row in try rows("lot") {
            guard let guid = GncGUID(hex: row["guid"]) else { continue }
            let lot = Lot(guid: guid, account: acct(row["accountGuid"]), title: row["title"],
                          notes: row["notes"], isClosed: row["isClosed"],
                          kvp: Serialize.parseKvp(row["kvp"]))
            for sr in lotSplitRows[row["guid"]] ?? [] {
                if let sg = GncGUID(hex: sr["splitGuid"]), let split = splits[sg] { lot.add(split) }
            }
            lotsByGUID[guid] = lot
            book.addLot(lot)
        }

        // Invoices and entries.
        var invEntryRows: [String: [Row]] = [:]
        for row in try rows("invoice_entry", orderedBy: "position") {
            invEntryRows[row["invoiceGuid"], default: []].append(row)
        }
        let txnsByGUID = Dictionary(book.transactions.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
        for row in try rows("invoice") {
            guard let guid = GncGUID(hex: row["guid"]),
                  let ownerGuid = GncGUID(hex: row["ownerGuid"]),
                  let owner = owner(type: row["ownerType"], guid: ownerGuid,
                                    customersByGUID, vendorsByGUID, employeesByGUID, jobsByGUID)
            else { continue }
            let invoice = Invoice(guid: guid, id: row["id"],
                kind: InvoiceKind(rawValue: row["kind"]) ?? .invoice,
                isCreditNote: (row["isCreditNote"] as Bool?) ?? false, owner: owner,
                dateOpened: row["dateOpened"], datePosted: row["datePosted"], dueDate: row["dueDate"],
                terms: term(row["termsGuid"]), billingID: row["billingID"], notes: row["notes"],
                currency: commodity(row["currencyNamespace"], row["currencyMnemonic"]),
                active: row["active"],
                kvp: Serialize.parseKvp(row["kvp"]))
            invoice.entries = (invEntryRows[row["guid"]] ?? []).map { e in
                InvoiceEntry(guid: Serialize.parseGUID(e["guid"]), date: e["date"],
                    entered: e["entered"],
                    entryDescription: e["entryDescription"], action: e["action"],
                    account: acct(e["accountGuid"]), quantity: Serialize.parseDecimal(e["quantity"]),
                    price: Serialize.parseDecimal(e["price"]),
                    discount: Serialize.parseDecimal(e["discount"]),
                    discountType: DiscountType(rawValue: e["discountType"]) ?? .percentage,
                    discountHow: DiscountHow(rawValue: e["discountHow"] ?? "pretax") ?? .pretax,
                    taxable: e["taxable"], taxIncluded: e["taxIncluded"], taxTable: table(e["taxTableGuid"]))
            }
            invoice.postedAccount = acct(row["postedAccountGuid"])
            invoice.postedTransaction = (row["postedTxnGuid"] as String?).flatMap { GncGUID(hex: $0) }
                .flatMap { txnsByGUID[$0] }
            invoice.postedLot = (row["postedLotGuid"] as String?).flatMap { GncGUID(hex: $0) }
                .flatMap { lotsByGUID[$0] }
            book.addInvoice(invoice)
        }
    }

    private static func owner(type: String, guid: GncGUID,
                              _ customers: [GncGUID: Customer], _ vendors: [GncGUID: Vendor],
                              _ employees: [GncGUID: Employee], _ jobs: [GncGUID: Job]) -> BusinessOwner? {
        switch OwnerType(rawValue: type) {
        case .customer: customers[guid].map { .customer($0) }
        case .vendor: vendors[guid].map { .vendor($0) }
        case .employee: employees[guid].map { .employee($0) }
        case .job: jobs[guid].map { .job($0) }
        case nil: nil
        }
    }

    // MARK: - Address (JSON)

    static func encodeAddress(_ address: BusinessAddress) -> String? {
        (try? JSONEncoder().encode(address)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private static func decodeAddress(_ text: String?) -> BusinessAddress {
        guard let text else { return BusinessAddress() }
        guard let data = text.data(using: .utf8),
              let address = try? JSONDecoder().decode(BusinessAddress.self, from: data)
        else {
            persistenceLog.warning("Unparseable business address discarded")
            LoadWarnings.current?.note(\.addresses)
            return BusinessAddress()
        }
        return address
    }
}
