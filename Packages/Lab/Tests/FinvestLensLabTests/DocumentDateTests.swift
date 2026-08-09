//
//  DocumentDateTests.swift
//  FinvestLens — Lab
//
//  The filenames below are the real shapes found in the document trees this
//  tool reads — the institutions' own naming, with account tokens removed.
//  They are here because every one of them once resolved to the wrong month.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
@testable import FinvestLensLabCore

@Suite("Document dates")
struct DocumentDateTests {

    /// The date `infer` returns, as `yyyy-MM-dd`.
    private func inferred(_ name: String, folder: String = "", modified: Date? = nil)
        -> (day: String?, source: DocumentDate.Source) {
        let (date, source) = DocumentDate.infer(name: name, folder: folder, modified: modified)
        return (date.map { LabOptions.dayFormatter.string(from: $0) }, source)
    }

    @Test("A receipt named by date is read from its name")
    func leadingDate() {
        let result = inferred("2026-01-02 Woolworths.png", folder: "2026-01 VISA")
        #expect(result.day == "2026-01-02")
        #expect(result.source == .leadingDate)
    }

    @Test("A registry's period end outranks the download stamp beside it")
    func periodEndBeatsDownloadStamp() {
        // The trap this rule exists for. Plato writes the period it is paying
        // for *and* the moment the PDF was generated into one filename; the
        // second is always later, and on a January statement downloaded in May
        // it is four months later.
        let result = inferred(
            "pl8-dividend_statement-dividend - period end 31 january 2026 eft-2026-05-01_17-25-58.pdf")
        #expect(result.day == "2026-01-31")
        #expect(result.source == .periodEnd)
    }

    @Test("A 2025 statement downloaded in 2026 stays in 2025")
    func downloadDateNeverPromotesAnOldStatement() {
        // The same trap in the direction that costs more: a bulk download in
        // January 2026 stamped nineteen 2024–2025 statements with a 2026
        // token. Reading the token would have pulled every one of them into
        // this period as if they were income received in January.
        let result = inferred(
            "pl8-dividend_statement-dividend - period end 31 december 2025 eft-2026-01-13_09-02-11.pdf")
        #expect(result.day == "2025-12-31")
    }

    @Test("Advice files use their underscore date")
    func underscoreDate() {
        #expect(inferred("CBA_Dividend_Advice_2026_03_30.pdf").day == "2026-03-30")
        #expect(inferred("YMAX_Distribution_Advice_2026_04_20.pdf").day == "2026-04-20")
        #expect(inferred("NAB_Payment_Advice_2026_03_17.pdf").source == .underscoreDate)
    }

    @Test("A compact CommSec statement name parses")
    func compactDate() {
        let result = inferred("Statements20260111.pdf")
        #expect(result.day == "2026-01-11")
        #expect(result.source == .compactDate)
    }

    @Test("A spelled date parses in either order")
    func spelledDates() {
        #expect(inferred("17 Mar 2026 Dist payt.pdf").day == "2026-03-17")
        #expect(inferred("19 Jan 2026 dist payt.pdf").day == "2026-01-19")
        #expect(inferred("20 Apr 2026 dist payt.pdf").day == "2026-04-20")
        #expect(inferred("ANZ VISA 2026-01-14.pdf").day == "2026-01-14")
    }

    @Test("A name with no date falls back to the folder it was filed in")
    func folderMonth() {
        // Two of the January receipts are scanner output — `img20260207_…` —
        // with no readable date. The folder is the only thing left that knows.
        let result = inferred("img20260207_20452286.png", folder: "2026-01 VISA")
        #expect(result.day == "2026-01-01")
        #expect(result.source == .folderMonth)
    }

    @Test("Modification time is the last resort, never the first")
    func modifiedIsLast() {
        let may = LabOptions.dayFormatter.date(from: "2026-05-01")
        // A name that says January beats an mtime that says May…
        #expect(inferred("2026-01-14 Chemist.png", modified: may).day == "2026-01-14")
        // …and only a nameless, folderless file falls through to it.
        let result = inferred("scan.png", modified: may)
        #expect(result.day == "2026-05-01")
        #expect(result.source == .modified)
    }

    @Test("A filename with nothing to go on yields no date at all")
    func noDate() {
        let result = inferred("receipt.png")
        #expect(result.day == nil)
        #expect(result.source == .none)
    }

    @Test("An impossible date is refused rather than clamped")
    func rejectsNonsense() {
        // `13` is not a month. Silently reading it as January would file the
        // document in the wrong period with no way to notice.
        #expect(inferred("2026-13-45 something.png").source != .leadingDate)
    }
}

@Suite("Lab options")
struct LabOptionsTests {

    @Test("Flags, values and both spellings of assignment")
    func parsing() {
        let options = LabOptions(["--file", "/tmp/a.finvestlens", "--apply",
                                  "--batch=25", "--since", "2026-01-01"])
        #expect(options.string("file") == "/tmp/a.finvestlens")
        #expect(options.flag("apply"))
        #expect(options.int("batch") == 25)
        #expect(options.date("since") != nil)
        #expect(!options.flag("missing"))
    }

    @Test("A flag before another flag is not swallowed as its value")
    func adjacentFlags() {
        let options = LabOptions(["--apply", "--force"])
        #expect(options.flag("apply"))
        #expect(options.flag("force"))
        #expect(options.string("apply") == nil)
    }

    @Test("A tilde path is expanded")
    func tildeExpansion() {
        let options = LabOptions(["--file", "~/Book.finvestlens"])
        #expect(options.url("file")?.path.hasPrefix("/Users") == true)
    }
}

@Suite("Chunking")
struct ChunkingTests {

    @Test("Batches are whole and ordered, with a short last one")
    func chunking() {
        let chunks = Array(1...10).chunked(into: 4)
        #expect(chunks.count == 3)
        #expect(chunks[0] == [1, 2, 3, 4])
        #expect(chunks[2] == [9, 10])
        #expect(chunks.flatMap(\.self) == Array(1...10))
    }

    @Test("An empty list makes no batches")
    func empty() {
        #expect([Int]().chunked(into: 5).isEmpty)
    }
}
