//
//  BookReplicaTests.swift
//  FinvestLens — Interchange
//
//  `Book.replica()` hands a copy of the book to another thread on the
//  strength of one claim the compiler cannot check: nothing in the copy is
//  shared with the original. These tests check it, object by object, and
//  check that the copy is the whole book — its GnuCash export is the
//  original's, byte for byte, and it stays so while the original is edited.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Book replica")
struct BookReplicaTests {

    /// Every kind of object a book holds, with references between them: a
    /// nested tree, a security with prices, slots on everything, a posted and
    /// part-paid invoice, a posted bill from a job's vendor, an employee's
    /// voucher, terms, a tax table, and the lots posting made.
    private func makeBook() throws -> Book {
        let book = Book(baseCurrency: .aud)
        let assets = book.addAccount(Account(name: "Assets", type: .asset, commodity: .aud, isPlaceholder: true))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud, code: "1010"), under: assets)
        bank.color = "rgb(144,144,238)"
        let shares = Commodity(namespace: .security("ASX"), mnemonic: "VAS", fullName: "Vanguard Australian Shares",
                               smallestFraction: 10_000)
        let broker = book.addAccount(Account(name: "Broker", type: .asset, commodity: .aud), under: assets)
        let vas = book.addAccount(Account(name: "VAS", type: .stock, commodity: shares), under: broker)
        let ar = book.addAccount(Account(name: "Accounts Receivable", type: .receivable, commodity: .aud))
        let ap = book.addAccount(Account(name: "Accounts Payable", type: .payable, commodity: .aud))
        let card = book.addAccount(Account(name: "Card", type: .credit, commodity: .aud))
        let sales = book.addAccount(Account(name: "Sales", type: .income, commodity: .aud))
        let supplies = book.addAccount(Account(name: "Supplies", type: .expense, commodity: .aud, isHidden: true))
        let gst = book.addAccount(Account(name: "GST Collected", type: .liability, commodity: .aud))

        book.addPrice(Price(commodity: shares, currency: .aud, date: Date(timeIntervalSince1970: 1_690_000_000),
                            value: dec("88.12"), source: "user:price", type: "last"))
        book.addPrice(Price(commodity: shares, currency: .aud, date: Date(timeIntervalSince1970: 1_700_000_000),
                            value: dec("91.40"), source: "Finance::Quote", type: "close"))

        let buy = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_690_000_000),
                              number: "17", description: "Buy VAS", notes: "First parcel")
        buy.tags = ["investing", "core"]
        buy.statementDate = Date(timeIntervalSince1970: 1_690_172_800)
        buy.addSplit(Split(account: vas, value: dec("881.20"), quantity: dec("10"),
                           reconcileState: .reconciled, reconcileDate: Date(timeIntervalSince1970: 1_691_000_000),
                           memo: "10 units", action: "Buy"))
        buy.addSplit(Split(account: bank, value: dec("-881.20"), memo: "BPAY 123", kvp: {
            var frame = KvpFrame(); frame["online_id"] = .string("FITID-1"); return frame }()))
        book.addTransaction(buy)

        let net30 = book.addBillTerm(BillTerm(name: "Net 30", kind: .days, dueDays: 30))
        let proximo = book.addBillTerm(BillTerm(name: "20th next month", kind: .proximo, dueDays: 20,
                                                cutoff: -3, discountPercent: dec("2.5")))
        let table = book.addTaxTable(TaxTable(name: "GST", entries: [
            TaxTableEntry(account: gst, kind: .percentage, amount: dec("10"))]))
        let customer = book.addCustomer(Customer(id: "000001", name: "Acme Pty Ltd",
            address: BusinessAddress(name: "Acme Pty Ltd", line1: "1 Test St", email: "ap@acme.test"),
            currency: .aud, terms: net30, taxTable: table, taxTableOverride: true,
            discountPercent: dec("5"), creditLimit: dec("10000")))
        let vendor = book.addVendor(Vendor(id: "V1", name: "Supplies Co", currency: .aud, terms: proximo))
        let employee = book.addEmployee(Employee(id: "E1", username: "sam", currency: .aud,
                                                 hourlyRate: dec("45"), creditAccount: card))
        let job = book.addJob(Job(id: "J1", name: "Fit-out", reference: "PO-9", owner: .vendor(vendor)))

        let invoice = book.addInvoice(Invoice(id: "INV-1", kind: .invoice, owner: .customer(customer),
            terms: net30, billingID: "B-1", notes: "Thanks", currency: .aud, entries: [
                InvoiceEntry(date: Date(timeIntervalSince1970: 1_699_000_000),
                             entered: Date(timeIntervalSince1970: 1_699_000_123),
                             entryDescription: "Widget", action: "Hours", account: sales,
                             quantity: dec("2"), price: dec("50"), discount: dec("10"),
                             taxable: true, taxTable: table)]))
        try book.postInvoice(invoice, to: ar, postDate: Date(timeIntervalSince1970: 1_700_000_000))
        try book.processPayment(owner: .customer(customer), amount: dec("60"),
                                from: bank, to: ar, on: Date(timeIntervalSince1970: 1_700_500_000))

        let bill = book.addInvoice(Invoice(id: "BILL-1", kind: .bill, owner: .job(job), currency: .aud,
            entries: [InvoiceEntry(account: supplies, quantity: dec("1"), price: dec("200"))]))
        try book.postInvoice(bill, to: ap, postDate: Date(timeIntervalSince1970: 1_700_100_000))

        let voucher = book.addInvoice(Invoice(id: "EXP-1", kind: .voucher, owner: .employee(employee),
            currency: .aud, entries: [InvoiceEntry(account: supplies, quantity: dec("3"), price: dec("12.5"))]))
        _ = voucher

        book.kvp["finvestlens/budgets"] = .string("[]")
        return book
    }

    /// Every object of a reference type in the book, by identity.
    private func objects(in book: Book) -> Set<ObjectIdentifier> {
        var all = Set<ObjectIdentifier>()
        all.insert(ObjectIdentifier(book))
        all.insert(ObjectIdentifier(book.rootAccount))
        for account in book.accounts { all.insert(ObjectIdentifier(account)) }
        for transaction in book.transactions {
            all.insert(ObjectIdentifier(transaction))
            for split in transaction.splits { all.insert(ObjectIdentifier(split)) }
        }
        for lot in book.lots { all.insert(ObjectIdentifier(lot)) }
        for term in book.billTerms { all.insert(ObjectIdentifier(term)) }
        for table in book.taxTables { all.insert(ObjectIdentifier(table)) }
        for customer in book.customers { all.insert(ObjectIdentifier(customer)) }
        for vendor in book.vendors { all.insert(ObjectIdentifier(vendor)) }
        for employee in book.employees { all.insert(ObjectIdentifier(employee)) }
        for job in book.jobs { all.insert(ObjectIdentifier(job)) }
        for invoice in book.invoices {
            all.insert(ObjectIdentifier(invoice))
            for entry in invoice.entries { all.insert(ObjectIdentifier(entry)) }
        }
        return all
    }

    /// Every object the book's objects point at, by identity.
    private func referenced(from book: Book) -> [ObjectIdentifier] {
        var refs: [ObjectIdentifier] = []
        func add(_ object: AnyObject?) { if let object { refs.append(ObjectIdentifier(object)) } }
        for account in book.accounts { add(account.parent) }
        for transaction in book.transactions {
            for split in transaction.splits { add(split.account); add(split.transaction) }
        }
        for lot in book.lots { add(lot.account); lot.splits.forEach { add($0) } }
        for table in book.taxTables { table.entries.forEach { add($0.account) } }
        for customer in book.customers { add(customer.terms); add(customer.taxTable) }
        for vendor in book.vendors { add(vendor.terms); add(vendor.taxTable) }
        for employee in book.employees { add(employee.creditAccount) }
        func owner(_ owner: BusinessOwner) {
            switch owner {
            case .customer(let party): add(party)
            case .vendor(let party): add(party)
            case .employee(let party): add(party)
            case .job(let party): add(party)
            }
        }
        for job in book.jobs { owner(job.owner) }
        for invoice in book.invoices {
            owner(invoice.owner)
            add(invoice.terms); add(invoice.postedAccount); add(invoice.postedTransaction); add(invoice.postedLot)
            for entry in invoice.entries { add(entry.account); add(entry.taxTable) }
        }
        return refs
    }

    @Test("The replica shares no object with the book, and points only at its own")
    func nothingShared() throws {
        let book = try makeBook()
        let replica = book.replica().book

        let mine = objects(in: book)
        let its = objects(in: replica)
        #expect(mine.isDisjoint(with: its))
        #expect(its.count == mine.count)
        // Every reference inside the copy lands on one of the copy's objects.
        let dangling = referenced(from: replica).filter { !its.contains($0) }
        #expect(dangling.isEmpty)
        #expect(!referenced(from: replica).isEmpty)
    }

    @Test("The replica is the whole book: its GnuCash export is the book's, byte for byte")
    func wholeBook() throws {
        let book = try makeBook()
        let original = GnuCashXMLExporter.export(book)
        #expect(GnuCashXMLExporter.export(book) == original)       // the oracle is deterministic
        let replica = book.replica().book
        #expect(GnuCashXMLExporter.export(replica) == original)
        #expect(LedgerExport.text(from: replica) == LedgerExport.text(from: book))
        #expect(CSVExporter.transactions(replica) == CSVExporter.transactions(book))

        // And the same for a book that came from GnuCash, slots and all.
        let imported = try GnuCashXMLImporter.importBook(from: original).book
        #expect(GnuCashXMLExporter.export(imported.replica().book) == GnuCashXMLExporter.export(imported))
    }

    @Test("Editing the book afterwards leaves the replica as it was")
    func independent() throws {
        let book = try makeBook()
        let replica = book.replica().book
        let before = GnuCashXMLExporter.export(replica)

        let bank = try #require(book.accounts.first { $0.name == "Bank" })
        bank.name = "Renamed"
        let split = try #require(book.transactions.first?.splits.first)
        split.value = dec("1"); split.memo = "changed"
        book.transactions.first?.tags = ["changed"]
        book.customers.first?.name = "Changed"
        book.invoices.first?.entries.first?.price = dec("999")
        book.lots.first?.isClosed.toggle()
        book.addTransaction(Transaction(currency: .aud, datePosted: Date(), description: "New"))
        book.addPrice(Price(commodity: .usd, currency: .aud, date: Date(), value: dec("1.5")))

        #expect(GnuCashXMLExporter.export(replica) == before)
        #expect(GnuCashXMLExporter.export(book) != before)
    }
}
