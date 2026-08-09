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

@Suite("How a receipt was paid")
struct TenderTests {

    @Test("A cash docket is cash")
    func cash() {
        #expect(DocumentClassifier.tender("""
            H HUNG RESTAURANT
            TOTAL      25.60
            CASH       30.00
            CHANGE      4.40
            """) == .cash)
    }

    @Test("A card docket is card even when it prints CHANGE")
    func cardPrintingChange() {
        // The asymmetry that matters. Card dockets routinely print a zero
        // change line, so "change" alone must never mean cash.
        #expect(DocumentClassifier.tender("""
            KIRRIBILLI SHOP
            TOTAL       4.99
            VISA CREDIT  ****1234
            CHANGE      0.00
            """) == .card)
    }

    @Test("An EFTPOS receipt offering cash out is still a card payment")
    func cashOutIsNotCash() {
        // The other direction of the same trap: the word "cash" appears on
        // the most card-like document there is.
        #expect(DocumentClassifier.tender("""
            EFTPOS PURCHASE + CASH OUT
            SAVINGS  APPROVED - 00
            PURCHASE 29.97   CASH  50.00
            """) == .card)
    }

    @Test("Anything card-shaped wins, because the mistakes are not equal")
    func cardDetectionIsDeliberatelyBroad() {
        // A $2,149 tablet bought on a debit card was proposed as a cash
        // purchase on a real run, because the reflowed OCR did not produce the
        // exact phrase the first list looked for. Calling a card purchase cash
        // invents a transaction that will double-count when the statement
        // arrives; missing a card merely leaves a receipt unmatched. So the
        // card list reads bare words too.
        for docket in ["TOTAL 2149.00\nDEBIT\nAPPROVED",
                       "TOTAL 49.58\nCONTACTLESS",
                       "TOTAL 19.00\nACCOUNT TYPE: SAVINGS",
                       "TOTAL 12.00\nAUTH 004512"] {
            #expect(DocumentClassifier.tender(docket) == .card, "should read as card: \(docket)")
        }
    }

    @Test("A receipt that says nothing about payment admits nothing")
    func unknown() {
        #expect(DocumentClassifier.tender("UMAYA IZAKAYA\nTOTAL 15.01") == .unknown)
        #expect(DocumentClassifier.tender("") == .unknown)
    }

    @Test("Tender says nothing about which account")
    func tenderIsNotAnAccount() {
        // Documented as a test because it is the whole reason the account is a
        // required parameter elsewhere: two people with a cash account each
        // produce identical dockets.
        let docket = "CAFE\nTOTAL 20.00\nCASH 20.00"
        #expect(DocumentClassifier.tender(docket) == .cash)
        // There is no API here that returns an account, and there should not be.
    }
}
