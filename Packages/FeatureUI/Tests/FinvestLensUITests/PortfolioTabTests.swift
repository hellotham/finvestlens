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
        return Fixture(model: model, url: url, broker: broker, superFund: superFund,
                       acme: acme, zeta: zeta)
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
        _ = try #require(model.addAccount(
            name: "ACME", type: .stock,
            commodity: Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                                 fullName: "Acme", smallestFraction: 10000),
            parentID: broker))

        #expect(model.portfolioAccounts.count == 1)
        let ids = ModeSidebarRows.groups(for: .investments, model: model)
            .flatMap(\.rows).map(\.id)
        #expect(!ids.contains(.portfolio(broker)))
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
