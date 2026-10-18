//
//  Book+Business.swift
//  FinvestLens — Engine
//
//  Registering and looking up the business object graph on a ``Book``
//  (`FR-BUS-*`).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public extension Book {

    // MARK: Registration

    @discardableResult
    func addCustomer(_ customer: Customer) -> Customer {
        customers.append(customer); registerCommodity(customer.currency); return customer
    }

    @discardableResult
    func addVendor(_ vendor: Vendor) -> Vendor {
        vendors.append(vendor); registerCommodity(vendor.currency); return vendor
    }

    @discardableResult
    func addEmployee(_ employee: Employee) -> Employee {
        employees.append(employee); registerCommodity(employee.currency); return employee
    }

    @discardableResult
    func addJob(_ job: Job) -> Job { jobs.append(job); return job }

    @discardableResult
    func addInvoice(_ invoice: Invoice) -> Invoice {
        invoices.append(invoice); registerCommodity(invoice.currency); return invoice
    }

    @discardableResult
    func addBillTerm(_ term: BillTerm) -> BillTerm { billTerms.append(term); return term }

    @discardableResult
    func addTaxTable(_ table: TaxTable) -> TaxTable { taxTables.append(table); return table }

    @discardableResult
    func addLot(_ lot: Lot) -> Lot { lots.append(lot); return lot }

    // MARK: Lookup

    func customer(with guid: GncGUID) -> Customer? { customers.first { $0.guid == guid } }
    func vendor(with guid: GncGUID) -> Vendor? { vendors.first { $0.guid == guid } }
    func employee(with guid: GncGUID) -> Employee? { employees.first { $0.guid == guid } }
    func job(with guid: GncGUID) -> Job? { jobs.first { $0.guid == guid } }
    func invoice(with guid: GncGUID) -> Invoice? { invoices.first { $0.guid == guid } }
    func taxTable(with guid: GncGUID) -> TaxTable? { taxTables.first { $0.guid == guid } }
    func billTerm(with guid: GncGUID) -> BillTerm? { billTerms.first { $0.guid == guid } }
    func lot(with guid: GncGUID) -> Lot? { lots.first { $0.guid == guid } }

    /// The lots that live in `account` (its A/R / A/P lots).
    func lots(in account: Account) -> [Lot] {
        lots.filter { $0.account === account }
    }

    /// Invoices addressed to a given party (by owner guid), posted or not.
    func invoices(forOwner ownerGuid: GncGUID) -> [Invoice] {
        invoices.filter { $0.owner.guid == ownerGuid }
    }

    // MARK: Undo

    /// The business layer as it stands now (see ``BusinessTables``).
    func businessTables() -> BusinessTables {
        BusinessTables(
            customers: customers, vendors: vendors, employees: employees, jobs: jobs,
            invoices: invoices, billTerms: billTerms, taxTables: taxTables, lots: lots,
            postings: invoices.map { invoice in
                (invoice, BusinessTables.Posting(
                    datePosted: invoice.datePosted, dueDate: invoice.dueDate,
                    account: invoice.postedAccount, transaction: invoice.postedTransaction,
                    lot: invoice.postedLot))
            },
            lotStates: lots.map { lot in
                (lot, BusinessTables.LotState(splits: lot.splits, isClosed: lot.isClosed,
                                              title: lot.title, notes: lot.notes, kvp: lot.kvp))
            })
    }

    /// Puts the business layer back as `tables` captured it.
    func restore(_ tables: BusinessTables) {
        customers = tables.customers
        vendors = tables.vendors
        employees = tables.employees
        jobs = tables.jobs
        invoices = tables.invoices
        billTerms = tables.billTerms
        taxTables = tables.taxTables
        lots = tables.lots
        for (invoice, posting) in tables.postings {
            invoice.datePosted = posting.datePosted
            invoice.dueDate = posting.dueDate
            invoice.postedAccount = posting.account
            invoice.postedTransaction = posting.transaction
            invoice.postedLot = posting.lot
        }
        for (lot, state) in tables.lotStates {
            lot.restoreSplits(state.splits)
            lot.isClosed = state.isClosed
            lot.title = state.title
            lot.notes = state.notes
            lot.kvp = state.kvp
        }
    }

    // MARK: Default receivable / payable accounts

    /// The first non-placeholder A/R account, the default an invoice posts to.
    var defaultReceivable: Account? {
        accounts.first { $0.type == .receivable && !$0.isPlaceholder }
    }

    /// The first non-placeholder A/P account, the default a bill posts to.
    var defaultPayable: Account? {
        accounts.first { $0.type == .payable && !$0.isPlaceholder }
    }
}

/// The business layer as it stood: which parties, terms, tax tables,
/// documents and lots the book held, and the fields the business operations
/// change in place — an invoice's posting, a lot's members. Taken before an
/// edit to them so it can be undone without a snapshot of the whole book
/// (``Book/businessTables()``, ``Book/restore(_:)``).
///
/// The objects are held, not copied: putting them back restores the very
/// ones that transactions, lots and invoices point at. Fields the business
/// operations never change in place — a party's name and address, an
/// invoice's lines — are not captured; an edit to those needs its own.
public struct BusinessTables {
    struct Posting {
        let datePosted: Date?
        let dueDate: Date?
        let account: Account?
        let transaction: Transaction?
        let lot: Lot?
    }

    struct LotState {
        let splits: [Split]
        let isClosed: Bool
        let title: String
        let notes: String
        let kvp: KvpFrame
    }

    let customers: [Customer]
    let vendors: [Vendor]
    let employees: [Employee]
    let jobs: [Job]
    let invoices: [Invoice]
    let billTerms: [BillTerm]
    let taxTables: [TaxTable]
    let lots: [Lot]
    let postings: [(Invoice, Posting)]
    let lotStates: [(Lot, LotState)]
}
