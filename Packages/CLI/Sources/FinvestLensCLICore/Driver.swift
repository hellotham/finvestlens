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

    public static let version = "finlens 0.1 (FinvestLens P10c)"

    /// One whole invocation, argv-tail in, output + exit status out.
    public func run(arguments: [String]) -> CLIOutput {
        var output = CLIOutput()
        let invocation: CLIInvocation
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
        if invocation.wantsHelp || (invocation.command == nil && arguments.isEmpty) {
            output.text = Self.helpText
            return output
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
        if terms.contains(where: { $0.lowercased() == "expr" }) {
            output.errorText += "finlens: 'expr' value expressions are not supported "
                + "(see docs/ledger-design.md §5.4); the term was ignored\n"
        }
        let request = ReportRequest(options: options, query: query, today: today)
        let pipeline = ReportPipeline(book: loaded.book, request: request)

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

    Value expressions (-l/-d/-F), select, xact, convert, --budget and
    --forecast are not implemented; see docs/ledger-design.md §5.4.

    """
}
