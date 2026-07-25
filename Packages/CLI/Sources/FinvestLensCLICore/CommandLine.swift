//
//  CommandLine.swift
//  FinvestLens — CLI
//
//  Argument parsing modelled on ledger's (docs/ledger-cli-reference.md §1):
//  options may appear anywhere — before the command, after it, interleaved
//  with query terms — because any argv token starting with `-` is consumed by
//  the option processor and everything else is a positional. Hand-rolled for
//  exactly that reason (design ADR-L1): the shape does not fit a declarative
//  parser, and the dependency budget stays at zero.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Everything one invocation asks for.
public struct CLIInvocation: Sendable {
    public var command: String?
    public var queryTerms: [String] = []
    public var files: [String] = []
    public var options = CLIOptions()
    /// `--help` / `--version` short-circuit everything else.
    public var wantsHelp = false
    public var wantsVersion = false
}

/// The option set the core-80 subset needs (design §5.3).
public struct CLIOptions: Sendable {
    // Dates & periods.
    public var begin: String?
    public var end: String?
    public var period: String?
    public var now: String?

    // State filters.
    public var cleared = false
    public var uncleared = false
    public var pending = false
    public var real = false
    public var related = false

    // Valuation.
    public var market = false            // -V
    public var exchange: [String] = []   // -X CODE (repeatable, incl. A:B)
    public var basis = false             // -B
    public var historical = false        // -H

    // Display.
    public var flat = false
    public var depth: Int?
    public var empty = false
    public var noTotal = false
    public var percent = false
    public var collapse = false
    public var subtotal = false
    public var average = false
    public var sortKeys: [String] = []
    public var head: Int?
    public var tail: Int?
    public var columns: Int?
    public var dateWidth: Int?
    public var payeeWidth: Int?
    public var accountWidth: Int?
    public var amountWidth: Int?
    public var dateFormat: String?
    public var output: String?
    public var color: Bool?              // nil = auto (TTY)
    public var raw = false               // print --raw
    public var count = false             // accounts/payees/commodities --count
    public var latest = false            // prices --latest
}

public enum CLIParseError: Error, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(String)
    case badValue(String, String)

    public var description: String {
        switch self {
        case .unknownOption(let option):
            "unrecognised option '\(option)' (try 'finlens --help')"
        case .missingValue(let option):
            "option '\(option)' needs a value"
        case .badValue(let option, let value):
            "option '\(option)' cannot take '\(value)'"
        }
    }
}

public enum CLIParser {

    /// Parses one argv tail (excluding the program name), or the words of one
    /// REPL line — the same grammar serves both.
    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var invocation = CLIInvocation()
        var positionals: [String] = []
        var index = 0

        func value(for option: String, inline: String?) throws -> String {
            if let inline { return inline }
            index += 1
            guard index < arguments.count else { throw CLIParseError.missingValue(option) }
            return arguments[index]
        }
        func intValue(for option: String, inline: String?) throws -> Int {
            let text = try value(for: option, inline: inline)
            guard let number = Int(text) else { throw CLIParseError.badValue(option, text) }
            return number
        }

        while index < arguments.count {
            let argument = arguments[index]
            defer { index += 1 }

            guard argument.hasPrefix("-"), argument != "-" else {
                positionals.append(argument)
                continue
            }

            // `--option=value` and short clusters like `-Mn`.
            var name = argument
            var inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            }

            switch name {
            case "--help", "-h": invocation.wantsHelp = true
            case "--version": invocation.wantsVersion = true

            case "--file", "-f":
                invocation.files.append(try value(for: name, inline: inline))

            case "--begin", "-b": invocation.options.begin = try value(for: name, inline: inline)
            case "--end", "-e": invocation.options.end = try value(for: name, inline: inline)
            case "--period", "-p": invocation.options.period = try value(for: name, inline: inline)
            case "--now": invocation.options.now = try value(for: name, inline: inline)
            case "--daily", "-D": invocation.options.period = "daily"
            case "--weekly", "-W": invocation.options.period = "weekly"
            case "--monthly", "-M": invocation.options.period = "monthly"
            case "--quarterly": invocation.options.period = "quarterly"
            case "--yearly", "-Y": invocation.options.period = "yearly"

            case "--cleared", "-C": invocation.options.cleared = true
            case "--uncleared", "-U": invocation.options.uncleared = true
            case "--pending": invocation.options.pending = true
            case "--real", "-R": invocation.options.real = true
            case "--related", "-r": invocation.options.related = true

            case "--market", "-V": invocation.options.market = true
            case "--exchange", "-X":
                invocation.options.exchange.append(try value(for: name, inline: inline))
            case "--basis", "--cost", "-B": invocation.options.basis = true
            case "--historical", "-H": invocation.options.historical = true

            case "--flat": invocation.options.flat = true
            case "--depth": invocation.options.depth = try intValue(for: name, inline: inline)
            case "--empty", "-E": invocation.options.empty = true
            case "--no-total": invocation.options.noTotal = true
            case "--percent", "-%": invocation.options.percent = true
            case "--collapse", "-n": invocation.options.collapse = true
            case "--subtotal", "-s": invocation.options.subtotal = true
            case "--average", "-A": invocation.options.average = true
            case "--sort", "-S":
                let keys = try value(for: name, inline: inline)
                invocation.options.sortKeys = keys.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--head", "--first": invocation.options.head = try intValue(for: name, inline: inline)
            case "--tail", "--last": invocation.options.tail = try intValue(for: name, inline: inline)
            case "--columns": invocation.options.columns = try intValue(for: name, inline: inline)
            case "--wide", "-w": invocation.options.columns = 132
            case "--date-width": invocation.options.dateWidth = try intValue(for: name, inline: inline)
            case "--payee-width": invocation.options.payeeWidth = try intValue(for: name, inline: inline)
            case "--account-width": invocation.options.accountWidth = try intValue(for: name, inline: inline)
            case "--amount-width": invocation.options.amountWidth = try intValue(for: name, inline: inline)
            case "--date-format", "-y": invocation.options.dateFormat = try value(for: name, inline: inline)
            case "--output", "-o": invocation.options.output = try value(for: name, inline: inline)
            case "--color", "--ansi": invocation.options.color = true
            case "--no-color": invocation.options.color = false
            case "--raw": invocation.options.raw = true
            case "--count": invocation.options.count = true
            case "--latest": invocation.options.latest = true

            default:
                // A short cluster of flags: -Cn, -Mw…
                if !name.hasPrefix("--"), name.count > 2, inline == nil {
                    let letters = name.dropFirst().map { "-\($0)" }
                    guard letters.allSatisfy({ Self.isKnownShortFlag($0) }) else {
                        throw CLIParseError.unknownOption(argument)
                    }
                    var expanded = try parse(letters)
                    expanded.files = []
                    invocation.options.merge(expanded.options)
                    if expanded.wantsHelp { invocation.wantsHelp = true }
                    continue
                }
                throw CLIParseError.unknownOption(argument)
            }
        }

        if let first = positionals.first {
            invocation.command = first
            invocation.queryTerms = Array(positionals.dropFirst())
        }
        return invocation
    }

    /// Short options that take no value (the only ones a cluster may hold).
    static func isKnownShortFlag(_ flag: String) -> Bool {
        ["-C", "-U", "-R", "-r", "-V", "-B", "-H", "-E", "-n", "-s", "-A",
         "-w", "-D", "-W", "-M", "-Y", "-h"].contains(flag)
    }
}

extension CLIOptions {
    /// Folds another option set's non-default values into this one — used to
    /// expand short clusters, and by the REPL's `push`/`pop`.
    mutating func merge(_ other: CLIOptions) {
        if other.begin != nil { begin = other.begin }
        if other.end != nil { end = other.end }
        if other.period != nil { period = other.period }
        if other.now != nil { now = other.now }
        cleared = cleared || other.cleared
        uncleared = uncleared || other.uncleared
        pending = pending || other.pending
        real = real || other.real
        related = related || other.related
        market = market || other.market
        exchange += other.exchange
        basis = basis || other.basis
        historical = historical || other.historical
        flat = flat || other.flat
        if other.depth != nil { depth = other.depth }
        empty = empty || other.empty
        noTotal = noTotal || other.noTotal
        percent = percent || other.percent
        collapse = collapse || other.collapse
        subtotal = subtotal || other.subtotal
        average = average || other.average
        if !other.sortKeys.isEmpty { sortKeys = other.sortKeys }
        if other.head != nil { head = other.head }
        if other.tail != nil { tail = other.tail }
        if other.columns != nil { columns = other.columns }
        if other.dateWidth != nil { dateWidth = other.dateWidth }
        if other.payeeWidth != nil { payeeWidth = other.payeeWidth }
        if other.accountWidth != nil { accountWidth = other.accountWidth }
        if other.amountWidth != nil { amountWidth = other.amountWidth }
        if other.dateFormat != nil { dateFormat = other.dateFormat }
        if other.output != nil { output = other.output }
        if other.color != nil { color = other.color }
        raw = raw || other.raw
        count = count || other.count
        latest = latest || other.latest
    }
}
