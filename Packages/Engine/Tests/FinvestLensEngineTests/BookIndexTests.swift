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

/// `Book.account(with:)` is served from an index the tree can change under
/// (accounts are added, moved and removed on each other, not through the
/// book). It must answer exactly what walking the tree answers.
@Suite("Book account index")
struct BookAccountIndexTests {

    /// What the walk the index replaced returned.
    private func walked(_ book: Book, _ guid: GncGUID) -> Account? {
        book.accounts.first { $0.guid == guid }
    }

    @Test("Finds any account in the tree, never the root, and agrees with the walk")
    func findsWhatTheWalkFinds() {
        let book = Book(baseCurrency: .aud)
        let assets = book.addAccount(Account(name: "Assets", type: .asset, commodity: .aud))
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud), under: assets)
        let savings = book.addAccount(Account(name: "Savings", type: .bank, commodity: .aud), under: bank)
        for account in [assets, bank, savings] {
            #expect(book.account(with: account.guid) === account)
            #expect(walked(book, account.guid) === account)
        }
        #expect(book.account(with: book.rootAccount.guid) == nil)
        #expect(book.account(with: GncGUID.random()) == nil)
    }

    @Test("Follows the tree as it changes: added, moved, removed, put back")
    func followsTheTree() {
        let book = Book(baseCurrency: .aud)
        let assets = book.addAccount(Account(name: "Assets", type: .asset, commodity: .aud))
        let other = book.addAccount(Account(name: "Other", type: .asset, commodity: .aud))
        _ = book.account(with: assets.guid)                 // the index is built

        // Added on a parent directly, not through the book.
        let bank = Account(name: "Bank", type: .bank, commodity: .aud)
        assets.addChild(bank)
        #expect(book.account(with: bank.guid) === bank)

        // Moved: still the same account.
        other.addChild(bank)
        #expect(book.account(with: bank.guid) === bank)
        #expect(bank.parent === other)

        // Removed from the tree, a subtree with it: gone, as the walk says.
        let child = Account(name: "Child", type: .bank, commodity: .aud)
        bank.addChild(child)
        #expect(book.account(with: child.guid) === child)
        other.removeChild(bank)
        #expect(book.account(with: bank.guid) == nil)
        #expect(book.account(with: child.guid) == nil)
        #expect(walked(book, child.guid) == nil)

        // Put back, as an undo does.
        assets.addChild(bank, at: 0)
        #expect(book.account(with: bank.guid) === bank)
        #expect(book.account(with: child.guid) === child)
    }

    @Test("Two accounts with one GUID: the one the walk meets first")
    func duplicateGUIDs() {
        let book = Book(baseCurrency: .aud)
        let shared = GncGUID.random()
        let first = book.addAccount(Account(guid: shared, name: "First", type: .bank, commodity: .aud))
        let parent = book.addAccount(Account(name: "Parent", type: .asset, commodity: .aud))
        _ = book.addAccount(Account(guid: shared, name: "Second", type: .bank, commodity: .aud), under: parent)
        #expect(book.account(with: shared) === first)
        #expect(walked(book, shared) === first)
    }
}

/// The lookup indexes are kept up to date edit by edit rather than dropped
/// (P5.4). After any sequence of adds, removals and in-place edits they must
/// be exactly what a rebuild makes — the same objects, every account's legs
/// in book order — or the lot engine, which reads legs in that order, would
/// silently change cost basis.
@Suite("Book lookup indexes kept up to date")
struct BookIndexMaintenanceTests {

    @Test("Adds, removals, restores and in-place edits leave the indexes a rebuild would make")
    func randomEdits() {
        var generator = SeededGenerator(seed: 0x5EED)
        let book = Book(baseCurrency: .aud)
        let accounts = (0..<6).map { book.addAccount(Account(name: "A\($0)", type: .bank, commodity: .aud)) }
        func randomAccount() -> Account { accounts[Int.random(in: 0..<accounts.count, using: &generator)] }
        func makeTransaction() -> Transaction {
            let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: Double(Int.random(in: 0..<400, using: &generator)) * 86_400))
            let amount = Decimal(Int.random(in: 1..<500, using: &generator))
            txn.addSplit(account: randomAccount(), value: amount)
            txn.addSplit(account: randomAccount(), value: -amount)
            return txn
        }
        for _ in 0..<40 { book.addTransaction(makeTransaction()) }
        _ = book.splits(for: accounts[0])           // the indexes are built
        var removed: [Transaction] = []

        for step in 0..<600 {
            let live = book.transactions
            switch Int.random(in: 0..<6, using: &generator) {
            case 0:
                book.addTransaction(makeTransaction())
            case 1 where !live.isEmpty:
                let victim = live[Int.random(in: 0..<live.count, using: &generator)]
                book.removeTransaction(victim)
                removed.append(victim)
            case 2 where !removed.isEmpty:
                book.restoreTransaction(removed.removeLast())
            case 3 where !live.isEmpty:
                // A leg moves to another account.
                let txn = live[Int.random(in: 0..<live.count, using: &generator)]
                let before = txn.detachedCopy().splits
                txn.splits.first?.account = randomAccount()
                book.reindex(txn, previous: before)
            case 4 where !live.isEmpty:
                // A leg added and one taken away.
                let txn = live[Int.random(in: 0..<live.count, using: &generator)]
                let before = txn.detachedCopy().splits
                txn.addSplit(account: randomAccount(), value: 0)
                if txn.splits.count > 2 { txn.removeSplit(txn.splits[0]) }
                book.reindex(txn, previous: before)
            case 5 where !live.isEmpty:
                // Every leg replaced by a copy, as an undo restores them.
                let txn = live[Int.random(in: 0..<live.count, using: &generator)]
                let before = txn.detachedCopy().splits
                let copies = txn.detachedCopy().splits
                for split in Array(txn.splits) { txn.removeSplit(split) }
                for split in copies { txn.addSplit(split) }
                book.reindex(txn, previous: before)
            default:
                break
            }
            #expect(book.lookupIndexesMatchRebuild(), "the indexes drifted at step \(step)")
            if !book.lookupIndexesMatchRebuild() { return }
        }
        // And answers through the public lookups agree with a scan.
        for account in accounts {
            let scanned = book.transactions.flatMap(\.splits).filter { $0.account === account }
            #expect(book.splits(for: account).map(ObjectIdentifier.init) == scanned.map(ObjectIdentifier.init))
        }
    }

    @Test("An account with no splits is an answer, not a miss")
    func emptyAccount() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let empty = book.addAccount(Account(name: "Imbalance-AUD", type: .bank, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: Date())
        txn.addSplit(account: bank, value: 1)
        txn.addSplit(account: bank, value: -1)
        book.addTransaction(txn)
        #expect(book.splits(for: empty).isEmpty)
        #expect(book.splits(for: bank).count == 2)
        // A leg moved into it shows up once the edit is reported.
        let before = txn.detachedCopy().splits
        txn.splits[1].account = empty
        book.reindex(txn, previous: before)
        #expect(book.splits(for: empty).map(ObjectIdentifier.init) == [ObjectIdentifier(txn.splits[1])])
        #expect(book.lookupIndexesMatchRebuild())
    }

    @Test("The accounts an edit changed, or nil when the book cannot say")
    func changedAccounts() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        #expect(book.takeChangedAccounts() == nil)          // nothing has asked yet: any
        let txn = Transaction(currency: .aud, datePosted: Date())
        txn.addSplit(account: bank, value: -5)
        txn.addSplit(account: food, value: 5)
        book.addTransaction(txn)
        #expect(Set(book.takeChangedAccounts()?.map(\.name) ?? []) == ["Bank", "Food"])
        #expect(book.takeChangedAccounts()?.isEmpty == true)
        let before = txn.detachedCopy().splits
        txn.splits[1].account = rent
        book.reindex(txn, previous: before)
        #expect(Set(book.takeChangedAccounts()?.map(\.name) ?? []) == ["Bank", "Food", "Rent"])
        book.invalidateLookupIndexes()
        #expect(book.takeChangedAccounts() == nil)
    }

    @Test("A replica keeps the book's order, and goes on from it")
    func replicaOrder() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        for day in 0..<5 {
            let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: Double(day) * 86_400))
            txn.addSplit(account: bank, value: 1)
            txn.addSplit(account: bank, value: -1)
            book.addTransaction(txn)
        }
        let replica = book.replica().book
        let replicaBank = replica.account(with: bank.guid)!
        _ = replica.splits(for: replicaBank)
        let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0))
        txn.addSplit(account: replicaBank, value: 2)
        txn.addSplit(account: replicaBank, value: -2)
        replica.addTransaction(txn)
        #expect(replica.lookupIndexesMatchRebuild())
        #expect(replica.splits(for: replicaBank).last === txn.splits.last)
    }
}

/// A small deterministic generator, so a failing sequence can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
