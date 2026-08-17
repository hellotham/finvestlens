//
//  MT940Import.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses SWIFT **MT940** (customer statement) and **MT942** (interim report)
/// messages (`FR-XIO-04`).
///
/// Both carry transactions as `:61:` statement lines, each optionally followed
/// by an `:86:` information-to-account-owner narrative; MT942 adds interim
/// header tags (`:13D:`, `:90D:`/`:90C:`) this parser simply ignores, so one
/// scanner covers both. Hand-written per Architecture §5.8a against the SWIFT
/// field specification and published bank samples (ABN AMRO, ING, Danske) —
/// the same approach as the QIF/OFX parsers.
///
/// Layout rules honoured here:
/// - A field starts with `:TAG:` at the beginning of a line; any following
///   line that does not start a new field (or a `{`/`-}` block marker) is a
///   continuation of the current one.
/// - `:61:` subfields: value date `YYMMDD`, optional entry date `MMDD`,
///   debit/credit mark (`D`, `C`, `RD`, `RC` — reversals flip the sign),
///   optional funds code letter, amount with a **comma** decimal separator,
///   4-character transaction type (`NTRF`, …), customer reference up to `//`,
///   then an optional bank reference.
/// - `:86:` narratives may span lines; German-convention `?nn` subfields are
///   recognised (`?32`/`?33` name the payee, `?20`–`?29` the remittance text),
///   otherwise the whole narrative becomes the memo.
public enum MT940Importer {

    public static func parse(_ data: Data) -> [StagedTransaction] {
        parse(ImportParsing.decode(data))
    }

    /// Folds continuation lines into their field, producing (tag, value).
    private static func fields(_ text: String) -> [(tag: String, value: String)] {
        var fields: [(tag: String, value: String)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("{") || line == "-}" || line == "-" { continue }
            if line.hasPrefix(":"),
               let close = line.dropFirst().firstIndex(of: ":"),
               close > line.index(after: line.startIndex) {
                let tag = String(line[line.index(after: line.startIndex)..<close])
                let value = String(line[line.index(after: close)...])
                fields.append((tag, value))
            } else if !fields.isEmpty {
                fields[fields.count - 1].value += "\n" + line
            }
        }
        return fields
    }

    /// The statement's `:25:` account identification — the bank's own name for
    /// the account, matched against a stored `online_id` on later imports.
    public static func accountIdentifier(_ data: Data) -> String? {
        accountIdentifier(ImportParsing.decode(data))
    }

    public static func accountIdentifier(_ text: String) -> String? {
        // 25 or 25P, matching `parse` — otherwise a 25P file reports no account
        // here while its rows are labelled, and the two disagree.
        guard let value = fields(text).first(where: { $0.tag == "25" || $0.tag == "25P" })?.value
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func parse(_ text: String) -> [StagedTransaction] {
        let fields = fields(text)
        var result: [StagedTransaction] = []
        var index = 0
        // A download may hold several statements back to back, each opening
        // with its own `:25:`. Carrying the current one onto every row is what
        // lets the import sheet tell them apart instead of posting all of them
        // into whichever account happened to be selected.
        var account: String?
        while index < fields.count {
            let field = fields[index]
            index += 1
            // `:20:` opens every statement and is mandatory, so it — not the
            // account tag — is the boundary. Resetting here means a statement
            // whose `:25:` is missing, blank, or written as the field-25a
            // variant `:25P:` degrades to *unlabelled* rather than silently
            // inheriting the previous statement's account, which would post
            // its rows into the wrong account under a confidently wrong label.
            if field.tag == "20" {
                account = nil
                continue
            }
            // 25 or 25P (field 25a): both identify the statement's account.
            if field.tag == "25" || field.tag == "25P" {
                let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                account = trimmed.isEmpty ? nil : trimmed
                continue
            }
            guard field.tag == "61", var row = statementLine(field.value) else { continue }
            // The narrative for a :61: is the :86: that immediately follows it.
            if index < fields.count, fields[index].tag == "86" {
                let (payee, memo) = narrative(fields[index].value)
                row.payee = payee
                row.memo = memo
                index += 1
            }
            row.sourceAccountID = account
            result.append(row)
        }
        return result
    }

    /// Decodes one `:61:` statement line into a staged row (without narrative).
    static func statementLine(_ raw: String) -> StagedTransaction? {
        // Only the first line of the field is the structured part; a second
        // line, when present, is the free-form supplementary.
        let value = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        var rest = Substring(value)

        // Value date YYMMDD.
        guard rest.count >= 6, let date = date(String(rest.prefix(6))) else { return nil }
        rest = rest.dropFirst(6)
        // Optional entry date MMDD (digits where the D/C mark should be).
        if rest.count >= 4, rest.prefix(4).allSatisfy(\.isNumber) {
            rest = rest.dropFirst(4)
        }
        // Debit/credit mark: C, D, RC, RD (reversals flip).
        var reversal = false
        if rest.first == "R" {
            reversal = true
            rest = rest.dropFirst()
        }
        guard let mark = rest.first, mark == "C" || mark == "D" else { return nil }
        rest = rest.dropFirst()
        var negative = (mark == "D")
        if reversal { negative.toggle() }
        // Optional funds code: a letter before the amount digits.
        if let first = rest.first, first.isLetter { rest = rest.dropFirst() }
        // Amount: digits with a comma decimal separator.
        let amountText = String(rest.prefix { $0.isNumber || $0 == "," })
        rest = rest.dropFirst(amountText.count)
        guard !amountText.isEmpty,
              let magnitude = Decimal(string: amountText.replacingOccurrences(of: ",", with: "."),
                                      locale: Locale(identifier: "en_US_POSIX")),
              magnitude != 0
        else { return nil }
        // Transaction type (N/S/F + 3), then customer ref up to //, bank ref after.
        rest = rest.dropFirst(min(4, rest.count))
        let references = rest.components(separatedBy: "//")
        let customer = references.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let bank = references.count > 1
            ? references[1].trimmingCharacters(in: .whitespaces) : ""
        // `NONREF` is the SWIFT sentinel for "there isn't one", and it appears
        // on either half. Blanking it only on the customer side let a
        // `…//NONREF` line be treated as a bank-unique id, after which the
        // literal string "NONREF" went into `online_id` and matched every
        // later row that also had no reference — an unconditional duplicate
        // for the whole statement.
        let bankRef = bank.uppercased() == "NONREF" ? "" : bank
        let reference = !bankRef.isEmpty ? bankRef
            : (customer.uppercased() == "NONREF" ? "" : customer)
        // Only the bank's own reference (the half after `//`) is an identifier
        // the bank guarantees. The customer reference is whatever the payer
        // typed and repeats month to month, so it must not be treated as a
        // unique id or written to `online_id`.
        let unique = !bankRef.isEmpty

        return StagedTransaction(date: date,
                                 amount: negative ? -magnitude : magnitude,
                                 reference: reference,
                                 referenceIsBankUnique: unique)
    }

    /// Splits an `:86:` narrative into (payee, memo). German-convention `?nn`
    /// subfields put the counterparty name in `?32`/`?33` and the remittance
    /// text in `?20`–`?29`; free-form narratives become the memo whole.
    static func narrative(_ raw: String) -> (payee: String, memo: String) {
        let joined = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        guard joined.contains("?") else { return ("", joined) }

        var subfields: [String: String] = [:]
        let parts = joined.components(separatedBy: "?")
        for part in parts.dropFirst() {
            guard part.count >= 2 else { continue }
            let code = String(part.prefix(2))
            guard code.allSatisfy(\.isNumber) else { continue }
            let text = String(part.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if let existing = subfields[code] {
                subfields[code] = text.isEmpty ? existing : existing + " " + text
            } else {
                subfields[code] = text
            }
        }
        guard !subfields.isEmpty else { return ("", joined) }

        let payee = ["32", "33"].compactMap { subfields[$0] }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let memo = (20...29).compactMap { subfields[String($0)] }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (payee, memo.isEmpty ? joined : memo)
    }

    private static func date(_ yymmdd: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMdd"
        return formatter.date(from: yymmdd)
    }
}
