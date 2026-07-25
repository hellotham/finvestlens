//
//  ValueExpression.swift
//  FinvestLens — CLI
//
//  The mini value-expression engine backing `-l/--limit` and `-d/--display`
//  (design §5.4 / docs/ledger-cli-reference.md "Deliberately hard parts":
//  a small typed AST — comparisons, and/or/not, the posting vocabulary,
//  regex match, `[date]` literals — grown deliberately rather than porting
//  ledger's ~80-function language).
//
//  Supported vocabulary:
//    amount total date account payee note code cleared pending real
//    depth  (account path components)
//    abs(EXPR)  and the literals  123.45  "text"  /regex/  [smart date]
//    operators  == != < <= > >=  =~ !~  + - * /  and or not  ( )
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public enum ValueExpressionError: Error, CustomStringConvertible {
    case syntax(String)
    case unknownIdentifier(String)

    public var description: String {
        switch self {
        case .syntax(let detail): "value expression: \(detail)"
        case .unknownIdentifier(let name):
            "value expression: '\(name)' is not one of the supported names "
                + "(amount, total, date, account, payee, note, code, cleared, "
                + "pending, real, depth, abs)"
        }
    }
}

/// A value in the little language: number, string, date, or boolean.
public enum EvaluatedValue: Sendable {
    case number(Decimal)
    case text(String)
    case date(Date)
    case boolean(Bool)

    var truthiness: Bool {
        switch self {
        case .number(let value): value != 0
        case .text(let value): !value.isEmpty
        case .date: true
        case .boolean(let value): value
        }
    }
}

/// What an expression is evaluated against: one posting plus the running
/// total at that point (so `total` works in a register predicate).
public struct ExpressionContext {
    public let split: Split
    public let transaction: Transaction
    public let amount: Decimal
    public let total: Decimal

    public init(split: Split, transaction: Transaction, amount: Decimal, total: Decimal) {
        self.split = split
        self.transaction = transaction
        self.amount = amount
        self.total = total
    }
}

public indirect enum ValueExpression: Sendable {
    case number(Decimal)
    case text(String)
    case regex(RegexMatcher)
    case dateLiteral(String)          // resolved against `today` at evaluation
    case identifier(String)
    case call(String, ValueExpression)
    case binary(String, ValueExpression, ValueExpression)
    case unaryNot(ValueExpression)
    case negate(ValueExpression)

    public func evaluate(_ context: ExpressionContext, today: Date) throws -> EvaluatedValue {
        switch self {
        case .number(let value): return .number(value)
        case .text(let value): return .text(value)
        case .regex: return .boolean(false)   // only meaningful beside =~
        case .dateLiteral(let text):
            guard let date = PeriodExpression.date(text, today: today) else {
                throw ValueExpressionError.syntax("cannot read the date '\(text)'")
            }
            return .date(date)

        case .identifier(let name):
            switch name {
            case "amount": return .number(context.amount)
            case "total": return .number(context.total)
            case "date": return .date(context.transaction.datePosted)
            case "account": return .text(context.split.account?.fullName ?? "")
            case "payee", "desc": return .text(context.transaction.transactionDescription)
            case "note": return .text(context.split.memo.isEmpty
                                      ? context.transaction.notes : context.split.memo)
            case "code": return .text(context.transaction.number)
            case "cleared": return .boolean(context.split.reconcileState == .reconciled)
            case "pending": return .boolean(context.split.reconcileState == .cleared)
            case "real": return .boolean(context.split.kvp["ledger/virtual"] == nil)
            case "depth":
                let path = context.split.account?.fullName ?? ""
                return .number(Decimal(path.isEmpty ? 0 : path.split(separator: ":").count))
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            default: throw ValueExpressionError.unknownIdentifier(name)
            }

        case .call(let name, let argument):
            let value = try argument.evaluate(context, today: today)
            switch name {
            case "abs":
                guard case .number(let number) = value else {
                    throw ValueExpressionError.syntax("abs() needs a number")
                }
                return .number(abs(number))
            default: throw ValueExpressionError.unknownIdentifier(name)
            }

        case .unaryNot(let inner):
            return .boolean(!(try inner.evaluate(context, today: today).truthiness))

        case .negate(let inner):
            guard case .number(let number) = try inner.evaluate(context, today: today) else {
                throw ValueExpressionError.syntax("cannot negate a non-number")
            }
            return .number(-number)

        case .binary(let op, let lhs, let rhs):
            // Regex operators keep their right side unevaluated.
            if op == "=~" || op == "!~" {
                let text = try Self.string(of: lhs.evaluate(context, today: today))
                guard case .regex(let matcher) = rhs else {
                    let pattern = try Self.string(of: rhs.evaluate(context, today: today))
                    let matches = RegexMatcher(pattern).matches(text)
                    return .boolean(op == "=~" ? matches : !matches)
                }
                let matches = matcher.matches(text)
                return .boolean(op == "=~" ? matches : !matches)
            }
            if op == "and" || op == "or" {
                let left = try lhs.evaluate(context, today: today).truthiness
                if op == "and" {
                    guard left else { return .boolean(false) }   // short-circuit
                    return .boolean(try rhs.evaluate(context, today: today).truthiness)
                }
                if left { return .boolean(true) }
                return .boolean(try rhs.evaluate(context, today: today).truthiness)
            }

            let left = try lhs.evaluate(context, today: today)
            let right = try rhs.evaluate(context, today: today)
            switch op {
            case "+", "-", "*", "/":
                let a = try Self.number(of: left), b = try Self.number(of: right)
                switch op {
                case "+": return .number(a + b)
                case "-": return .number(a - b)
                case "*": return .number(a * b)
                default:
                    guard b != 0 else { throw ValueExpressionError.syntax("division by zero") }
                    return .number(a / b)
                }
            case "==", "!=", "<", "<=", ">", ">=":
                let order = try Self.compare(left, right)
                let result: Bool
                switch op {
                case "==": result = order == 0
                case "!=": result = order != 0
                case "<": result = order < 0
                case "<=": result = order <= 0
                case ">": result = order > 0
                default: result = order >= 0
                }
                return .boolean(result)
            default:
                throw ValueExpressionError.syntax("unknown operator '\(op)'")
            }
        }
    }

    static func number(of value: EvaluatedValue) throws -> Decimal {
        switch value {
        case .number(let number): number
        case .boolean(let flag): flag ? 1 : 0
        case .date(let date): Decimal(date.timeIntervalSinceReferenceDate)
        case .text: throw ValueExpressionError.syntax("expected a number, got text")
        }
    }

    static func string(of value: EvaluatedValue) throws -> String {
        switch value {
        case .text(let text): text
        case .number(let number): NSDecimalNumber(decimal: number).stringValue
        case .boolean(let flag): flag ? "true" : "false"
        case .date(let date): LedgerDateFormatting.iso(date)
        }
    }

    static func compare(_ lhs: EvaluatedValue, _ rhs: EvaluatedValue) throws -> Int {
        if case .text(let a) = lhs, case .text(let b) = rhs {
            return a == b ? 0 : (a < b ? -1 : 1)
        }
        if case .date(let a) = lhs, case .date(let b) = rhs {
            return a == b ? 0 : (a < b ? -1 : 1)
        }
        if case .boolean(let a) = lhs, case .boolean(let b) = rhs {
            return a == b ? 0 : (!a ? -1 : 1)
        }
        let a = try number(of: lhs), b = try number(of: rhs)
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    /// Evaluates as a predicate, treating an evaluation failure as "no match"
    /// so one odd posting can't abort a whole report.
    public func matches(_ context: ExpressionContext, today: Date) -> Bool {
        ((try? evaluate(context, today: today))?.truthiness) ?? false
    }
}

// MARK: - Parser

public enum ValueExpressionParser {

    /// Every name the language knows — checked at parse time so a typo is an
    /// error the user sees, not a predicate that quietly matches nothing.
    static let identifiers: Set<String> = [
        "amount", "total", "date", "account", "payee", "desc", "note", "code",
        "cleared", "pending", "real", "depth", "true", "false",
    ]
    static let functions: Set<String> = ["abs"]

    public static func parse(_ text: String) throws -> ValueExpression {
        var tokens = try tokenize(text)
        var index = 0
        let expression = try parseOr(&tokens, &index)
        guard index == tokens.count else {
            throw ValueExpressionError.syntax("unexpected '\(tokens[index].text)'")
        }
        try validate(expression)
        return expression
    }

    static func validate(_ expression: ValueExpression) throws {
        switch expression {
        case .number, .text, .regex, .dateLiteral:
            return
        case .identifier(let name):
            guard identifiers.contains(name) else {
                throw ValueExpressionError.unknownIdentifier(name)
            }
        case .call(let name, let argument):
            guard functions.contains(name) else {
                throw ValueExpressionError.unknownIdentifier(name)
            }
            try validate(argument)
        case .unaryNot(let inner), .negate(let inner):
            try validate(inner)
        case .binary(_, let lhs, let rhs):
            try validate(lhs)
            try validate(rhs)
        }
    }

    struct Token { var kind: Kind; var text: String
        enum Kind { case number, string, regex, date, identifier, op, open, close }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var characters = Array(text)
        var index = 0

        func take(while predicate: (Character) -> Bool) -> String {
            var out = ""
            while index < characters.count, predicate(characters[index]) {
                out.append(characters[index]); index += 1
            }
            return out
        }

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }

            if character == "(" { tokens.append(Token(kind: .open, text: "(")); index += 1; continue }
            if character == ")" { tokens.append(Token(kind: .close, text: ")")); index += 1; continue }

            if character == "\"" || character == "'" {
                let quote = character
                index += 1
                let value = take(while: { $0 != quote })
                guard index < characters.count else {
                    throw ValueExpressionError.syntax("unterminated string")
                }
                index += 1
                tokens.append(Token(kind: .string, text: value))
                continue
            }
            if character == "/" , !(tokens.last.map { $0.kind == .number || $0.kind == .identifier } ?? false) {
                index += 1
                let value = take(while: { $0 != "/" })
                guard index < characters.count else {
                    throw ValueExpressionError.syntax("unterminated regex")
                }
                index += 1
                tokens.append(Token(kind: .regex, text: value))
                continue
            }
            if character == "[" {
                index += 1
                let value = take(while: { $0 != "]" })
                guard index < characters.count else {
                    throw ValueExpressionError.syntax("unterminated date literal")
                }
                index += 1
                tokens.append(Token(kind: .date, text: value))
                continue
            }
            if character.isNumber || (character == "." && index + 1 < characters.count
                                      && characters[index + 1].isNumber) {
                let value = take(while: { $0.isNumber || $0 == "." })
                tokens.append(Token(kind: .number, text: value))
                continue
            }
            if character.isLetter || character == "_" {
                let value = take(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                tokens.append(Token(kind: .identifier, text: value))
                continue
            }
            // Operators, longest first.
            let twoCharacter = index + 1 < characters.count
                ? String([characters[index], characters[index + 1]]) : ""
            if ["==", "!=", "<=", ">=", "=~", "!~", "&&", "||"].contains(twoCharacter) {
                let normalised = twoCharacter == "&&" ? "and" : (twoCharacter == "||" ? "or" : twoCharacter)
                tokens.append(Token(kind: .op, text: normalised))
                index += 2
                continue
            }
            // Ledger spells the connectives `&`, `|`, `!` as often as the
            // words; both forms normalise to the same node.
            if character == "&" || character == "|" {
                tokens.append(Token(kind: .op, text: character == "&" ? "and" : "or"))
                index += 1
                continue
            }
            if "+-*/<>!=".contains(character) {
                tokens.append(Token(kind: .op, text: String(character)))
                index += 1
                continue
            }
            throw ValueExpressionError.syntax("unexpected character '\(character)'")
        }
        characters = []
        return tokens
    }

    static func parseOr(_ tokens: inout [Token], _ index: inout Int) throws -> ValueExpression {
        var left = try parseAnd(&tokens, &index)
        while index < tokens.count, tokens[index].kind == .op || tokens[index].kind == .identifier,
              tokens[index].text.lowercased() == "or" {
            index += 1
            let right = try parseAnd(&tokens, &index)
            left = .binary("or", left, right)
        }
        return left
    }

    static func parseAnd(_ tokens: inout [Token], _ index: inout Int) throws -> ValueExpression {
        var left = try parseComparison(&tokens, &index)
        while index < tokens.count, tokens[index].kind == .op || tokens[index].kind == .identifier,
              tokens[index].text.lowercased() == "and" {
            index += 1
            let right = try parseComparison(&tokens, &index)
            left = .binary("and", left, right)
        }
        return left
    }

    static func parseComparison(_ tokens: inout [Token], _ index: inout Int) throws -> ValueExpression {
        var left = try parseAdditive(&tokens, &index)
        while index < tokens.count, tokens[index].kind == .op,
              ["==", "!=", "<", "<=", ">", ">=", "=~", "!~"].contains(tokens[index].text) {
            let op = tokens[index].text
            index += 1
            let right = try parseAdditive(&tokens, &index)
            left = .binary(op, left, right)
        }
        return left
    }

    static func parseAdditive(_ tokens: inout [Token], _ index: inout Int) throws -> ValueExpression {
        var left = try parseMultiplicative(&tokens, &index)
        while index < tokens.count, tokens[index].kind == .op,
              ["+", "-"].contains(tokens[index].text) {
            let op = tokens[index].text
            index += 1
            let right = try parseMultiplicative(&tokens, &index)
            left = .binary(op, left, right)
        }
        return left
    }

    static func parseMultiplicative(_ tokens: inout [Token], _ index: inout Int) throws -> ValueExpression {
        var left = try parseUnary(&tokens, &index)
        while index < tokens.count, tokens[index].kind == .op,
              ["*", "/"].contains(tokens[index].text) {
            let op = tokens[index].text
            index += 1
            let right = try parseUnary(&tokens, &index)
            left = .binary(op, left, right)
        }
        return left
    }

    static func parseUnary(_ tokens: inout [Token], _ index: inout Int) throws -> ValueExpression {
        guard index < tokens.count else { throw ValueExpressionError.syntax("unexpected end") }
        let token = tokens[index]
        if token.kind == .op, token.text == "!" {
            index += 1
            return .unaryNot(try parseUnary(&tokens, &index))
        }
        if token.kind == .identifier, token.text.lowercased() == "not" {
            index += 1
            return .unaryNot(try parseUnary(&tokens, &index))
        }
        if token.kind == .op, token.text == "-" {
            index += 1
            return .negate(try parseUnary(&tokens, &index))
        }
        return try parsePrimary(&tokens, &index)
    }

    static func parsePrimary(_ tokens: inout [Token], _ index: inout Int) throws -> ValueExpression {
        guard index < tokens.count else { throw ValueExpressionError.syntax("unexpected end") }
        let token = tokens[index]
        index += 1
        switch token.kind {
        case .number:
            guard let value = Decimal(string: token.text, locale: Locale(identifier: "en_US_POSIX"))
            else { throw ValueExpressionError.syntax("bad number '\(token.text)'") }
            return .number(value)
        case .string: return .text(token.text)
        case .regex: return .regex(RegexMatcher(token.text))
        case .date: return .dateLiteral(token.text)
        case .open:
            let inner = try parseOr(&tokens, &index)
            guard index < tokens.count, tokens[index].kind == .close else {
                throw ValueExpressionError.syntax("missing ')'")
            }
            index += 1
            return inner
        case .identifier:
            // A call: NAME ( EXPR )
            if index < tokens.count, tokens[index].kind == .open {
                index += 1
                let argument = try parseOr(&tokens, &index)
                guard index < tokens.count, tokens[index].kind == .close else {
                    throw ValueExpressionError.syntax("missing ')' after \(token.text)(")
                }
                index += 1
                return .call(token.text.lowercased(), argument)
            }
            return .identifier(token.text.lowercased())
        case .op, .close:
            throw ValueExpressionError.syntax("unexpected '\(token.text)'")
        }
    }
}
