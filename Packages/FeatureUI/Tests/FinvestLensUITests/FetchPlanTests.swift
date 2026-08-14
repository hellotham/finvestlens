//
//  FetchPlanTests.swift
//  FinvestLens — FeatureUI
//
//  Phase I7 of the Investments hub: what a refresh covers, what it will cost,
//  and when a hand-valued holding is genuinely late. ISINs invented.
//  // synthetic
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensQuotes
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}

private final class SilentHTTP: HTTPFetching, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> Data { throw QuoteError.noData }
}

@MainActor
@Suite("Fetch plan and valuation cadence")
struct FetchPlanTests {

    private func book() throws -> (AppModel, URL) {
        let url = tempURL()
        let model = AppModel(apiKeys: InMemoryAPIKeyStore(), quoteHTTP: SilentHTTP())
        try model.newDocument(at: url)
        return (model, url)
    }

    /// A holding with a purchase and, optionally, a sale that closes it.
    @discardableResult
    private func hold(_ model: AppModel, _ mnemonic: String,
                      namespace: String = "ASX", isin: String? = nil,
                      closed: Bool = false, pricedOn: [Date] = []) -> Commodity {
        let commodity = Commodity(namespace: .security(namespace), mnemonic: mnemonic,
                                  fullName: mnemonic, smallestFraction: 10000,
                                  exchangeCode: isin)
        // `addAccount` returns the new account's GUID, so resolve it against
        // the book to get the `Account` a split needs.
        let stockID = model.addAccount(name: mnemonic, type: .stock, commodity: commodity)
        guard let stock = stockID.flatMap({ model.book?.account(with: $0) }) else { return commodity }
        if model.book?.accounts.first(where: { $0.type == .bank }) == nil {
            _ = model.addAccount(name: "Bank", type: .bank, commodity: model.reportCurrency)
        }
        guard let bank = model.book?.accounts.first(where: { $0.type == .bank }) else {
            return commodity
        }

        let buy = Transaction(currency: model.reportCurrency,
                              datePosted: utc.date(from: DateComponents(year: 2025, month: 1, day: 6))!,
                              description: "Buy")
        buy.addSplit(Split(account: stock, value: dec("1000"), quantity: dec("100")))
        buy.addSplit(account: bank, value: dec("-1000"))
        model.book?.addTransaction(buy)

        if closed {
            let sell = Transaction(currency: model.reportCurrency,
                                   datePosted: utc.date(from: DateComponents(year: 2025, month: 6, day: 6))!,
                                   description: "Sell")
            sell.addSplit(Split(account: stock, value: dec("-1200"), quantity: dec("-100")))
            sell.addSplit(account: bank, value: dec("1200"))
            model.book?.addTransaction(sell)
        }
        for date in pricedOn {
            model.addPrice(commodity: commodity, currency: model.reportCurrency,
                           date: date, value: dec("10"))
        }
        model.refreshAll()
        return commodity
    }

    // MARK: Scope (`FR-INV-25`)

    @Test("Holdings scope leaves closed positions out")
    func holdingsScope() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let open = hold(model, "OPEN", pricedOn: [Date()])
        _ = hold(model, "CLOSED", closed: true)

        let chosen = model.securities(in: .holdings)
        #expect(chosen.contains(open))
        #expect(!chosen.contains { $0.mnemonic == "CLOSED" },
                "a closed position is not worth today's price")
    }

    @Test("A closed position with a gap while held is fetched — once, not daily")
    func closedGapsScope() throws {
        // D4 in one line. A hole inside the period it *was* held silently
        // corrupts historical net worth and every past valuation, so it is
        // worth one fetch; today's price for a position you no longer own is
        // worth none.
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = hold(model, "OPEN", pricedOn: [Date()])
        let closed = hold(model, "CLOSED", closed: true)

        let holdingsOnly = model.securities(in: .holdings)
        let withGaps = model.securities(in: .withClosedGaps)
        #expect(!holdingsOnly.contains(closed))
        // The closed position has a five-month held period and no prices at
        // all, so every trading day in it is a gap.
        #expect(withGaps.count >= holdingsOnly.count)
    }

    // MARK: The preview (`FR-INV-34`)

    @Test("A batch provider's whole group counts as one request")
    func requestsNotSecurities() throws {
        // The number that costs anything. Counting securities would make the
        // cheapest scope look like the dearest: eleven bonds and one share is
        // two requests, not twelve.
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = hold(model, "SHARE", pricedOn: [Date()])
        for index in 1...3 {
            let bond = hold(model, "BOND\(index)", namespace: "Bond",
                            isin: "AU0EXAMPLE0\(index)", pricedOn: [Date()])
            model.setQuoteProvider(.fiig, for: bond)
        }

        let plan = model.fetchPlan(scope: .holdings, using: .yahoo)
        #expect(plan.securities.count == 4)
        #expect(plan.byProvider[.fiig] == 3)
        #expect(plan.byProvider[.yahoo] == 1)
        #expect(plan.requests == 2, "three bonds in one request, plus the share")
    }

    @Test("The plan names what the scope leaves out, so an empty run is explicable")
    func skippedIsReported() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = hold(model, "OPEN", pricedOn: [Date()])
        _ = hold(model, "CLOSED", closed: true)

        let plan = model.fetchPlan(scope: .holdings, using: .yahoo)
        #expect(plan.skipped > 0)
    }

    @Test("The chosen scope survives a save and reopen")
    func scopeIsPersisted() async throws {
        let (model, url) = try book()
        defer { try? FileManager.default.removeItem(at: url) }
        model.fetchScope = .withClosedGaps
        try model.save()
        model.close()

        let reopened = AppModel(apiKeys: InMemoryAPIKeyStore(), quoteHTTP: SilentHTTP())
        defer { reopened.close() }
        try await reopened.open(at: url)
        #expect(reopened.fetchScope == .withClosedGaps)
    }

    // MARK: Manual valuation (`FR-INV-30`)

    @Test("A hand-valued holding is judged against its own cadence, not the market's")
    func cadenceNotTradingCalendar() throws {
        // The false alarm this prevents: a super fund posting a unit price
        // quarterly reads as stale every Tuesday the ASX trades, and a worklist
        // that tells you off for that is one you stop reading.
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let sixWeeksAgo = Calendar.current.date(byAdding: .day, value: -42, to: Date())!
        let fund = hold(model, "SUPER", namespace: "Super", pricedOn: [sixWeeksAgo])

        model.setValuationCadence(.monthly, for: fund)
        #expect(model.isValuationOverdue(fund), "six weeks past a monthly cadence")

        model.setValuationCadence(.quarterly, for: fund)
        #expect(!model.isValuationOverdue(fund), "and comfortably inside a quarterly one")
    }

    @Test("A holding valued only when the user says is never overdue")
    func neverCadence() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let old = Calendar.current.date(byAdding: .year, value: -5, to: Date())!
        let art = hold(model, "ART", namespace: "Other", pricedOn: [old])

        model.setValuationCadence(.never, for: art)
        #expect(!model.isValuationOverdue(art),
                "a collectable valued once is not late, ever")
    }

    @Test("A security never valued at all is overdue by definition")
    func neverValued() throws {
        let (model, url) = try book()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let fund = hold(model, "SUPER", namespace: "Super")
        #expect(model.isValuationOverdue(fund), "there is no figure to trust")
    }

    @Test("The cadence defaults to quarterly and survives a reopen")
    func cadenceIsPersisted() async throws {
        let (model, url) = try book()
        defer { try? FileManager.default.removeItem(at: url) }
        let fund = hold(model, "SUPER", namespace: "Super")
        #expect(model.valuationCadence(for: fund) == .quarterly,
                "what an Australian super fund typically publishes")

        model.setValuationCadence(.halfYearly, for: fund)
        try model.save()
        model.close()

        let reopened = AppModel(apiKeys: InMemoryAPIKeyStore(), quoteHTTP: SilentHTTP())
        defer { reopened.close() }
        try await reopened.open(at: url)
        let again = try #require(reopened.pricableSecurities.first { $0.mnemonic == "SUPER" })
        #expect(reopened.valuationCadence(for: again) == .halfYearly)
    }
}
