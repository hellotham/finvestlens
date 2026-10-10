//
//  BookSnapshot.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import FinvestLensEngine

/// Everything ``SQLiteDocumentStore/write(_:progress:)`` persists, as plain
/// database values — one row of bound arguments per table row, in exactly the
/// column order the store's INSERT statements expect.
///
/// Taken on the actor that owns the `Book` and immutable thereafter, so the
/// write itself — the expensive half of a save, seconds on a large book — can
/// run on any thread while the book keeps being edited. An edit made after the
/// snapshot is simply not in this save; the document's change token keeps the
/// book dirty for the next one. That is what lets a save leave the main actor
/// without the read-gate the architecture defers (Architecture §10).
public struct BookSnapshot: Sendable {

    typealias Row = [SnapshotValue]

    struct TransactionRow: Sendable {
        let values: Row
        let splits: [Row]
    }

    struct TaxTableRow: Sendable {
        let values: Row
        let entries: [Row]
    }

    struct LotRow: Sendable {
        let values: Row
        let splits: [Row]
    }

    struct InvoiceRow: Sendable {
        let values: Row
        let entries: [Row]
    }

    let commodities: [Row]
    let accounts: [Row]
    let transactions: [TransactionRow]
    let prices: [Row]
    let billTerms: [Row]
    let taxTables: [TaxTableRow]
    let customers: [Row]
    let vendors: [Row]
    let employees: [Row]
    let jobs: [Row]
    let lots: [LotRow]
    let invoices: [InvoiceRow]
    let bookGuid: String
    let bookKvp: String?

    /// Counts for progress reporting — the same weights the write uses.
    public let transactionCount: Int
    public let splitCount: Int
    public let priceCount: Int

    /// Walks `book` once. The argument lists below are the store's INSERT
    /// argument lists, moved here verbatim: the write must stay byte-for-byte
    /// what it was, and the round-trip suites are what hold it to that.
    ///
    /// Only copies happen here. Dates, decimals and kvp frames are carried as
    /// values and formatted by the thread that writes them — formatting them
    /// here was 0.95 s of main-actor time per save on the reference book,
    /// most of what remained after the write itself left the actor.
    public init(_ book: Book) {
        func row(_ values: [SnapshotValue]) -> Row { values }

        commodities = book.commodities.map { commodity in
            row([.v(Serialize.namespace(commodity.namespace)), .v(commodity.mnemonic),
                 .v(commodity.fullName), .v(commodity.smallestFraction), .v(commodity.roundingMode.rawValue),
                 .v(commodity.exchangeCode), .v(commodity.getQuotes),
                 .v(commodity.quoteSource), .v(commodity.quoteTimezone),
                 .kvp(commodity.kvp)])
        }

        accounts = ([book.rootAccount] + book.rootAccount.descendants).map { account in
            row([.v(account.guid.hexString), .v(account.name), .v(account.type.rawValue),
                 .v(account.code), .v(account.accountDescription), .v(account.notes),
                 .v(Serialize.namespace(account.commodity.namespace)), .v(account.commodity.mnemonic),
                 .v(account.isPlaceholder), .v(account.isHidden),
                 .v(account.parent.map { $0.guid.hexString }), .kvp(account.kvp)])
        }

        var splits = 0
        transactions = book.transactions.map { txn in
            let txnGuid = txn.guid.hexString
            splits += txn.splits.count
            return TransactionRow(
                values: row([.v(txnGuid), .v(Serialize.namespace(txn.currency.namespace)),
                             .v(txn.currency.mnemonic), .v(txn.datePosted), .v(txn.dateEntered),
                             .v(txn.number), .v(txn.transactionDescription), .v(txn.notes), .kvp(txn.kvp)]),
                splits: txn.splits.map { split in
                    row([.v(split.guid.hexString), .v(txnGuid), .v(split.account?.guid.hexString),
                         .decimal(split.value), .decimal(split.quantity),
                         .v(split.reconcileState.rawValue), .v(split.reconcileDate),
                         .v(split.memo), .v(split.action), .kvp(split.kvp)])
                })
        }
        transactionCount = book.transactions.count
        splitCount = splits

        prices = book.prices.map { price in
            row([.v(price.guid.hexString),
                 .v(Serialize.namespace(price.commodity.namespace)), .v(price.commodity.mnemonic),
                 .v(Serialize.namespace(price.currency.namespace)), .v(price.currency.mnemonic),
                 .v(price.date), .decimal(price.value), .v(price.source), .v(price.type)])
        }
        priceCount = book.prices.count

        billTerms = book.billTerms.map { term in
            row([.v(term.guid.hexString), .v(term.name), .v(term.termDescription),
                 .v(term.kind.rawValue), .v(term.dueDays), .v(term.discountDays), .v(term.cutoff),
                 .decimal(term.discountPercent), .v(term.active)])
        }
        taxTables = book.taxTables.map { table in
            TaxTableRow(
                values: row([.v(table.guid.hexString), .v(table.name), .v(table.active)]),
                entries: table.entries.enumerated().map { position, entry in
                    row([.v(table.guid.hexString), .v(entry.account.guid.hexString),
                         .v(entry.kind.rawValue), .decimal(entry.amount), .v(position)])
                })
        }
        customers = book.customers.map { customer in
            row([.v(customer.guid.hexString), .v(customer.id), .v(customer.name),
                 .v(SQLiteDocumentStore.encodeAddress(customer.address)), .v(customer.notes), .v(customer.active),
                 .v(Serialize.namespace(customer.currency.namespace)), .v(customer.currency.mnemonic),
                 .v(customer.terms?.guid.hexString), .v(customer.taxTable?.guid.hexString),
                 .v(customer.taxTableOverride), .v(customer.taxIncluded),
                 .decimal(customer.discountPercent),
                 .decimal(customer.creditLimit)])
        }
        vendors = book.vendors.map { vendor in
            row([.v(vendor.guid.hexString), .v(vendor.id), .v(vendor.name),
                 .v(SQLiteDocumentStore.encodeAddress(vendor.address)), .v(vendor.notes), .v(vendor.active),
                 .v(Serialize.namespace(vendor.currency.namespace)), .v(vendor.currency.mnemonic),
                 .v(vendor.terms?.guid.hexString), .v(vendor.taxTable?.guid.hexString),
                 .v(vendor.taxTableOverride), .v(vendor.taxIncluded), .v("0"), .v("0")])
        }
        employees = book.employees.map { employee in
            row([.v(employee.guid.hexString), .v(employee.id), .v(employee.username),
                 .v(SQLiteDocumentStore.encodeAddress(employee.address)), .v(employee.notes), .v(employee.active),
                 .v(Serialize.namespace(employee.currency.namespace)), .v(employee.currency.mnemonic),
                 .decimal(employee.hourlyRate), .v(employee.creditAccount?.guid.hexString)])
        }
        jobs = book.jobs.map { job in
            row([.v(job.guid.hexString), .v(job.id), .v(job.name), .v(job.reference),
                 .v(job.active), .v(job.owner.type.rawValue), .v(job.owner.guid.hexString)])
        }
        lots = book.lots.map { lot in
            LotRow(
                values: row([.v(lot.guid.hexString), .v(lot.account?.guid.hexString), .v(lot.title),
                             .v(lot.notes), .v(lot.isClosed), .kvp(lot.kvp)]),
                splits: lot.splits.enumerated().map { position, split in
                    row([.v(lot.guid.hexString), .v(split.guid.hexString), .v(position)])
                })
        }
        invoices = book.invoices.map { invoice in
            InvoiceRow(
                values: row([.v(invoice.guid.hexString), .v(invoice.id), .v(invoice.kind.rawValue),
                             .v(invoice.isCreditNote),
                             .v(invoice.owner.type.rawValue), .v(invoice.owner.guid.hexString), .v(invoice.dateOpened),
                             .v(invoice.datePosted), .v(invoice.dueDate), .v(invoice.terms?.guid.hexString),
                             .v(invoice.billingID), .v(invoice.notes),
                             .v(Serialize.namespace(invoice.currency.namespace)), .v(invoice.currency.mnemonic),
                             .v(invoice.postedAccount?.guid.hexString), .v(invoice.postedTransaction?.guid.hexString),
                             .v(invoice.postedLot?.guid.hexString), .v(invoice.active),
                             .kvp(invoice.kvp)]),
                entries: invoice.entries.enumerated().map { position, entry in
                    row([.v(entry.guid.hexString), .v(invoice.guid.hexString), .v(entry.date),
                         .v(entry.entered),
                         .v(entry.entryDescription), .v(entry.action), .v(entry.account?.guid.hexString),
                         .decimal(entry.quantity), .decimal(entry.price),
                         .decimal(entry.discount), .v(entry.discountType.rawValue),
                         .v(entry.discountHow.rawValue),
                         .v(entry.taxable), .v(entry.taxIncluded), .v(entry.taxTable?.guid.hexString), .v(position)])
                })
        }

        bookGuid = book.guid.hexString
        bookKvp = Serialize.kvp(book.kvp)
    }
}

/// One bound argument of a snapshot row. Strings, integers and flags are
/// copied as they are; dates, decimals and kvp frames are kept as values and
/// rendered by ``databaseValue`` on the writing thread, which is where that
/// work belongs.
enum SnapshotValue: Sendable {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case decimal(Decimal)
    case kvp(KvpFrame)
    case raw(DatabaseValue)

    /// Any other value the store binds. Dates are deferred; the rest is a copy.
    static func v(_ value: (any DatabaseValueConvertible)?) -> SnapshotValue {
        switch value {
        case nil: return .null
        case let text as String: return .text(text)
        case let flag as Bool: return .bool(flag)
        case let int as Int: return .integer(Int64(int))
        case let int as Int64: return .integer(int)
        case let double as Double: return .real(double)
        case let date as Date: return .date(date)
        case let other?: return .raw(other.databaseValue)
        }
    }

    /// Rendered exactly as the store's own argument lists rendered it: the
    /// same `Serialize` helpers, so the bytes in the file do not change.
    var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .text(let text): return text.databaseValue
        case .integer(let int): return int.databaseValue
        case .real(let double): return double.databaseValue
        case .bool(let flag): return flag.databaseValue
        case .date(let date): return date.databaseValue
        case .decimal(let value): return Serialize.decimal(value).databaseValue
        case .kvp(let frame): return Serialize.kvp(frame)?.databaseValue ?? .null
        case .raw(let value): return value
        }
    }
}

extension Array where Element == SnapshotValue {
    /// The row as GRDB wants it, rendered on the calling thread.
    var arguments: StatementArguments { StatementArguments(map(\.databaseValue)) }
}
