//
//  FundamentalsCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensUI

/// `finlab fundamentals` — company profile and financials for every security
/// (`FR-INV-39`).
///
/// The same `AppModel.fetchAllFundamentals` the app's Investments ▸ More
/// command calls, so a headless fill and an in-app one produce the same book.
/// Sequential by design: these are the rate-limited hosts the quote fetch uses,
/// and a fan-out over eighty securities is how a provider starts refusing.
///
/// Bonds are the cheap case — FIIG's profile rides in the same one-request
/// index its prices come from, so `companyDescription` for every bond costs
/// nothing extra.
enum FundamentalsCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let file = try options.existingURL("file")
        let force = options.flag("force")

        let model = AppModel()
        let (_, openSeconds) = try await Stopwatch.measure {
            try await model.open(at: file, breakStaleLock: true)
        }
        defer { model.close() }
        log(Fmt.row("open \(file.lastPathComponent)", Fmt.time(openSeconds)))
        guard !model.isReadOnly else { throw LabError.message("book opened read-only") }

        let covered = model.fundamentalsCoveredSecurities
        log(Fmt.row("securities with a provider", Fmt.count(covered.count)))
        guard !covered.isEmpty else {
            log("  no configured provider supplies company data — nothing to fetch.")
            return
        }
        if force { log("  --force: refetching every section, TTLs ignored.") }

        let (_, seconds) = try await Stopwatch.measure {
            await model.fetchAllFundamentals(force: force)
        }
        log(Fmt.row("fetch", Fmt.time(seconds)))

        var withProfile = 0
        var missing: [String] = []
        for commodity in covered {
            if model.fundamentals(for: commodity)?.profile != nil {
                withProfile += 1
            } else {
                missing.append(commodity.mnemonic)
            }
        }
        log(Fmt.row("with a profile", "\(withProfile) of \(covered.count)"))
        if !missing.isEmpty {
            log("  no profile served for: \(missing.sorted().joined(separator: ", "))")
        }
        let (_, saveSeconds) = try Stopwatch.measure { try model.save() }
        log(Fmt.row("save", Fmt.time(saveSeconds)))
    }
}
