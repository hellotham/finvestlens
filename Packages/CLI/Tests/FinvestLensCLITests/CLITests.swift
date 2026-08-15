//
//  CLITests.swift
//  FinvestLens — CLI
//
//  P10c exit criteria: golden outputs per command (widths, elision,
//  separators pinned), the query and period grammars, and the read-only
//  guarantee.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensPersistence
@testable import FinvestLensCLICore

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: m, day: d))!
}

/// A small journal covering the shapes the renderers must handle.
private let fixtureJournal = """
commodity AUD
    format 0.00 AUD

P 2026/01/20 BHP 42.10 AUD

2026/01/05 * Opening Balances
    Assets:Bank:Everyday          1000.00 AUD
    Equity:Opening

2026/01/10 * (42) Grocery Store
    Expenses:Food:Groceries         65.00 AUD
    Assets:Bank:Everyday

2026/01/12 ! Cafe  ; :treats:
    Expenses:Food:Dining            12.50 AUD
    Assets:Bank:Everyday

2026/02/03 Salary
    Assets:Bank:Everyday          2000.00 AUD
    Income:Salary

2026/02/14 Broker
    Assets:Brokerage:BHP           10 BHP @@ 421.00 AUD
    Assets:Bank:Everyday
"""

private func fixtureSource() throws -> LoadedSource {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("ledger")
    try fixtureJournal.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return try SourceLoader.load(paths: [url.path], today: day(2026, 3, 1))
}

private func run(_ command: String, _ terms: [String] = [],
                 options: CLIOptions = CLIOptions()) throws -> String {
    let driver = CLIDriver(today: day(2026, 3, 1), environment: [:])
    let source = try fixtureSource()
    let output = driver.execute(command: command, terms: terms,
                                options: options, loaded: source)
    return output.text
}

@Suite("finlens option parsing")
struct CLIParsingTests {

    @Test("Options interleave with the command and query terms, as in ledger")
    func interleaved() throws {
        let invocation = try CLIParser.parse(
            ["-f", "book.ledger", "bal", "^Assets", "--depth", "2", "food", "-C"])
        #expect(invocation.files == ["book.ledger"])
        #expect(invocation.command == "bal")
        #expect(invocation.queryTerms == ["^Assets", "food"])
        #expect(invocation.options.depth == 2)
        #expect(invocation.options.cleared)
    }

    @Test("Short clusters, --option=value, and interval shortcuts")
    func shapes() throws {
        let cluster = try CLIParser.parse(["reg", "-Cn"])
        #expect(cluster.options.cleared && cluster.options.collapse)

        let inline = try CLIParser.parse(["bal", "--depth=3", "--period=monthly"])
        #expect(inline.options.depth == 3)
        #expect(inline.options.period == "monthly")

        let shortcut = try CLIParser.parse(["reg", "-M"])
        #expect(shortcut.options.period == "monthly")

        let sort = try CLIParser.parse(["reg", "-S", "-date,amount"])
        #expect(sort.options.sortKeys == ["-date", "amount"])
    }

    @Test("Unknown options and missing values are errors")
    func errors() {
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["bal", "--nope"]) }
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["bal", "--depth"]) }
    }
}

@Suite("finlens query grammar")
struct CLIQueryTests {

    private func subject(account: String, payee: String = "", tags: [String] = [],
                         code: String = "") -> QuerySubject {
        let book = Book(baseCurrency: .aud)
        let target = book.addAccount(Account(name: account, type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 1, 1),
                              number: code, description: payee)
        txn.tags = tags
        let split = Split(account: target, value: 1)
        txn.addSplit(split)
        return QuerySubject(split: split, transaction: txn)
    }

    @Test("Bare terms are account regexes ORed together")
    func implicitOr() {
        let query = QueryParser.parse(["food", "rent"])
        #expect(query.predicate.matches(subject(account: "Food")))
        #expect(query.predicate.matches(subject(account: "Rent")))
        #expect(!query.predicate.matches(subject(account: "Travel")))
    }

    @Test("and / or / not with parentheses")
    func booleans() {
        let query = QueryParser.parse(["Expenses", "and", "not", "(", "Drinks", "or", "Candy", ")"])
        #expect(query.predicate.matches(subject(account: "Expenses")))
        #expect(!query.predicate.matches(subject(account: "Drinks")))
    }

    @Test("payee/@, tag/%, code/#, note/= keywords and shorthands")
    func keywords() {
        let byPayee = QueryParser.parse(["@Chevron"])
        #expect(byPayee.predicate.matches(subject(account: "Fuel", payee: "Chevron Station")))
        #expect(!byPayee.predicate.matches(subject(account: "Fuel", payee: "Shell")))

        let byTag = QueryParser.parse(["%treats"])
        #expect(byTag.predicate.matches(subject(account: "Food", tags: ["treats"])))

        let byCode = QueryParser.parse(["#42"])
        #expect(byCode.predicate.matches(subject(account: "Food", code: "42")))

        let keyword = QueryParser.parse(["payee", "Chevron"])
        #expect(keyword.predicate.matches(subject(account: "Fuel", payee: "Chevron")))
    }

    @Test("Trailing sections split off the period and display predicates")
    func sections() {
        let query = QueryParser.parse(["food", "for", "last", "month", "show", "@Safeway"])
        #expect(query.periodWords == ["last", "month"])
        #expect(query.display != nil)
        #expect(query.predicate.matches(subject(account: "Food")))
    }
}

@Suite("finlens period expressions")
struct CLIPeriodTests {

    private let today = day(2026, 3, 15)

    @Test("Smart dates")
    func smartDates() {
        #expect(PeriodExpression.date("today", today: today) == day(2026, 3, 15))
        #expect(PeriodExpression.date("yesterday", today: today) == day(2026, 3, 14))
        #expect(PeriodExpression.date("2026/07", today: today) == day(2026, 7, 1))
        #expect(PeriodExpression.date("2026-07-04", today: today) == day(2026, 7, 4))
        #expect(PeriodExpression.date("2025", today: today) == day(2025, 1, 1))
        #expect(PeriodExpression.date("last month", today: today) == day(2026, 2, 1))
        #expect(PeriodExpression.date("oct", today: today) == day(2026, 10, 1))
    }

    @Test("Period expressions: interval plus from/to, and bare spans")
    func periods() {
        let monthly = PeriodExpression.parse("monthly", today: today)
        #expect(monthly.interval == .monthly)

        let ranged = PeriodExpression.parse("monthly from 2026/01 to 2026/04", today: today)
        #expect(ranged.interval == .monthly)
        #expect(ranged.begin == day(2026, 1, 1))
        #expect(ranged.end == day(2026, 4, 1))

        let bare = PeriodExpression.parse("in 2025", today: today)
        #expect(bare.begin == day(2025, 1, 1))
        #expect(bare.end == day(2026, 1, 1))   // end is exclusive

        let every = PeriodExpression.parse("every 2 weeks", today: today)
        #expect(every.interval == .biweekly)
    }

    @Test("Interval buckets align to natural period starts")
    func buckets() {
        let buckets = PeriodExpression.buckets(interval: .monthly,
                                               from: day(2026, 1, 15), to: day(2026, 4, 1))
        // Jan/Feb/Mar — the Apr 1 end is exclusive.
        #expect(buckets.count == 3)
        #expect(buckets[0].start == day(2026, 1, 1))   // aligned back to the 1st
        #expect(buckets[2].start == day(2026, 3, 1))
        #expect(buckets[2].end == day(2026, 4, 1))
    }
}

@Suite("finlens report output")
struct CLIRenderTests {

    @Test("balance: tree, 20-column totals, chain elision, dashed grand total")
    func balanceTree() throws {
        let text = try run("balance")
        // Multi-commodity balances stack, the account name on the last line.
        #expect(text == """
                2,501.50 AUD
                      10 BHP  Assets
                2,501.50 AUD    Bank:Everyday
                      10 BHP    Brokerage:BHP
               -1,000.00 AUD  Equity:Opening
                   77.50 AUD  Expenses:Food
                   12.50 AUD    Dining
                   65.00 AUD    Groceries
               -2,000.00 AUD  Income:Salary
        --------------------
                 -421.00 AUD
                      10 BHP

        """)
    }

    @Test("balance --flat lists full names with no elision")
    func balanceFlat() throws {
        var options = CLIOptions(); options.flat = true; options.noTotal = true
        let text = try run("balance", ["Expenses"], options: options)
        #expect(text == """
                   12.50 AUD  Expenses:Food:Dining
                   65.00 AUD  Expenses:Food:Groceries

        """)
    }

    @Test("balance --depth folds deeper accounts into their ancestor")
    func balanceDepth() throws {
        // `--depth N` counts ACCOUNT PATH components, as ledger does.
        var one = CLIOptions(); one.depth = 1; one.noTotal = true
        #expect(try run("balance", ["Expenses"], options: one) == """
                   77.50 AUD  Expenses

        """)

        var two = CLIOptions(); two.depth = 2; two.noTotal = true
        #expect(try run("balance", ["Expenses"], options: two) == """
                   77.50 AUD  Expenses:Food

        """)
    }

    @Test("register: date, payee, account, amount, running total")
    func register() throws {
        var options = CLIOptions(); options.columns = 80
        let text = try run("register", ["Groceries"], options: options)
        #expect(text.contains("26-Jan-10"))
        #expect(text.contains("Grocery Store"))
        #expect(text.contains("65.00 AUD"))
        // The running total is the last column and equals the amount here.
        let columns = text.split(separator: "\n")[0]
        #expect(columns.hasSuffix("65.00 AUD"))
    }

    @Test("register --related shows the other side of each match")
    func registerRelated() throws {
        var options = CLIOptions(); options.related = true; options.columns = 80
        let text = try run("register", ["Groceries"], options: options)
        #expect(text.contains("Assets:Bank:Everyday"))
        #expect(!text.contains("Groceries"))
    }

    @Test("Date filters: --end is exclusive, as in ledger")
    func endExclusive() throws {
        var options = CLIOptions(); options.end = "2026/01/10"; options.noTotal = true
        let text = try run("balance", ["Groceries"], options: options)
        #expect(text.isEmpty)   // the 10 Jan posting is excluded

        var inclusive = CLIOptions(); inclusive.end = "2026/01/11"; inclusive.noTotal = true
        let after = try run("balance", ["Groceries"], options: inclusive)
        #expect(after.contains("65.00 AUD"))
    }

    @Test("State filters follow the transaction flag")
    func stateFilters() throws {
        var cleared = CLIOptions(); cleared.cleared = true; cleared.noTotal = true
        let clearedText = try run("balance", ["Bank"], options: cleared)
        #expect(clearedText.contains("935.00 AUD"))   // opening + groceries only

        var pending = CLIOptions(); pending.pending = true; pending.noTotal = true
        let pendingText = try run("balance", ["Dining"], options: pending)
        #expect(pendingText.contains("12.50 AUD"))
    }

    @Test("accounts / payees / commodities list sorted names")
    func lists() throws {
        #expect(try run("accounts", ["Food"]) == """
        Expenses:Food:Dining
        Expenses:Food:Groceries

        """)
        #expect(try run("payees", ["Groceries"]) == "Grocery Store\n")
        #expect(try run("commodities").contains("BHP"))
    }

    @Test("csv quotes every field in ledger's column order")
    func csv() throws {
        let text = try run("csv", ["Groceries"])
        #expect(text == "\"2026/01/10\",\"42\",\"Grocery Store\",\"Expenses:Food:Groceries\","
            + "\"AUD\",\"65\",\"*\",\"\"\n")
    }

    @Test("prices and pricedb render the price history")
    func prices() throws {
        #expect(try run("prices") == "2026/01/20 BHP 42.10 AUD\n")
        #expect(try run("pricedb") == "P 2026/01/20 00:00:00 BHP 42.10 AUD\n")
    }

    @Test("print re-emits matching transactions as a journal")
    func print() throws {
        let text = try run("print", ["Groceries"])
        #expect(text.contains("2026/01/10 * (42) Grocery Store"))
        #expect(text.contains("Expenses:Food:Groceries"))
        // Re-parseable.
        let reparsed = LedgerParserFacade.parse(text)
        #expect(reparsed)
    }

    @Test("equity states the balances as one opening transaction")
    func equity() throws {
        let text = try run("equity", ["Bank"])
        #expect(text.contains("Opening Balances"))
        #expect(text.contains("Assets:Bank:Everyday"))
        #expect(text.contains("Equity:Opening Balances"))
    }

    @Test("cleared shows outstanding, cleared, and the last cleared date")
    func cleared() throws {
        let text = try run("cleared", ["Everyday"])
        #expect(text.contains("Assets:Bank:Everyday"))
        #expect(text.contains("26-Jan-10"))   // last cleared posting
        #expect(text.contains("---"))
    }

    @Test("stats summarises the matched postings")
    func stats() throws {
        let text = try run("stats")
        #expect(text.contains("Number of transactions: 5"))
        #expect(text.contains("Unique accounts:"))
    }

    @Test("--sort orders the register, with a leading - reversing")
    func sorting() throws {
        var options = CLIOptions(); options.sortKeys = ["-date"]; options.columns = 80
        let text = try run("register", ["Bank"], options: options)
        let firstLine = text.split(separator: "\n").first ?? ""
        #expect(firstLine.contains("26-Feb-14"))
    }
}

/// Tiny helper so a golden test can assert re-parseability without importing
/// the codec's internals into every case.
enum LedgerParserFacade {
    static func parse(_ text: String) -> Bool {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("ledger")
        guard (try? text.write(to: source, atomically: true, encoding: .utf8)) != nil
        else { return false }
        defer { try? FileManager.default.removeItem(at: source) }
        return (try? SourceLoader.load(paths: [source.path], today: Date())) != nil
    }
}

@Suite("finlens read-only guarantee (ADR-L2)")
struct CLIReadOnlyTests {

    @Test("Reading a book leaves the file byte-identical and takes no lock")
    func readOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteDocumentStore(path: url.path)
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Food", type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 1, 5), description: "Shop")
        txn.addSplit(Split(account: food, value: dec("10.00")))
        txn.addSplit(Split(account: bank, value: dec("-10.00")))
        book.addTransaction(txn)
        try store.write(book)

        let before = try Data(contentsOf: url)
        let driver = CLIDriver(today: day(2026, 3, 1), environment: [:])
        let output = driver.run(arguments: ["-f", url.path, "bal"])

        #expect(output.status == 0)
        #expect(output.text.contains("10.00 AUD"))
        #expect(try Data(contentsOf: url) == before)
        let lockURL = url.deletingPathExtension().appendingPathExtension("lock")
        #expect(!FileManager.default.fileExists(atPath: lockURL.path))
    }

    @Test("A missing source and an unknown command exit 1 with a message")
    func exitCodes() {
        let driver = CLIDriver(today: Date(), environment: [:])
        let noFile = driver.run(arguments: ["bal"])
        #expect(noFile.status == 1)
        #expect(noFile.errorText.contains("no source file"))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("ledger")
        try? "2026/01/01 X\n    A  1.00 AUD\n    B\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let unknown = driver.run(arguments: ["-f", url.path, "frobnicate"])
        #expect(unknown.status == 1)
        #expect(unknown.errorText.contains("unknown command"))

        let version = driver.run(arguments: ["--version"])
        #expect(version.status == 0)
        #expect(version.text.contains("finlens"))
    }

    @Test("A journal with errors fails the run, naming file:line")
    func journalErrors() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("ledger")
        try? """
        2026/01/01 Unbalanced
            Expenses:Food   10.00 AUD
            Assets:Cash     -9.00 AUD
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let driver = CLIDriver(today: Date(), environment: [:])
        let output = driver.run(arguments: ["-f", url.path, "bal"])
        #expect(output.status == 1)
        #expect(output.errorText.contains("does not balance"))
    }
}

/// The one place still paying ADR-8's network cost, closed 15 Aug 2026.
///
/// ADR-L2 makes the CLI take no lock and no working copy. That is right for
/// safety and expensive over a network: `finlens stats` on the 54 MB reference
/// book took 40.6 s across SMB against the app's 3.5 s, and only 2.0 s of that
/// was CPU — the rest is SQLite's small random reads paying latency one at a
/// time. `SourceLoader.readBook` now takes a local copy first when the book
/// lives on a network volume, which keeps both of ADR-L2's promises: no lock,
/// and the book itself is never written to.
@Suite("finlens book reading")
struct CLIBookReadTests {

    /// A local book is read in place — the hop is 0 ms on APFS, where a copy is
    /// a clone, so there is nothing to win and a scratch directory to lose.
    @Test("A local book reads in place and reads correctly")
    func localBookReadsInPlace() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteDocumentStore(path: url.path)
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Everyday", type: .bank, commodity: .aud))
        let food = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 1, 5), description: "Shop")
        txn.addSplit(Split(account: food, value: dec("10.00")))
        txn.addSplit(Split(account: bank, value: dec("-10.00")))
        book.addTransaction(txn)
        try store.write(book)

        let read = try SourceLoader.readBook(at: url.path)
        #expect(read.accounts.contains { $0.name == "Everyday" })
        #expect(read.transactions.count == 1)

        // Reading leaves nothing behind — a read-only tool must not strew
        // copies of someone's book through the temp directory.
        let strays = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path))?
            .filter { $0.hasPrefix("finlens-") } ?? []
        #expect(strays.isEmpty)
    }

    /// The whole book comes back in memory, so the copy — when one is taken —
    /// can be removed the moment `readBook` returns.
    @Test("A read returns the book detached from its file")
    func readIsDetached() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")

        let store = try SQLiteDocumentStore(path: url.path)
        let book = Book(baseCurrency: .aud)
        _ = book.addAccount(Account(name: "Everyday", type: .bank, commodity: .aud))
        try store.write(book)

        let read = try SourceLoader.readBook(at: url.path)
        try FileManager.default.removeItem(at: url)
        // Still answerable with the file gone.
        #expect(read.accounts.contains { $0.name == "Everyday" })
    }
}
