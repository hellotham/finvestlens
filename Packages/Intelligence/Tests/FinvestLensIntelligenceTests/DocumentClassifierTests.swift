//
//  DocumentClassifierTests.swift
//  FinvestLens — Intelligence
//
//  The phrasings below are the ones real Australian registries use, taken
//  from which marker words actually appear in a run of live statements (the
//  documents themselves are never in this repo — only the vocabulary).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import FinvestLensIntelligence

@Suite("Security-income classification")
struct DocumentClassifierIncomeTests {

    @Test("A capital-note advice that never says “dividend” is still income")
    func distributionWithoutTheWordDividend() {
        // NAB capital notes: the word "dividend" appears nowhere. Requiring it
        // sent this to the invoice path, which then hunted for that amount going
        // *out* of the account — while the deposit sat in the book on the day
        // the advice names.
        let advice = """
            NAB CAPITAL NOTES 2 — DISTRIBUTION PAYMENT ADVICE
            Record Date: 9 March 2026      Payment Date: 17 March 2026
            Distribution rate per note   $0.9338
            Franked amount   500.00
            """
        #expect(DocumentClassifier.isSecurityIncome(advice))
    }

    @Test("A Vanguard advice that never says “franked” is still income")
    func distributionWithoutFranking() {
        // The mirror image, and why the old rule could not simply be relaxed
        // on one side: this one says "dividend" and "distribution" but carries
        // no franking language at all.
        let advice = """
            VANGUARD INTERNATIONAL SHARES HEDGED ETF (VGAD)
            Distribution / Dividend Payment Advice
            Record Date  31 December 2025     Payment Date  19 January 2026
            Securities held   1,234
            Distribution Reinvestment Plan: not participating
            """
        #expect(DocumentClassifier.isSecurityIncome(advice))
    }

    @Test("A fully franked dividend advice is income")
    func frankedDividend() {
        let advice = """
            TELSTRA GROUP LIMITED — DIVIDEND ADVICE
            Record Date 27 February 2026   Payment Date 27 March 2026
            Franked Amount   1,000.00    Franking Credit   428.57
            """
        #expect(DocumentClassifier.isSecurityIncome(advice))
    }

    @Test("A shop receipt is never income, whatever words it happens to carry")
    func receiptsAreNotIncome() {
        // The guard the two-signal rule exists for. One word on its own must
        // not flip a purchase into a deposit — a receipt hunted for among
        // *incoming* money would never match, and if it did it would be wrong.
        #expect(!DocumentClassifier.isSecurityIncome("""
            WOOLWORTHS 3421 SYDNEY
            TOTAL  45.67   GST INCLUDED  4.15
            EFTPOS PURCHASE — APPROVED
            """))
        // A cafe that prints "payment date" on its invoice still is not income:
        // there is no dividend or distribution being paid.
        #expect(!DocumentClassifier.isSecurityIncome("""
            TAX INVOICE — ALPINE CAFE
            Payment Date: 20 January 2026   Amount Due: 18.00
            """))
        // And a share-purchase confirmation names a security but pays nothing.
        #expect(!DocumentClassifier.isSecurityIncome("""
            CHESS HOLDING STATEMENT — UNITS SOLD
            Trade confirmation. Consideration 2,000.00
            """))
    }

    @Test("Classification by keywords still recognises the same statements")
    func keywordKindUnchanged() {
        #expect(DocumentClassifier.classifyByKeywords("Dividend advice, franked amount")
                == .dividendStatement)
        #expect(DocumentClassifier.classifyByKeywords("TAX INVOICE total 45.67") == .invoice)
    }
}
