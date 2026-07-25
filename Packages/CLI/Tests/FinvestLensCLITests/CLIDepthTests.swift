//
//  CLIDepthTests.swift
//  FinvestLens — CLI
//
//  P10d exit criteria: value expressions (`-l`/`-d`), the budget family over
//  `~` entries, `--forecast`, `xact` drafts, and the init file / `FINLENS_*`
//  precedence. The running-total column is the subtle one — `-d` must hide a
//  row without the totals below it moving.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensCLICore

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: m, day: d))!
}

/// A budgeted journal: one `~ Monthly` template, four real transactions, and
/// one account (Entertainment) the template never mentions.
private let budgetJournal = """
commodity AUD
    format 0.00 AUD

~ Monthly
    Expenses:Food                 500.00 AUD
    Expenses:Transport            120.00 AUD
    Assets:Bank

2026/01/05 * Woolworths
    Expenses:Food                 412.30 AUD
    Assets:Bank

2026/01/20 Opal
    Expenses:Transport            140.00 AUD
    Assets:Bank

2026/02/03 Coles
    Expenses:Food                 611.15 AUD
    Assets:Bank

2026/02/11 Netflix
    Expenses:Entertainment         22.99 AUD
    Assets:Bank
"""

private func budgetSource() throws -> LoadedSource {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("ledger")
    try budgetJournal.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return try SourceLoader.load(paths: [url.path], today: day(2026, 3, 1))
}

private func runBudget(_ command: String, _ terms: [String] = [],
                       options: CLIOptions = CLIOptions()) throws -> CLIOutput {
    let driver = CLIDriver(today: day(2026, 3, 1), environment: [:])
    return driver.execute(command: command, terms: terms,
                          options: options, loaded: try budgetSource())
}

// MARK: - Value expressions

@Suite("finlens value expressions")
struct CLIValueExpressionTests {

    // The book owns the account tree: `Account.parent` is weak, so a chain
    // built from locals would deallocate before the expression reads it.
    private let book = Book(baseCurrency: .aud)

    private func account(_ path: String) -> Account {
        var parent = book.rootAccount
        for component in path.split(separator: ":") {
            if let existing = parent.children.first(where: { $0.name == component }) {
                parent = existing
                continue
            }
            let child = Account(name: String(component), type: .expense,
                                commodity: book.baseCurrency)
            parent = book.addAccount(child, under: parent)
        }
        return parent
    }

    private func context(amount: Decimal, total: Decimal = 0, account path: String = "Expenses:Food",
                         payee: String = "Woolworths", date: Date = day(2026, 1, 5),
                         state: ReconcileState = .notReconciled,
                         note: String = "", code: String = "") -> ExpressionContext {
        let transaction = Transaction(currency: book.baseCurrency, datePosted: date,
                                      description: payee)
        transaction.notes = note
        transaction.number = code
        let split = Split(account: account(path), value: amount, reconcileState: state)
        transaction.addSplit(split)
        return ExpressionContext(split: split, transaction: transaction,
                                 amount: amount, total: total)
    }

    @Test("Comparisons over amount and total")
    func comparisons() throws {
        let over = try ValueExpressionParser.parse("amount > 100")
        #expect(over.matches(context(amount: dec("412.30")), today: day(2026, 3, 1)))
        #expect(!over.matches(context(amount: dec("12.50")), today: day(2026, 3, 1)))

        let running = try ValueExpressionParser.parse("total >= 1000")
        #expect(running.matches(context(amount: 1, total: dec("1000")), today: day(2026, 3, 1)))
        #expect(!running.matches(context(amount: 1, total: dec("999.99")), today: day(2026, 3, 1)))
    }

    @Test("Regex and string tests over account, payee, note, code")
    func textTests() throws {
        let today = day(2026, 3, 1)
        #expect(try ValueExpressionParser.parse("account =~ /Food/")
            .matches(context(amount: 1), today: today))
        #expect(try !ValueExpressionParser.parse("account =~ /Transport/")
            .matches(context(amount: 1), today: today))
        #expect(try ValueExpressionParser.parse("payee =~ /^Wool/")
            .matches(context(amount: 1), today: today))
        #expect(try ValueExpressionParser.parse("note =~ /gift/")
            .matches(context(amount: 1, note: "a gift"), today: today))
        #expect(try ValueExpressionParser.parse("code == \"42\"")
            .matches(context(amount: 1, code: "42"), today: today))
    }

    @Test("Booleans, negation, parentheses, and the cleared/pending predicates")
    func booleans() throws {
        let today = day(2026, 3, 1)
        let both = try ValueExpressionParser.parse("amount > 100 and account =~ /Food/")
        #expect(both.matches(context(amount: dec("412.30")), today: today))
        #expect(!both.matches(context(amount: dec("412.30"), account: "Expenses:Transport"),
                              today: today))

        let either = try ValueExpressionParser.parse("(amount > 1000) | (payee =~ /Wool/)")
        #expect(either.matches(context(amount: 1), today: today))

        let negated = try ValueExpressionParser.parse("!(amount > 100)")
        #expect(negated.matches(context(amount: dec("12.50")), today: today))

        #expect(try ValueExpressionParser.parse("cleared")
            .matches(context(amount: 1, state: .reconciled), today: today))
        #expect(try !ValueExpressionParser.parse("cleared")
            .matches(context(amount: 1), today: today))
        #expect(try ValueExpressionParser.parse("pending")
            .matches(context(amount: 1, state: .cleared), today: today))
    }

    @Test("Arithmetic, abs(), and date literals")
    func arithmeticAndDates() throws {
        let today = day(2026, 3, 1)
        #expect(try ValueExpressionParser.parse("abs(amount) > 100")
            .matches(context(amount: dec("-412.30")), today: today))
        #expect(try ValueExpressionParser.parse("amount * 2 > 100")
            .matches(context(amount: dec("60")), today: today))
        #expect(try ValueExpressionParser.parse("date < [2026/02/01]")
            .matches(context(amount: 1), today: today))
        #expect(try !ValueExpressionParser.parse("date >= [2026/02/01]")
            .matches(context(amount: 1), today: today))
        #expect(try ValueExpressionParser.parse("depth == 2")
            .matches(context(amount: 1), today: today))
    }

    @Test("A malformed expression is an error, not a silent pass")
    func malformed() {
        #expect(throws: ValueExpressionError.self) {
            _ = try ValueExpressionParser.parse("amount >")
        }
        #expect(throws: ValueExpressionError.self) {
            _ = try ValueExpressionParser.parse("(amount > 1")
        }
        #expect(throws: ValueExpressionError.self) {
            _ = try ValueExpressionParser.parse("nonesuch > 1")
        }
    }

    @Test("An unparseable -l/-d exits 1 with the parser's message")
    func reportedToTheUser() throws {
        var options = CLIOptions()
        options.limit = "amount >"
        let output = try runBudget("register", [], options: options)
        #expect(output.status == 1)
        #expect(output.errorText.contains("value expression"))
    }
}

// MARK: - -l vs -d

@Suite("finlens -l / -d")
struct CLILimitDisplayTests {

    @Test("-l removes postings from the calculation; -d only from the view")
    func limitVersusDisplay() throws {
        let plain = try runBudget("register", ["Expenses"]).text
        // Every posting, with the running total ending at the full sum.
        #expect(plain.contains("1,186.44"))

        // Only Coles (611.15) survives; under -l it is the whole calculation,
        // so its running total is its own amount.
        var limited = CLIOptions()
        limited.limit = "amount > 500"
        let limitedText = try runBudget("register", ["Expenses"], options: limited).text
        #expect(limitedText.contains("Coles"))
        #expect(!limitedText.contains("Woolworths"))
        #expect(!limitedText.contains("1,163.45"))

        // Under -d the same single row is shown, but the total still counts
        // the rows it hid: 412.30 + 140.00 + 611.15.
        var displayed = CLIOptions()
        displayed.display = "amount > 500"
        let displayedText = try runBudget("register", ["Expenses"], options: displayed).text
        #expect(displayedText.contains("Coles"))
        #expect(!displayedText.contains("Woolworths"))
        #expect(displayedText.contains("1,163.45"))
    }

    @Test("--head/--tail keep the running totals of the whole set")
    func headAndTailTotals() throws {
        var options = CLIOptions()
        options.tail = 1
        let tail = try runBudget("register", ["Expenses"], options: options).text
        // The last row's total is the grand total, not its own amount.
        #expect(tail.contains("1,186.44"))
        #expect(!tail.contains("412.30"))
    }
}

// MARK: - Budget & forecast

@Suite("finlens budget and forecast")
struct CLIBudgetTests {

    @Test("budget compares actual with the ~ entry, per account")
    func budgetColumns() throws {
        var options = CLIOptions()
        options.begin = "2026/01/01"
        options.end = "2026/03/01"
        let text = try runBudget("budget", [], options: options).text

        #expect(text.contains("Actual"))
        #expect(text.contains("Budgeted"))
        #expect(text.contains("Remaining"))
        // Two months at 500.00 against 412.30 + 611.15.
        #expect(text.contains("1,023.45 AUD"))
        #expect(text.contains("1,000.00 AUD"))
        #expect(text.contains("102%"))
        // Transport: 140.00 of 240.00 used.
        #expect(text.contains("58%"))
        // Only budgeted accounts by default…
        #expect(!text.contains("Expenses:Entertainment"))

        // …and --add-budget brings in the ones with actuals but no plan.
        options.addBudget = true
        let withUnbudgeted = try runBudget("budget", [], options: options).text
        #expect(withUnbudgeted.contains("Expenses:Entertainment"))

        // --unbudgeted is the complement.
        options.addBudget = false
        options.unbudgeted = true
        let onlyUnbudgeted = try runBudget("budget", [], options: options).text
        #expect(onlyUnbudgeted.contains("Expenses:Entertainment"))
        #expect(!onlyUnbudgeted.contains("Expenses:Food"))
    }

    @Test("--budget keeps only budgeted accounts, --unbudgeted only the rest")
    func budgetFilters() throws {
        var budgeted = CLIOptions()
        budgeted.budget = true
        let budgetedText = try runBudget("balance", ["Expenses"], options: budgeted).text
        #expect(budgetedText.contains("Food"))
        #expect(!budgetedText.contains("Entertainment"))

        var unbudgeted = CLIOptions()
        unbudgeted.unbudgeted = true
        let unbudgetedText = try runBudget("balance", ["Expenses"], options: unbudgeted).text
        #expect(unbudgetedText.contains("Entertainment"))
        #expect(!unbudgetedText.contains("Food"))
    }

    @Test("A source with no ~ entries and no budgets says so")
    func noTemplates() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("ledger")
        try """
        2026/01/05 Shop
            Expenses:Food   10.00 AUD
            Assets:Cash
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let driver = CLIDriver(today: day(2026, 3, 1), environment: [:])
        let output = driver.run(arguments: ["-f", url.path, "budget"])
        #expect(output.status == 0)
        #expect(output.text.contains("No periodic transactions"))
    }

    @Test("--forecast projects the template forward, starting after real data")
    func forecast() throws {
        var options = CLIOptions()
        options.forecast = "date < [2026/05/01]"
        let text = try runBudget("register", ["Expenses:Food"], options: options).text

        #expect(text.contains("Woolworths"))
        #expect(text.contains("Forecast"))
        // The last real posting is 2026/02/11, so February is history.
        #expect(!text.contains("26-Feb-01"))
        #expect(text.contains("26-Mar-01"))
        #expect(text.contains("26-Apr-01"))
        // The predicate stops it before May.
        #expect(!text.contains("26-May-01"))
    }

    @Test("--forecast leaves the loaded book untouched")
    func forecastIsReadOnly() throws {
        let source = try budgetSource()
        let before = source.book.transactions.count
        let driver = CLIDriver(today: day(2026, 3, 1), environment: [:])
        var options = CLIOptions()
        options.forecast = "date < [2027/01/01]"
        _ = driver.execute(command: "register", terms: [], options: options, loaded: source)
        #expect(source.book.transactions.count == before)
    }
}

// MARK: - print

@Suite("finlens print")
struct CLIPrintQueryTests {

    @Test("print emits only the matching transactions")
    func printHonoursTheQuery() throws {
        let text = try runBudget("print", ["Expenses:Food"]).text
        #expect(text.contains("Woolworths"))
        #expect(text.contains("Coles"))
        // Regression: the query used to be ignored and every transaction
        // printed (the guid it filtered on is written as a note line, not
        // as parsed metadata, so nothing ever matched).
        #expect(!text.contains("Netflix"))
        #expect(!text.contains("Opal"))
    }

    @Test("print includes forecast transactions when they are reported")
    func printIncludesForecasts() throws {
        var options = CLIOptions()
        options.forecast = "date < [2026/05/01]"
        let text = try runBudget("print", ["Expenses:Food"], options: options).text
        #expect(text.contains("Woolworths"))
        #expect(text.contains("Forecast"))
    }
}

// MARK: - xact

@Suite("finlens xact")
struct CLIXactTests {

    @Test("xact copies the most recent match, eliding the balancing leg")
    func draftFromTemplate() throws {
        let output = try runBudget("xact", ["2026/03/15", "Coles"])
        #expect(output.status == 0)
        #expect(output.text.contains("2026/03/15 Coles"))
        #expect(output.text.contains("Expenses:Food"))
        #expect(output.text.contains("611.15 AUD"))
        // The funding leg carries no amount, so the draft always balances.
        let lines = output.text.split(separator: "\n").map(String.init)
        #expect(lines.last?.contains("Assets:Bank") == true)
        #expect(lines.last?.contains("AUD") == false)
    }

    @Test("A bare amount replaces the first non-funding leg")
    func amountSubstitution() throws {
        let output = try runBudget("xact", ["2026/03/15", "Coles", "99.95"])
        #expect(output.text.contains("99.95 AUD"))
        #expect(!output.text.contains("611.15"))
    }

    @Test("An account regex targets which leg an amount replaces")
    func targetedSubstitution() throws {
        let output = try runBudget("xact", ["Opal", "Transport", "77.00"])
        #expect(output.text.contains("77.00 AUD"))
        #expect(output.text.contains("Expenses:Transport"))
    }

    @Test("No match exits 1")
    func noMatch() throws {
        let output = try runBudget("xact", ["Nonesuch"])
        #expect(output.status == 1)
        #expect(output.errorText.contains("no earlier transaction"))
    }
}

// MARK: - Init file and environment

@Suite("finlens init file and FINLENS_* defaults")
struct CLIInitFileTests {

    @Test("One option per line, with or without --, comments and quotes")
    func tokens() {
        let tokens = InitFile.tokens(text: """
        ; a comment
        --wide
        depth 2
        --period "last month"

        # another comment
        """)
        #expect(tokens == ["--wide", "--depth", "2", "--period", "last month"])
    }

    @Test("FINLENS_* variables map to options; flags read as booleans")
    func environmentMapping() {
        let tokens = InitFile.environmentTokens([
            "FINLENS_FILE": "/ignored/here.ledger",       // the loader's job
            "FINLENS_INIT_FILE": "/also/ignored",
            "FINLENS_DEPTH": "3",
            "FINLENS_WIDE": "true",
            "FINLENS_FLAT": "false",                      // a flag, left off
            "FINLENS_DATE_FORMAT": "%Y-%m-%d",
            "PATH": "/usr/bin",
        ])
        #expect(tokens == ["--date-format", "%Y-%m-%d", "--depth", "3", "--wide"])
    }

    @Test("A value that looks boolean is still a value")
    func booleanLookingValue() throws {
        // FINLENS_DEPTH=1 must not be read as the bare flag `--depth`.
        let tokens = InitFile.environmentTokens(["FINLENS_DEPTH": "1"])
        #expect(tokens == ["--depth", "1"])
        let parsed = try CLIParser.parse(tokens)
        #expect(parsed.options.depth == 1)
    }

    @Test("The command line overrides the init file, which overrides nothing else")
    func precedence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finlensrc")
        try "--depth 1\n--flat\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let defaults = InitFile.defaults(explicitPath: url.path, environment: [:])
        #expect(defaults.options.depth == 1)
        #expect(defaults.options.flat)

        // argv wins.
        var merged = defaults.options
        merged.merge(try CLIParser.parse(["--depth", "3"]).options)
        #expect(merged.depth == 3)
        #expect(merged.flat)
    }

    @Test("--no-init-file ignores it, and a bad line warns without failing")
    func skippedAndTolerant() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finlensrc")
        try "--nonesuch\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let defaults = InitFile.defaults(explicitPath: url.path, environment: [:])
        #expect(defaults.warnings.count == 1)
        #expect(defaults.warnings[0].contains("unrecognised option"))

        let invocation = try CLIParser.parse(["--no-init-file", "bal"])
        #expect(invocation.skipInitFile)
    }

    @Test("An init file can name the source, and argv still overrides it")
    func fileFromInitFile() throws {
        let journal = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("ledger")
        try budgetJournal.write(to: journal, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: journal) }

        let rc = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finlensrc")
        try "--file \(journal.path)\n".write(to: rc, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rc) }

        let driver = CLIDriver(today: day(2026, 3, 1), environment: [:])
        let output = driver.run(arguments: ["--init-file", rc.path, "bal", "Expenses:Food"])
        #expect(output.status == 0)
        #expect(output.text.contains("1,023.45"))
    }
}
