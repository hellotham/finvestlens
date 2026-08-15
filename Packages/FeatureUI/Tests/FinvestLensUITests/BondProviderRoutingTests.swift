//
//  BondProviderRoutingTests.swift
//  FinvestLens — FeatureUI
//
//  Phase I4 of the Investments hub (docs/investments-design.md §9): a book that
//  holds both shares and bonds must serve each from the provider that can price
//  it, in one run. The ISINs below are invented. // synthetic
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Synchronization
import Testing
import FinvestLensEngine
import FinvestLensQuotes
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

private let chartJSON = """
{"chart":{"result":[{"meta":{"currency":"AUD","symbol":"CBA.AX",
"regularMarketPrice":105.20,"regularMarketTime":1700000000},
"timestamp":[1699800000],"indicators":{"quote":[{"close":[105.20]}]}}],"error":null}}
"""

private let bondIndexJSON = """
{"data":[{"isin":"AU0EXAMPLE01","georgiaId":18,"price":98.5,"marketRegion":"AUD"},
         {"isin":"AU0EXAMPLE02","georgiaId":27,"price":72.25,"marketRegion":"AUD"}],
 "pagination":{"pageNo":1,"pageSize":2000,"pageCount":1}}
"""

/// Routes by host, and counts what each host was asked for — the point of the
/// batch path is that one host is hit once however many bonds are held.
private final class RoutingHTTP: HTTPFetching, @unchecked Sendable {
    // A plain mutex rather than `NSLock`: `lock()`/`unlock()` are unavailable
    // from an async context under strict concurrency, and `withLock` is the
    // scoped form that is not.
    private let hits = Mutex<[String: Int]>([:])

    func data(for request: URLRequest) async throws -> Data {
        let url = request.url!.absoluteString
        let isFIIG = url.contains("fiig")
        hits.withLock { $0[isFIIG ? "fiig" : "yahoo", default: 0] += 1 }
        // FIIG's history is a second endpoint keyed by its numeric id, so the
        // stub has to answer two shapes on the one host.
        if isFIIG && url.contains("/history") { return Data(bondHistoryJSON.utf8) }
        return Data((isFIIG ? bondIndexJSON : chartJSON).utf8)
    }

    func count(_ host: String) -> Int {
        hits.withLock { $0[host] ?? 0 }
    }
}

@MainActor
@Suite("Bond provider routing")
struct BondProviderRoutingTests {

    private func book(_ http: HTTPFetching) throws -> (AppModel, URL) {
        let url = tempURL()
        let model = AppModel(apiKeys: InMemoryAPIKeyStore(), quoteHTTP: http)
        try model.newDocument(at: url)
        return (model, url)
    }

    private func share(_ model: AppModel) -> Commodity {
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        _ = model.addAccount(name: "CBA", type: .stock, commodity: cba)
        return cba
    }

    private func bond(_ model: AppModel, _ mnemonic: String, isin: String) -> Commodity {
        let commodity = Commodity(namespace: .security("Bond"), mnemonic: mnemonic,
                                  fullName: "A bond", smallestFraction: 100,
                                  exchangeCode: isin)
        _ = model.addAccount(name: mnemonic, type: .stock, commodity: commodity)
        return commodity
    }

    // MARK: The defect this exists to prevent

    @Test("Shares and bonds are priced in one run, each by its own provider")
    func mixedBookIsPricedInOneRun() async throws {
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let cba = share(model)
        model.setQuoteSymbol("CBA.AX", for: cba)
        let first = bond(model, "BOND1", isin: "AU0EXAMPLE01")
        let second = bond(model, "BOND2", isin: "AU0EXAMPLE02")
        model.setQuoteProvider(.fiig, for: first)
        model.setQuoteProvider(.fiig, for: second)

        await model.fetchLatestQuotes(using: .yahoo)

        // Three securities priced, and the bonds cost **one** request between
        // them: without the batch path this would be two full downloads of the
        // same half-megabyte index.
        #expect(model.quoteStatus == .success(3))
        #expect(http.count("fiig") == 1)
        #expect(http.count("yahoo") == 1)

        let prices = model.book?.prices ?? []
        #expect(prices.first { $0.commodity == first }?.value == dec("0.985"),
                "percent of par ÷ 100 — a bond price is par-relative in the book")
        #expect(prices.first { $0.commodity == second }?.value == dec("0.7225"))
        #expect(prices.first { $0.commodity == cba }?.value == dec("105.20"))
    }

    @Test("A bond with no provider chosen goes to the run's provider and fails there")
    func unroutedBondFailsHonestly() async throws {
        // Deliberate: nothing infers a provider from an identifier's shape. The
        // failure names the security, and the fix is one picker on its page.
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = bond(model, "BOND1", isin: "AU0EXAMPLE01")

        await model.fetchLatestQuotes(using: .yahoo)
        #expect(http.count("fiig") == 0, "an ISIN is never sent to FIIG unasked")
    }

    // MARK: Which securities FIIG could serve

    @Test("Candidates are securities with an ISIN-shaped code and no provider yet")
    func candidates() throws {
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        _ = share(model)                                    // no identifier
        let withISIN = bond(model, "BOND1", isin: "AU0EXAMPLE01")
        let routed = bond(model, "BOND2", isin: "AU0EXAMPLE02")
        _ = bond(model, "BOND3", isin: "TOO-SHORT")         // not an ISIN's shape
        model.setQuoteProvider(.fiig, for: routed)          // already answered

        #expect(model.fiigCandidates == [withISIN])
    }

    @Test("ISIN shape: two country letters, nine alphanumerics, a check digit")
    func isinShape() {
        #expect(AppModel.looksLikeISIN("AU0EXAMPLE01"))
        #expect(AppModel.looksLikeISIN(" au0example01 "), "trimmed and case-folded")
        #expect(!AppModel.looksLikeISIN("AU0EXAMPLE0"), "eleven characters")
        #expect(!AppModel.looksLikeISIN("AU0EXAMPLE012"), "thirteen characters")
        #expect(!AppModel.looksLikeISIN("A00EXAMPLE01"), "one country letter")
        #expect(!AppModel.looksLikeISIN("AU0EXAMPLE0X"), "check digit is a digit")
        #expect(!AppModel.looksLikeISIN(nil))
        #expect(!AppModel.looksLikeISIN(""))
        // An ASX ticker is not an ISIN, and must never be treated as one.
        #expect(!AppModel.looksLikeISIN("CBA"))
    }

    // MARK: The per-security choice

    @Test("A security's own provider outranks the run's")
    func perSecurityChoiceWins() throws {
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let held = bond(model, "BOND1", isin: "AU0EXAMPLE01")

        #expect(model.effectiveProvider(for: held, in: .yahoo) == .yahoo)
        model.setQuoteProvider(.fiig, for: held)
        #expect(model.effectiveProvider(for: held, in: .yahoo) == .fiig)
        model.setQuoteProvider(nil, for: held)
        #expect(model.effectiveProvider(for: held, in: .yahoo) == .yahoo)
    }

    @Test("A chosen provider with no API key falls back rather than failing the security")
    func unconfiguredChoiceFallsBack() throws {
        // EODHD needs a key. A book that names it and then loses the key would
        // otherwise report "API key not set" for that security on every run,
        // when the run's own provider could have priced it.
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let cba = share(model)

        model.setQuoteProvider(.eodhd, for: cba)
        #expect(!model.availableProviders.contains(.eodhd))
        #expect(model.effectiveProvider(for: cba, in: .yahoo) == .yahoo)
    }

    @Test("The choice survives a save and reopen")
    func choiceIsPersisted() async throws {
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { try? FileManager.default.removeItem(at: url) }
        let held = bond(model, "BOND1", isin: "AU0EXAMPLE01")
        model.setQuoteProvider(.fiig, for: held)
        try model.save()
        model.close()

        let reopened = AppModel(apiKeys: InMemoryAPIKeyStore(), quoteHTTP: http)
        defer { reopened.close() }
        try await reopened.open(at: url)
        let again = reopened.pricableSecurities.first { $0.mnemonic == "BOND1" }
        #expect(again != nil)
        #expect(reopened.quoteProvider(for: again!) == .fiig)
    }

    // MARK: History

    /// FIIG publishes a daily series after all — from a second endpoint keyed
    /// by its own numeric id (`/api/instruments/bonds/{georgiaId}/history`).
    ///
    /// This suite previously asserted the opposite, on the evidence that the
    /// index's `bondHistory` field is null on every record. It is; the list
    /// just does not embed the series. The invariant the old test protected —
    /// a rebuild must never replace years of prices with one dot — still holds
    /// and is now tested against a provider that really is latest-only.
    @Test("A bond's history rebuilds from FIIG's daily series")
    func rebuildUsesTheSeries() async throws {
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let held = bond(model, "BOND1", isin: "AU0EXAMPLE01")
        model.setQuoteProvider(.fiig, for: held)

        await model.refetchPriceHistory(for: [held], using: .fiig)

        let after = model.book?.prices.filter { $0.commodity == held } ?? []
        #expect(after.count == 3, "one row per published day")
        // Par-relative here: this security has no purchase to learn a scale
        // from, so 98.5 reads as 0.985 (`AppModel.parPercentScaled`).
        #expect(after.contains { $0.value == dec("0.985") })
        #expect(after.contains { $0.value == dec("0.99") })
    }

    /// The invariant the FIIG case used to carry: a provider with no history
    /// must not be allowed to wipe a series and leave a single point.
    @Test("Rebuilding never deletes a history to install one price")
    func rebuildDoesNotWipeAHistoryForOnePoint() async throws {
        let http = RoutingHTTP()
        let (model, url) = try book(http)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let cba = share(model)
        model.setQuoteProvider(.finnhub, for: cba)
        #expect(!QuoteProviderKind.finnhub.supportsHistory)

        for day in 1...5 {
            model.addPrice(commodity: cba, currency: model.reportCurrency,
                           date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                           value: dec("1.0"))
        }
        #expect(model.book?.prices.filter { $0.commodity == cba }.count == 5)

        await model.refetchPriceHistory(for: [cba], using: .finnhub)

        let after = model.book?.prices.filter { $0.commodity == cba } ?? []
        #expect(after.count >= 5, "the five stored prices survive a latest-only refetch")
    }
}

/// Three days of FIIG history, in the live shape: no ISIN on the rows, price
/// as percent of par.
private let bondHistoryJSON = """
{"data":[
  {"georgiaId":18,"isin":"","yield":0.05,"priceDate":"2021-10-27","priceValue":98.5},
  {"georgiaId":18,"isin":"","yield":0.05,"priceDate":"2021-10-28","priceValue":99.0},
  {"georgiaId":18,"isin":"","yield":0.05,"priceDate":"2021-10-29","priceValue":99.5}
]}
"""
