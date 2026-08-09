//
//  PricesCommand.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes
import FinvestLensUI

/// `finlab prices` — refresh every security in the book.
///
/// Goes through `AppModel.updatePriceHistory`, the same call the app's ⌘⇧U
/// makes, so what is measured here is what a person gets there.
///
/// Keys come from an in-memory store seeded from the environment, never from
/// the Keychain. The app's `KeychainAPIKeyStore` writes items whose ACL names
/// the app binary; a differently-signed tool asking for them is what a
/// "wants to use your confidential information" prompt is *for*, and a prompt
/// is the one thing a headless run cannot answer. Yahoo and Stooq need no key
/// at all, which is why the default is Yahoo.
enum PricesCommand {

    @MainActor
    static func run(_ options: LabOptions, log: LabLog) async throws {
        let file = try options.existingURL("file")
        let kind = try providerKind(options.string("provider"))

        let model = AppModel(apiKeys: environmentKeys())
        let (_, openSeconds) = try await Stopwatch.measure {
            try await model.open(at: file, breakStaleLock: true)
        }
        defer { _ = model.saveAndCloseIfOpen() }

        let securities = model.pricableSecurities
        log("Prices for \(file.lastPathComponent) — \(securities.count) securit\(securities.count == 1 ? "y" : "ies")")
        log(Fmt.row("open book", Fmt.time(openSeconds)))
        log("  provider: \(kind)")

        guard !securities.isEmpty else {
            log("  nothing to price.")
            return
        }
        if options.flag("dry-run") {
            log("  --dry-run: would fetch " + securities.map(\.mnemonic).sorted().joined(separator: ", "))
            return
        }

        // Counted through the public price history rather than the book, and
        // per security rather than book-wide: this is the number that says
        // whether the fetch did anything for the things being priced.
        func storedPoints() -> Int {
            securities.reduce(0) { $0 + model.priceHistory(for: $1).count }
        }
        let before = storedPoints()
        let (_, fetchSeconds) = await Stopwatch.measure {
            await model.updatePriceHistory(using: kind)
        }
        let after = storedPoints()

        log(Fmt.row("fetch \(securities.count) securities", Fmt.time(fetchSeconds)))
        log(Fmt.row("  per security", Fmt.time(fetchSeconds / Double(securities.count))))
        log("  prices \(Fmt.count(before)) → \(Fmt.count(after)) (+\(Fmt.count(after - before)))")

        // `updatePriceHistory` reports failures rather than throwing them, so
        // silence would otherwise read as success.
        switch model.quoteStatus {
        case .failure(let message): log("  ⚠︎ \(message)")
        case .success(let count): log("  \(Fmt.count(count)) price(s) added")
        case .fetching(let what): log("  still fetching: \(what)")
        case .idle: break
        }

        let (_, saveSeconds) = try Stopwatch.measure { try model.save() }
        log(Fmt.row("save", Fmt.time(saveSeconds)))
    }

    private static func providerKind(_ name: String?) throws -> QuoteProviderKind {
        switch (name ?? "yahoo").lowercased() {
        case "yahoo": .yahoo
        case "stooq": .stooq
        case "eodhd": .eodhd
        case "alphavantage", "alpha": .alphaVantage
        case "finnhub": .finnhub
        case "twelvedata", "twelve": .twelveData
        default: throw LabError.message("unknown provider '\(name ?? "")' — "
                                        + "yahoo, stooq, eodhd, alphavantage, finnhub, twelvedata")
        }
    }

    /// API keys from `FINLAB_<PROVIDER>_KEY`, for the keyed providers.
    private static func environmentKeys() -> InMemoryAPIKeyStore {
        let environment = ProcessInfo.processInfo.environment
        var seeded: [QuoteProviderKind: String] = [:]
        for kind in [QuoteProviderKind.eodhd, .alphaVantage, .finnhub, .twelveData] {
            let name = "FINLAB_\(kind.rawValue.uppercased())_KEY"
            if let key = environment[name], !key.isEmpty { seeded[kind] = key }
        }
        return InMemoryAPIKeyStore(seeded)
    }
}
