//
//  InitFile.swift
//  FinvestLens — CLI
//
//  Ledger reads `~/.ledgerrc` before argv and lets `LEDGER_*` variables stand
//  in for options; `finlens` reads `~/.finlensrc` (or `$FINLENS_INIT_FILE`,
//  or `./.finlensrc`) and `FINLENS_*` the same way. Precedence, weakest to
//  strongest: init file → environment → command line — so a flag typed at the
//  prompt always wins (docs/cli.md).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum InitFile {

    /// The init file's path: `--init-file`, else `$FINLENS_INIT_FILE`, else
    /// `./.finlensrc` if present, else `~/.finlensrc`.
    public static func path(explicit: String?, environment: [String: String],
                            fileManager: FileManager = .default) -> String? {
        if let explicit { return explicit }
        if let fromEnvironment = environment["FINLENS_INIT_FILE"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        let local = fileManager.currentDirectoryPath + "/.finlensrc"
        if fileManager.fileExists(atPath: local) { return local }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let user = home + "/.finlensrc"
        return fileManager.fileExists(atPath: user) ? user : nil
    }

    /// The argv-shaped tokens an init file holds: one option per line,
    /// `--option value` or `--option=value`, `;`/`#` comments, blank lines
    /// ignored. Unlike argv it may not name a command — only defaults.
    public static func tokens(text: String) -> [String] {
        var tokens: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let comment = line.firstIndex(where: { $0 == ";" || $0 == "#" }) {
                line = String(line[..<comment])
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // An unadorned line is still an option: `--` is optional, as in
            // ledgerrc, so `wide` and `--wide` both work.
            let words = splitRespectingQuotes(trimmed)
            guard var first = words.first else { continue }
            if !first.hasPrefix("-") { first = "--" + first }
            tokens.append(first)
            tokens.append(contentsOf: words.dropFirst())
        }
        return tokens
    }

    /// `key value` with a quoted remainder kept whole: `--period "last month"`.
    static func splitRespectingQuotes(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// `FINLENS_<OPTION>` variables, as argv tokens. `FINLENS_FILE` stays with
    /// the source loader; the rest map name-for-name, with `_` for `-`.
    public static func environmentTokens(_ environment: [String: String]) -> [String] {
        var tokens: [String] = []
        for name in environment.keys.sorted() {
            guard name.hasPrefix("FINLENS_"), name != "FINLENS_FILE",
                  name != "FINLENS_INIT_FILE" else { continue }
            guard let value = environment[name], !value.isEmpty else { continue }
            let option = "--" + name.dropFirst("FINLENS_".count)
                .lowercased().replacingOccurrences(of: "_", with: "-")
            // A flag's variable is read as a boolean — `FINLENS_WIDE=false`
            // leaves it off. Everything else passes its value through, even
            // when the value looks boolean (`FINLENS_DEPTH=1`).
            guard !CLIParser.valuelessOptions.contains(option) else {
                if ["true", "1", "yes", "on"].contains(value.lowercased()) {
                    tokens.append(option)
                }
                continue
            }
            tokens.append(option)
            tokens.append(value)
        }
        return tokens
    }

    /// The defaults for one invocation: init-file tokens then environment
    /// tokens, both parsed with the ordinary grammar. Unparseable defaults are
    /// reported, never fatal — a stale rc file must not lock the user out.
    public static func defaults(explicitPath: String?, environment: [String: String],
                                fileManager: FileManager = .default)
        -> (options: CLIOptions, files: [String], warnings: [String]) {
        var options = CLIOptions()
        var files: [String] = []
        var warnings: [String] = []

        func absorb(_ tokens: [String], from source: String) {
            guard !tokens.isEmpty else { return }
            do {
                var parsed = try CLIParser.parse(tokens)
                // `--output` is the one option that makes finlens write to a
                // path — and `./.finlensrc` is read from whatever directory
                // the tool is run in. A dropped-in rc file redirecting output
                // is an arbitrary file overwrite wearing a convenience
                // feature; the redirect stays a per-invocation, typed-at-the-
                // prompt decision (ledger's own docs place --output in argv).
                if let redirected = parsed.options.output {
                    parsed.options.output = nil
                    warnings.append("finlens: ignoring --output \(redirected) in \(source) "
                        + "(--output is command-line only)")
                }
                options.merge(parsed.options)
                files += parsed.files
                if let stray = parsed.command {
                    warnings.append("finlens: ignoring '\(stray)' in \(source) "
                        + "(it may only set options)")
                }
            } catch {
                warnings.append("finlens: \(source): \(error)")
            }
        }

        if let path = path(explicit: explicitPath, environment: environment,
                           fileManager: fileManager),
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            absorb(tokens(text: text), from: path)
        }
        absorb(environmentTokens(environment), from: "the environment")
        return (options, files, warnings)
    }
}
