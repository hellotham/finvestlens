//
//  FinancialReviewTests.swift
//  FinvestLens — FeatureUI
//
//  The Financial Review deck: slides appear only with meaningful data, every
//  slide carries a deterministic headline (Apple Intelligence only ever
//  improves one), and the net-worth bridge's steps reconcile exactly.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensIntelligence
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Financial Review deck")
struct FinancialReviewTests {

    /// A cash-only book: income, expenses, a liability — no securities, no
    /// dividends, activity in a single month.
    private func makeCashBook() throws -> (AppModel, URL, Date) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let loan = try #require(model.addAccount(name: "Loan", type: .liability))
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        func txn(_ amount: Decimal, from: GncGUID, to: GncGUID) throws {
            _ = try model.addTransaction(date: date, description: "t", currency: .aud,
                splits: [SplitInput(accountID: from, value: -amount),
                         SplitInput(accountID: to, value: amount)])
        }
        try txn(6_000, from: salary, to: bank)
        try txn(1_500, from: bank, to: food)
        try txn(2_000, from: loan, to: bank)
        return (model, url, date)
    }

    @Test("Slides appear only where the book has something to present")
    func slideSelection() throws {
        let (model, url, date) = try makeCashBook()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let slides = model.financialReviewSlides(
            from: date.addingTimeInterval(-86_400 * 30),
            to: date.addingTimeInterval(86_400), label: "Test period")
        let ids = slides.map(\.id)

        // Present: the always-on story slides.
        #expect(ids.contains("highlights"))
        #expect(ids.contains("bridge"))
        #expect(ids.contains("income"))
        #expect(ids.contains("spending"))
        #expect(ids.contains("position"))
        // Absent: no securities, no dividends, no disposals, one month only.
        #expect(!ids.contains("portfolio"))
        #expect(!ids.contains("dividends"))
        #expect(!ids.contains("gains"))
        #expect(!ids.contains("cashflow"))

        // Every slide has a deterministic voice and a bounded callout row.
        for slide in slides {
            #expect(!slide.headline.isEmpty, "slide \(slide.id) needs a headline")
            #expect(!slide.callouts.isEmpty && slide.callouts.count <= 4)
            #expect(!slide.facts.figures.isEmpty)
        }
    }

    @Test("The net-worth bridge reconciles: opening + surplus + valuation = closing")
    func bridgeReconciles() throws {
        let (model, url, date) = try makeCashBook()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let from = date.addingTimeInterval(-86_400 * 30)
        let to = date.addingTimeInterval(86_400)

        let slides = model.financialReviewSlides(from: from, to: to, label: "Test")
        let bridge = try #require(slides.first { $0.id == "bridge" })

        func figure(_ label: String) -> Decimal {
            bridge.facts.figures.first { $0.0 == label }?.1 ?? 0
        }
        let opening = figure("Opening net worth")
        let income = figure("Income")
        let expenses = figure("Expenses")
        let valuation = figure("Valuation and currency movement")
        let closing = figure("Closing net worth")
        #expect(opening + income - expenses + valuation == closing)

        // And the closing figure is the engine's own net worth.
        let sheet = try #require(model.balanceSheet(asOf: to))
        #expect(closing == sheet.totalAssets - sheet.totalLiabilities)

        // The waterfall's anchors carry the same opening and closing.
        guard case .waterfall(let steps) = bridge.chart else {
            Issue.record("bridge slide should carry a waterfall"); return
        }
        #expect(steps.first?.end == opening)
        #expect(steps.last?.end == closing)
    }

    @Test("The story validator rejects numbers the facts don't contain")
    func storyValidation() {
        let facts = ReviewSlideFacts(
            kicker: "Net worth", periodLabel: "FY 2025–26", currencyCode: "AUD",
            figures: [("Closing net worth", Decimal(3_825_458.71)),
                      ("Net surplus", Decimal(145_432)),
                      ("Change in net worth", Decimal(50_194.68))],
            deltaPercents: [("Net worth", Decimal(string: "1.2")!)])

        // Grounded: quotes listed figures, rounded and abbreviated.
        let grounded = ReviewSlideStory(
            headline: "Net worth up 1.2% to $3.8m",
            insight: "The change of 50,194.68 AUD includes a 145k surplus, ending FY 2025–26 well.")
        #expect(ReviewStoryValidator.isGrounded(grounded, facts: facts))

        // Invented percentages (the exact live failure) are rejected.
        let invented = ReviewSlideStory(
            headline: "Net worth increased by 17.9%.",
            insight: "Driven by a 15.2% increase in income and a 7.4% decrease in expenses.")
        #expect(!ReviewStoryValidator.isGrounded(invented, facts: facts))

        // An invented absolute figure is rejected too.
        let inventedAbsolute = ReviewSlideStory(
            headline: "Net worth up 1.2%",
            insight: "Assets of 9,999,999 dominate the position.")
        #expect(!ReviewStoryValidator.isGrounded(inventedAbsolute, facts: facts))

        // Calendar years pass as dates, not figures.
        let withYear = ReviewSlideStory(
            headline: "A steady close to 2026",
            insight: "Net worth ended at $3.8m.")
        #expect(ReviewStoryValidator.isGrounded(withYear, facts: facts))
    }

    @Test("Investment deck: gated on holdings, decomposition adds up")
    func investmentDeck() throws {
        // The cash book has no securities → no investment deck at all.
        let (cashModel, cashURL, cashDate) = try makeCashBook()
        defer { cashModel.close(); try? FileManager.default.removeItem(at: cashURL) }
        #expect(cashModel.investmentReviewSlides(
            from: .distantPast, to: cashDate.addingTimeInterval(86_400),
            label: "Test").isEmpty)

        // A book with two priced holdings.
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let bank = try #require(model.addAccount(name: "Broker", type: .bank))
        let acme = Commodity(namespace: .security("ASX"), mnemonic: "ACME",
                             fullName: "Acme", smallestFraction: 10000)
        let zorg = Commodity(namespace: .security("ASX"), mnemonic: "ZORG",
                             fullName: "Zorg", smallestFraction: 10000)
        let acmeAccount = try #require(model.addAccount(name: "ACME", type: .stock, commodity: acme))
        let zorgAccount = try #require(model.addAccount(name: "ZORG", type: .stock, commodity: zorg))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try model.addTransaction(date: date, description: "Buy ACME", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -1_000),
                     SplitInput(accountID: acmeAccount, value: 1_000, quantity: 100)])
        _ = try model.addTransaction(date: date, description: "Buy ZORG", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -2_000),
                     SplitInput(accountID: zorgAccount, value: 2_000, quantity: 100)])
        model.addPrice(commodity: acme, currency: .aud, date: date, value: 12)   // +200
        model.addPrice(commodity: zorg, currency: .aud, date: date, value: 15)   // −500

        let to = date.addingTimeInterval(86_400)
        let slides = model.investmentReviewSlides(from: .distantPast, to: to, label: "Test")
        let ids = slides.map(\.id)
        #expect(ids.contains("inv.dashboard"))
        #expect(ids.contains("inv.allocation"))
        #expect(ids.contains("inv.leaders"))
        #expect(ids.contains("inv.decomposition"))
        // No dividends, no disposals.
        #expect(!ids.contains("inv.income"))
        #expect(!ids.contains("inv.realised"))

        // Decomposition: the components in the facts sum to the stated gain.
        let decomposition = try #require(slides.first { $0.id == "inv.decomposition" })
        func figure(_ label: String) -> Decimal {
            decomposition.facts.figures.first { $0.0 == label }?.1 ?? 0
        }
        #expect(figure("Income") + figure("Realised gain") + figure("Unrealised gain")
                == figure("Total gain"))
        let portfolio = try #require(model.advancedPortfolio(asOf: to))
        #expect(figure("Total gain")
                == portfolio.totalUnrealized + portfolio.totalRealized + portfolio.totalIncome)

        // Leaders: ACME best (+200), ZORG weakest (−500).
        let leaders = try #require(slides.first { $0.id == "inv.leaders" })
        #expect(leaders.callouts.contains { $0.label == "Best: ACME" })
        #expect(leaders.callouts.contains { $0.label == "Weakest: ZORG" })
    }

    @Test("A dividend book gains the dividends slide with a grossed-up callout")
    func dividendSlide() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Everyday Card", type: .bank))
        let income = try #require(model.book?.account(with:
            model.addAccount(name: "Income", type: .income)!))
        let dividends = Account(name: "Dividends", type: .income, commodity: .aud)
        income.addChild(dividends)
        let bhp = Account(name: "BHP", type: .income, commodity: .aud)
        dividends.addChild(bhp)
        let franked = Account(name: "Franked", type: .income, commodity: .aud)
        bhp.addChild(franked)
        model.refreshAll()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try model.addTransaction(date: date, description: "Dividend", currency: .aud,
            splits: [SplitInput(accountID: bank, value: 70),
                     SplitInput(accountID: franked.guid, value: -70)])

        let slides = model.financialReviewSlides(
            from: date.addingTimeInterval(-86_400), to: date.addingTimeInterval(86_400),
            label: "Test")
        let slide = try #require(slides.first { $0.id == "dividends" })
        #expect(slide.callouts.contains { $0.label == "Grossed-up" })
        #expect(slide.facts.figures.contains { $0.0 == "Franked dividends" && $0.1 == 70 })
        // The bar is the security's cash, which the deck used to find by a
        // section title ending in "dividends".
        guard case .categoryBars(let bars) = slide.chart else {
            Issue.record("the dividends slide should carry bars"); return
        }
        #expect(bars.map(\.label) == ["BHP"])
        #expect(bars.first?.current == 70)
    }

    // MARK: The decks in the reader's language

    nonisolated private static let builders = ["FinancialReview.swift", "InvestmentReview.swift"]

    nonisolated private static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FinvestLensUI/\(name)"), encoding: .utf8)
    }

    /// A slide and its callouts carry `String`s, which SwiftUI draws as they
    /// are. So a literal put straight into one is English in every language
    /// — on screen, and in the facts the narrator writes from — and nothing
    /// says so: the two builders held 133 phrases that way. Each has to be a phrase
    /// in `String(localized:)`; what may stay bare is a slide's id, the
    /// story cache's key, and a value that is only numbers.
    @Test("Every word a deck shows or hands the narrator goes through the string catalog",
          arguments: builders)
    func nothingIsLeftInEnglish(file: String) throws {
        let localized = try Regex(#"String\(localized: "(?:[^"\\]|\\.)*"\)"#)
        let interpolation = try Regex(#"\\\((?:[^()]|\([^()]*\))*\)"#)
        let wordInLiteral = try Regex(#""[^"]*\p{L}[^"]*""#)
        var found = 0
        for (number, line) in try Self.source(file).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var code = String(line)
            if let comment = code.range(of: "//") { code = String(code[..<comment.lowerBound]) }
            found += code.matches(of: localized).count
            code = code.replacing(localized, with: "")
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("id:"), !trimmed.hasPrefix("let key = \"review.story:") else { continue }
            code = code.replacing(interpolation, with: "")
            #expect(code.firstMatch(of: wordInLiteral) == nil,
                    "\(file):\(number + 1) has a bare literal: \(trimmed)")
        }
        // The check passes on a file with no strings in it at all.
        #expect(found > 50, "\(file): only \(found) localized phrases found")
    }

    @Test("A percentage is written the reader's way")
    func percentages() throws {
        let (model, url, _) = try makeCashBook()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let english = Locale(identifier: "en_AU")
        #expect(model.reviewPercent(Decimal(string: "8.4")!, locale: english) == "8.4%")
        #expect(model.reviewPercent(26, places: 0, locale: english) == "26%")
        #expect(model.reviewPercent(12, locale: english) == "12%")
        #expect(model.reviewPercent(Decimal(string: "8.4")!, signed: true, locale: english) == "+8.4%")
        #expect(model.reviewPercent(Decimal(string: "-8.4")!, signed: true, locale: english) == "-8.4%")
        // A decimal comma, and the space each language puts before the sign.
        let german = model.reviewPercent(Decimal(string: "8.4")!, locale: Locale(identifier: "de_DE"))
        #expect(german.hasPrefix("8,4") && german.hasSuffix("%"))
        let french = model.reviewPercent(Decimal(string: "8.4")!, locale: Locale(identifier: "fr_FR"))
        #expect(french.hasPrefix("8,4") && french.hasSuffix("%"))
    }

    @Test("A change is listed under the label of the figure it is a change in")
    func changesShareTheirFiguresLabel() throws {
        // The narrator's prompt puts a change on its figure's line by
        // matching the two labels — which now come out of the catalog, so
        // they have to be the same phrase and not two that happen to agree
        // in English.
        let (model, url, date) = try makeCashBook()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        // A year earlier, so that there is a prior period to compare with.
        let bank = try #require(model.postableAccounts.first { $0.name == "Bank" }?.id)
        let salary = try #require(model.postableAccounts.first { $0.name == "Salary" }?.id)
        let food = try #require(model.postableAccounts.first { $0.name == "Food" }?.id)
        let earlier = date.addingTimeInterval(-86_400 * 365)
        _ = try model.addTransaction(date: earlier, description: "t", currency: .aud,
            splits: [SplitInput(accountID: salary, value: -5_000), SplitInput(accountID: bank, value: 5_000)])
        _ = try model.addTransaction(date: earlier, description: "t", currency: .aud,
            splits: [SplitInput(accountID: bank, value: -2_000), SplitInput(accountID: food, value: 2_000)])

        let slides = model.financialReviewSlides(
            from: date.addingTimeInterval(-86_400 * 30), to: date.addingTimeInterval(86_400), label: "Test")
        for id in ["highlights", "income", "spending"] {
            let slide = try #require(slides.first { $0.id == id })
            #expect(!slide.facts.deltaPercents.isEmpty, "\(id) lists no change")
            for (label, _) in slide.facts.deltaPercents {
                #expect(slide.facts.figures.contains { $0.0 == label }, "\(id): no figure is labelled \(label)")
            }
        }
        // Spending fell from 2,000 to 1,500, and the slide says which way.
        let spending = try #require(slides.first { $0.id == "spending" })
        #expect(spending.headline == "Spending down 25% at \(AmountFormat.compact(1_500, code: "AUD"))")
        #expect(spending.callouts.first?.label == "Total spending")
    }
}
