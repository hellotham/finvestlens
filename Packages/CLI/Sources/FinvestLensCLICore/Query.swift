//
//  Query.swift
//  FinvestLens — CLI
//
//  Ledger's query language, the subset the design ships
//  (docs/ledger-cli-reference.md §3): bare terms are account regexes with an
//  implicit OR between them, `and`/`or`/`not` with parentheses, and the
//  keyword/shorthand pairs payee/@, tag/%, code/#, note/=. Trailing `show`,
//  `for`, `since`, `until` sections split off their own predicates.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One posting under test: the split plus its transaction.
public struct QuerySubject {
    public let split: Split
    public let transaction: Transaction

    public init(split: Split, transaction: Transaction) {
        self.split = split
        self.transaction = transaction
    }
}

public indirect enum QueryNode: Sendable {
    case all
    case account(RegexMatcher)
    case payee(RegexMatcher)
    case code(RegexMatcher)
    case note(RegexMatcher)
    case tag(RegexMatcher, value: RegexMatcher?)
    case and(QueryNode, QueryNode)
    case or(QueryNode, QueryNode)
    case not(QueryNode)

    public func matches(_ subject: QuerySubject) -> Bool {
        switch self {
        case .all: true
        case .account(let matcher):
            matcher.matches(subject.split.account?.fullName ?? "")
        case .payee(let matcher):
            matcher.matches(subject.transaction.transactionDescription)
        case .code(let matcher):
            matcher.matches(subject.transaction.number)
        case .note(let matcher):
            matcher.matches(subject.transaction.notes) || matcher.matches(subject.split.memo)
        case .tag(let key, let value):
            subject.transaction.tags.contains { tag in
                guard key.matches(tag) else { return false }
                guard let value else { return true }
                return value.matches(tag)
            }
        case .and(let lhs, let rhs): lhs.matches(subject) && rhs.matches(subject)
        case .or(let lhs, let rhs): lhs.matches(subject) || rhs.matches(subject)
        case .not(let inner): !inner.matches(subject)
        }
    }
}

/// A case-insensitive regex with a literal fallback, so a malformed pattern
/// degrades to substring matching rather than failing the whole run.
public struct RegexMatcher: Sendable {
    private let regex: NSRegularExpression?
    private let literal: String

    public init(_ pattern: String) {
        literal = pattern.lowercased()
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    public func matches(_ text: String) -> Bool {
        guard let regex else { return text.lowercased().contains(literal) }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

/// A parsed query: the predicate plus the trailing sections ledger allows
/// (`for`/`since`/`until` periods, and a `show` display predicate).
public struct ParsedQuery: Sendable {
    public var predicate: QueryNode = .all
    public var display: QueryNode?
    public var periodWords: [String] = []
}

public enum QueryParser {

    public static func parse(_ terms: [String]) -> ParsedQuery {
        var result = ParsedQuery()
        // Split off trailing sections first.
        var main: [String] = []
        var current: String?
        var sections: [String: [String]] = [:]
        for term in terms {
            switch term.lowercased() {
            case "show", "only", "bold", "for", "since", "until":
                current = term.lowercased()
                if current == "since" || current == "until" {
                    sections["period", default: []].append(term.lowercased())
                    current = "period"
                }
                continue
            default: break
            }
            if let key = current == "for" ? "period" : current {
                sections[key, default: []].append(term)
            } else {
                main.append(term)
            }
        }
        result.periodWords = sections["period"] ?? []
        if let show = sections["show"], !show.isEmpty {
            result.display = parseExpression(show)
        }
        result.predicate = parseExpression(main)
        return result
    }

    static func parseExpression(_ terms: [String]) -> QueryNode {
        guard !terms.isEmpty else { return .all }
        var tokens = tokenize(terms)
        var index = 0
        let node = parseOr(&tokens, &index)
        return node ?? .all
    }

    /// Splits parentheses off adjacent words so `(food` lexes as two tokens.
    static func tokenize(_ terms: [String]) -> [String] {
        var out: [String] = []
        for term in terms {
            var current = ""
            for character in term {
                if character == "(" || character == ")" {
                    if !current.isEmpty { out.append(current); current = "" }
                    out.append(String(character))
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    static func parseOr(_ tokens: inout [String], _ index: inout Int) -> QueryNode? {
        var left = parseAnd(&tokens, &index)
        while index < tokens.count {
            let token = tokens[index].lowercased()
            if token == "or" || token == "|" {
                index += 1
                guard let right = parseAnd(&tokens, &index) else { break }
                left = left.map { .or($0, right) } ?? right
            } else if tokens[index] == ")" {
                break
            } else {
                // Adjacent terms are an implicit OR (ledger's rule).
                guard let right = parseAnd(&tokens, &index) else { break }
                left = left.map { .or($0, right) } ?? right
            }
        }
        return left
    }

    static func parseAnd(_ tokens: inout [String], _ index: inout Int) -> QueryNode? {
        var left = parseUnary(&tokens, &index)
        while index < tokens.count {
            let token = tokens[index].lowercased()
            guard token == "and" || token == "&" else { break }
            index += 1
            guard let right = parseUnary(&tokens, &index) else { break }
            left = left.map { .and($0, right) } ?? right
        }
        return left
    }

    static func parseUnary(_ tokens: inout [String], _ index: inout Int) -> QueryNode? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        let lowered = token.lowercased()

        if lowered == "not" || lowered == "!" {
            index += 1
            guard let inner = parseUnary(&tokens, &index) else { return nil }
            return .not(inner)
        }
        if token == "(" {
            index += 1
            let inner = parseOr(&tokens, &index)
            if index < tokens.count, tokens[index] == ")" { index += 1 }
            return inner
        }
        if token == ")" { return nil }

        // Keyword forms take the next token as their pattern.
        switch lowered {
        case "payee", "desc":
            index += 1
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return .payee(RegexMatcher(unquote(tokens[index])))
        case "code":
            index += 1
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return .code(RegexMatcher(unquote(tokens[index])))
        case "note":
            index += 1
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return .note(RegexMatcher(unquote(tokens[index])))
        case "tag", "meta", "data":
            index += 1
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tagNode(unquote(tokens[index]))
        case "expr":
            // Value expressions are out of scope (design NG-L1) — consume the
            // pattern so the rest of the query still parses; the driver warns.
            index += 1
            if index < tokens.count { index += 1 }
            return .all
        default: break
        }

        index += 1
        // Shorthands.
        if token.hasPrefix("@") { return .payee(RegexMatcher(unquote(String(token.dropFirst())))) }
        if token.hasPrefix("%") { return tagNode(unquote(String(token.dropFirst()))) }
        if token.hasPrefix("#") { return .code(RegexMatcher(unquote(String(token.dropFirst())))) }
        if token.hasPrefix("=") { return .note(RegexMatcher(unquote(String(token.dropFirst())))) }
        return .account(RegexMatcher(unquote(token)))
    }

    static func tagNode(_ pattern: String) -> QueryNode {
        // `tag NAME=VALUE` (value regex) / `tag NAME==VALUE` (exact).
        if let range = pattern.range(of: "==") {
            let key = String(pattern[..<range.lowerBound])
            let value = String(pattern[range.upperBound...])
            return .tag(RegexMatcher(key), value: RegexMatcher("^" + NSRegularExpression.escapedPattern(for: value) + "$"))
        }
        if let equals = pattern.firstIndex(of: "=") {
            let key = String(pattern[..<equals])
            let value = String(pattern[pattern.index(after: equals)...])
            return .tag(RegexMatcher(key), value: RegexMatcher(value))
        }
        return .tag(RegexMatcher(pattern), value: nil)
    }

    static func unquote(_ text: String) -> String {
        if text.count >= 2 {
            let first = text.first!, last = text.last!
            if (first == "/" && last == "/") || (first == "\"" && last == "\"")
                || (first == "'" && last == "'") {
                return String(text.dropFirst().dropLast())
            }
        }
        return text
    }
}
