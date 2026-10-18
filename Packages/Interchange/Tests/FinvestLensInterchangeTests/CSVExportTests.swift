//
//  CSVExportTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

struct CSVExportTests {

    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let txn = Transaction(currency: .aud, datePosted: day, description: "Pay, incl. \"bonus\"")
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: salary, value: dec("-100.00"))
        book.addTransaction(txn)
        let stock = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                              fullName: "Commonwealth Bank", smallestFraction: 10000)
        book.addPrice(Price(commodity: stock, currency: .aud, date: day, value: dec("105.20")))
        return book
    }

    @Test("Account export lists non-root accounts with full names")
    func accountsExport() {
        let csv = CSVExporter.accounts(makeBook())
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("Type,Full Account Name,Account Name") == true)
        #expect(lines.contains { $0.contains("Bank") })
        #expect(lines.contains { $0.contains("Salary") })
        // Root account is excluded.
        #expect(!lines.dropFirst().contains { $0.hasPrefix("ROOT") || $0.hasPrefix("root") })
    }

    @Test("Transaction export writes one row per split and quotes special chars")
    func transactionsExport() {
        let csv = CSVExporter.transactions(makeBook())
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)   // header + 2 splits
        // The description has a comma and a quote → must be RFC-4180 quoted.
        #expect(csv.contains("\"Pay, incl. \"\"bonus\"\"\""))
        #expect(csv.contains("100.00"))
        #expect(csv.contains("-100.00"))
    }

    @Test("Price export lists the price DB")
    func pricesExport() {
        let csv = CSVExporter.prices(makeBook())
        #expect(csv.contains("Date,Namespace,Commodity,Currency,Price"))
        #expect(csv.contains("CBA"))
        #expect(csv.contains("105.20"))
    }

    @Test("CSV price import round-trips the price export")
    func priceImportRoundTrip() {
        let csv = CSVExporter.prices(makeBook())
        let staged = CSVPriceImporter.parse(csv, mapping:
            CSVPriceColumnMapping(date: 0, commodity: 2, price: 4, currency: 3))
        #expect(staged.count == 1)
        #expect(staged.first?.commoditySymbol == "CBA")
        #expect(staged.first?.currencyCode == "AUD")
        #expect(staged.first?.value == dec("105.20"))
    }

    @Test("CSV price import skips malformed / non-positive rows")
    func priceImportSkipsBadRows() {
        let csv = """
        Date,Symbol,Price
        2024-01-02,CBA,105.20
        not-a-date,CBA,1.00
        2024-01-03,,2.00
        2024-01-04,CBA,0
        """
        let staged = CSVPriceImporter.parse(csv, mapping:
            CSVPriceColumnMapping(date: 0, commodity: 1, price: 2))
        #expect(staged.count == 1)
        #expect(staged.first?.value == dec("105.20"))
    }
}

/// The CSV exports as they were before their formatter and sort keys were
/// cached (17 Oct 2026), kept as the oracle the faster ones must match.
private enum ReferenceCSV {
    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func transactions(_ book: Book) -> String {
        var out = CSVExporter.row([
            "Date", "Transaction ID", "Number", "Description", "Notes",
            "Commodity/Currency", "Action", "Memo", "Full Account Name",
            "Amount Num.", "Value Num.", "Reconcile", "Reconcile Date", "Rate/Price",
        ])
        let txns = book.transactions.sorted { a, b in
            if a.datePosted != b.datePosted { return a.datePosted < b.datePosted }
            return a.guid.hexString < b.guid.hexString
        }
        for txn in txns {
            for split in txn.splits {
                let rate: String
                if split.quantity != 0, split.quantity != split.value {
                    rate = CSVExporter.num(abs(split.value / split.quantity))
                } else {
                    rate = ""
                }
                out += CSVExporter.row([
                    date(txn.datePosted), txn.guid.hexString, txn.number,
                    txn.transactionDescription, txn.notes,
                    "\(GnuCashXMLExporter.namespace(txn.currency.namespace))::\(txn.currency.mnemonic)",
                    split.action, split.memo, split.account?.fullName ?? "",
                    CSVExporter.num(split.quantity), CSVExporter.num(split.value),
                    split.reconcileState.rawValue, split.reconcileDate.map(date) ?? "", rate,
                ])
            }
        }
        return out
    }

    static func prices(_ book: Book) -> String {
        var out = CSVExporter.row(["Date", "Namespace", "Commodity", "Currency", "Price", "Source", "Type"])
        for price in book.prices.sorted(by: CSVExporter.priceOrder) {
            out += CSVExporter.row([
                date(price.date), GnuCashXMLExporter.namespace(price.commodity.namespace),
                price.commodity.mnemonic, price.currency.mnemonic, CSVExporter.num(price.value),
                price.source, price.type,
            ])
        }
        return out
    }
}

@Suite("CSV export matches its reference")
struct CSVExportReferenceTests {

    /// Same-day transactions (the guid tie-break), nested and missing
    /// accounts, reconcile dates, a security with a rate, and prices across
    /// days and commodities — instants late in a UTC day included.
    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let assets = book.addAccount(Account(name: "Assets", type: .asset, commodity: .aud))
        let bank = book.addAccount(Account(name: "Bank, Main", type: .bank, commodity: .aud), under: assets)
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let stock = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                              fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = book.addAccount(Account(name: "CBA", type: .stock, commodity: stock), under: assets)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<60 {
            let day = base.addingTimeInterval(Double(index / 4) * 86_400 + Double(index % 4) * 21_600)
            let txn = Transaction(currency: .aud, datePosted: day, number: "\(index)",
                                  description: index % 7 == 0 ? "Pay, \"bonus\"" : "Entry \(index)",
                                  notes: index % 5 == 0 ? "line\nbreak" : "")
            if index % 3 == 0 {
                txn.addSplit(Split(account: shares, value: dec("1052.00"), quantity: dec("10"),
                                   reconcileState: .reconciled, reconcileDate: day.addingTimeInterval(86_400),
                                   memo: "buy", action: "Buy"))
                txn.addSplit(Split(account: bank, value: dec("-1052.00")))
            } else {
                txn.addSplit(Split(account: bank, value: dec("\(index).25"),
                                   reconcileState: index % 2 == 0 ? .cleared : .notReconciled))
                txn.addSplit(Split(account: index % 11 == 0 ? nil : salary, value: dec("-\(index).25")))
            }
            book.addTransaction(txn)
        }
        for index in 0..<40 {
            book.addPrice(Price(commodity: index % 2 == 0 ? stock : .usd, currency: .aud,
                                date: base.addingTimeInterval(Double(index / 3) * 86_400),
                                value: dec("\(100 + index).125"), source: "user:price", type: "last"))
        }
        return book
    }

    @Test("Transactions and prices are byte for byte what they were")
    func matchesReference() {
        let book = makeBook()
        #expect(CSVExporter.transactions(book) == ReferenceCSV.transactions(book))
        #expect(CSVExporter.prices(book) == ReferenceCSV.prices(book))
    }
}
