//
//  CSVFormatDetection.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A CSV export the app worked out for itself: which row is the header, which
/// columns mean what, and what its dates look like (`FR-XIO-13`).
public struct CSVFormatDetection: Sendable, Equatable {
    /// The mapping to import with, preamble included.
    public var mapping: CSVColumnMapping
    /// The export's name where the header identifies one ("Wise"), for telling
    /// the user what was recognised rather than silently reconfiguring.
    public var name: String?
    /// Rows above the header — a title line, an account summary, a blank.
    public var preambleRows: Int
    /// How many data rows below the header parsed into a date and an amount.
    public var parsedRows: Int
    /// How many data rows the header row implies.
    public var dataRows: Int
}

/// Works out a bank CSV's shape from its own header row.
///
/// Two things make this safe to apply without asking:
///
/// 1. **The header is found, never assumed.** Exports routinely carry a
///    preamble — a title line, an account block, a blank row — and Excel adds
///    more. Every row in the first ``scanDepth`` is scored by how many of its
///    cells are recognisable column names, so a preamble line has to *look*
///    like a header to win.
/// 2. **The winner is proved by parsing.** A candidate is only accepted when
///    the rows beneath it actually yield dates and amounts
///    (``minimumParseRate``). A stray line containing the word "Date" cannot
///    survive that, and a file the app has not really understood falls back to
///    the manual mapping instead of importing something wrong.
public enum CSVFormatDetector {

    /// Rows searched for a header. Deep enough for the preambles seen in the
    /// wild, shallow enough that a headerless file is not scanned to its end.
    public static let scanDepth = 20
    /// The share of rows below the header that must parse for the detection to
    /// be trusted. Below this the file is handed to the manual mapping.
    public static let minimumParseRate = 0.6

    // MARK: Column vocabularies (first match wins, so order is priority)

    private static let dateNames = [
        "date", "transaction date", "posted date", "date posted", "value date",
        "booking date", "completed date", "settlement date", "started date",
    ]
    private static let amountNames = [
        "amount", "transaction amount", "value", "amount (aud)", "net amount",
    ]
    private static let debitNames = ["debit", "debit amount", "withdrawal", "money out", "paid out", "out"]
    private static let creditNames = ["credit", "credit amount", "deposit", "money in", "paid in", "in"]
    private static let payeeNames = [
        "merchant", "payee", "payee name", "counterparty", "beneficiary",
        "description", "narrative", "details", "name", "particulars",
    ]
    private static let memoNames = [
        "description", "narrative", "details", "memo", "note", "notes",
        "reference", "particulars",
    ]
    private static let referenceNames = [
        "transferwise id", "transaction id", "transaction reference", "reference number",
        "id", "reference", "payment reference", "receipt number",
    ]

    /// Header signatures that name a known export. Only exports whose real
    /// files have been seen belong here — a guessed signature that matches the
    /// wrong bank is worse than no name at all.
    private static let signatures: [(name: String, required: [String])] = [
        ("Wise", ["transferwise id", "running balance"]),
    ]

    /// Date formats tried against the data, most specific first. Ambiguous
    /// day/month pairs are settled below by looking for a component over 12.
    private static let dateFormats = [
        "yyyy-MM-dd", "dd-MM-yyyy", "MM-dd-yyyy", "dd/MM/yyyy", "MM/dd/yyyy",
        "yyyy/MM/dd", "dd.MM.yyyy", "yyyyMMdd", "dd MMM yyyy", "d MMM yyyy",
        "MMM d, yyyy", "dd-MMM-yyyy", "dd/MM/yy", "MM/dd/yy",
    ]

    // MARK: Detection

    public static func detect(_ data: Data) -> CSVFormatDetection? {
        detect(ImportParsing.decode(data))
    }

    public static func detect(_ text: String) -> CSVFormatDetection? {
        let rows = CSV.parse(text)
        guard rows.count >= 2 else { return nil }

        var best: CSVFormatDetection?
        for index in 0..<min(scanDepth, rows.count - 1) {
            guard let candidate = evaluate(headerAt: index, in: rows) else { continue }
            // An earlier header wins ties: a preamble line cannot outscore the
            // real header without also parsing more rows beneath it.
            if best == nil || candidate.parsedRows > best!.parsedRows { best = candidate }
        }
        return best
    }

    private static func evaluate(headerAt index: Int, in rows: [[String]]) -> CSVFormatDetection? {
        let header = rows[index].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard header.count >= 2 else { return nil }

        func column(_ candidates: [String]) -> Int? {
            for candidate in candidates {
                if let hit = header.firstIndex(of: candidate) { return hit }
            }
            return nil
        }
        guard let date = column(dateNames) else { return nil }
        let amount = column(amountNames)
        let debit = column(debitNames)
        let credit = column(creditNames)
        guard amount != nil || (debit != nil && credit != nil) else { return nil }

        // A payee column that would duplicate the memo is dropped: the matcher
        // already falls back to the memo when the payee is blank, and two
        // copies of one string helps nobody.
        let memo = column(memoNames)
        var payee = column(payeeNames)
        if payee == memo { payee = nil }

        let body = Array(rows.dropFirst(index + 1)).filter { $0.count == rows[index].count }
        guard !body.isEmpty else { return nil }

        guard let format = inferDateFormat(body.map { row -> String in
            date < row.count ? row[date] : ""
        }) else { return nil }

        var mapping = CSVColumnMapping(
            date: date, amount: amount, debit: debit, credit: credit,
            payee: payee, memo: memo, reference: column(referenceNames),
            dateFormat: format, hasHeader: true)
        mapping.skipRows = index

        // Prove it: the mapping has to actually produce rows from this file.
        let parsed = CSVTransactionImporter.parse(rebuild(rows), mapping: mapping)
        let rate = Double(parsed.count) / Double(body.count)
        guard rate >= minimumParseRate else { return nil }

        let name = signatures.first { signature in
            signature.required.allSatisfy(header.contains)
        }?.name

        return CSVFormatDetection(mapping: mapping, name: name, preambleRows: index,
                                  parsedRows: parsed.count, dataRows: body.count)
    }

    /// Re-emits parsed rows as CSV so a candidate mapping can be tested through
    /// the real importer rather than a second copy of its logic.
    private static func rebuild(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { field in
                field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                    ? "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
                    : field
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// The punctuation between a date's parts, in order — "05/01/2026" and
    /// "dd/MM/yyyy" both give `["/", "/"]`.
    private static func separators(of text: String) -> [Character] {
        text.filter { !$0.isLetter && !$0.isNumber }
    }

    /// The format that parses the most of these dates. Where a day/month pair
    /// is genuinely ambiguous — every value 12 or under — the first format in
    /// ``dateFormats`` wins, which puts ISO ahead of day-first ahead of
    /// month-first rather than guessing from the machine's locale.
    static func inferDateFormat(_ values: [String]) -> String? {
        let samples = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !samples.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")

        var best: (format: String, hits: Int)?
        for format in dateFormats {
            // `DateFormatter` accepts "05/01/2026" for "dd-MM-yyyy", so hit
            // counts alone would pick whichever separator came first in the
            // list and report a format the file does not use. Require the
            // punctuation to line up before trusting the count.
            guard samples.allSatisfy({ separators(of: $0) == separators(of: format) })
            else { continue }
            formatter.dateFormat = format
            let hits = samples.reduce(into: 0) { count, sample in
                if formatter.date(from: sample) != nil { count += 1 }
            }
            if hits == 0 { continue }
            if best == nil || hits > best!.hits { best = (format, hits) }
        }
        guard let best, Double(best.hits) / Double(samples.count) >= minimumParseRate else { return nil }
        return best.format
    }
}
