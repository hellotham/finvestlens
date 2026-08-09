//
//  LabDriver.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Where a command's output goes.
///
/// A closure rather than `print`, for two reasons: a long ingestion run wants
/// its lines *now* rather than in one block at the end, and a test wants to
/// read them back.
public typealias LabLog = @MainActor (String) -> Void

/// Parsed `--flag value` arguments.
///
/// Small on purpose. `finlens` needs a real grammar because it implements
/// Ledger's; this tool has four verbs and a handful of switches, and a hundred
/// lines of parser would be a hundred lines to keep right.
public struct LabOptions {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    public private(set) var positional: [String] = []

    public init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                index += 1
                continue
            }
            let name = String(argument.dropFirst(2))
            // `--flag=value` and `--flag value` both work; a `--flag` followed
            // by another `--flag` is a boolean.
            if let equals = name.firstIndex(of: "=") {
                values[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
            } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[name] = arguments[index + 1]
                index += 1
            } else {
                flags.insert(name)
            }
            index += 1
        }
    }

    public func string(_ name: String) -> String? { values[name] }
    public func flag(_ name: String) -> Bool { flags.contains(name) }
    public func int(_ name: String) -> Int? { values[name].flatMap(Int.init) }

    /// A file URL from `name`, tilde-expanded and made absolute.
    public func url(_ name: String) -> URL? {
        guard let raw = values[name] else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// A `YYYY-MM-DD` date.
    public func date(_ name: String) -> Date? {
        guard let raw = values[name] else { return nil }
        return LabOptions.dayFormatter.date(from: raw)
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// The `finlab` command table.
public enum Lab {

    public static let usage = """
        finlab — headless FinvestLens book maintenance (the write side of finlens)

        USAGE
          finlab import   --from BOOK.gnucash --to BOOK.finvestlens [--break-lock] [--force]
                          [--mode document|direct]
          finlab bench    --file BOOK.finvestlens [--save] [--repeat N]
          finlab prices   --file BOOK.finvestlens [--provider yahoo|stooq] [--dry-run]
          finlab documents --file BOOK.finvestlens --root DIR
                          [--since YYYY-MM-DD] [--until YYYY-MM-DD]
                          [--kind any|invoice|dividend] [--limit N] [--batch N]
                          [--attachments DIR] [--fx NZD=0.905,MYR=0.34] [--apply] [--report FILE.csv]

        Every command prints its own timings. Nothing is written to the book
        unless the command says it writes, and `documents` writes only with
        --apply.
        """

    /// Runs one invocation. Returns a process exit status.
    @MainActor
    public static func run(arguments: [String], log: LabLog) async -> Int32 {
        guard let verb = arguments.first else {
            log(usage)
            return 1
        }
        let options = LabOptions(Array(arguments.dropFirst()))

        do {
            switch verb {
            case "import":
                try await ImportCommand.run(options, log: log)
            case "bench":
                try await BenchCommand.run(options, log: log)
            case "prices":
                try await PricesCommand.run(options, log: log)
            case "documents", "docs":
                try await DocumentsCommand.run(options, log: log)
            case "help", "--help", "-h":
                log(usage)
            default:
                log("finlab: unknown command '\(verb)'")
                log(usage)
                return 1
            }
        } catch let error as LabError {
            log("finlab: \(error.description)")
            return 1
        } catch {
            log("finlab: \(error.localizedDescription)")
            return 1
        }
        return 0
    }
}

/// What a command refuses to do, and why.
public enum LabError: Error, CustomStringConvertible {
    case missingOption(String)
    case notFound(URL)
    case destinationExists(URL)
    case message(String)

    public var description: String {
        switch self {
        case .missingOption(let name): "missing required option --\(name)"
        case .notFound(let url): "no such file: \(url.path)"
        case .destinationExists(let url):
            "\(url.lastPathComponent) already exists — pass --force to replace it "
            + "(the existing file is moved aside, not deleted)"
        case .message(let text): text
        }
    }
}

extension LabOptions {
    /// A required option, or a refusal naming it.
    func requiredURL(_ name: String) throws -> URL {
        guard let url = url(name) else { throw LabError.missingOption(name) }
        return url
    }

    /// A required option that must already exist on disk.
    func existingURL(_ name: String) throws -> URL {
        let url = try requiredURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LabError.notFound(url) }
        return url
    }
}
