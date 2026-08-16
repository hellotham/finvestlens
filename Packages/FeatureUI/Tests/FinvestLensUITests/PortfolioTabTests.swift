//
//  PortfolioTabTests.swift
//  FinvestLens — FeatureUI
//
//  Investments tabs: All Holdings, then one per portfolio (P13.3).
//
//  Asked for on 16 Aug 2026 — "we talked about tabs in the investment mode
//  (All Holdings, and then each portfolio) - I did not see this" — and again
//  after the first attempt. `securityAccountNodes` existed and the sidebar
//  never read it, so there was nothing for a tab to open.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Investments portfolios")
struct PortfolioTabTests {

    private struct Fixture {
        let model: AppModel
        let url: URL
        let broker: GncGUID
        let superFund: GncGUID
        let acme: Commodity
        let zeta: Commodity
    }

    /// Two portfolios — a broker and a super fund — each parenting one security
    /// account, which is the shape a portfolio *is*: GnuCash has no such type,
    /// so it is the parent of security accounts or it is nothing.
    private func makeFixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)

        let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme", smallestFraction: 10000)
        let zeta = Commodity(namespace: .security("ASX"), mnemonic: "ZETA",
                             fullName: "Zeta", smallestFraction: 10000)
        let broker = try #require(model.addAccount(name: "Broker", type: .asset))
        let superFund = try #require(model.addAccount(name: "Super", type: .asset))
        _ = try #require(model.addAccount(name: "ACME", type: .stock,
                                          commodity: acme, parentID: broker))
        _ = try #require(model.addAccount(name: "ZETA", type: .stock,
                                          commodity: zeta, parentID: superFund))
        // **Both actually hold something.** A portfolio with no open holding is
        // not listed any more (closed positions are hidden by default), so a
        // fixture of empty accounts would test the wrong thing.
        try buy(model, security: acme, under: broker, cash: "Broker Cash", units: 10)
        try buy(model, security: zeta, under: superFund, cash: "Super Cash", units: 5)
        return Fixture(model: model, url: url, broker: broker, superFund: superFund,
                       acme: acme, zeta: zeta)
    }

    /// Puts units into a security account, so its portfolio counts as open.
    @discardableResult
    private func buy(_ model: AppModel, security: Commodity, under parent: GncGUID,
                     cash name: String, units: Decimal) throws -> GncGUID {
        let settlement = try #require(model.addAccount(name: name, type: .bank,
                                                       parentID: parent))
        let account = try #require(model.book?.accounts.first { $0.commodity == security })
        return try model.addTransaction(
            date: Date(), description: "Buy \(security.mnemonic)", currency: .aud,
            splits: [SplitInput(accountID: settlement, value: -100),
                     SplitInput(accountID: account.guid, value: 100, quantity: units)])
    }

    @Test("A portfolio is a parent of security accounts, and only that")
    func portfoliosAreDerived() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let names = f.model.portfolioAccounts.map(\.name)
        #expect(names == ["Broker", "Super"], "sorted by the name shown")
        // The security accounts themselves are not portfolios, and neither is
        // a plain bank account.
        _ = try #require(f.model.addAccount(name: "Everyday", type: .bank))
        #expect(f.model.portfolioAccounts.map(\.name) == ["Broker", "Super"])
    }

    @Test("Each portfolio holds its own securities")
    func holdingsAreScoped() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(f.model.securityCommodities(inPortfolio: f.broker) == [f.acme])
        #expect(f.model.securityCommodities(inPortfolio: f.superFund) == [f.zeta])
        #expect(f.model.securityCommodities(inPortfolio: .random()).isEmpty)
    }

    /// The sidebar is where a tab comes from, so a portfolio that is not listed
    /// there cannot be opened in one — which is exactly why this ask kept
    /// coming back.
    @Test("The Investments sidebar lists All Holdings and every portfolio")
    func sidebarListsPortfolios() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let ids = ModeSidebarRows.groups(for: .investments, model: f.model)
            .flatMap(\.rows).map(\.id)
        #expect(ids.contains(.investments))
        #expect(ids.contains(.portfolio(f.broker)))
        #expect(ids.contains(.portfolio(f.superFund)))
    }

    /// One portfolio is not a grouping. Listing it would put a row beside All
    /// Holdings saying exactly what All Holdings says.
    @Test("A book with a single portfolio lists no portfolio rows")
    func onePortfolioIsNotAGrouping() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let broker = try #require(model.addAccount(name: "Broker", type: .asset))
        let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme", smallestFraction: 10000)
        _ = try #require(model.addAccount(name: "ACME", type: .stock,
                                          commodity: acme, parentID: broker))
        try buy(model, security: acme, under: broker, cash: "Cash", units: 10)

        #expect(model.portfolioAccounts.count == 1)
        let ids = ModeSidebarRows.groups(for: .investments, model: model)
            .flatMap(\.rows).map(\.id)
        #expect(!ids.contains(.portfolio(broker)))
    }

    /// **Closed portfolios are not tabs.** Reported 16 Aug 2026: "Investments
    /// shows a lot of portfolio tabs, many are closed positions." A broker you
    /// last held a share through years ago is history, not a place you work —
    /// and the existing Show Closed Positions toggle governs it, so one control
    /// means one thing in the tab strip and the holdings table alike.
    @Test("Only portfolios with an open holding appear, unless closed are shown")
    func closedPortfoliosAreHidden() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(f.model.showsClosedPositions == false)
        #expect(f.model.portfolioAccounts.map(\.name) == ["Broker", "Super"])

        // Sell the super fund's whole holding: that portfolio is now history.
        let zeta = try #require(f.model.book?.accounts.first { $0.commodity == f.zeta })
        let cash = try #require(f.model.book?.accounts.first { $0.name == "Super Cash" })
        _ = try f.model.addTransaction(
            date: Date(), description: "Sell ZETA", currency: .aud,
            splits: [SplitInput(accountID: zeta.guid, value: -100, quantity: -5),
                     SplitInput(accountID: cash.guid, value: 100)])

        #expect(f.model.portfolioAccounts.map(\.name) == ["Broker"],
                "a portfolio with nothing left in it is not a place you work")

        // The toggle brings it back — and the cache must not serve the previous
        // answer when the toggle moves.
        f.model.showsClosedPositions = true
        #expect(f.model.portfolioAccounts.map(\.name) == ["Broker", "Super"])
        f.model.showsClosedPositions = false
        #expect(f.model.portfolioAccounts.map(\.name) == ["Broker"], "stale cache")
    }

    /// Seen on screen 16 Aug 2026: the securities group in the Investments
    /// sidebar was headed `security("ASX")` — the enum's synthesized
    /// description, printed straight into the UI.
    @Test("A securities group is headed by the exchange, not the enum case")
    func namespaceHeadingIsTheExchange() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        let headings = ModeSidebarRows.groups(for: .investments, model: f.model)
            .compactMap(\.text)
        #expect(headings.contains("ASX"))
        #expect(!headings.contains { $0.contains("security(") },
                "the enum's description reached the screen")
    }

    @Test("A portfolio opens in its own tab, named after the account")
    func portfolioOpensInATab() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        f.model.showMode(.investments)
        #expect(f.model.tabTitle(for: .investments) == "All Holdings")

        f.model.navigate(to: .portfolio(f.broker), inNewTab: true)
        #expect(f.model.openTabs.contains(.portfolio(f.broker)))
        #expect(f.model.tabTitle(for: .portfolio(f.broker)) == "Broker")
        // A portfolio belongs to Investments, so opening one must not move the
        // window to another mode.
        #expect(f.model.mode == .investments)
    }

    /// A tab for a portfolio the book no longer has must be dropped on reopen
    /// rather than restored onto nothing.
    @Test("A deleted portfolio does not survive as a tab")
    func deadPortfolioIsFilteredOut() throws {
        let f = try makeFixture()
        defer { f.model.close(); try? FileManager.default.removeItem(at: f.url) }

        #expect(f.model.exists(.portfolio(f.broker)))
        #expect(!f.model.exists(.portfolio(.random())))
    }
}
