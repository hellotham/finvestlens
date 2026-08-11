//
//  BookIndexTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

/// `Book.splits(for:)` is served from an index rather than by scanning every
/// transaction per account. These pin the two properties the change must not
/// alter: the same splits, in the same order.
@Suite("Book split index")
struct BookIndexTests {

    private func makeBook() -> (Book, Account, Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        return (book, bank, food)
    }

    @discardableResult
    private func post(_ book: Book, _ from: Account, _ to: Account,
                      _ amount: String, on date: Date) -> Transaction {
        let txn = Transaction(currency: .aud, datePosted: date, description: "T")
        txn.addSplit(account: from, value: -dec(amount))
        txn.addSplit(account: to, value: dec(amount))
        book.addTransaction(txn)
        return txn
    }

    @Test("Splits come back in transaction order")
    func preservesOrder() {
        // The lot engine consumes these in sequence, so a reordering would
        // silently change cost basis — this is the property that matters most.
        let (book, bank, food) = makeBook()
        for (index, date) in [day(2026, 1, 5), day(2026, 2, 5), day(2026, 3, 5)].enumerated() {
            post(book, bank, food, "\(index + 1)0", on: date)
        }

        let splits = book.splits(for: bank)
        #expect(splits.count == 3)
        #expect(splits.map(\.value) == [dec("-10"), dec("-20"), dec("-30")])
        // The same order the scanning form produced.
        let scanned = book.transactions.flatMap(\.splits).filter { $0.account === bank }
        #expect(splits.map(\.guid) == scanned.map(\.guid))
    }

    @Test("An account with no splits returns empty without rebuilding forever")
    func emptyAccount() {
        let (book, bank, food) = makeBook()
        post(book, bank, food, "10", on: day(2026, 1, 5))
        let unused = book.addAccount(Account(name: "Unused", type: .expense, commodity: .aud))

        // Asked repeatedly: a miss must not be mistaken for a stale index every
        // single call, or an empty account rebuilds the whole thing on each ask.
        for _ in 0..<3 { #expect(book.splits(for: unused).isEmpty) }
        #expect(book.splits(for: bank).count == 1, "the index still serves populated accounts")
    }

    @Test("Adding and removing transactions is reflected")
    func addAndRemove() {
        let (book, bank, food) = makeBook()
        let first = post(book, bank, food, "10", on: day(2026, 1, 5))
        #expect(book.splits(for: bank).count == 1)

        post(book, bank, food, "20", on: day(2026, 2, 5))
        #expect(book.splits(for: bank).count == 2, "addTransaction invalidates the index")

        book.removeTransaction(first)
        #expect(book.splits(for: bank).count == 1, "removeTransaction invalidates the index")
        #expect(book.splits(for: bank).first?.value == dec("-20"))
    }

    @Test("A split added to a transaction already in the book needs an invalidate")
    func mutationContract() {
        // The index cannot see a split appear on a transaction it already holds
        // — the book does not observe that. This is the same contract the GUID
        // lookups have always had, and why the app invalidates after every edit.
        let (book, bank, food) = makeBook()
        let txn = post(book, bank, food, "10", on: day(2026, 1, 5))
        #expect(book.splits(for: bank).count == 1)

        let other = book.addAccount(Account(name: "Other", type: .expense, commodity: .aud))
        txn.addSplit(account: other, value: dec("5"))
        txn.splits.first { $0.account === food }?.value = dec("5")

        book.invalidateLookupIndexes()
        #expect(book.splits(for: other).count == 1, "visible once invalidated")
        #expect(book.splits(for: bank).count == 1)
    }
}
