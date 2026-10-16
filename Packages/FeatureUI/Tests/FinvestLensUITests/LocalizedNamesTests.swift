//
//  LocalizedNamesTests.swift
//  FinvestLens — FeatureUI
//
//  What the views drew straight from a raw value — "Mutual", "startsWith",
//  "Etf" — is named for the reader now. Tests run without the app's catalog,
//  so a name comes back as its English key; what is pinned is that there is
//  one for every case, and that nothing compares against the words.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensRules
@testable import FinvestLensUI

@Suite("Names for the reader")
struct LocalizedNamesTests {

    @Test("Every raw-valued type the views show has a name for each case")
    func everyCaseNamed() {
        for type in AccountType.allCases { #expect(!type.localizedName.isEmpty, "\(type)") }
        #expect(AccountType.mutualFund.localizedName == "Mutual Fund")
        #expect(AccountType.receivable.localizedName == "A/Receivable")
        for field in RuleField.allCases { #expect(!field.localizedName.isEmpty) }
        #expect(RuleOperator.startsWith.localizedName == "starts with")
        for sort in RegisterSort.allCases { #expect(!sort.title.isEmpty) }
        #expect(RegisterSort.standard.title == RegisterSort.standard.rawValue)
        for kind in BillableEntry.Kind.allCases { #expect(!kind.localizedName.isEmpty) }
        #expect(InvestmentDetail.Action.reinvestDividend.localizedName == "Reinvest Dividend")
    }

    @Test("A provider's security type is named; one this does not know is shown as it came")
    func securityKinds() {
        #expect(SecurityKindName.name("EQUITY") == "Share")
        #expect(SecurityKindName.name("etf") == "ETF")
        #expect(SecurityKindName.name("MUTUALFUND") == "Fund")
        #expect(SecurityKindName.name("WARRANT") == "WARRANT")
    }

    @Test("A currency is named by the reader's locale; a security by its own name")
    func commodityNames() {
        let expected = Locale.current.localizedString(forCurrencyCode: "AUD") ?? "Australian Dollar"
        #expect(Commodity.aud.localizedName == expected)
        let security = Commodity(namespace: .security("ASX"), mnemonic: "VAS",
                                 fullName: "Vanguard Australian Shares", smallestFraction: 1)
        #expect(security.localizedName == "Vanguard Australian Shares")
    }

    /// The rotor's list of unreconciled rows compared each row's *word* with
    /// "Not reconciled". The word is the reader's now, and that comparison
    /// would have found nothing in any other language.
    @Test("Unreconciled rows are found by their letter, not by a word")
    func unreconciledByLetter() {
        for glyph in ["", "n", " "] { #expect(ReconcileBadge.isUnreconciled(glyph)) }
        for glyph in ["c", "y", "f", "v"] { #expect(!ReconcileBadge.isUnreconciled(glyph)) }
    }

    @Test("A schedule reads as one sentence, whatever its period")
    func scheduleSummaries() {
        for period in RecurrencePeriod.allCases {
            let summary = period.summary(interval: 2, from: "1 March 2026")
            #expect(summary.contains("1 March 2026"), "\(period)")
            #expect(!period.every(2).isEmpty)
        }
    }
}
