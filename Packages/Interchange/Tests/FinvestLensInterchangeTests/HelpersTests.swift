//
//  HelpersTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensInterchange

@Suite("GnuCash numeric parsing")
struct GnuCashNumericTests {

    @Test("Parses rational and integer forms")
    func rationals() {
        #expect(GnuCashNumeric.parse("10000/100") == Decimal(string: "100"))
        #expect(GnuCashNumeric.parse("-10000/100") == Decimal(string: "-100"))
        #expect(GnuCashNumeric.parse("1234/1000") == Decimal(string: "1.234"))
        #expect(GnuCashNumeric.parse("42") == Decimal(42))
    }

    @Test("Rejects malformed input")
    func malformed() {
        #expect(GnuCashNumeric.parse("10/0") == nil)
        #expect(GnuCashNumeric.parse("abc") == nil)
        #expect(GnuCashNumeric.parse("") == nil)
    }
}

@Suite("GnuCash date parsing")
struct GnuCashDateTests {

    @Test("Parses ts:date and gdate forms")
    func dates() {
        #expect(GnuCashDate.parse("2026-01-15 00:00:00 +0000") != nil)
        #expect(GnuCashDate.parse("2026-01-15") != nil)
        #expect(GnuCashDate.parse("not a date") == nil)
    }

    @Test("ts:date decodes to the expected instant")
    func instant() throws {
        let date = try #require(GnuCashDate.parse("2026-01-15 00:00:00 +0000"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents([.year, .month, .day], from: date)
        #expect(components.year == 2026 && components.month == 1 && components.day == 15)
    }
}

@Suite("Gzip")
struct GzipTests {

    // gzip of a minimal GnuCash document (produced via the `gzip` CLI).
    static let minimalGzipBase64 = "H4sICKsLU2oAA21pbi5nbnVjYXNoAL2WXW+bMBSG7/srELcTsSEf6yJClaa9mLYmU7ZK26VjnBSV2AybZPz7Gn+kJFSQrlutSOBznnM458V2CK/+bFNnR3KeMDpx/R50HUIxixO6mbiFWHuX7lV0EW4o9naBI2HKx3IycR+EyMYA7Pf73oYWGPGHHss34OfdVyD9rkERFq2o9FtU5LQVlX6L8ixN2vMqwuJ4G4uyFVfEoRDeXge34Iqxx1a0AlytnoKfhQ56UEotXZV5nMSOKDMycTdFErsR8lcB7scDMlyP0MfVJf4UQ+KvA9RfDfAwHoXARJnUmG238o2JspE/VI1JvRAm0ex+ubydz36FoG41iEw2vb+xLjkz9nUuX5FMGfkQWu/BZhiKtiSaFlzkKE0QdW5YmqLc0sobgqNCTeEIY1ZQ0Sxb5tdxS8aEM9VYCA5mBZyoBjuGDq86q65VZLRcLH5os5oqx3ONbxEPnKQCtXbPbv4a0ceOpv2O8ULT19P5l/dp+mjqcVzoRdQ0KzJDOZFyvP6V6sC/1Pg7kku17FA56BgvqPx5Plvc3b6fzv9DPbmfKddbvamgPI5PZep3jBDoIB2Mi1w+Gb9RiuNM1SxGgngZ44JUD+JqHgUwGHnQ9/yhA+FY/ZwPWgSL6FzH0ZWBcJwnmTrvvqHSUDWjotT/Da/dR6G6nEo06BghsGE2QU4wozhJSexxUdVJLdPwmIgdSgtSbTUIgdpwdbNhfheIimrxNLCDx5B2C73u1DmKNdIaXbokGnaMfyeRd6ZGTe4ckboPjRaRQH1RgZPNKLcnsJ8U5l5+nEUXT1OVYNjNCQAA"

    @Test("Detects the gzip magic")
    func magic() throws {
        let data = try #require(Data(base64Encoded: Self.minimalGzipBase64))
        #expect(Gzip.isGzipped(data))
        #expect(!Gzip.isGzipped(Data("<plain/>".utf8)))
    }

    @Test("Decompresses real gzip data")
    func decompress() throws {
        let data = try #require(Data(base64Encoded: Self.minimalGzipBase64))
        let xml = try Gzip.decompress(data)
        let text = String(decoding: xml, as: UTF8.self)
        #expect(text.contains("<gnc-v2"))
        #expect(text.contains("Salary"))
    }

    @Test("decompressIfNeeded passes plain data through")
    func passthrough() throws {
        let plain = Data("<plain/>".utf8)
        #expect(try Gzip.decompressIfNeeded(plain) == plain)
    }

    @Test("Rejects non-gzip data")
    func rejectsPlain() {
        #expect(throws: Gzip.GzipError.notGzip) {
            try Gzip.decompress(Data("nope".utf8))
        }
    }
}

@Suite("Tolerant amount parsing (review pins)")
struct ImportParsingAmountTests {

    @Test("A lone decimal comma is not thousands grouping")
    func decimalComma() {
        // 1–2 trailing digits after a lone comma can only be a decimal comma —
        // stripping it read the amount 100× too large ("4,99" → 499).
        #expect(ImportParsing.amount("4,99") == Decimal(string: "4.99"))
        #expect(ImportParsing.amount("1234,56") == Decimal(string: "1234.56"))
        #expect(ImportParsing.amount("-45,2") == Decimal(string: "-45.2"))
        // Groups of exactly three stay the en/US thousands reading.
        #expect(ImportParsing.amount("1,234") == Decimal(1234))
        // Dual separators keep their disambiguation.
        #expect(ImportParsing.amount("1.234,56") == Decimal(string: "1234.56"))
        #expect(ImportParsing.amount("1,234.56") == Decimal(string: "1234.56"))
    }

    @Test("An explicit inner sign does not cancel a wrapper negative")
    func doubleNegative() {
        #expect(ImportParsing.amount("(-5)") == Decimal(-5))
        #expect(ImportParsing.amount("(5)") == Decimal(-5))
        #expect(ImportParsing.amount("500.00-") == Decimal(-500))
    }

    @Test("A UTF-8 BOM is stripped at decode")
    func bomDecode() {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("date,amount".utf8))
        #expect(ImportParsing.decode(data) == "date,amount")
    }
}

@Suite("OFX entities & security list (review pins)")
struct OFXEntityTests {

    @Test("SGML entities decode in values")
    func entities() {
        let ofx = """
        <STMTTRN><DTPOSTED>20260115<TRNAMT>-50.00<FITID>F1<NAME>JOHNSON &amp; JOHNSON &lt;PTY&gt;<MEMO>A&#38;B
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.first?.payee == "JOHNSON & JOHNSON <PTY>")
        #expect(rows.first?.memo == "A&B")
    }

    @Test("Investment rows are labelled by SECLIST ticker, not CUSIP")
    func seclistTicker() {
        let ofx = """
        <SECLIST><STOCKINFO><SECINFO><SECID><UNIQUEID>023135106<UNIQUEIDTYPE>CUSIP</SECID>
        <SECNAME>Amazon.com Inc<TICKER>AMZN</SECINFO></STOCKINFO></SECLIST>
        <INVSTMTRS><BUYSTOCK><INVBUY><INVTRAN><FITID>T1<DTTRADE>20260110</INVTRAN>
        <SECID><UNIQUEID>023135106</SECID><UNITS>10<UNITPRICE>150.00<TOTAL>-1500.00</INVBUY></BUYSTOCK></INVSTMTRS>
        """
        let rows = OFXImporter.parse(ofx)
        let investment = rows.first { $0.investment != nil }
        #expect(investment?.investment?.security == "AMZN")
    }

    @Test("RETOFCAP maps to the return-of-capital action")
    func returnOfCapital() {
        let ofx = """
        <RETOFCAP><INVTRAN><FITID>R1<DTTRADE>20260201</INVTRAN><SECID><UNIQUEID>X1</SECID><TOTAL>500.00</RETOFCAP>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.first?.investment?.action == .returnOfCapital)
    }
}

@Suite("QIF investment actions (review pins)")
struct QIFActionTests {
    @Test("RtrnCap maps to return-of-capital, not dividend income")
    func qifReturnOfCapital() {
        #expect(QIFImporter.investmentAction("RtrnCap") == .returnOfCapital)
        #expect(QIFImporter.investmentAction("RtrnCapX") == .returnOfCapital)
        #expect(QIFImporter.investmentAction("Div") == .dividend)
    }
}
