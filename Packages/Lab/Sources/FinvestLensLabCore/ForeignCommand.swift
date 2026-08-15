//
//  ForeignCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensUI

/// `finlab foreign` — restructures card transactions the bank already told us
/// were foreign (`FR-CUR-02`, `FR-REG-07`).
///
/// The reading and the decision both live in `AppModel` (see
/// ``NarrativeFX`` and `parseNarrativeFX`), so the same parse the app could
/// offer is the one this writes with, and it is unit-tested there rather than
/// only exercised by running the tool over someone's book.
///
/// What it writes is GnuCash's own multi-currency form and nothing else: the
/// transaction's currency becomes the foreign one, each split's `value` carries
/// the foreign amount so the transaction balances in the currency it was struck
/// in, and each `quantity` keeps the local amount that moved the account. The
/// implied rate is recorded as a price.
///
/// **The stated card fee is left inside the charge.** Splitting it out is a
/// decision about a chart of accounts — which expense account, and whether the
/// owner wants fees separated at all — so it is reported, not posted.
///
/// Nothing is written without `--apply`.
enum ForeignCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let file = try options.existingURL("file")
        let apply = options.flag("apply")
        let accountName = options.string("account")
        // Where a stated card fee should go. Absent, the fee stays inside the
        // charge and is only reported — which expense account it belongs to is
        // not something this tool should decide.
        let feeAccountName = options.string("fee-account")
        let since = try options.string("since").map { text -> Date in
            guard let date = Self.day.date(from: text) else {
                throw LabError.message("--since wants yyyy-MM-dd, got '\(text)'")
            }
            return date
        }

        let model = AppModel()
        let (_, openSeconds) = try await Stopwatch.measure {
            try await model.open(at: file, breakStaleLock: true)
        }
        defer { model.close() }
        log(Fmt.row("open \(file.lastPathComponent)", Fmt.time(openSeconds)))
        guard !model.isReadOnly else { throw LabError.message("book opened read-only") }

        let feeAccountID = try feeAccountName.map { name -> GncGUID in
            let matches = model.postableAccounts.filter {
                $0.fullName == name || $0.name == name
            }
            guard let only = matches.first, matches.count == 1 else {
                throw LabError.message(matches.isEmpty
                    ? "no account named '\(name)'"
                    : "'\(name)' matches \(matches.count) accounts — use the full path")
            }
            return only.id
        }

        let candidates = model.narrativeForeignCandidates(accountName: accountName, since: since)
        guard !candidates.isEmpty else {
            log("  no transaction carries a foreign amount in its narrative — nothing to do.")
            return
        }

        if let feeAccountName {
            log("  card fees → \(feeAccountName)")
        }
        log("  \(candidates.count) transaction(s) the bank recorded in another currency:")
        var applied = 0
        var aligned = 0
        var refused: [String] = []
        for candidate in candidates {
            let line = Self.line(candidate)
            guard apply else { log(line); continue }
            let outcome = model.restructureAsForeign(
                transactionID: candidate.transactionID,
                foreignAmount: candidate.foreignAmount,
                currencyCode: candidate.currencyCode)
            if outcome.didRestructure {
                applied += 1
                log(line)
            } else if model.alignForeignAccountQuantity(
                        transactionID: candidate.transactionID,
                        foreignAmount: candidate.foreignAmount,
                        currencyCode: candidate.currencyCode, apply: apply) {
                // Not a purchase abroad but money moved into an account already
                // held in that currency, carrying the wrong quantity.
                aligned += 1
                log(line + "  [quantity corrected]")
            } else if outcome == .notForeign, feeAccountID != nil {
                // Already converted on an earlier run — still a candidate for
                // having its fee separated, which is the whole point of being
                // able to run this twice.
                log(line)
            } else {
                refused.append("\(Self.day.string(from: candidate.date)) "
                               + "\(candidate.currencyCode): \(outcome)")
            }
        }
        for reason in refused { log("    refused: \(reason)") }

        // The fee pass runs over the same list, after the conversions, because
        // it needs the rate the conversion establishes.
        var feesSplit = 0
        if let feeAccountID {
            for candidate in candidates {
                guard let fee = candidate.plausibleFee else { continue }
                let outcome = model.splitCardFee(transactionID: candidate.transactionID,
                                                 feeLocal: fee, feeAccountID: feeAccountID,
                                                 apply: apply)
                if outcome.didSplit {
                    feesSplit += 1
                } else if outcome != .notSimple {
                    // `.notSimple` is the already-done case on a second run,
                    // which is not worth a line every time.
                    refused.append("\(Self.day.string(from: candidate.date)) fee: \(outcome)")
                }
            }
        }

        guard apply else {
            if feeAccountID != nil { log("  \(feesSplit) fee(s) would move to their own leg.") }
            log("  dry run — pass --apply to write.")
            return
        }
        try model.save()
        log("  restructured \(applied), \(aligned) foreign-account quantity/ies corrected, saved.")
        let withFees = candidates.filter { $0.plausibleFee != nil }
        let total = withFees.compactMap(\.plausibleFee).reduce(Decimal(0), +)
        if feeAccountID != nil {
            log("  \(feesSplit) card fee(s) totalling \(Self.money(total)) "
                + "moved to \(feeAccountName ?? "").")
        } else if !withFees.isEmpty {
            log("  \(withFees.count) carried a stated card fee totalling "
                + "\(Self.money(total)) — left inside the charge, because which "
                + "expense account it belongs to is yours to say.")
        }
    }

    private static func line(_ candidate: NarrativeFX) -> String {
        var out = "    " + Self.day.string(from: candidate.date) + "  "
        out += Self.money(candidate.foreignAmount) + " " + candidate.currencyCode
        out += " → " + Self.money(candidate.localAmount)
        out += " @ " + Self.rate(candidate.impliedRate)
        if let fee = candidate.plausibleFee { out += "  (fee " + Self.money(fee) + ")" }
        return out
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// Five decimal places.
    ///
    /// `NSDecimalNumber.intValue` was the obvious spelling and it is wrong:
    /// a Decimal division carries more significant digits than `Int64` holds,
    /// so `intValue` returned 0 and the first dry run reported every rate as
    /// "@ 0". `NSDecimalRound` works on the Decimal itself and has no such
    /// ceiling.
    private static func rate(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 5, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}
