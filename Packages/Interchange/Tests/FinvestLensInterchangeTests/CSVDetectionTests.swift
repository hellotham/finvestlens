//
//  CSVDetectionTests.swift
//  FinvestLens — Interchange
//
//  CSV shape detection (`FR-XIO-13`). Column names are taken from the real
//  exports; every value is invented.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensInterchange

/// Wise's real column set, with a title line above the header exactly as the
/// export writes it, and invented rows underneath.
private let wiseCSV = """
statement_00000000_AUD_2024-07-29_2025-06-30
TransferWise ID,Date,Date Time,Amount,Currency,Description,Payment Reference,Running Balance,Exchange From,Exchange To,Exchange Rate,Payer Name,Payee Name,Payee Account Number,Merchant,Card Last Four Digits,Card Holder Full Name,Attachment,Note,Total fees,Exchange To Amount,Transaction Type
CARD-1111111111,30-06-2025,30-06-2025 09:00:00.000,-12.50,AUD,Card transaction of 35.00 MYR issued by Corner Cafe,,487.50,AUD,MYR,2.8000,,,,Corner Cafe,1234,A Cardholder,,,0.30,35.00,DEBIT
FEE-CARD-1111111111,30-06-2025,30-06-2025 09:00:00.000,-0.30,AUD,Wise Charges for: CARD-1111111111,,487.20,,,,,,,Corner Cafe,1234,A Cardholder,,,0,,DEBIT
TRANSFER-2222222222,15-06-2025,15-06-2025 12:00:00.000,500.00,AUD,Topped up account,,987.20,,,,,,,,,,,,0,,CREDIT
"""

@Suite("CSV line endings")
struct CSVLineEndingTests {

    /// RFC 4180 specifies CRLF and most bank exports use it, but Swift groups
    /// CR+LF into **one** `Character` matching neither `"\r"` nor `"\n"`. The
    /// tokenizer therefore appended line breaks into the field and returned the
    /// whole file as a single row — a real 44-line export tokenized as one row
    /// of 925 fields and imported nothing. Every fixture here was LF-only,
    /// which is why nothing caught it.
    @Test("CRLF, LF and bare CR all split rows")
    func lineEndings() {
        let expected = [["a", "b"], ["c", "d"]]
        #expect(CSV.parse("a,b\r\nc,d\r\n") == expected)
        #expect(CSV.parse("a,b\nc,d\n") == expected)
        #expect(CSV.parse("a,b\rc,d\r") == expected)
        #expect(CSV.parse("a,b\r\nc,d") == expected)      // no trailing break
    }

    @Test("A CRLF file imports every row")
    func crlfImport() {
        let csv = "Date,Description,Amount\r\n2026-01-05,Coffee,-4.50\r\n2026-01-06,Salary,2000.00\r\n"
        let rows = CSVTransactionImporter.parse(
            csv, mapping: CSVColumnMapping(date: 0, amount: 2, payee: 1))
        #expect(rows.count == 2)
        #expect(rows[0].amount == Decimal(string: "-4.50"))
        #expect(rows[1].payee == "Salary")
    }

    @Test("A line break inside a quoted field is kept, not treated as a row end")
    func quotedLineBreak() {
        let rows = CSV.parse("a,\"line1\r\nline2\"\r\nb,c\r\n")
        #expect(rows.count == 2)
        #expect(rows[0][1].contains("line1"))
        #expect(rows[0][1].contains("line2"))
        #expect(rows[1] == ["b", "c"])
    }
}

@Suite("CSV shape detection")
struct CSVDetectionTests {

    @Test("A Wise export is recognised through its title line")
    func detectsWise() throws {
        let found = try #require(CSVFormatDetector.detect(wiseCSV))
        #expect(found.name == "Wise")
        #expect(found.preambleRows == 1)          // the statement_… title line
        #expect(found.mapping.skipRows == 1)
        #expect(found.mapping.dateFormat == "dd-MM-yyyy")
        #expect(found.parsedRows == 3)
        #expect(found.dataRows == 3)

        // Amount, not "Total fees" or "Exchange To Amount": the fee is already
        // its own row, so folding the column in would double-count every one.
        #expect(found.mapping.amount == 3)
        #expect(found.mapping.date == 1)          // "Date", not "Date Time"
        #expect(found.mapping.payee == 14)        // Merchant
        #expect(found.mapping.memo == 5)          // Description
        #expect(found.mapping.reference == 0)     // TransferWise ID
    }

    @Test("The detected mapping imports the rows correctly")
    func importsWithDetectedMapping() throws {
        let found = try #require(CSVFormatDetector.detect(wiseCSV))
        let rows = CSVTransactionImporter.parse(wiseCSV, mapping: found.mapping)
        #expect(rows.count == 3)

        // The fee row is a movement in its own right — it is not netted away.
        #expect(rows.map(\.amount).contains(Decimal(string: "-0.30")!))
        #expect(rows.map(\.amount).contains(Decimal(string: "-12.50")!))
        #expect(rows.map(\.amount).contains(Decimal(500)))

        let card = try #require(rows.first { $0.reference == "CARD-1111111111" })
        #expect(card.payee == "Corner Cafe")
        #expect(card.memo.hasPrefix("Card transaction of"))

        // A transfer has no merchant; the payee is blank and the matcher's own
        // fallback uses the memo, so nothing is lost.
        let transfer = try #require(rows.first { $0.reference == "TRANSFER-2222222222" })
        #expect(transfer.payee.isEmpty)
        #expect(transfer.memo == "Topped up account")
    }

    @Test("A deeper preamble is still found")
    func multiLinePreamble() throws {
        let csv = """
        Account Statement
        Account,Everyday Saver
        Period,01/01/2026 to 31/01/2026

        Date,Description,Debit,Credit,Balance
        05/01/2026,Coffee,4.50,,995.50
        06/01/2026,Salary,,2000.00,2995.50
        """
        let found = try #require(CSVFormatDetector.detect(csv))
        // Three, not four: the tokenizer drops the blank line before detection
        // ever sees it, so a blank row costs nothing in the preamble count.
        #expect(found.preambleRows == 3)
        #expect(found.mapping.dateFormat == "dd/MM/yyyy")
        #expect(found.mapping.debit != nil)
        #expect(found.mapping.credit != nil)

        let rows = CSVTransactionImporter.parse(csv, mapping: found.mapping)
        #expect(rows.count == 2)
        #expect(rows[0].amount == Decimal(string: "-4.50"))
        #expect(rows[1].amount == Decimal(2000))
    }

    @Test("A preamble line mentioning a column name cannot pose as the header")
    func preambleDoesNotWin() throws {
        // "Date range" is not a header, and nothing below it parses — the real
        // header two rows down has to win.
        let csv = """
        Date range,01/01/2026,31/01/2026
        Exported by,Someone
        Date,Description,Amount
        05/01/2026,Coffee,-4.50
        06/01/2026,Salary,2000.00
        """
        let found = try #require(CSVFormatDetector.detect(csv))
        #expect(found.preambleRows == 2)
        #expect(found.parsedRows == 2)
        let rows = CSVTransactionImporter.parse(csv, mapping: found.mapping)
        #expect(rows.count == 2)
    }

    @Test("A file it cannot understand is refused rather than guessed at")
    func refusesUnknown() {
        // No recognisable date column.
        #expect(CSVFormatDetector.detect("""
        Widget,Quantity,Price
        Bolt,10,1.50
        """) == nil)
        // A date column whose rows are not dates: detection must not "succeed"
        // on a file that yields nothing.
        #expect(CSVFormatDetector.detect("""
        Date,Amount
        not a date,12.00
        also not,13.00
        """) == nil)
        #expect(CSVFormatDetector.detect("") == nil)
    }

    @Test("Ambiguous day/month dates resolve to day-first, unambiguous ones to the truth")
    func dateFormatInference() {
        // 31 can only be a day.
        #expect(CSVFormatDetector.inferDateFormat(["31-12-2025", "01-02-2026"]) == "dd-MM-yyyy")
        // 13 can only be a month in a month-first file.
        #expect(CSVFormatDetector.inferDateFormat(["12-13-2025", "01-02-2026"]) == "MM-dd-yyyy")
        #expect(CSVFormatDetector.inferDateFormat(["2026-01-31"]) == "yyyy-MM-dd")
        #expect(CSVFormatDetector.inferDateFormat(["nonsense", "also nonsense"]) == nil)
        // The separator has to match: DateFormatter would otherwise accept
        // "05/01/2026" for "dd-MM-yyyy" and report the wrong format.
        #expect(CSVFormatDetector.inferDateFormat(["05/01/2026", "31/01/2026"]) == "dd/MM/yyyy")
        #expect(CSVFormatDetector.inferDateFormat(["05-01-2026", "31-01-2026"]) == "dd-MM-yyyy")
        #expect(CSVFormatDetector.inferDateFormat(["05 Jan 2026"]) == "dd MMM yyyy")
    }
}

/// Runs the detector against a real bank export, which no fixture can stand in
/// for: preambles, column sets and date styles are exactly what banks vary.
/// Skips itself unless `FL_CSV_FILE` points at one — the same gate the other
/// live harnesses use, so real statements never enter the repository.
@Suite("Live CSV detection")
struct LiveCSVDetectionTests {

    @Test("Detects and imports a real bank CSV")
    func realExport() throws {
        guard let path = ProcessInfo.processInfo.environment["FL_CSV_FILE"] else { return }
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)

        let found = try #require(CSVFormatDetector.detect(text), "no shape detected")
        let rows = CSVTransactionImporter.parse(text, mapping: found.mapping)

        // Report the shape, never the contents.
        print("""
            detected: name=\(found.name ?? "—") preamble=\(found.preambleRows) \
            dateFormat=\(found.mapping.dateFormat) \
            columns(date:\(found.mapping.date) amount:\(found.mapping.amount.map(String.init) ?? "—") \
            payee:\(found.mapping.payee.map(String.init) ?? "—") \
            memo:\(found.mapping.memo.map(String.init) ?? "—") \
            ref:\(found.mapping.reference.map(String.init) ?? "—")) \
            parsed=\(found.parsedRows)/\(found.dataRows) imported=\(rows.count)
            """)

        #expect(rows.count == found.dataRows, "every data row should import")
        #expect(rows.allSatisfy { $0.amount != 0 })
        #expect(rows.allSatisfy { !$0.reference.isEmpty })
    }
}
