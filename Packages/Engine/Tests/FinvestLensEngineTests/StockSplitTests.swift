//
//  StockSplitTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@Suite("Stock splits")
struct StockSplitTests {

    @Test("2:1 split doubles shares, halves per-share cost, preserves basis")
    func twoForOne() {
        // Buy 10 @ $10 ($100), then a 2:1 split adds 10 shares.
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
            LotEvent(date: day(100), quantity: dec("10"), value: 0, isSplit: true),
        ], method: .fifo)
        #expect(result.remainingQuantity == dec("20"))
        #expect(result.remainingCostBasis == dec("100"))   // unchanged
        #expect(result.openLots.first?.costPerShare == dec("5"))
    }

    @Test("Selling after a split uses the rescaled basis")
    func sellAfterSplit() {
        // Buy 10 @ $10, 2:1 split (→ 20 @ $5), sell 5 @ $8.
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
            LotEvent(date: day(100), quantity: dec("10"), value: 0, isSplit: true),
            LotEvent(date: day(200), quantity: dec("-5"), value: dec("-40")),
        ], method: .fifo)
        // 5 sold at $5 basis = $25; proceeds $40 → gain $15. 15 remain, basis $75.
        #expect(result.totalCostBasis == dec("25"))
        #expect(result.totalRealizedGain == dec("15"))
        #expect(result.remainingQuantity == dec("15"))
        #expect(result.remainingCostBasis == dec("75"))
    }

    @Test("A split on an open short rescales the short, so the cover strikes the true gain")
    func splitOnShortPosition() {
        // Short 100 @ $10 ($1,000 proceeds), 2:1 split while short (balance
        // −100 → −200, so the event quantity is −100), buy 200 @ $4 to cover:
        // the economic result is a $200 gain and a flat position. Before the
        // fix the split was a no-op on shorts, yielding a $600 gain plus a
        // phantom open lot of 100 shares.
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("-100"), value: dec("-1000")),
            LotEvent(date: day(50), quantity: dec("-100"), value: 0, isSplit: true),
            LotEvent(date: day(100), quantity: dec("200"), value: dec("800")),
        ], method: .fifo)
        #expect(result.totalRealizedGain == dec("200"))
        #expect(result.remainingQuantity == 0)
        #expect(result.openLots.isEmpty)
        #expect(result.shortQuantity == 0)
    }

    @Test("Average cost: a split on an open short rescales the short, not the pool")
    func averageSplitOnShort() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("-100"), value: dec("-1000")),
            LotEvent(date: day(50), quantity: dec("-100"), value: 0, isSplit: true),
            LotEvent(date: day(100), quantity: dec("200"), value: dec("800")),
        ], method: .average)
        #expect(result.totalRealizedGain == dec("200"))
        #expect(result.remainingQuantity == 0)
        #expect(result.shortQuantity == 0)
    }

    @Test("Reverse 1:2 split halves shares, doubles per-share cost")
    func reverseSplit() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
            LotEvent(date: day(100), quantity: dec("-5"), value: 0, isSplit: true),
        ], method: .fifo)
        #expect(result.remainingQuantity == dec("5"))
        #expect(result.remainingCostBasis == dec("100"))
        #expect(result.openLots.first?.costPerShare == dec("20"))
    }

    @Test("Average cost: split moves shares, not the pool")
    func averageSplit() {
        let result = CostBasis.compute(events: [
            LotEvent(date: day(0), quantity: dec("10"), value: dec("100")),
            LotEvent(date: day(100), quantity: dec("10"), value: 0, isSplit: true),
        ], method: .average)
        #expect(result.remainingQuantity == dec("20"))
        #expect(result.remainingCostBasis == dec("100"))
    }

    @Test("Book marks Split-action splits as split events")
    func bookIntegration() {
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10000)
        let book = Book(baseCurrency: .aud)
        let stock = Account(name: "CBA", type: .stock, commodity: cba)
        book.addAccount(stock)
        book.addTransaction(StockTransaction.buy(
            security: stock, cash: book.rootAccount,
            shares: dec("10"), pricePerShare: dec("10"),
            date: day(0), currency: .aud, description: "Buy"))
        book.addTransaction(StockTransaction.stockSplit(
            security: stock, addedShares: dec("10"),
            date: day(100), currency: .aud, description: "2:1 split"))

        let result = book.costBasis(for: stock, method: .fifo)
        #expect(result.remainingQuantity == dec("20"))
        #expect(result.remainingCostBasis == dec("100"))
    }
}
