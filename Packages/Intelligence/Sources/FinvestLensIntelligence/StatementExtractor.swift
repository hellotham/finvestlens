//
//  StatementExtractor.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensInterchange
import FoundationModels

/// Extracts transactions from PDF bank/card statements using the on-device
/// model (`FR-AI-01`).
///
/// PDFs have no machine-readable transaction structure, so this is where a
/// language model earns its keep: each page of extracted text becomes one
/// guided-generation request (the on-device context window is small, and
/// statements are naturally page-structured), and the typed results merge
/// into the same ``StagedTransaction`` rows the CSV/QIF/OFX importers emit —
/// so matching, rules, and review all work unchanged downstream.
public enum StatementExtractor {

    @Generable
    struct ModelTransaction {
        @Guide(description: "Transaction date in yyyy-MM-dd format")
        var date: String
        @Guide(description: "Signed amount: negative for money out (withdrawals, purchases, fees, amounts in a Debit column), positive for money in (deposits, salary, refunds, amounts in a Credit column)")
        var amount: String
        @Guide(description: "Merchant or payee name, cleaned up")
        var payee: String
        @Guide(description: "Reference or receipt number if shown, else empty")
        var reference: String
        @Guide(description: "The running balance printed at the end of this row, empty if the statement has no balance column")
        var balanceAfter: String
    }

    @Generable
    struct ModelPage {
        @Guide(description: "Opening or brought-forward balance printed on this page, empty if none")
        var openingBalance: String
        /// The ceiling is the point of this guide, not the wording.
        ///
        /// Guided generation constrains the *shape* of the answer, not its
        /// length, so an unbounded array is an unbounded token budget — and the
        /// context window counts generated tokens alongside the prompt.
        /// Measured on a real ANZ statement: a **664-character** slice failed at
        /// "4093 tokens, which exceeds the maximum allowed context size of
        /// 4096" after 56 seconds. The input was some 200 tokens; the model
        /// spent the other 3,900 repeating rows. Capped, the same slice
        /// answered in 11.8 seconds.
        ///
        /// 20 comfortably exceeds the rows in one ``sliceBudget`` of statement
        /// text, so it truncates runaway generation without truncating a real
        /// page. It does not stop the model *padding* up to the cap — that is
        /// what the grounding check in `extract(slice:)` is for.
        @Guide(description: "Every transaction row on this statement page. Exclude opening/closing balance lines, subtotals, and marketing text.", .maximumCount(20))
        var transactions: [ModelTransaction]
    }

    /// What every request is told, and how a slice is put to the model — in
    /// one place so that a harness asking why a row went missing asks the
    /// model exactly what the reader asks it.
    static let instructions = """
        You extract transaction rows from bank and credit card statement text.
        Report amounts exactly as printed, signed from the account holder's \
        perspective: purchases, withdrawals and fees are negative; deposits, \
        salary and refunds are positive. Never invent transactions that are \
        not in the text.
        """

    static func prompt(for slice: String) -> String { "Statement page:\n\n\(slice)" }

    /// Reads `text` whole; where it will not go through, or comes back with
    /// the debris of an answer gone wrong, halves it on a line boundary and
    /// reads each half in document order, so the running balance and the
    /// dedupe set still see rows in the order they were printed.
    ///
    /// What reads a slice is handed in, so that this — which decides what a
    /// statement import keeps when a model misbehaves — can be tested with
    /// answers that are scripted rather than hoped for.
    ///
    /// - Parameters:
    ///   - rereads: how many more times a slice may be halved because its
    ///     *answer* went wrong. Halving for overflow has no such limit: a
    ///     slice that does not fit never will.
    ///   - read: one request over one slice.
    ///   - keep: what is done with each answer that is to be kept, with the
    ///     slice it was read from.
    static func reading(
        _ text: String, rereads: Int = 2,
        read: (String) async throws -> ModelPage,
        keep: (ModelPage, String) -> Void
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        func halves(rereads: Int, keep: (ModelPage, String) -> Void) async throws {
            let middle = lines.count / 2
            try await reading(lines[..<middle].joined(separator: "\n"), rereads: rereads, read: read, keep: keep)
            try await reading(lines[middle...].joined(separator: "\n"), rereads: rereads, read: read, keep: keep)
        }

        let page: ModelPage
        do {
            let answered = try await read(trimmed)
            page = answered
        } catch IntelligenceError.contextOverflow {
            // Only overflow is worth retrying smaller. A guardrail refusal or
            // an unavailable model would fail identically on both halves and
            // on all four quarters, so halving those would turn one failure
            // into 2n slow ones and still report the same thing.
            //
            // A single line that will not go through is a real failure too,
            // not something more halving can fix.
            guard lines.count > 1 else { throw IntelligenceError.contextOverflow }
            try await halves(rereads: rereads, keep: keep)
            return
        }

        // An answer that has lost its place — a date that is ": ", an amount
        // that is "date:" — is short as well as wrong: on a supplied model,
        // eighteen of a hundred and twenty rows were never written at all,
        // each time after a row like that (12 October 2026). The rows that
        // are sound are not the trouble; the ones that are missing are, and
        // only reading again finds them. A shorter slice is a shorter
        // answer, with less of it to go wrong.
        guard rereads > 0, lines.count > 1, hasDebris(page) else {
            keep(page, trimmed)
            return
        }
        // The second reading is held until both halves are in. If either
        // fails, the first reading is what there is, and what the checks
        // keep of it is kept — as it always was. (Kept as they came, a
        // failed second half left the slice with half its rows where the
        // reading being replaced had most of them; and an overflow beneath
        // was caught above and both halves read a second time.)
        var held: [(ModelPage, String)] = []
        do {
            try await halves(rereads: rereads - 1) { held.append(($0, $1)) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = IntelligenceError.wrap(error)
            if failure.endsABatch { throw failure }
            keep(page, trimmed)
            return
        }
        for (page, slice) in held { keep(page, slice) }
    }

    /// Whether an answer carries the debris of having gone wrong part-way
    /// (``IntelligenceParsing/isDebris(_:)``), in any field of any row.
    ///
    /// A date or an amount is debris either way it can be. A payee is only
    /// when it is the grammar's own punctuation: a page can print a payee
    /// as one word and a colon ("Interest:"), and reading that page again
    /// in halves — six more requests — would find the same word.
    static func hasDebris(_ page: ModelPage) -> Bool {
        IntelligenceParsing.isDebris(page.openingBalance) || page.transactions.contains {
            IntelligenceParsing.isDebris($0.date) || IntelligenceParsing.isDebris($0.amount)
                || IntelligenceParsing.isDebris($0.balanceAfter)
                || IntelligenceParsing.isStructuralDebris($0.payee)
                || IntelligenceParsing.isStructuralDebris($0.reference)
        }
    }

    /// How much statement text to put in one request.
    ///
    /// Not a context-window limit — the window is dominated by *output*, which
    /// ``ModelPage/transactions`` bounds. This is a working-set size: the
    /// smaller the slice, the fewer rows the model has to hold in mind at once,
    /// and the closer its answer stays to what is actually printed. 1,000
    /// characters is roughly fifteen statement rows, comfortably inside the
    /// twenty-row cap, so a slice never needs the cap to save it.
    static let sliceBudget = 1_000

    /// Splits text into groups of whole lines, each at most `budget`
    /// characters. A single line longer than the budget is left whole — cutting
    /// mid-row would split a transaction from its amount.
    static func lineGroups(_ text: String, budget: Int) -> [String] {
        var groups: [String] = []
        var current: [Substring] = []
        var size = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if size + line.count > budget, !current.isEmpty {
                groups.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { groups.append(current.joined(separator: "\n")) }
        return groups
    }

    /// Extracts staged transactions from statement pages.
    ///
    /// - Parameter onProgress: called on completion of each page with
    ///   (pagesDone, pageCount) — drive a progress indicator from this.
    public static func extract(
        pages: [DocumentText.Page],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [StagedTransaction] {
        // Says "unavailable" once, before any page is read, rather than once
        // per slice.
        _ = try await LanguageModels.resolve(.statementExtractor)

        struct RawRow {
            var date: Date; var amount: Decimal; var payee: String; var reference: String
            var previous: Decimal?; var balance: Decimal?
        }
        var raw: [RawRow] = []
        var seen = Set<String>()
        // Running balance carried across rows (and pages) for sign correction.
        var previousBalance: Decimal?
        /// One request over one slice of statement text, folding whatever it
        /// finds into `raw`.
        ///
        /// A page is **not** a safe unit of work: measured on four real ANZ
        /// credit-card statements (Jan–Apr 2026), every page of every month
        /// failed with "Exceeded model context window size" under the old
        /// 6,000-character cap.
        ///
        /// The cause was not the size of the page, which is worth stating
        /// plainly because the obvious reading is wrong and cost a day. A
        /// **664-character** slice failed the same way, at "4093 tokens, which
        /// exceeds the maximum allowed context size of 4096", after 56 seconds
        /// — some 200 tokens of input and 3,900 of the model repeating itself
        /// into an unbounded array. Capping the array fixed all four
        /// statements; the same slice then answered in 11.8 seconds.
        ///
        /// So slicing is for answer quality, not for fitting, and the halving
        /// retry below is a safety net for a window that is no longer expected
        /// to overflow at all.
        func read(slice: String) async throws -> ModelPage {
            try await LanguageModels.respond(
                .statementExtractor,
                instructions: Self.instructions,
                prompt: Self.prompt(for: slice),
                generating: ModelPage.self)
        }

        /// Folds what one request found on one slice into `raw`.
        func fold(_ page: ModelPage, from slice: String) {
            if let opening = IntelligenceParsing.amount(page.openingBalance) {
                previousBalance = opening
            }
            let source = SourceGrounding.folded(slice)
            // A row may not be reported more often than its amount is
            // printed on this slice. The dedupe set below holds the payee
            // verbatim, so a restated row worded differently slips past it;
            // the page cannot be argued with.
            var reported: [String: Int] = [:]
            for row in page.transactions {
                guard let date = IntelligenceParsing.date(row.date),
                      let amount = IntelligenceParsing.amount(row.amount),
                      amount != 0,
                      // The instructions say never to invent a transaction;
                      // this is what checks. A capped array stops runaway
                      // generation but not padding — the model fills the
                      // remaining slots with plausible rows — so a row is
                      // kept only if both its payee and its amount are
                      // actually in the text it was extracted from.
                      SourceGrounding.isNamePrinted(row.payee, in: source),
                      SourceGrounding.isAmountPrinted(row.amount, in: source)
                else { continue }
                let digits = row.amount.filter(\.isNumber)
                reported[digits, default: 0] += 1
                guard reported[digits, default: 0]
                        <= SourceGrounding.printedCount(row.amount, in: source)
                else { continue }
                let balance = IntelligenceParsing.amount(row.balanceAfter)
                // Dedupe across pages (carried-over rows, repeated headers).
                // Include the running balance and reference so two genuinely
                // distinct same-day/amount/payee rows (e.g. two identical
                // coffees) aren't collapsed — only a truly repeated row, which
                // shares its balance and reference too, is dropped.
                let key = "\(row.date)|\(abs(amount))|\(row.payee.lowercased())|\(row.reference)|\(row.balanceAfter)"
                guard seen.insert(key).inserted else {
                    if let balance { previousBalance = balance }
                    continue
                }
                // What cannot be a reference is not kept as one: at the end
                // of its rereads an answer may still carry ": " there.
                raw.append(RawRow(date: date, amount: amount, payee: row.payee,
                                  reference: IntelligenceParsing.isDebris(row.reference) ? "" : row.reference,
                                  previous: previousBalance, balance: balance))
                if let balance { previousBalance = balance }
            }
        }

        // One slice the model will not read must not cost the whole statement.
        // Real pages carry blocks that are barely language at all — BSB and
        // card numbers, transaction codes, an interest-rate table — and the
        // model rejects those outright ("An unsupported language or locale was
        // used"), which on a four-page ANZ statement threw away three good
        // pages for one bad block. Failures are collected instead, and only
        // reported if nothing came back at all, so a total failure is still
        // told the truth rather than reported as a statement with no
        // transactions.
        //
        // That is for a failure about one slice. A failure about the model
        // itself — it is unavailable, it is rate-limited because the app
        // went to the background, the run was cancelled — will be the same
        // on every slice that follows, and collecting those returned the
        // first two pages of a six-page statement as the statement. Those
        // stop the run: an incomplete statement presented as complete is
        // worse than being asked to try again.
        var firstFailure: IntelligenceError?
        for (index, page) in pages.enumerated() {
            for group in Self.lineGroups(page.text, budget: Self.sliceBudget) {
                do {
                    try await Self.reading(group, read: read(slice:), keep: fold)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let failure = IntelligenceError.wrap(error)
                    if failure.endsABatch { throw failure }
                    if firstFailure == nil { firstFailure = failure }
                }
            }
            onProgress?(index + 1, pages.count)
        }
        if raw.isEmpty, let firstFailure { throw firstFailure }

        // The balance column fixes signs deterministically — but the
        // CONVENTION depends on the account: an asset statement's balance
        // falls after money out, while a credit card's positive amount-owed
        // balance RISES after a purchase. Applying the asset reading
        // unconditionally inverted every row on card statements, so the
        // statement votes: whichever reading agrees with more of the model's
        // own signs (the guide makes purchases negative) wins, and rows whose
        // balance delta explains their magnitude are corrected under it.
        var assetVotes = 0
        var liabilityVotes = 0
        for row in raw {
            guard let previous = row.previous, let balance = row.balance else { continue }
            let delta = balance - previous
            guard delta != 0, abs(delta) == abs(row.amount) else { continue }
            if (delta > 0) == (row.amount > 0) { assetVotes += 1 }
            if (delta < 0) == (row.amount > 0) { liabilityVotes += 1 }
        }
        let liabilityConvention = liabilityVotes > assetVotes

        var staged: [StagedTransaction] = []
        for row in raw {
            var amount = row.amount
            if let previous = row.previous, let balance = row.balance {
                let delta = balance - previous
                if abs(delta) == abs(amount) {
                    amount = liabilityConvention ? -delta : delta
                }
            }
            staged.append(StagedTransaction(
                date: row.date, amount: amount,
                payee: row.payee, reference: row.reference))
        }
        return staged.sorted { $0.date < $1.date }
    }
}
