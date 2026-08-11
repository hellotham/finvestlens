//
//  DividendReconcilerTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The statement text below reproduces the registry layout only. Every figure
//  is synthetic and internally consistent — rate × units = the franked amount,
//  and the credit is three sevenths of it — so the reconciliation arithmetic is
//  exercised without a real statement's numbers. The model answers are the ones
//  the on-device model actually produced. This file previously carried a real
//  statement's figures, including a unit count, which is a holding.
//
//  Decimal expectations are written `Decimal(string:)`, never as literals: a
//  bare 456.78 is a Double first and reaches Decimal as 456.7799999999998976,
//  which does not equal the exact value parsed from the page.
//

import Testing
import Foundation
@testable import FinvestLensIntelligence

@Suite("Dividend reconciliation")
struct DividendReconcilerTests {

    /// A registry statement: the five-column row, plus the prose restatement
    /// of the arithmetic that the model keeps reading instead of the row.
    ///
    /// The rate divides evenly into the amount here, which is the shape
    /// `check-no-real-data.py` flags as a recoverable holding — deliberately,
    /// because that is what a reconciliation fixture has to look like to
    /// exercise the arithmetic. These figures are invented. // synthetic
    private let page = """
        EXAMPLE INCOME FUND LIMITED (ASX: XYZ)
        Payment Date:   30 April 2025
        This statement represents your dividend of 0.70 cents per share
        $0.0070 x 100,000 Shares
        = 700.00
        Ordinary   Dividend Rate   Unfranked   Franked   Franking   Gross Payment:   $700.00
        Shares   per Share   Amount   Amount   Credit
        100,000   $0.0070   $0.00   $700.00   $300.00   Net Payment:   $700.00
        """

    @Test("A franked amount read off the calculation line is replaced by the printed one")
    func recoversFrankedFromPrintedPayment() {
        // "$0.0070 x 100,000" parses to 70100.000 — a number that appears
        // nowhere on the page. The payment and the unfranked amount do, so the
        // franked amount is their difference.
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "70100.000", unfranked: "0.00", net: "700.00"),
            printedIn: page)
        #expect(details.frankedAmount == 700)
        #expect(details.unfrankedAmount == 0)
        #expect(details.netPayment == 700)
        #expect(details.componentsMatchPayment)
    }

    @Test("A payment the model computed is replaced by the components")
    func recoversPaymentFromComponents() {
        // Told about franking credits, the model nets them off the payment:
        // it reported a $700.00 dividend as $400.00. That figure is not on the
        // page; the components are.
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "700.00", unfranked: "0.00",
                                     credits: "300.00", net: "400.00"),
            printedIn: page)
        #expect(details.netPayment == 700)
        #expect(details.frankingCredits == Decimal(string: "300.00"))
        #expect(details.componentsMatchPayment)
    }

    @Test("A missed franking credit is found by grossing up — when the page prints it")
    func creditRecoveredByGrossUp() {
        // The model reports "0.00" for a column it failed to read. A fully
        // franked dividend implies its credit exactly, so the figure is
        // computed and then looked for: 700 × 30/70 = 300.00, which this page
        // does print.
        for reported in ["", "0.00", "0"] {
            let details = DividendReconciler.details(
                from: RawDividendFigures(franked: "700.00", unfranked: "0.00",
                                         credits: reported, net: "700.00"),
                printedIn: page)
            #expect(details.frankingCredits == Decimal(string: "300.00"),
                    "credit not recovered when the model reported \"\(reported)\"")
        }
    }

    @Test("A credit the page does not print is never claimed")
    func grossUpIsOnlyASearchKey() {
        // Partly franked: the gross-up does not hold, so the computed figure
        // is absent from the page and nothing is reported. This is the whole
        // distinction — the arithmetic says where to look, never what is true.
        let partly = """
            Unfranked   Franked   Franking Credit
            300.00   400.00   55.00   Net Payment:   700.00
            """
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "400.00", unfranked: "300.00",
                                     credits: "0.00", net: "700.00"),
            printedIn: partly)
        // 400 × 30/70 = 171.43, which is not on this page — the real credit is
        // 55.00, and guessing it would have been wrong.
        #expect(details.frankingCredits == 0)
        #expect(details.componentsMatchPayment)
    }

    @Test("A rate read into the empty component column is zeroed")
    func rateInTheWrongColumn() {
        // Capital-note statements print a distribution per note, and the
        // model puts that rate in the Unfranked column. It is on the page, so
        // the printed-check cannot object — but the franked amount already
        // equals the payment, and the two components sum to it, so the other
        // one can only be zero.
        let notes = """
            CAPITAL NOTES (ASX: XYZPA)
            Distribution rate per note   $0.7000
            Unfranked   Franked   Franking Credit
            0.00   350.00   150.00   Net Payment:   350.00
            """
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "350.00", unfranked: "0.7000",
                                     credits: "150.00", net: "350.00"),
            printedIn: notes)
        #expect(details.unfrankedAmount == 0)
        #expect(details.frankedAmount == Decimal(string: "350.00"))
        #expect(details.componentsMatchPayment)
    }

    @Test("A franking credit as large as the dividend is refused")
    func creditCannotEqualTheDividend() {
        // The model returned the franked amount in both columns. That figure
        // is genuinely printed, so grounding had no objection — but a credit
        // is three sevenths of the dividend at 30% and a third at 25%, never
        // all of it. Refused, then recovered by grossing up.
        let notes = """
            Unfranked   Franked   Franking Credit
            0.00   350.00   150.00   Net Payment:   350.00
            """
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "350.00", unfranked: "0.00",
                                     credits: "350.00", net: "350.00"),
            printedIn: notes)
        #expect(details.frankingCredits == Decimal(string: "150.00"))
    }

    @Test("An unfranked distribution grosses up to nothing")
    func noCreditWithoutFranking() {
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "0.00", unfranked: "700.00",
                                     credits: "0.00", net: "700.00"),
            printedIn: page)
        #expect(details.frankingCredits == 0)
    }

    @Test("A derived figure that is not printed is refused")
    func derivationMustAlsoBePrinted() {
        // The guard against manufacturing agreement: asked in the wrong field
        // order the model returned the rate in both columns, and their sum was
        // recorded as a payment of $0.014 — self-consistent and nonsense.
        // Figures invented, same as the fixture they exercise. // synthetic
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "0.0070", unfranked: "0.0070", net: ""),
            printedIn: page)
        #expect(details.netPayment == 0)
    }

    @Test("A statement that contradicts itself is left contradicting itself")
    func bothPrintedAndDisagreeing() {
        // Both components are on the page, neither accounts for the payment on
        // its own, and they still do not add up to it. Nothing is invented —
        // the mismatch is what the reviewer needs to see.
        let odd = """
            Unfranked   Franked   Franking Credit
            200.00   300.00   128.57   Net Payment:   700.00
            """
        let details = DividendReconciler.details(
            from: RawDividendFigures(franked: "300.00", unfranked: "200.00", net: "700.00"),
            printedIn: odd)
        #expect(details.frankedAmount == 300)
        #expect(details.unfrankedAmount == 200)
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
            from: RawDividendFigures(security: "Example Income Fund", ticker: "xyz",
                                     paymentDate: "2025-04-30", franked: "700.00",
                                     unfranked: "0.00", net: "700.00"),
            printedIn: page)
        #expect(details.ticker == "XYZ")
        #expect(details.securityName == "Example Income Fund")
        #expect(details.paymentDate != nil)
    }
}
