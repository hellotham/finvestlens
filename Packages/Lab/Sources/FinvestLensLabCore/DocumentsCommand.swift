//
//  DocumentsCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensUI

/// `finlab documents` — read a folder of receipts and statements, find the
/// transaction each one belongs to, attach it, and categorise it.
///
/// The matching itself is `AppModel.matchAttachments`, the same call the app's
/// Match Attachments sheet makes. What this adds is the part that only existed
/// inside a SwiftUI sheet: the loop that walks accepted matches, attaches the
/// file and applies the suggestion.
///
/// Work is done in batches, and each batch is applied and saved before the
/// next is matched. That is not just for progress. `matchAttachments` refuses
/// to let two files in one call claim the same transaction, but across two
/// calls its only defence is the set of transactions that already carry a
/// link — which is only true once the previous batch has been *applied*.
/// Matching everything up front and applying at the end would let two receipts
/// for the same amount both claim one transaction.
enum DocumentsCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let file = try options.existingURL("file")
        let root = try options.existingURL("root")
        let kind = DocumentScanner.Kind(rawValue: options.string("kind") ?? "any") ?? .any
        let apply = options.flag("apply")
        let batchSize = max(1, options.int("batch") ?? 12)
        let rates = try Self.exchangeRates(options.string("fx"))

        // 1 — decide what to feed in.
        let (documents, duplicates, outOfPeriod) = try Stopwatch.measure {
            try DocumentScanner.scan(root: root, since: options.date("since"),
                                     until: options.date("until"), kind: kind,
                                     limit: options.int("limit"))
        }.value
        log("Scanned \(root.path)")
        log("  \(documents.count) document(s) in period"
            + (duplicates > 0 ? ", \(duplicates) duplicate(s) skipped" : "")
            + (outOfPeriod > 0 ? ", \(outOfPeriod) outside the window" : ""))
        guard !documents.isEmpty else { return }

        let bySource = Dictionary(grouping: documents, by: \.dateSource)
            .map { "\($0.value.count) by \($0.key.rawValue)" }.sorted()
        log("  dates: " + bySource.joined(separator: ", "))
        log("")

        // 2 — open the book.
        let model = AppModel()
        let (_, openSeconds) = try await Stopwatch.measure {
            try await model.open(at: file, breakStaleLock: true)
        }
        log(Fmt.row("open \(file.lastPathComponent)", Fmt.time(openSeconds)))
        // Release the lock however this run ends. A headless session drives no
        // heartbeat, so a leaked lock is not merely untidy: it stays *fresh*
        // for its full staleness window, and the next run — including a retry
        // seconds later — is refused rather than being allowed to break it.
        defer { model.close() }
        guard !model.isReadOnly else { throw LabError.message("book opened read-only; nothing can be applied") }

        // Files this book already carries a link to.
        //
        // `matchAttachments` recognises them too, but only after OCR'ing each
        // one — and OCR plus two model calls is essentially the entire cost of
        // a run. Dropping them here is what makes the ingest loop usable:
        // each pass over a folder then costs only the documents that have not
        // been placed yet, so improving the matcher and running again is a
        // minute's work rather than a quarter of an hour's.
        var alreadyLinked: Set<String> = []
        for linked in model.linkedDocuments() {
            alreadyLinked.insert(linked.displayName.lowercased())
            if let decoded = linked.link.removingPercentEncoding {
                alreadyLinked.insert((decoded as NSString).lastPathComponent.lowercased())
            }
        }
        let pending = documents.filter { !alreadyLinked.contains($0.url.lastPathComponent.lowercased()) }
        if pending.count != documents.count {
            log("  \(documents.count - pending.count) already attached — skipping")
        }
        guard !pending.isEmpty else {
            log("  nothing left to do.")
            return
        }

        // Attachments are copied into a folder beside the book unless told
        // otherwise. A CLI has its own UserDefaults domain, so the app's
        // configured folder is not visible here and must be set explicitly —
        // otherwise every link would resolve against the book's own directory
        // and the originals would never be copied anywhere.
        if let attachments = options.url("attachments") {
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
            model.configuredDocumentFolder = attachments
            log("  attachments → \(attachments.path)")
        }
        log("")

        var linked = 0, categorised = 0, matched = 0, applyFailures = 0, byRate = 0
        var unmatched: [(name: String, note: String)] = []
        var claimedThisRun: Set<GncGUID> = []
        let started = Stopwatch()

        /// Copies the file beside the book and links it. Shared because a
        /// rate-derived match is attached exactly like an exact one — the
        /// difference is only in how the transaction was found, and that
        /// belongs in the log, not in what gets written.
        @MainActor func attach(_ match: AppModel.AttachmentMatch, to transactionID: GncGUID) async {
            guard let data = try? await Task.detached(operation: { [url = match.url] in
                try Data(contentsOf: url)
            }).value else { applyFailures += 1; return }
            do {
                _ = try model.attachDocument(named: match.fileName, data: data, to: transactionID)
                linked += 1
            } catch {
                applyFailures += 1
                log("  ⚠︎ \(match.fileName): \(error.localizedDescription)")
            }
            if let suggestion = match.suggestion,
               model.applyAttachmentSuggestion(suggestion, to: transactionID) {
                categorised += 1
            }
        }

        // 3 — match, apply, save, one batch at a time.
        for (index, batch) in pending.chunked(into: batchSize).enumerated() {
            let urls = batch.map(\.url)
            let (matches, matchSeconds) = await Stopwatch.measure {
                await model.matchAttachments(urls: urls)
            }

            for match in matches {
                guard let transactionID = match.transactionID else {
                    // The currency the document names, when it names one, is
                    // the difference between "the matcher failed" and "this
                    // receipt is in ringgit and the posting is in dollars, so
                    // no amount on it could ever equal the amount in the
                    // book". Those need opposite responses, so the report has
                    // to tell them apart.
                    // Last resort, and only when asked for: convert at a rate
                    // the operator supplied for this trip. Off unless --fx
                    // names the currency, because converting at an assumed
                    // rate is guesswork and guesswork about money is worse
                    // than an unmatched receipt.
                    if let code = match.currencyHint, let rate = rates[code],
                       let converted = match.candidateAmounts.lazy.compactMap({ amount in
                           model.matchByConvertedAmount(amount, rate: rate, near: match.documentDate,
                                                        spending: true, excluding: claimedThisRun)
                       }).first {
                        matched += 1
                        byRate += 1
                        claimedThisRun.insert(converted.transactionID)
                        log("  ~ \(match.fileName): \(code) at \(rate) → \(converted.summary) "
                            + "(implied \(converted.impliedRate))")
                        if apply { await attach(match, to: converted.transactionID) }
                        continue
                    }
                    let hint = match.currencyHint.map { " [\($0)]" } ?? ""
                    unmatched.append((match.fileName, (match.note ?? "no reason given") + hint))
                    continue
                }
                matched += 1
                claimedThisRun.insert(transactionID)
                guard apply else { continue }
                await attach(match, to: transactionID)
            }

            if apply {
                try model.save()
            }
            let done = min((index + 1) * batchSize, pending.count)
            log("  batch \(index + 1): \(done)/\(pending.count) — "
                + "matched \(matched), linked \(linked), categorised \(categorised) "
                + "(\(Fmt.time(matchSeconds)) for \(urls.count) file(s))")
        }

        // 4 — report.
        let elapsed = started.seconds
        log("")
        log(Fmt.row("total", Fmt.time(elapsed)))
        log(Fmt.row("  per document", Fmt.time(elapsed / Double(pending.count))))
        log("")
        log("  matched      \(matched)/\(pending.count) "
            + "(\(percent(matched, of: pending.count)))")
        if apply {
            log("  attached     \(linked)")
            if byRate > 0 { log("  by fx rate   \(byRate)  (approximate — review these)") }
            log("  categorised  \(categorised)")
            if applyFailures > 0 { log("  failed       \(applyFailures)") }
        } else {
            log("  (dry run — pass --apply to attach and categorise)")
        }

        if !unmatched.isEmpty {
            log("")
            log("  \(unmatched.count) unmatched:")
            // Grouped by reason: thirty lines of the same sentence tells you
            // nothing, one line saying it happened thirty times tells you where
            // to look next.
            let grouped = Dictionary(grouping: unmatched, by: { reasonBucket($0.note) })
            for (reason, items) in grouped.sorted(by: { $0.value.count > $1.value.count }) {
                log("    \(items.count)× \(reason)")
                // The note carries the amounts that were read and the date they
                // were searched near — which is the whole diagnosis. Printed in
                // full while the list is short enough to read, because the next
                // move after a failed run is deciding *why*, and a bucket name
                // alone cannot tell you whether OCR misread the total or the
                // transaction simply is not in the book.
                let detailed = items.count <= 40
                for item in items.prefix(detailed ? items.count : 4) {
                    log(detailed ? "        \(item.name)\n            \(item.note)" : "        \(item.name)")
                }
                if !detailed { log("        … and \(items.count - 4) more") }
            }
        }

        if let report = options.url("report") {
            try writeReport(documents: pending, unmatched: unmatched, matched: matched,
                            linked: linked, categorised: categorised, to: report)
            log("")
            log("  report → \(report.path)")
        }
    }

    /// `--fx NZD=0.905,MYR=0.34` — book currency per unit of the foreign one.
    ///
    /// Deliberately explicit and per-run rather than stored: a card's rate
    /// moves daily and carries the issuer's margin, so a rate is only ever
    /// right for one trip. Naming it at the point of use keeps that visible,
    /// and leaving it out keeps rate-based matching off — which is the
    /// default, because most issuers record the original amount and reading it
    /// beats converting at a guess.
    static func exchangeRates(_ text: String?) throws -> [String: Decimal] {
        guard let text, !text.isEmpty else { return [:] }
        var rates: [String: Decimal] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let rate = Decimal(string: String(parts[1]).trimmingCharacters(in: .whitespaces)),
                  rate > 0
            else { throw LabError.message("bad --fx entry '\(pair)' — expected e.g. NZD=0.905") }
            rates[String(parts[0]).trimmingCharacters(in: .whitespaces).uppercased()] = rate
        }
        return rates
    }

    /// Collapses a per-file note to the class of problem it represents.
    private static func reasonBucket(_ note: String) -> String {
        if note.contains("already has an attachment") { return "the matching transaction is already linked" }
        if note.contains("Couldn't read an amount") { return "no amount could be read (OCR)" }
        if note.contains("No unlinked transaction matches") { return "no transaction matches the amount read" }
        return note
    }

    private static func percent(_ part: Int, of whole: Int) -> String {
        whole == 0 ? "—" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    /// A run report. Filenames and outcomes only — no amounts, no payees, no
    /// account names: this is the file most likely to be pasted somewhere.
    private static func writeReport(documents: [ScannedDocument], unmatched: [(name: String, note: String)],
                                    matched: Int, linked: Int, categorised: Int, to url: URL) throws {
        var lines = ["file,date,date_source,outcome"]
        let unmatchedNames = Set(unmatched.map(\.name))
        for document in documents {
            let date = document.date.map { LabOptions.dayFormatter.string(from: $0) } ?? ""
            let outcome = unmatchedNames.contains(document.url.lastPathComponent) ? "unmatched" : "matched"
            lines.append("\"\(document.url.lastPathComponent)\",\(date),\(document.dateSource.rawValue),\(outcome)")
        }
        lines.append("")
        lines.append("# matched \(matched), attached \(linked), categorised \(categorised), total \(documents.count)")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension Array {
    /// Fixed-size slices, last one short.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
