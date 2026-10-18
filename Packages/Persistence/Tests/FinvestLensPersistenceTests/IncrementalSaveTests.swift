//
//  IncrementalSaveTests.swift
//  FinvestLens — Persistence
//
//  A save writes only what changed since the last one (P10b): transactions
//  edited in place are rewritten where they are, ones added since go at the
//  end, prices added since go at the end, and the small tables are written
//  whole. What lands must be exactly what a full write would have written —
//  every row, and the order a reopened book is read back in, which is the
//  order the lot engine reads legs in.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
import FinvestLensEngine
@testable import FinvestLensPersistence

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

/// A book's rows as a full write renders them: transactions with their legs,
/// prices, accounts — each in order.
private func rows(_ book: Book) -> [[DatabaseValue]] {
    let snapshot = BookSnapshot(book)
    var all: [[DatabaseValue]] = []
    for txn in snapshot.transactions {
        all.append(txn.values.map(\.databaseValue))
        all += txn.splits.map { $0.map(\.databaseValue) }
    }
    all += snapshot.prices.map { $0.map(\.databaseValue) }
    all += snapshot.accounts.map { $0.map(\.databaseValue) }
    return all
}

/// A deterministic generator, so a failing run can be replayed.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Incremental save")
struct IncrementalSaveTests {

    @Test("Edits in place, adds, removals, restores and prices, saved round by round, land as a full write would")
    func randomRounds() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        let book = document.book
        var generator = Seeded(state: 0xFEED)
        let accounts = (0..<5).map { book.addAccount(Account(name: "A\($0)", type: .bank, commodity: .aud)) }
        let stock = Commodity(namespace: .security("ASX"), mnemonic: "VAS", fullName: "VAS", smallestFraction: 10_000)
        func any<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &generator)] }
        func makeTransaction() -> Transaction {
            let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_000
                + Double(Int.random(in: 0..<200, using: &generator)) * 86_400),
                                  description: "T\(Int.random(in: 0..<1_000, using: &generator))")
            let amount = Decimal(Int.random(in: 1..<900, using: &generator))
            txn.addSplit(account: any(accounts), value: amount, memo: "m")
            txn.addSplit(account: any(accounts), value: -amount)
            return txn
        }
        for _ in 0..<30 { book.addTransaction(makeTransaction()) }
        document.markDirty()
        try document.save()
        #expect(try document.workingCopyHoldsBook())

        var removed: [Transaction] = []
        var removedPrices: [Price] = []
        for round in 0..<40 {
            for _ in 0..<Int.random(in: 1..<5, using: &generator) {
                let live = book.transactions
                switch Int.random(in: 0..<8, using: &generator) {
                case 0:
                    book.addTransaction(makeTransaction())
                case 1 where !live.isEmpty:
                    let txn = any(live)
                    book.removeTransaction(txn)
                    removed.append(txn)
                case 2 where !removed.isEmpty:
                    book.restoreTransaction(removed.removeLast())
                case 3 where !live.isEmpty:
                    // In place, as the app reports it: a leg's value, the
                    // description, a leg moved.
                    let txn = any(live)
                    let before = txn.detachedCopy().splits
                    txn.transactionDescription = "edited \(round)"
                    txn.splits[0].value += 1
                    txn.splits[1].value -= 1
                    txn.splits[1].account = any(accounts)
                    book.reindex(txn, previous: before)
                case 4 where !live.isEmpty:
                    // A leg added and the first taken away.
                    let txn = any(live)
                    let before = txn.detachedCopy().splits
                    txn.addSplit(account: any(accounts), value: 0, memo: "new")
                    if txn.splits.count > 2 { txn.removeSplit(txn.splits[0]) }
                    book.reindex(txn, previous: before)
                case 5:
                    // Two prices on one day: which is the day's comes from order.
                    let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(round % 7) * 86_400)
                    book.addPrice(Price(commodity: stock, currency: .aud, date: date,
                                        value: Decimal(90 + round)))
                    book.addPrice(Price(commodity: stock, currency: .aud, date: date,
                                        value: Decimal(91 + round)))
                case 6 where !book.prices.isEmpty:
                    let price = any(book.prices)
                    book.removePrice(price.guid)
                    removedPrices.append(price)
                case 7 where !removedPrices.isEmpty:
                    book.addPrice(removedPrices.removeLast())
                default:
                    break
                }
            }
            document.markDirty()
            try document.save()
            #expect(try document.workingCopyHoldsBook(), "round \(round)")
        }

        let expected = rows(book)
        document.discard()
        let reopened = try FinvestLensDocument.open(at: url)
        defer { reopened.discard() }
        #expect(rows(reopened.book) == expected)
        #expect(reopened.book.transactions.map(\.guid) == book.transactions.map(\.guid))
        #expect(reopened.book.prices.map(\.guid) == book.prices.map(\.guid))
    }

    @Test("An edit nobody reported is still written — and one the app reports as unknown is written whole")
    func unreportedEdits() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        let book = document.book
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_000))
        txn.addSplit(account: bank, value: -5)
        txn.addSplit(account: food, value: 5)
        book.addTransaction(txn)
        document.markDirty()
        try document.save()

        // Changed with nobody told — the leg's own setter tells the book, as
        // GnuCash's do, so the file gets it. It used to be left out: the
        // save went through and the change was gone on reopening.
        txn.splits[0].memo = "unreported"
        txn.splits[1].value = 6
        txn.splits[0].value = -6
        txn.transactionDescription = "also unreported"
        document.markDirty()
        try document.save()
        #expect(try document.workingCopyHoldsBook())

        // What the app does for an edit that does not say what it changed:
        // drop the indexes, which makes the next save write every transaction.
        book.invalidateLookupIndexes()
        document.markDirty()
        try document.save()
        #expect(try document.workingCopyHoldsBook())
    }

    @Test("A save that does not land gives back what it took, and the next one writes it")
    func failedSaveGivesBack() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        let book = document.book
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        for index in 0..<3 {
            let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            txn.addSplit(account: bank, value: -Decimal(index + 1))
            txn.addSplit(account: food, value: Decimal(index + 1))
            book.addTransaction(txn)
        }
        book.addPrice(Price(commodity: .usd, currency: .aud, date: Date(), value: 1.5))
        document.markDirty()

        // Staged, and then the write never happens.
        let staged = try document.stageSnapshot()
        document.saveFailed(staged)
        // More changes after the failure join what was given back.
        let later = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_100))
        later.addSplit(account: bank, value: -9)
        later.addSplit(account: food, value: 9)
        book.addTransaction(later)
        document.markDirty()
        try document.save()
        #expect(try document.workingCopyHoldsBook())
    }

    @Test("A save that fails after a later one has written gives nothing back — the file keeps the book's order")
    func earlierFailsAfterLaterLands() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        let book = document.book
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        func add(_ amount: Decimal) {
            let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_000))
            txn.addSplit(account: bank, value: -amount)
            txn.addSplit(account: food, value: amount)
            book.addTransaction(txn)
            document.markDirty()
        }
        add(1)
        try document.save()

        add(2)
        let earlier = try document.stageSnapshot()      // an autosave, slow to write back
        add(3)
        let later = try document.stageSnapshot()        // a save meanwhile: it carries the first's share
        let fingerprint = try FinvestLensDocument.commitStaged(later)
        document.finishSave(fingerprint: fingerprint, staged: later)
        document.saveFailed(earlier)                    // and then the earlier one's write-back fails

        add(4)
        try document.save()
        #expect(try document.workingCopyHoldsBook())
        let expected = rows(book)
        document.discard()
        let reopened = try FinvestLensDocument.open(at: url)
        defer { reopened.discard() }
        #expect(rows(reopened.book) == expected)
    }

    @Test("A book read with identifiers it could not parse writes everything on its first save")
    func inventedIdentifiers() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let document = try FinvestLensDocument.create(at: url)
            let book = document.book
            let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
            let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
            for amount in [Decimal(1), 2] {
                let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_000))
                txn.addSplit(account: bank, value: -amount)
                txn.addSplit(account: food, value: amount)
                book.addTransaction(txn)
            }
            book.addPrice(Price(commodity: .usd, currency: .aud, date: Date(timeIntervalSince1970: 1_700_000_000),
                                value: 1.5))
            document.markDirty()
            try document.save()
            document.discard()
        }
        // A price whose identifier no longer parses, in the file itself: the
        // book gets a new one, which no row of the file has.
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE price SET guid = 'not-a-guid'")
        }
        try queue.close()

        let document = try FinvestLensDocument.open(at: url)
        defer { document.discard() }
        #expect((document.loadWarnings?.guids ?? 0) > 0)
        // The book does not match the file row for row, so it is not taken as
        // saved: what the first save writes is everything.
        let unsaved = document.book.takeUnsaved()
        #expect(unsaved.transactions == nil)
        #expect(unsaved.prices == nil)

        // Revert reads the book again — and Reload from Disk and adopting a
        // conflict version are revert — so it must refuse the same way.
        try document.revert()
        #expect((document.loadWarnings?.guids ?? 0) > 0)
        let reverted = document.book.takeUnsaved()
        #expect(reverted.transactions == nil)
        #expect(reverted.prices == nil)
    }

    @Test("Two saves staged before either writes land complete, in either order",
          arguments: [false, true])
    func overlappingSaves(laterFirst: Bool) throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FinvestLensDocument.create(at: url)
        defer { document.discard() }
        let book = document.book
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        func add(_ amount: Decimal, _ day: Double) -> Transaction {
            let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1_700_000_000 + day * 86_400))
            txn.addSplit(account: bank, value: -amount)
            txn.addSplit(account: food, value: amount)
            return book.addTransaction(txn)
        }
        let first = add(1, 0)
        document.markDirty()
        let earlier = try document.stageSnapshot()          // an autosave, staged

        // More changes, among them the first transaction again, before it writes.
        let before = first.detachedCopy().splits
        first.splits[0].value = -7
        first.splits[1].value = 7
        book.reindex(first, previous: before)
        _ = add(2, 1)
        book.addPrice(Price(commodity: .usd, currency: .aud, date: Date(), value: 1.5))
        document.markDirty()
        let later = try document.stageSnapshot()            // a second save

        for staged in laterFirst ? [later, earlier] : [earlier, later] {
            let fingerprint = try FinvestLensDocument.commitStaged(staged)
            document.finishSave(fingerprint: fingerprint, staged: staged)
        }
        #expect(try document.workingCopyHoldsBook())
        let expected = rows(book)
        document.discard()
        let reopened = try FinvestLensDocument.open(at: url)
        defer { reopened.discard() }
        #expect(rows(reopened.book) == expected)
    }
}
