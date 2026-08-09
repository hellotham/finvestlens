//
//  LiveStatementChunkingTests.swift
//  FinvestLens — Intelligence
//
//  A harness for the one thing synthetic PDFs cannot exercise: real statement
//  pages, which are far denser than anything a test renders. Point
//  `FL_STATEMENT_PDF` at a statement (or a folder of them) and run:
//
//      FL_STATEMENT_PDF=~/path/to/statements swift test \
//        --package-path Packages/Intelligence --filter LiveStatementChunking
//
//  Skipped otherwise — the files it reads are real financial data and never
//  live in this repo. It prints sizes and counts only, never a payee or an
//  amount, so its output is safe to paste into a review.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)
import Foundation
import Testing
@testable import FinvestLensIntelligence

private let statementPath = ProcessInfo.processInfo.environment["FL_STATEMENT_PDF"]
private let harnessEnabled = statementPath != nil && IntelligenceAvailability.current().isAvailable

/// Pure, and therefore always run: the sizing rule the live harness below
/// depends on should not be gated behind having a real statement to hand.
@Suite("Statement chunking")
struct StatementChunkingTests {

    @Test("Line grouping keeps whole lines and respects the budget")
    func grouping() {
        let text = (1...50).map { "row \($0) some payee text and an amount 123.45" }
            .joined(separator: "\n")
        let groups = StatementExtractor.lineGroups(text, budget: 200)
        #expect(groups.count > 1)
        for group in groups {
            // A group may exceed the budget only when it is a single long line.
            #expect(group.count <= 200 || !group.contains("\n"))
        }
        // Nothing is lost and nothing is reordered.
        #expect(groups.joined(separator: "\n") == text)
    }

    @Test("A single over-budget line is never cut in half")
    func longLineSurvivesWhole() {
        let long = String(repeating: "x", count: 500)
        let groups = StatementExtractor.lineGroups("short\n\(long)\nshort", budget: 100)
        #expect(groups.contains { $0 == long })
    }

    @Test("A cleaned-up payee is still recognised in the printed line")
    func groundingAcceptsCleanedNames() {
        let source = SourceGrounding.folded("""
            12 FEB  WOOLWORTHS 3421 SYDNEY NS          45.67
            13 FEB  TRANSPORT FOR NSW TRAVEL            8.20
            14 FEB  AMZN Mktp AU*RT4XY9  SYDNEY        21.99
            """)
        // The prompt asks for the payee "cleaned up", so these are the shapes
        // the model actually returns for those lines.
        #expect(SourceGrounding.isNamePrinted("Woolworths", in: source))
        #expect(SourceGrounding.isNamePrinted("WOOLWORTHS 3421", in: source))
        #expect(SourceGrounding.isNamePrinted("Transport for NSW", in: source))
        #expect(SourceGrounding.isNamePrinted("Amazon Marketplace", in: source) == false)
        #expect(SourceGrounding.isNamePrinted("AMZN Mktp", in: source))
    }

    @Test("An invented merchant is rejected")
    func groundingRejectsInvention() {
        let source = SourceGrounding.folded("12 FEB  WOOLWORTHS 3421 SYDNEY NS   45.67")
        // Padding is the failure mode this exists for: the model fills unused
        // array slots with plausible merchants that are not on the page.
        #expect(!SourceGrounding.isNamePrinted("Netflix", in: source))
        #expect(!SourceGrounding.isNamePrinted("Uber Eats", in: source))
        #expect(!SourceGrounding.isNamePrinted("Coles Supermarket", in: source))
    }

    @Test("An amount must actually be printed on the page")
    func amountGrounding() {
        let source = SourceGrounding.folded("""
            12 FEB  WOOLWORTHS 3421 SYDNEY NS          45.67
            13 FEB  ANZ INTEREST CHARGED            1,204.30 CR
            """)
        #expect(SourceGrounding.isAmountPrinted("45.67", in: source))
        #expect(SourceGrounding.isAmountPrinted("-45.67", in: source))
        // A thousands separator the model drops, and a CR the statement writes
        // instead of a sign, both fold away.
        #expect(SourceGrounding.isAmountPrinted("1204.30", in: source))
        // An invented figure has nothing to match.
        #expect(!SourceGrounding.isAmountPrinted("99.99", in: source))
        #expect(!SourceGrounding.isAmountPrinted("512.00", in: source))
        // Under $10.00 there are too few digits to test on, so it abstains.
        #expect(SourceGrounding.isAmountPrinted("0.50", in: source))
    }

    @Test("Payees too short to discriminate are not rejected on length alone")
    func groundingIsLenientOnShortNames() {
        // Below four folded characters containment stops meaning anything, so
        // the check abstains rather than throwing away real rows.
        let source = SourceGrounding.folded("12 FEB  BP CONNECT ROZELLE   88.00")
        #expect(SourceGrounding.isNamePrinted("BP", in: source))
        #expect(!SourceGrounding.isNamePrinted("", in: source))
    }
}

@Suite("LiveStatementChunking", .enabled(if: harnessEnabled),
       .timeLimit(.minutes(20)), .serialized)
struct LiveStatementChunkingTests {

    /// Every PDF under the configured path, at most `limit` of them.
    private func statements(limit: Int = 4) throws -> [URL] {
        let root = URL(fileURLWithPath: try #require(statementPath))
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { return [root] }
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "pdf" } ?? []
        return Array(found.sorted { $0.path < $1.path }.prefix(limit))
    }

    @Test("Real statement pages extract without overflowing the context window")
    func realStatements() async throws {
        for url in try statements() {
            let pages = try await DocumentText.extractPages(from: url)
            let sizes = pages.map(\.text.count)
            let groups = pages.map { StatementExtractor.lineGroups($0.text, budget: StatementExtractor.sliceBudget).count }
            print("""
                \(url.deletingPathExtension().lastPathComponent.prefix(0))\
                statement: \(pages.count) page(s), chars \(sizes), slices \(groups)
                """)

            let started = Date()
            let rows = try await StatementExtractor.extract(pages: pages)
            let elapsed = Date().timeIntervalSince(started)
            print("  -> \(rows.count) row(s) in \(String(format: "%.1f", elapsed))s")

            // The point of the harness: it completes. An empty result on a page
            // of transactions means the chunking is not doing its job.
            #expect(!rows.isEmpty)
            // Rows come back in date order and carry a non-zero amount.
            #expect(rows.map(\.date) == rows.map(\.date).sorted())
            #expect(rows.allSatisfy { $0.amount != 0 })
        }
    }
}
#endif
