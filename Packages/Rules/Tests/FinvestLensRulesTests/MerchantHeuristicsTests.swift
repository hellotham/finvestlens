//
//  MerchantHeuristicsTests.swift
//  FinvestLens — Rules
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import FinvestLensRules

@Suite("Merchant heuristics")
struct MerchantHeuristicsTests {

    @Test("Cleans a noisy statement line to a merchant name")
    func clean() {
        #expect(MerchantHeuristics.cleanMerchant("WOOLWORTHS 1234 SYDNEY AU") == "Woolworths")
        #expect(MerchantHeuristics.cleanMerchant("EFTPOS BP CONNECT 456 CARD 7788") == "Bp Connect")
        #expect(MerchantHeuristics.cleanMerchant("NETFLIX.COM") == "Netflix.com")
    }

    @Test("Maps merchants to default categories")
    func categorise() {
        #expect(MerchantHeuristics.category(for: "WOOLWORTHS 1234") == "Groceries")
        #expect(MerchantHeuristics.category(for: "Netflix monthly") == "Subscriptions")
        #expect(MerchantHeuristics.category(for: "Shell Petrol Station") == "Fuel")
        #expect(MerchantHeuristics.category(for: "ACME WIDGETS") == nil)
    }

    /// A book the app starts is in the reader's language, so a category is
    /// looked for by the reader's name and then by the English one. A
    /// category added to the keywords without a name beside it would be found
    /// in English books only.
    @Test("Every category the heuristics name has the reader's name beside it")
    func everyCategoryHasALocalizedName() {
        for (_, category) in MerchantHeuristics.keywordCategories {
            #expect(MerchantHeuristics.localizedName(ofCategory: category) != nil, "\(category)")
        }
        #expect(MerchantHeuristics.localizedName(ofCategory: "Not A Category") == nil)
    }
}
