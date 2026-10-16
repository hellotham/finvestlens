//
//  QuoteErrorWordsTests.swift
//  FinvestLens — Quotes
//
//  A failed quote is listed after its symbol — "BHP: no data". The guards'
//  refusals were written as careful sentences and then never read: they were
//  plain errors, and what reached the list was "The operation couldn’t be
//  completed" and a type's name. Each describes itself now.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

@Suite("Quote errors in words")
struct QuoteErrorWordsTests {

    @Test("A quote error describes itself")
    func quoteErrors() {
        #expect(QuoteError.noData.localizedDescription == "no data")
        #expect(QuoteError.httpStatus(503).localizedDescription == "HTTP 503")
        #expect(QuoteError.missingAPIKey(.finnhub).localizedDescription == "Finnhub API key not set")
        #expect(QuoteError.malformedResponse("no rows").localizedDescription == "bad response (no rows)")
        // A provider's own sentence is passed on as it came.
        #expect(QuoteError.providerError("Invalid API key").localizedDescription == "Invalid API key")
        #expect(QuoteError.unsupported("Not on this plan").localizedDescription == "Not on this plan")
    }

    @Test("The guards' refusals are sentences a person can act on")
    func guardRefusals() {
        let mismatch = QuoteService.CurrencyMismatch(symbol: "MG", reported: "USD", expected: "AUD")
        #expect(mismatch.localizedDescription == "MG priced in USD, not AUD — check the ticker’s exchange suffix")
        var inferred = mismatch
        inferred.inferred = true
        #expect(inferred.localizedDescription.hasPrefix("MG trades in USD, not AUD"))
        #expect(QuoteService.ImplausibleQuote(symbol: "WMX", reason: .undated).localizedDescription
            == "WMX returned no observation date")
        #expect(QuoteService.ImplausibleQuote(symbol: "WMX", reason: .datedAhead).localizedDescription
            == "WMX is dated more than a year ahead")
        #expect(QuoteService.ImplausibleQuote(symbol: "WMX", reason: .notAPrice(0)).localizedDescription
            .hasPrefix("WMX priced at 0"))
    }
}
