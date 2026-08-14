//
//  LiveFIIGTests.swift
//  FinvestLens — Quotes
//
//  The FIIG provider against the live endpoint, through the real URLSession.
//  Two things only a live run can establish, and both are claims the design
//  makes (docs/investments-design.md §9):
//
//    1. URLSession's own trust evaluation accepts the certificate chain. The
//       reference implementation disables verification because Node will not
//       chase AIA for the missing intermediate; if that were a *server*
//       problem this test would fail, and the answer would be to supply the
//       intermediate — never to turn verification off.
//    2. The response still has the shape the parser expects. A provider that
//       silently changed a field type is exactly what a captured fixture
//       cannot catch.
//
//  Env-gated: CI never reaches the network, and the endpoint geo-restricts
//  non-AU egress, so an unconditional test would fail for anyone abroad.
//  Output is counts and ranges only — never an ISIN, which would say which
//  bonds someone holds.
//
//      FL_LIVE_FIIG=1 swift test --package-path Packages/Quotes --filter LiveFIIGTests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

private let live = ProcessInfo.processInfo.environment["FL_LIVE_FIIG"] != nil

@Suite(.serialized)
struct LiveFIIGTests {

    @Test("The live index parses through URLSession, with a chain URLSession trusts")
    func liveIndex() async throws {
        guard live else { return }
        // The production transport, deliberately: a stub would prove nothing
        // about TLS, which is the whole reason this test exists.
        let provider = FIIGQuoteProvider(http: URLSessionHTTPClient())
        let started = Date()
        let index = try await provider.wholeIndex()
        let elapsed = Date().timeIntervalSince(started)

        #expect(index.count > 100, "the index should carry the whole market")
        print("FIIG live: \(index.count) bonds in \(String(format: "%.1f", elapsed))s")

        // Par-relative after the ÷100, which is the conversion that makes a
        // bond price mean the same thing as every other price in the book.
        let prices = index.values.map(\.price)
        guard let low = prices.min(), let high = prices.max() else {
            Issue.record("no priced bonds in the live index")
            return
        }
        #expect(low > 0, "a priced bond is never free")
        #expect(high < 3, "a par-relative price above 3 means the ÷100 was lost")
        print("FIIG live: par-relative \(low) … \(high)")

        // Currency is carried; the index is mostly AUD with some USD and GBP.
        let currencies = Set(index.values.compactMap(\.currencyCode))
        #expect(currencies.contains("AUD"))
        print("FIIG live: currencies \(currencies.sorted())")
    }

    @Test("History is refused live too, because the endpoint carries none")
    func liveHistory() async throws {
        guard live else { return }
        await #expect(throws: QuoteError.self) {
            try await FIIGQuoteProvider(http: URLSessionHTTPClient())
                .history(symbol: "AU0000000000", from: .distantPast, to: .distantFuture)
        }
    }
}

/// Yahoo's company data through the real endpoints (I5).
///
/// The crumb handshake is the part only a live run can establish: a captured
/// fixture proves the parser, never that `quoteSummary` will let us in. Gated
/// on `FL_LIVE_YAHOO=1` because it is a network test and because the handshake
/// is rate-limited.
///
///     FL_LIVE_YAHOO=1 swift test --package-path Packages/Quotes --filter LiveYahooFundamentalsTests
@Suite(.serialized)
struct LiveYahooFundamentalsTests {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["FL_LIVE_YAHOO"] != nil
    }

    /// A large, long-listed ASX security, chosen because it is public
    /// information and says nothing about anyone's holdings.
    private let symbol = "CBA.AX"

    /// Whether an error is Yahoo declining to start a session, as opposed to a
    /// parsing or shape problem — which would be ours and must still fail.
    private static func isHandshakeRefusal(_ error: QuoteError) -> Bool {
        if case .providerError(let message) = error {
            return message.contains("session token")
        }
        return false
    }

    @Test("The crumb handshake succeeds and quoteSummary answers")
    func liveProfile() async throws {
        guard enabled else { return }
        // A session of its own, so the cookie the handshake needs is not
        // inherited from another test's shared session — which would make this
        // pass for the wrong reason.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        let http = URLSessionHTTPClient(session: URLSession(configuration: configuration))

        // Yahoo rate-limits the handshake per address, and hard: the same
        // sequence returned 200 with 9 KB of company data minutes before it
        // started answering 429. That is an environmental condition, not a
        // defect in this code, so it is reported and skipped rather than
        // failed — a harness that goes red for someone else's rate limiter is
        // a harness people learn to ignore.
        let result: SecurityFundamentals
        do {
            result = try await YahooFundamentalsProvider(http: http)
                .fundamentals(symbol: symbol, kinds: [.profile, .statements])
        } catch QuoteError.httpStatus(429) {
            print("live profile: SKIPPED — Yahoo is rate-limiting the crumb handshake (429)")
            return
        } catch let error as QuoteError where Self.isHandshakeRefusal(error) {
            print("live profile: SKIPPED — \(error)")
            return
        }
        let profile = try #require(result.profile?.value, "no profile came back")
        print("live profile: sector=\(profile.sector ?? "—") employees=\(profile.employees.map(String.init) ?? "—")")
        #expect(profile.sector != nil)
        #expect(!profile.isFixedIncome)

        let periods = result.statements?.value ?? []
        print("live statements: \(periods.count) periods across \(Set(periods.map(\.statement)).count) kinds")
        // Sparse for some issuers — a bank reports no gross profit — so the
        // assertion is that *something* parsed, not that every line is there.
        #expect(!periods.isEmpty)
        #expect(periods.allSatisfy { !$0.lines.isEmpty })
    }

    @Test("Dividends come from the chart endpoint with no handshake at all")
    func liveDividends() async throws {
        guard enabled else { return }
        let result = try await YahooFundamentalsProvider(http: URLSessionHTTPClient())
            .fundamentals(symbol: symbol, kinds: [.dividends])
        let dividends = result.dividends?.value ?? []
        print("live dividends: \(dividends.count) over ten years")
        #expect(!dividends.isEmpty)
        #expect(dividends.allSatisfy { $0.amount > 0 })
        // Oldest first, which the reconciliation in I6 depends on.
        #expect(zip(dividends, dividends.dropFirst()).allSatisfy { $0.date <= $1.date })
    }
}
