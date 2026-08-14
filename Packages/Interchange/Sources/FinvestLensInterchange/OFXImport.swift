//
//  OFXImport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses OFX / QFX files (`FR-XIO-02`).
///
/// Handles both **OFX v1 (SGML)** — where value-only tags have no closing tag —
/// and **OFX v2 (XML)** with a single tolerant scanner: for each field tag we
/// read the value up to the next `<`, which captures the value in both formats
/// (Architecture §5.8a). Extracts `<STMTTRN>` (cash) entries from bank and card
/// statements, and investment transactions — `<BUYSTOCK>`/`<SELLSTOCK>`/
/// `<BUYMF>`/`<SELLMF>`/`<INCOME>`/`<REINVEST>` (`FR-XIO-02`) — carried on the
/// staged row's ``StagedTransaction/investment`` detail.
public enum OFXImporter {

    public static func parse(_ data: Data) -> [StagedTransaction] {
        parse(ImportParsing.decode(data))
    }

    public static func parse(_ text: String) -> [StagedTransaction] {
        // Split on the transaction marker; the first chunk is the header/preamble.
        let chunks = text.components(separatedBy: "<STMTTRN>").dropFirst()
        var result: [StagedTransaction] = []

        for chunk in chunks {
            // Bound the chunk at the closing tag if present (v2) or the next
            // statement boundary (v1).
            let body = chunk.components(separatedBy: "</STMTTRN>").first ?? chunk

            guard let posted = value("DTPOSTED", in: body),
                  let date = parseDate(posted),
                  let amountText = value("TRNAMT", in: body),
                  let amount = ImportParsing.amount(amountText)
            else { continue }

            result.append(StagedTransaction(
                date: date,
                amount: amount,
                payee: value("NAME", in: body) ?? value("PAYEE", in: body) ?? "",
                memo: value("MEMO", in: body) ?? "",
                reference: value("FITID", in: body) ?? ""
            ))
        }
        result.append(contentsOf: parseInvestments(text))
        return result
    }

    /// The bank's identifier for the account this statement belongs to, for
    /// matching against an account's stored `online_id` on later imports.
    ///
    /// Composed routing-then-account (`BANKID/ACCTID`) when the statement
    /// carries a routing number, which bank statements do and card statements
    /// (`CCACCTFROM`) do not. The two are kept in that order deliberately: the
    /// matcher compares by prefix, so an id recorded from a card statement
    /// still matches a later bank statement for the same account number.
    public static func accountIdentifier(_ data: Data) -> String? {
        accountIdentifier(ImportParsing.decode(data))
    }

    public static func accountIdentifier(_ text: String) -> String? {
        // Read from the statement's own account block, not the whole file: a
        // response can carry more than one, and the first is the one whose
        // transactions follow.
        guard let account = value("ACCTID", in: text) else { return nil }
        if let bank = value("BANKID", in: text) { return "\(bank)/\(account)" }
        return account
    }

    /// OFX investment wrappers and the action each denotes.
    private static let investmentWrappers: [(tag: String, action: InvestmentDetail.Action)] = [
        ("BUYSTOCK", .buy), ("BUYMF", .buy), ("BUYOTHER", .buy), ("BUYDEBT", .buy),
        ("SELLSTOCK", .sell), ("SELLMF", .sell), ("SELLOTHER", .sell), ("SELLDEBT", .sell),
        ("REINVEST", .reinvestDividend), ("INCOME", .dividend),
        ("RETOFCAP", .returnOfCapital),
    ]

    /// The statement's `<SECLIST>`: `UNIQUEID` (CUSIP/ISIN) → ticker/name, so
    /// investment rows can be labelled by ticker instead of a raw CUSIP — the
    /// only place OFX carries the human-readable security identity.
    private static func securityDirectory(_ text: String)
        -> [String: (ticker: String?, name: String?)] {
        var map: [String: (ticker: String?, name: String?)] = [:]
        for info in ["STOCKINFO", "MFINFO", "DEBTINFO", "OTHERINFO"] {
            for chunk in text.components(separatedBy: "<\(info)>").dropFirst() {
                let body = chunk.components(separatedBy: "</\(info)>").first ?? chunk
                guard let id = value("UNIQUEID", in: body) else { continue }
                map[id] = (value("TICKER", in: body), value("SECNAME", in: body))
            }
        }
        return map
    }

    /// Extracts every investment transaction block into a staged row carrying
    /// its ``InvestmentDetail``. Quantity/price are absent on income rows.
    private static func parseInvestments(_ text: String) -> [StagedTransaction] {
        var result: [StagedTransaction] = []
        let directory = securityDirectory(text)
        for (tag, action) in investmentWrappers {
            for chunk in text.components(separatedBy: "<\(tag)>").dropFirst() {
                let body = chunk.components(separatedBy: "</\(tag)>").first ?? chunk
                guard let traded = value("DTTRADE", in: body) ?? value("DTPOSTED", in: body),
                      let date = parseDate(traded) else { continue }
                let units = value("UNITS", in: body).flatMap(ImportParsing.amount) ?? 0
                let price = value("UNITPRICE", in: body).flatMap(ImportParsing.amount) ?? 0
                let commission = value("COMMISSION", in: body).flatMap(ImportParsing.amount) ?? 0
                let total = value("TOTAL", in: body).flatMap(ImportParsing.amount) ?? 0
                let uniqueID = value("UNIQUEID", in: body) ?? ""
                let listed = directory[uniqueID]
                let security = listed?.ticker ?? listed?.name ?? uniqueID
                result.append(StagedTransaction(
                    date: date, amount: total, payee: security,
                    memo: value("MEMO", in: body) ?? "",
                    reference: value("FITID", in: body) ?? "",
                    investment: InvestmentDetail(action: action, security: security,
                                                 quantity: abs(units), pricePerShare: price,
                                                 commission: commission)))
            }
        }
        return result
    }

    /// Reads the value following `<TAG>` up to the next `<` — works for both
    /// unclosed SGML tags and closed XML tags.
    private static func value(_ tag: String, in body: String) -> String? {
        guard let range = body.range(of: "<\(tag)>", options: .caseInsensitive) else { return nil }
        let after = body[range.upperBound...]
        let end = after.firstIndex(of: "<") ?? after.endIndex
        let value = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : decodeEntities(value)
    }

    /// OFX 1.x §2.3.2 (and XML by definition) escape `&` `<` `>` in values;
    /// leaving `&amp;` literal polluted payees ("JOHNSON &amp; JOHNSON"),
    /// broke matcher history keys, and diverged from the CAMT path, whose
    /// `XMLParser` decodes natively.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        while let range = out.range(of: #"&#[xX]?[0-9a-fA-F]+;"#, options: .regularExpression) {
            let token = out[range]
            let isHex = token.lowercased().hasPrefix("&#x")
            let digits = token.dropFirst(isHex ? 3 : 2).dropLast()
            let scalar = UInt32(digits, radix: isHex ? 16 : 10).flatMap(Unicode.Scalar.init)
            out.replaceSubrange(range, with: scalar.map { String(Character($0)) } ?? "")
        }
        // Last, so a double-escaped "&amp;lt;" correctly yields a literal "&lt;".
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// OFX dates are `YYYYMMDD` optionally followed by time/zone; take the date.
    private static func parseDate(_ raw: String) -> Date? {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: String(digits.prefix(8)))
    }
}
