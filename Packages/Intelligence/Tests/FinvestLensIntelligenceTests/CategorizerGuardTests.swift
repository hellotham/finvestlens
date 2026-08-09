//
//  CategorizerGuardTests.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  An expense is never income. These drive `CategorySuggestionResolver`
//  itself rather than restating its filter in the test, and the model answers below were
//  recorded from the on-device model, not imagined — offered three categories
//  for one transaction it replied three times, numbering the *categories*.
//

import Testing
import Foundation
import FinvestLensEngine
@testable import FinvestLensIntelligence

@Suite("Categoriser sign invariant")
struct CategorizerGuardTests {

    private let groceries = Self.candidate("Expenses:Food:Groceries", income: false)
    private let fuel = Self.candidate("Expenses:Motor:Fuel", income: false)
    private let otherIncome = Self.candidate("Income:Other Income", income: true)
    private let salary = Self.candidate("Income:Salary", income: true)

    private static func candidate(_ name: String, income: Bool) -> CategoryCandidate {
        CategoryCandidate(id: guid(name), fullName: name, isIncome: income)
    }

    /// `GncGUID` has no zero-argument init; derive distinct bytes from the name
    /// so the helper stays pure (no mutable static, which Swift 6 rejects).
    private static func guid(_ seed: String) -> GncGUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in seed.utf8.prefix(16).enumerated() { bytes[i] = byte }
        return GncGUID(bytes: bytes)!
    }

    private func spend(_ payee: String, _ amount: Decimal) -> CategorizationItem {
        CategorizationItem(payee: payee, amount: amount)
    }

    @Test("Money out is never resolved to an income account")
    func spendingNeverBecomesIncome() {
        // The fuzzy matcher is forgiving by design, so the guard has to hold
        // even when the model names an income account outright.
        let coles = spend("Coles", -42.10)
        let result = CategorySuggestionResolver.resolve(
            answers: [(1, "Income:Other Income")],
            batch: [coles],
            offered: [groceries, otherIncome, salary])
        #expect(result[coles.id] == nil)
    }

    @Test("Money in may resolve to income, and to an expense account for a refund")
    func receiptsKeepBothDirections() {
        let dividend = spend("TLS Telstra", 3150)
        let refund = spend("Bunnings refund", 140)
        let offered = [groceries, otherIncome]
        #expect(CategorySuggestionResolver.resolve(
            answers: [(1, "Income:Other Income")], batch: [dividend], offered: offered)[dividend.id]
                == otherIncome.id)
        // A refund offsetting what it was spent on is the reason the rule is
        // one-way rather than symmetric.
        #expect(CategorySuggestionResolver.resolve(
            answers: [(1, "Expenses:Food:Groceries")], batch: [refund], offered: offered)[refund.id]
                == groceries.id)
    }

    @Test("Padded answers past the end of the batch are dropped")
    func paddingIsDropped() {
        // Recorded from the on-device model: one transaction, three candidates,
        // three answers — it enumerated the category list. Answer 3 was
        // "Income:Other Income", which is how an unrelated row acquired it.
        let coffee = spend("Coffee shop", -5)
        let result = CategorySuggestionResolver.resolve(
            answers: [(1, "Expenses:Food:Groceries"),
                      (2, "Expenses:Motor:Fuel"),
                      (3, "Income:Other Income")],
            batch: [coffee],
            offered: [groceries, fuel])
        #expect(result.count == 1)
        #expect(result[coffee.id] == groceries.id)
    }

    @Test("A pad landing inside the batch still cannot make spending income")
    func padWithinRangeIsStillGuarded() {
        // Same padding, but now the batch is long enough for answer 3 to land
        // on a real row. Without the sign guard that row becomes Other Income.
        let rows = [spend("Coles", -42.10), spend("Shell", -95), spend("Woolworths", -88.35)]
        let result = CategorySuggestionResolver.resolve(
            answers: [(1, "Expenses:Food:Groceries"),
                      (2, "Expenses:Motor:Fuel"),
                      (3, "Income:Other Income")],
            batch: rows,
            offered: [groceries, fuel, otherIncome])
        #expect(result[rows[0].id] == groceries.id)
        #expect(result[rows[1].id] == fuel.id)
        #expect(result[rows[2].id] == nil)
    }

    @Test("Invented categories the matcher cannot resolve are left alone")
    func inventedNamesAreDropped() {
        // Also recorded: the model returned "Expenses:Transportation:Uber",
        // which was never offered. An unmatched row stays for the person.
        let uber = spend("Uber", -24.50)
        let result = CategorySuggestionResolver.resolve(
            answers: [(1, "Expenses:Transportation:Uber")],
            batch: [uber],
            offered: [groceries, fuel])
        #expect(result[uber.id] == nil)
    }

    @Test("Out-of-range and zero numbers are ignored rather than crashing")
    func nonsenseNumbers() {
        let coles = spend("Coles", -42.10)
        let result = CategorySuggestionResolver.resolve(
            answers: [(0, "Expenses:Food:Groceries"),
                      (-3, "Expenses:Food:Groceries"),
                      (99, "Expenses:Food:Groceries")],
            batch: [coles],
            offered: [groceries])
        #expect(result.isEmpty)
    }

    @Test("Candidates default to expense so an unstamped one can't become income")
    func defaultIsNotIncome() {
        #expect(CategoryCandidate(id: Self.guid("Expenses:X"), fullName: "Expenses:X").isIncome == false)
    }
}
