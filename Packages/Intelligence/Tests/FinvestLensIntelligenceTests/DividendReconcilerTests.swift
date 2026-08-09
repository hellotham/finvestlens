//
//  DividendReconcilerTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The statement text below is the real Automic/Computershare layout, with the
//  figures changed; the model answers are the ones the on-device model actually
//  produced for it.
//
//  Decimal expectations are written `Decimal(string:)`, never as literals: a
//  bare 252.86 is a Double first and reaches Decimal as 252.8600000000000512,
//  which does not equal the exact value parsed from the page.
//

import Testing
import Foundation
@testable import FinvestLensIntelligence

@Suite("Dividend reconciliation")
struct DividendReconcilerTests {

    /// A registry statement: the five-column row, plus the prose restatement
    /// of the arithmetic that the model keeps reading instead of the row.
    private let page = """
        PLATO INCOME MAXIMISER LIMITED (ASX: PL8)
        Payment Date:   30 April 2025
        This statement represents your dividend of 0.55 cents per share
        $0.0055 x 107,272 Shares
        = 590.00
        Ordinary   Dividend Rate   Unfranked   Franked   Franking   Gross Payment:   $590.00
        Shares   per Share   Amount   Amount   Credit
        107,272   $0.0055   $0.00   $590.00   $252.86   Net Payment:   $590.00
        """

    @Test("A franked amount read off the calculation line is replaced by the printed one")
    func recoversFrankedFromPrintedPayment() {
        // "$0.0055 x 107,272" parses to 55107.272 — a number that appears
        // nowhere on the page. The payment and the unfranked amount do, so the
        // franked amount is their difference.
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "55107.272", unfranked: "0.00", net: "590.00"),
            printedIn: page)
        #expect(details.frankedAmount == 590)
        #expect(details.unfrankedAmount == 0)
        #expect(details.netPayment == 590)
        #expect(details.componentsMatchPayment)
    }

    @Test("A payment the model computed is replaced by the components")
    func recoversPaymentFromComponents() {
        // Told about franking credits, the model nets them off the payment:
        // it reported a $590.00 dividend as $337.14. That figure is not on the
        // page; the components are.
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "590.00", unfranked: "0.00",
                                     credits: "252.86", net: "337.14"),
            printedIn: page)
        #expect(details.netPayment == 590)
        #expect(details.frankingCredits == Decimal(string: "252.86"))
        #expect(details.componentsMatchPayment)
    }

    @Test("Franking credits are never derived — only reported when printed")
    func creditsAreNeverInvented() {
        // No arithmetic on the page constrains the credit, so a missing one
        // stays missing rather than being guessed from the tax rate.
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "590.00", unfranked: "0.00", credits: "", net: "590.00"),
            printedIn: page)
        #expect(details.frankingCredits == 0)
        #expect(details.componentsMatchPayment)
    }

    @Test("A derived figure that is not printed is refused")
    func derivationMustAlsoBePrinted() {
        // The guard against manufacturing agreement: asked in the wrong field
        // order the model returned the rate in both columns, and their sum was
        // recorded as a payment of $0.011 — self-consistent and nonsense.
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "0.0055", unfranked: "0.0055", net: ""),
            printedIn: page)
        #expect(details.netPayment == 0)
    }

    @Test("A statement that contradicts itself is left contradicting itself")
    func bothPrintedAndDisagreeing() {
        // Both components are on the page and still do not add up. Nothing is
        // invented — the mismatch is what the reviewer needs to see.
        let odd = page + "\n   Adjustment   $252.86"
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "590.00", unfranked: "252.86", net: "590.00"),
            printedIn: odd)
        #expect(details.frankedAmount == 590)
        #expect(details.unfrankedAmount == Decimal(string: "252.86"))
        #expect(!details.componentsMatchPayment)
    }

    @Test("A wholly unfranked distribution still balances")
    func unfrankedOnly() {
        let etf = """
            VANGUARD AUSTRALIAN SHARES HIGH YIELD ETF (VHY)
            Unfranked   Franked   Franking Credit
            1,240.50   0.00   0.00   Net Payment: 1,240.50
            """
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "0.00", unfranked: "1240.50", net: "1240.50"),
            printedIn: etf)
        #expect(details.unfrankedAmount == Decimal(string: "1240.50"))
        #expect(details.frankedAmount == 0)
        #expect(details.componentsMatchPayment)
    }

    @Test("The ticker is upper-cased and the date parsed")
    func passthroughFields() {
        let details = DividendReconciler.details(
            from: RawDividendFigures(security: "Plato Income Maximiser", ticker: "pl8",
                                     paymentDate: "2025-04-30", franked: "590.00",
                                     unfranked: "0.00", net: "590.00"),
            printedIn: page)
        #expect(details.ticker == "PL8")
        #expect(details.securityName == "Plato Income Maximiser")
        #expect(details.paymentDate != nil)
    }
}
