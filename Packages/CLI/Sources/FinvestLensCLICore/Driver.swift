//
//  Driver.swift
//  FinvestLens — CLI
//
//  Command dispatch, the interactive REPL (design §5.3a), and the exit-code
//  contract: 0 success, 1 any error, warnings to stderr never changing it
//  (docs/ledger-cli-reference.md §9). Loading the sources and running one
//  command are deliberately separate — the REPL loads once and runs many.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public struct CLIOutput: Sendable {
    public var text = ""
    public var errorText = ""
    public var status: Int32 = 0
}

public struct CLIDriver {
    public var today: Date
    public var environment: [String: String]

    public init(today: Date = Date(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.today = today
        self.environment = environment
    }

    public static let version = "finlens 0.2 (FinvestLens P10d)"

    /// One whole invocation, argv-tail in, output + exit status out.
    public func run(arguments: [String]) -> CLIOutput {
        var output = CLIOutput()
        var invocation: CLIInvocation
        do {
            invocation = try CLIParser.parse(arguments)
        } catch {
            output.errorText = "finlens: \(error)\n"
            output.status = 1
            return output
        }

        if invocation.wantsVersion {
            output.text = Self.version + "\n"
            return output
        }
        if invocation.wantsHelp || (invocation.command == nil && arguments.isEmpty
            && environment["FINLENS_FILE"] == nil) {
            output.text = Self.helpText
            return output
        }

        // Init file and `FINLENS_*` defaults sit *under* argv: they are the
        // base the command line overrides (see InitFile).
        if !invocation.skipInitFile {
            let defaults = InitFile.defaults(explicitPath: invocation.initFile,
                                             environment: environment)
            for warning in defaults.warnings { output.errorText += warning + "\n" }
            var merged = defaults.options
            merged.merge(invocation.options)
            invocation.options = merged
            if invocation.files.isEmpty { invocation.files = defaults.files }
        }

        let paths = SourceLoader.resolvePaths(invocation.files, environment: environment)
        let loaded: LoadedSource
        do {
            loaded = try SourceLoader.load(paths: paths, today: today)
        } catch {
            output.errorText = "finlens: \(error)\n"
            output.status = 1
            return output
        }

        // Journal warnings ride to stderr without changing the status.
        for diagnostic in loaded.extras.diagnostics where diagnostic.severity == .warning {
            output.errorText += "finlens: \(diagnostic)\n"
        }

        guard let command = invocation.command else {
            // No command: the interactive REPL (design §5.3a).
            return repl(loaded: loaded, base: invocation.options, initial: output)
        }

        var result = execute(command: command, terms: invocation.queryTerms,
                             options: invocation.options, loaded: loaded)
        result.errorText = output.errorText + result.errorText
        if let path = invocation.options.output, result.status == 0 {
            do {
                try result.text.write(toFile: path, atomically: true, encoding: .utf8)
                result.text = ""
            } catch {
                result.errorText += "finlens: cannot write '\(path)': \(error.localizedDescription)\n"
                result.status = 1
            }
        }
        return result
    }

    /// Runs one command against already-loaded sources.
    public func execute(command: String, terms: [String], options: CLIOptions,
                        loaded: LoadedSource) -> CLIOutput {
        var output = CLIOutput()
        let query = QueryParser.parse(terms)

        // `-l/--limit` and `-d/--display` value expressions (P10d).
        var limit: ValueExpression?
        var displayExpression: ValueExpression?
        do {
            if let text = options.limit { limit = try ValueExpressionParser.parse(text) }
            if let text = options.display { displayExpression = try ValueExpressionParser.parse(text) }
        } catch {
            output.errorText = "finlens: \(error)\n"
            output.status = 1
            return output
        }

        // `--budget` / `--unbudgeted` narrow the account set for the ordinary
        // reports (the `budget` command has its own columns instead).
        var effectiveQuery = query
        if options.budget || options.unbudgeted,
           ["balance", "bal", "b", "register", "reg", "r"].contains(command.lowercased()) {
            let narrowed = budgetFilteredTerms(terms, options: options, source: loaded)
            if narrowed != terms { effectiveQuery = QueryParser.parse(narrowed) }
        }

        let request = ReportRequest(options: options, query: effectiveQuery, today: today,
                                    limit: limit, displayExpression: displayExpression)

        // `--forecast` reports generated postings alongside the real ones.
        var forecast: [Transaction] = []
        if let forecastText = options.forecast {
            let templates = BudgetRenderers.templates(book: loaded.book,
                                                      extras: loaded.extras, today: today)
            if templates.isEmpty {
                output.errorText += "finlens: --forecast needs periodic (~) entries or budgets\n"
            } else {
                do {
                    forecast = try forecastTransactions(loaded.book, templates: templates,
                                                        whileText: forecastText,
                                                        years: options.forecastYears ?? 5)
                } catch {
                    output.errorText = "finlens: \(error)\n"
                    output.status = 1
                    return output
                }
            }
        }
        let pipeline = ReportPipeline(book: loaded.book, request: request,
                                      extraTransactions: forecast)

        switch command.lowercased() {
        case "balance", "bal", "b":
            output.text = Renderers.balance(pipeline, book: loaded.book)
        case "register", "reg", "r":
            output.text = Renderers.register(pipeline, book: loaded.book)
        case "print":
            output.text = Renderers.print(pipeline, book: loaded.book, extras: loaded.extras)
        case "csv":
            output.text = Renderers.csv(pipeline)
        case "accounts":
            output.text = Renderers.accounts(pipeline)
        case "payees":
            output.text = Renderers.payees(pipeline)
        case "commodities":
            output.text = Renderers.commodities(pipeline)
        case "prices":
            output.text = Renderers.prices(pipeline, book: loaded.book, asDatabase: false)
        case "pricedb":
            output.text = Renderers.prices(pipeline, book: loaded.book, asDatabase: true)
        case "stats", "stat":
            output.text = Renderers.stats(pipeline, book: loaded.book, sources: loaded.descriptions)
        case "equity":
            output.text = Renderers.equity(pipeline, book: loaded.book)
        case "cleared":
            output.text = Renderers.cleared(pipeline, book: loaded.book)
        case "budget":
            output.text = BudgetRenderers.budget(pipeline, book: loaded.book, extras: loaded.extras)
        case "xact", "entry", "draft":
            let (text, status) = BudgetRenderers.xact(terms, book: loaded.book, today: today)
            if status == 0 { output.text = text } else { output.errorText = text }
            output.status = status
        case "source":
            // Parse-check: loading already succeeded, so this is a clean exit.
            output.text = "\(loaded.book.transactions.count) transactions, "
                + "\(loaded.book.accounts.count) accounts read without error\n"
        default:
            output.errorText = "finlens: unknown command '\(command)' (try 'finlens --help')\n"
            output.status = 1
        }
        return output
    }

    /// `--budget` restricts balance/register to budgeted accounts and
    /// `--unbudgeted` to the rest. (`--add-budget` belongs to the `budget`
    /// command, where it adds the unbudgeted accounts to the comparison.)
    func budgetFilteredTerms(_ terms: [String], options: CLIOptions,
                             source: LoadedSource) -> [String] {
        guard options.budget || options.unbudgeted else { return terms }
        let templates = BudgetRenderers.templates(book: source.book,
                                                  extras: source.extras, today: today)
        let budgeted = Set(templates.flatMap { $0.postings.map(\.account) })
        guard !budgeted.isEmpty else { return terms }
        let patterns = budgeted.map { "^" + NSRegularExpression.escapedPattern(for: $0) + "$" }
        if options.budget { return terms + ["and", "("] + patterns + [")"] }
        return terms + ["and", "not", "("] + patterns + [")"]
    }

    /// Forecast transactions generated from the periodic entries while the
    /// `--forecast` predicate holds. They are returned, never added to the
    /// book: the CLI is read-only and the REPL reuses one `Book`.
    func forecastTransactions(_ book: Book, templates: [BudgetTemplate],
                              whileText: String, years: Int) throws -> [Transaction] {
        let calendar = PeriodExpression.utc
        let lastReal = book.transactions.map(\.datePosted).max() ?? today
        let horizon = calendar.date(byAdding: .year, value: max(1, years), to: lastReal) ?? lastReal
        let generated = PeriodicEntries.forecast(templates, from: lastReal,
                                                 limit: horizon, today: today)
        guard !generated.isEmpty else { return [] }

        // `--forecast EXPR` keeps generating while EXPR holds; ledger writes
        // it over the date (`d<[2027]`), so `d` is spelled out for the parser.
        let predicate = try ValueExpressionParser.parse(
            whileText.replacingOccurrences(of: "d<", with: "date<")
                .replacingOccurrences(of: "d>", with: "date>")
                .replacingOccurrences(of: "d=", with: "date=")
                .replacingOccurrences(of: "d ", with: "date "))

        var accounts: [String: Account] = [:]
        for account in book.accounts { accounts[account.fullName] = account }
        let counterAccount = accounts["Equity:Forecast"]
            ?? book.accounts.first { $0.type == .equity }

        var result: [Transaction] = []
        for entry in generated {
            // A projection starts after the real data ends: the bucket the
            // last real posting falls in is already history.
            guard entry.date > lastReal, let account = accounts[entry.account] else { continue }
            let currency = book.commodities.first { $0.mnemonic == entry.commodity }
                ?? book.baseCurrency
            let transaction = Transaction(currency: currency, datePosted: entry.date,
                                          description: "Forecast")
            let split = Split(account: account, value: entry.amount)
            transaction.addSplit(split)
            // The projection balances into equity: it is a what-if, not a
            // booked double entry, but it must still balance to report.
            if let counterAccount {
                transaction.addSplit(Split(account: counterAccount, value: -entry.amount))
            }
            let context = ExpressionContext(split: split, transaction: transaction,
                                            amount: entry.amount, total: 0)
            guard predicate.matches(context, today: today) else { continue }
            result.append(transaction)
        }
        return result
    }

    // MARK: REPL

    /// Ledger's interactive mode: sources are read once, then one command per
    /// prompt. `push`/`pop` layer option settings; `reload` re-reads.
    func repl(loaded: LoadedSource, base: CLIOptions, initial: CLIOutput) -> CLIOutput {
        var output = initial
        var sources = loaded
        var stack: [CLIOptions] = []
        var current = base

        FileHandle.standardError.write(Data((output.errorText).utf8))
        output.errorText = ""
        Swift.print(Self.version)
        Swift.print("Reading \(sources.descriptions.joined(separator: ", ")) — "
            + "\(sources.book.transactions.count) transactions. "
            + "Type a command (bal, reg, print…), 'quit' to exit.")

        while true {
            Swift.print("finlens> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else { break }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else { continue }

            switch first.lowercased() {
            case "quit", "exit", "q":
                return output
            case "push":
                stack.append(current)
                if let parsed = try? CLIParser.parse(Array(words.dropFirst())) {
                    current.merge(parsed.options)
                }
                continue
            case "pop":
                if let restored = stack.popLast() { current = restored }
                continue
            case "reload":
                if let reloaded = try? SourceLoader.load(paths: SourceLoader.resolvePaths(
                    [], environment: environment).isEmpty
                    ? sources.descriptions : SourceLoader.resolvePaths([], environment: environment),
                    today: today) {
                    sources = reloaded
                    Swift.print("Reloaded \(sources.book.transactions.count) transactions.")
                } else {
                    Swift.print("Could not reload the sources.")
                }
                continue
            case "help", "?":
                Swift.print(Self.helpText, terminator: "")
                continue
            default: break
            }

            guard let parsed = try? CLIParser.parse(words) else {
                Swift.print("finlens: could not parse that line")
                continue
            }
            var options = current
            options.merge(parsed.options)
            let result = execute(command: parsed.command ?? "balance",
                                 terms: parsed.queryTerms, options: options, loaded: sources)
            if !result.text.isEmpty { Swift.print(result.text, terminator: "") }
            if !result.errorText.isEmpty {
                FileHandle.standardError.write(Data(result.errorText.utf8))
            }
        }
        return output
    }

    // MARK: Help

    public static let helpText = """
    finlens — read-only ledger-style reporting over FinvestLens books,
    Ledger journals, and GnuCash files.

    USAGE
      finlens [OPTIONS] COMMAND [QUERY...]
      finlens -f Book.finvestlens              (no command: interactive REPL)

    SOURCES
      -f, --file FILE      .finvestlens (read-only), .ledger/.journal/.dat,
                           .gnucash, or - for a journal on stdin. Repeatable
                           for journals. Falls back to $FINLENS_FILE.
                           A book is opened read-only: no lock is taken and
                           nothing is ever written. (A read racing the app's
                           save sees the pre-save file.)

    COMMANDS
      balance (bal, b)     account balances as an indented tree
      register (reg, r)    one line per posting, with a running total
      print                the matching transactions as a Ledger journal
      csv                  one CSV row per posting
      accounts | payees | commodities     sorted names (--count for tallies)
      prices | pricedb     price history (--latest for the newest each)
      stats                a summary of the matched postings
      equity               balances as one opening-balances transaction
      cleared              outstanding vs cleared balances, with last dates
      budget               actual vs budgeted, remaining, and percent used
      xact [DATE] PAYEE [ACCOUNT] AMOUNT…   a draft modelled on a past
                           transaction, printed (never saved)
      source               parse-check the sources (exit 0/1)

    QUERY
      Bare terms are account regexes, ORed together. Also: and / or / not with
      parentheses, payee REGEX (or @REGEX), tag REGEX (%REGEX, tag K=V),
      code REGEX (#REGEX), note REGEX (=REGEX). Trailing 'for PERIOD',
      'since DATE', 'until DATE' and 'show TERMS' sections are honoured.

    DATES
      -b, --begin DATE     on/after DATE
      -e, --end DATE       before DATE (exclusive, as in ledger)
      -p, --period EXPR    e.g. "monthly", "last month", "from 2026/01 to may"
      -D -W -M --quarterly -Y    interval shortcuts
      --now DATE           treat DATE as today

    FILTERS
      -C --cleared   -U --uncleared   --pending   -R --real   -r --related

    VALUATION
      -V --market    -X CODE (or A:B)   -B --basis   -H --historical

    DISPLAY
      --flat  --depth N  -E --empty  --no-total  -%  -n --collapse
      -s --subtotal  -A --average  -S KEY[,KEY]  --head N  --tail N
      --columns N  -w  --date-width/--payee-width/--account-width/--amount-width
      -y --date-format FMT   -o --output FILE   --color / --no-color

    EXPRESSIONS
      -l, --limit EXPR     keep only postings where EXPR holds (affects totals)
      -d, --display EXPR   show only rows where EXPR holds (totals unchanged)
      EXPR reads: amount total date account payee note code cleared pending
      real depth abs(x), with < <= > >= == != and & | ! and parentheses.
      Literals: 12.50, "text", /regex/, [2026/07/01] or [last month].

    BUDGET & FORECAST
      --budget             only accounts a ~ entry (or a book Budget) covers
      --unbudgeted         only accounts none covers (with actuals)
      --add-budget         budget: add the unbudgeted accounts to the table
      --forecast EXPR      project the ~ entries forward while EXPR holds
      --forecast-years N   hard stop for the projection (default 5)

    DEFAULTS
      ~/.finlensrc (or ./.finlensrc, or --init-file PATH) holds one option per
      line; FINLENS_* variables map to the same options (FINLENS_FILE names the
      source). Both sit under the command line: a typed flag always wins.
      --no-init-file ignores them. Full reference: docs/cli.md.

    select, convert, and format strings (-F) are not implemented; see
    docs/ledger-design.md §5.4.

    """
}
