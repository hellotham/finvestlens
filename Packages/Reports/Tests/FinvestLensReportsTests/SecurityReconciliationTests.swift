//
//  SecurityReconciliationTests.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

private func income(_ amount: String, on date: Date, id: String = UUID().uuidString) -> SecurityEvent {
    SecurityEvent(id: id, kind: .income, date: date, units: 0, amount: dec(amount),
                  unitPrice: nil, accountName: "Broker", eventDescription: "Dividend")
}

/// Held continuously from 2024, 1,000 units throughout unless a test says
/// otherwise.
private let alwaysHeld = [HoldingPeriod(start: day(2024, 1, 1), end: nil)]
private func thousandUnits(_ date: Date) -> Decimal { 1000 }

@Suite("Dividend reconciliation")
struct DividendReconciliationTests {

    @Test("A declared dividend with no matching payment is reported as missing")
    func missingIncome() {
        // The case that finds real money: the issuer paid, the book never
        // recorded it, and income is understated.
        let found = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50"))],
            events: [], holdingPeriods: alwaysHeld, unitsOn: thousandUnits)

        #expect(found.count == 1)
        #expect(found[0].kind == .missing)
        #expect(found[0].expectedAmount == dec("500"))
        #expect(found[0].unitsHeld == 1000)
    }

    @Test("A payment weeks after the declaration is the same event, not two problems")
    func paymentLagIsNotADiscrepancy() {
        // Registries pay weeks after the ex-date and the book records the day
        // the cash landed. A tight window would report every single dividend
        // twice — once missing, once unexpected — which is a worklist nobody
        // would open again.
        let found = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50"))],
            events: [income("500.00", on: day(2026, 3, 28))],
            holdingPeriods: alwaysHeld, unitsOn: thousandUnits)
        #expect(found.isEmpty)
    }

    @Test("A payment far from any declaration is reported as unexpected")
    func unexpectedPayment() {
        let found = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50"))],
            events: [income("500.00", on: day(2026, 3, 28)),
                     income("120.00", on: day(2026, 3, 20), id: "special")],
            holdingPeriods: alwaysHeld, unitsOn: thousandUnits)

        // The $500 payment matched the $500 declaration even though the $120
        // special sits **nearer** to it in time. Matching on nearness alone
        // reported both as wrong — one as an amount mismatch, one as
        // unexpected — which is two false findings from one clean quarter.
        #expect(found.count == 1)
        #expect(found[0].kind == .unexpected)
        #expect(found[0].recordedAmount == dec("120.00"))
    }

    @Test("Small rounding is tolerated; a real shortfall is not")
    func amountTolerance() {
        // A dividend is rarely paid to the cent of the declaration — rounding
        // per holding, and withholding — so a zero tolerance reports every
        // payment ever made.
        let close = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50"))],
            events: [income("498.00", on: day(2026, 3, 10))],
            holdingPeriods: alwaysHeld, unitsOn: thousandUnits)
        #expect(close.isEmpty, "0.4% apart is rounding")

        // 30% short is withholding, a franking mix-up, or a DRP recorded at the
        // wrong price — all worth a person's time.
        let short = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50"))],
            events: [income("350.00", on: day(2026, 3, 10))],
            holdingPeriods: alwaysHeld, unitsOn: thousandUnits)
        #expect(short.count == 1)
        #expect(short[0].kind == .amountDiffers)
        #expect(short[0].expectedAmount == dec("500"))
        #expect(short[0].recordedAmount == dec("350.00"))
    }

    @Test("A dividend declared before you bought is not your missing income")
    func onlyWhileHeld() {
        // Otherwise the worklist fills with other people's dividends: every
        // declaration in the provider's ten-year history for a security bought
        // last year.
        let found = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2023, 3, 1), perUnit: dec("0.50")),
                       DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50"))],
            events: [], holdingPeriods: alwaysHeld, unitsOn: thousandUnits)

        #expect(found.count == 1)
        #expect(found[0].date == day(2026, 3, 1))
    }

    @Test("Two declarations close together do not both claim one payment")
    func nearestMatchWins() {
        let found = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50")),
                       DeclaredPayment(date: day(2026, 3, 20), perUnit: dec("0.50"))],
            events: [income("500.00", on: day(2026, 3, 5))],
            holdingPeriods: alwaysHeld, unitsOn: thousandUnits)

        // The 1 March declaration takes the 5 March payment (nearest); the
        // 20 March one is genuinely unrecorded.
        #expect(found.count == 1)
        #expect(found[0].kind == .missing)
        #expect(found[0].date == day(2026, 3, 20))
    }

    @Test("A holding of nothing on the declaration date is skipped")
    func zeroUnits() {
        let found = FinancialReports.reconcileDividends(
            declared: [DeclaredPayment(date: day(2026, 3, 1), perUnit: dec("0.50"))],
            events: [], holdingPeriods: alwaysHeld, unitsOn: { _ in 0 })
        #expect(found.isEmpty)
    }

    @Test("A clean book reports nothing")
    func cleanBook() {
        let declared = (1...4).map {
            DeclaredPayment(date: day(2026, $0 * 3 - 2, 1), perUnit: dec("0.50"))
        }
        let events = (1...4).map { income("500.00", on: day(2026, $0 * 3 - 2, 15)) }
        #expect(FinancialReports.reconcileDividends(
            declared: declared, events: events,
            holdingPeriods: alwaysHeld, unitsOn: thousandUnits).isEmpty)
    }
}

@Suite("Corporate action detection")
struct SplitReconciliationTests {

    @Test("A split the book never recorded is found")
    func unrecordedSplit() {
        // Quietly serious: every price before the split is inconsistent with
        // the units held, so the whole historical chart is wrong and nothing
        // else in the app would notice.
        let found = FinancialReports.reconcileSplits(
            declared: [DeclaredCapitalChange(date: day(2026, 6, 1), ratio: 2)],
            unitsOn: { _ in 1000 },        // unchanged across the split
            holdingPeriods: alwaysHeld)

        #expect(found.count == 1)
        #expect(found[0].unitsBefore == 1000)
        #expect(found[0].expectedUnitsAfter == 2000)
        #expect(found[0].actualUnitsAfter == 1000)
    }

    @Test("A split the book did record is not reported")
    func recordedSplit() {
        let split = day(2026, 6, 1)
        let found = FinancialReports.reconcileSplits(
            declared: [DeclaredCapitalChange(date: split, ratio: 2)],
            unitsOn: { $0 < split ? 1000 : 2000 },
            holdingPeriods: alwaysHeld)
        #expect(found.isEmpty)
    }

    @Test("Trading around a split does not read as a missing one")
    func toleranceAroundASplit() {
        // A book that recorded the split *and* sold some on the day will not
        // land on the arithmetic exactly. A strict equality would report every
        // real split as missing.
        let split = day(2026, 6, 1)
        let found = FinancialReports.reconcileSplits(
            declared: [DeclaredCapitalChange(date: split, ratio: 2)],
            unitsOn: { $0 < split ? 1000 : 1950 },   // 2.5% off
            holdingPeriods: alwaysHeld)
        #expect(found.isEmpty)
    }

    @Test("A one-for-one is not a capital change")
    func identityRatio() {
        #expect(FinancialReports.reconcileSplits(
            declared: [DeclaredCapitalChange(date: day(2026, 6, 1), ratio: 1)],
            unitsOn: { _ in 1000 }, holdingPeriods: alwaysHeld).isEmpty)
    }

    @Test("A consolidation is detected the same way as a split")
    func consolidation() {
        // One-for-ten: the ratio is below 1, and the arithmetic is identical.
        let found = FinancialReports.reconcileSplits(
            declared: [DeclaredCapitalChange(date: day(2026, 6, 1), ratio: dec("0.1"))],
            unitsOn: { _ in 1000 }, holdingPeriods: alwaysHeld)
        #expect(found.count == 1)
        #expect(found[0].expectedUnitsAfter == 100)
    }

    @Test("A split from before you held it is ignored")
    func onlyWhileHeld() {
        #expect(FinancialReports.reconcileSplits(
            declared: [DeclaredCapitalChange(date: day(2020, 6, 1), ratio: 2)],
            unitsOn: { _ in 1000 }, holdingPeriods: alwaysHeld).isEmpty)
    }
}

@Suite("Price outliers")
struct PriceOutlierTests {

    private func series(_ values: [String], from start: Date = day(2026, 1, 1)) -> [SecurityPriceRow] {
        values.enumerated().map { index, value in
            SecurityPriceRow(id: GncGUID.random(),
                             date: utc.date(byAdding: .day, value: index, to: start)!,
                             value: dec(value), currencyCode: "AUD", source: "user:price")
        }
    }

    @Test("A decimal-point slip is caught and named")
    func decimalSlip() {
        // The classic: 100.00 typed as 1000.00.
        var values = Array(repeating: "100.00", count: 11)
        values[5] = "1000.00"
        let found = FinancialReports.priceOutliers(series(values))

        #expect(found.count == 1)
        #expect(found[0].value == dec("1000.00"))
        #expect(found[0].neighbourMedian == dec("100.00"))
        #expect(found[0].likelyCause == .decimalSlip)
    }

    @Test("A price entered in cents is caught")
    func centsInsteadOfDollars() {
        var values = Array(repeating: "100.00", count: 11)
        values[5] = "1.00"
        let found = FinancialReports.priceOutliers(series(values))
        #expect(found.count == 1)
        #expect(found[0].likelyCause == .decimalSlip, "a factor of 100 either way")
    }

    @Test("Real volatility is not an outlier")
    func realMovesAreLeftAlone() {
        // A security really can move 50% in a week. A check that fires on that
        // is a check people switch off, and then it catches nothing at all.
        let found = FinancialReports.priceOutliers(
            series(["100", "110", "125", "140", "150", "155", "150", "140", "130", "120", "110"]))
        #expect(found.isEmpty)
    }

    @Test("The median is used, so one bad price cannot hide behind itself")
    func medianNotMean() {
        // With a mean, a 1000 among 100s drags the neighbourhood average to
        // ~180 and the ratio to 5.6 — and worse, implicates its neighbours. The
        // median is unmoved by a single outlier, which is the whole reason.
        var values = Array(repeating: "100.00", count: 11)
        values[5] = "1000.00"
        let found = FinancialReports.priceOutliers(series(values))
        #expect(found.count == 1, "only the bad row, not its neighbours")
    }

    @Test("Too short a series is not judged at all")
    func shortSeries() {
        // Three prices have no neighbourhood to be an outlier against, and
        // guessing would flag a security's first week every time.
        #expect(FinancialReports.priceOutliers(series(["100", "1000", "100"])).isEmpty)
    }

    @Test("A clean series reports nothing")
    func cleanSeries() {
        #expect(FinancialReports.priceOutliers(series(Array(repeating: "100.00", count: 30))).isEmpty)
    }
}
