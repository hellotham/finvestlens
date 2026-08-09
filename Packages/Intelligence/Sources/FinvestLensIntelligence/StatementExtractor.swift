//
//  StatementExtractor.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensInterchange
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extracts transactions from PDF bank/card statements using the on-device
/// model (`FR-AI-01`).
///
/// PDFs have no machine-readable transaction structure, so this is where a
/// language model earns its keep: each page of extracted text becomes one
/// guided-generation request (the on-device context window is small, and
/// statements are naturally page-structured), and the typed results merge
/// into the same ``StagedTransaction`` rows the CSV/QIF/OFX importers emit —
/// so matching, rules, and review all work unchanged downstream.
@available(macOS 26.0, iOS 26.0, *)
public enum StatementExtractor {

    #if canImport(FoundationModels)
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
    #endif

    /// How much statement text to put in one request.
    ///
    /// Not a context-window limit — the window is dominated by *output*, which
    /// ``ModelPage/transactions`` bounds. This is a working-set size: the
    /// smaller the slice, the fewer rows the model has to hold in mind at once,
    /// and the closer its answer stays to what is actually printed. 1,000
    /// characters is roughly fifteen statement rows, comfortably inside the
    /// twenty-row cap, so a slice never needs the cap to save it.
    static let sliceBudget = 1_000

    /// Folds text to letters and digits only, so a payee can be looked for in
    /// the source without spacing, case or punctuation getting in the way.
    static func grounding(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Whether an amount the model reported is actually printed in the slice.
    ///
    /// The instructions say "report amounts exactly as printed", so the digits
    /// must be there. Folded to digits alone this survives the differences that
    /// do not matter — a leading minus the statement writes as a trailing `CR`,
    /// a thousands separator the model drops — while a padded row's invented
    /// amount has no match at all. It is the sharper half of the grounding
    /// pair: a merchant name can be guessed plausibly, an exact cent figure
    /// much less so.
    static func isAmountPrinted(_ amount: String, in source: String) -> Bool {
        let digits = amount.filter(\.isNumber)
        // Under $10.00 an amount folds to three digits or fewer, which is short
        // enough to hit by chance in a page of card numbers and dates — so the
        // check abstains there rather than rejecting a real row on a weak test.
        guard digits.count >= 4 else { return true }
        return source.contains(digits)
    }

    /// Whether `payee` actually occurs in the slice it was extracted from.
    ///
    /// The prompt asks for the payee "cleaned up", so an exact match is the
    /// wrong test: `WOOLWORTHS 3421 SYDNEY NS` legitimately comes back as
    /// `Woolworths`. Folded to letters and digits, the cleaned name is still a
    /// substring of the printed one — while an invented merchant is not.
    ///
    /// Short names are exempt: below four folded characters the containment
    /// test stops discriminating (`BP`, `Aldi`) and would start accepting
    /// anything.
    static func isGrounded(_ payee: String, in source: String) -> Bool {
        let needle = grounding(payee)
        guard needle.count >= 4 else { return !needle.isEmpty }
        if source.contains(needle) { return true }
        // A multi-word payee may be cleaned by dropping a word rather than
        // punctuation ("Transport for NSW Travel" → "Transport NSW"), so accept
        // it when every word of four or more characters is present.
        let words = payee.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { grounding(String($0)) }
            .filter { $0.count >= 4 }
        return !words.isEmpty && words.allSatisfy { source.contains($0) }
    }

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
        #if canImport(FoundationModels)
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

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
        func extract(slice: String) async throws {
            let session = LanguageModelSession(instructions: """
                You extract transaction rows from bank and credit card statement text.
                Report amounts exactly as printed, signed from the account holder's \
                perspective: purchases, withdrawals and fees are negative; deposits, \
                salary and refunds are positive. Never invent transactions that are \
                not in the text.
                """)
            do {
                let response = try await session.respond(
                    to: "Statement page:\n\n\(slice)",
                    generating: ModelPage.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                if let opening = IntelligenceParsing.amount(response.content.openingBalance) {
                    previousBalance = opening
                }
                let source = Self.grounding(slice)
                for row in response.content.transactions {
                    guard let date = IntelligenceParsing.date(row.date),
                          let amount = IntelligenceParsing.amount(row.amount),
                          amount != 0,
                          // The instructions say never to invent a transaction;
                          // this is what checks. A capped array stops runaway
                          // generation but not padding — the model fills the
                          // remaining slots with plausible rows — so a row is
                          // kept only if both its payee and its amount are
                          // actually in the text it was extracted from.
                          Self.isGrounded(row.payee, in: source),
                          Self.isAmountPrinted(row.amount, in: source)
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
                    raw.append(RawRow(date: date, amount: amount, payee: row.payee,
                                      reference: row.reference,
                                      previous: previousBalance, balance: balance))
                    if let balance { previousBalance = balance }
                }
            } catch {
                throw IntelligenceError.wrap(error)
            }
        }

        /// Tries `text` whole; on refusal, halves it on a line boundary and
        /// tries each half in document order, so the running balance and the
        /// dedupe set still see rows in the order they were printed.
        func extractSplitting(_ text: String) async throws {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            do {
                try await extract(slice: trimmed)
                return
            } catch IntelligenceError.contextOverflow {
                // Only overflow is worth retrying smaller. A guardrail refusal
                // or an unavailable model would fail identically on both halves
                // and on all four quarters, so halving those would turn one
                // failure into 2n slow ones and still report the same thing.
                //
                // A single line that will not go through is a real failure too,
                // not something more halving can fix.
                let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                guard lines.count > 1 else { throw IntelligenceError.contextOverflow }
                let middle = lines.count / 2
                try await extractSplitting(lines[..<middle].joined(separator: "\n"))
                try await extractSplitting(lines[middle...].joined(separator: "\n"))
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
        var firstFailure: IntelligenceError?
        for (index, page) in pages.enumerated() {
            for group in Self.lineGroups(page.text, budget: Self.sliceBudget) {
                do {
                    try await extractSplitting(group)
                } catch {
                    if firstFailure == nil { firstFailure = IntelligenceError.wrap(error) }
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
        #else
        throw IntelligenceError.unavailable("Apple Intelligence is not available on this platform.")
        #endif
    }
}
