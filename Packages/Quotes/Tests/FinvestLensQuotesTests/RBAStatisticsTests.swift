//
//  RBAStatisticsTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

@Suite("RBA table G1 — consumer price index")
struct RBAStatisticsTests {

    /// The head and tail of the table as downloaded on 25 October 2026, the
    /// columns past the second dropped.
    private let sample = """
    \u{FEFF}G1 CONSUMER PRICE INFLATION
    Title,Consumer price index,Year-ended inflation,"Year-ended inflation – excluding volatile items, interest charges and tax changes"
    Description,Consumer price index; All groups,Consumer price index; All groups; Year-ended change (in per cent),x
    Frequency,Quarterly,Quarterly,Quarterly
    Type,Original,Original,Original
    Units,"Index, September 2025 month = 100",Per cent,Per cent


    Source,ABS / RBA,ABS / RBA,ABS / RBA
    Publication date,30-Jul-2026,30-Jul-2026,30-Jul-2026
    Series ID,GCPIAG,GCPIAGYP,GCPIXVIYP
    30/06/1922,1.93
    30/09/1999,47.72,1.7,
    31/03/2026,101.70,4.1,3.5
    30/06/2026,102.31,3.9,3.4
    """

    @Test("Each quarter's reading is keyed by its calendar quarter")
    func parses() throws {
        let cpi = try RBAStatistics.parseCPI(sample)
        #expect(cpi["2026-Q2"] == 102.31)
        #expect(cpi["2026-Q1"] == 101.70)
        #expect(cpi["1999-Q3"] == 47.72)
        #expect(cpi["1922-Q2"] == 1.93)
        #expect(cpi.count == 4)
    }

    @Test("Another series comes from its own column")
    func otherSeries() throws {
        let yearEnded = try RBAStatistics.parseCPI(sample, series: "GCPIAGYP")
        #expect(yearEnded["2026-Q2"] == 3.9)
        #expect(yearEnded["1922-Q2"] == nil, "a short row has no reading for it")
    }

    @Test("A table without the series is an error, not an empty table")
    func missingSeries() {
        #expect(throws: RBAStatisticsError.seriesNotFound("GCPIAG")) {
            try RBAStatistics.parseCPI("Title,x\nSeries ID,OTHER\n30/06/2026,1")
        }
    }

    @Test("Quoted commas stay inside their field")
    func quotedFields() {
        #expect(RBAStatistics.fields(of: "Units,\"Index, September 2025 month = 100\",Per cent")
                == ["Units", "Index, September 2025 month = 100", "Per cent"])
        #expect(RBAStatistics.quarterKey("31/12/2025") == "2025-Q4")
        #expect(RBAStatistics.quarterKey("Series ID") == nil)
    }
}
