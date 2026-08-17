//
//  RuleEngineTests.swift
//  FinvestLens — Rules
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensRules

private let groceries = GncGUID.random()
private let subs = GncGUID.random()

@Suite("Rule engine")
struct RuleEngineTests {

    private func group(_ rules: [Rule]) -> [RuleGroup] {
        [RuleGroup(name: "Default", rules: rules)]
    }

    @Test("A description-contains rule categorises")
    func categorise() {
        let rule = Rule(name: "Woolworths → Groceries",
                        triggers: [RuleTrigger(field: .description, op: .contains, value: "woolworths")],
                        actions: [.setAccount(groceries)])
        let outcome = RuleEngine.evaluate(group([rule]),
                                          context: RuleContext(description: "WOOLWORTHS 123"))
        #expect(outcome.accountID == groceries)
    }

    @Test("An allocate-to-goal action carries the goal id into the outcome (FR-RULE-01)")
    func allocateToGoal() {
        let goal = GncGUID.random()
        let rule = Rule(name: "Round-up → Holiday",
                        triggers: [RuleTrigger(field: .description, op: .contains, value: "save")],
                        actions: [.allocateToGoal(goal)])
        let outcome = RuleEngine.evaluate(group([rule]),
                                          context: RuleContext(description: "Auto SAVE transfer"))
        #expect(outcome.goalID == goal)
        // A non-matching context leaves the goal unset.
        #expect(RuleEngine.evaluate(group([rule]),
                                    context: RuleContext(description: "Groceries")).goalID == nil)
    }

    @Test("matchAll requires every trigger; any requires one")
    func andOr() {
        let triggers = [
            RuleTrigger(field: .description, op: .contains, value: "netflix"),
            RuleTrigger(field: .amount, op: .lessThan, value: "0"),
        ]
        let all = Rule(name: "AND", triggers: triggers, matchAll: true, actions: [.setAccount(subs)])
        let any = Rule(name: "OR", triggers: triggers, matchAll: false, actions: [.setAccount(subs)])

        let outflow = RuleContext(description: "Netflix", amount: Decimal(-19))
        let inflow = RuleContext(description: "Netflix", amount: Decimal(19))

        #expect(RuleEngine.evaluate(group([all]), context: outflow).accountID == subs)
        #expect(RuleEngine.evaluate(group([all]), context: inflow).accountID == nil)   // amount fails
        #expect(RuleEngine.evaluate(group([any]), context: inflow).accountID == subs)  // description matches
    }

    @Test("stopProcessing halts later rules")
    func stopProcessing() {
        let first = Rule(name: "First",
                         triggers: [RuleTrigger(field: .description, op: .contains, value: "shop")],
                         actions: [.setAccount(groceries)], stopProcessing: true)
        let second = Rule(name: "Second",
                          triggers: [RuleTrigger(field: .description, op: .contains, value: "shop")],
                          actions: [.setAccount(subs)])
        let outcome = RuleEngine.evaluate(group([first, second]),
                                          context: RuleContext(description: "Corner Shop"))
        #expect(outcome.accountID == groceries)  // second never ran
        #expect(outcome.stopped)
    }

    @Test("Inactive rules and groups are skipped")
    func inactive() {
        let rule = Rule(name: "Off",
                        triggers: [RuleTrigger(field: .description, op: .contains, value: "x")],
                        actions: [.setAccount(subs)], isActive: false)
        #expect(RuleEngine.evaluate(group([rule]), context: RuleContext(description: "x")).accountID == nil)

        let activeRule = Rule(name: "On",
                              triggers: [RuleTrigger(field: .description, op: .contains, value: "x")],
                              actions: [.setAccount(subs)])
        let offGroup = [RuleGroup(name: "Off", isActive: false, rules: [activeRule])]
        #expect(RuleEngine.evaluate(offGroup, context: RuleContext(description: "x")).accountID == nil)
    }

    @Test("Rule groups round-trip through Codable")
    func codable() throws {
        let groups = group([Rule(name: "R",
                                 triggers: [RuleTrigger(field: .description, op: .equals, value: "v")],
                                 actions: [.setAccount(groceries), .setNotes("n")])])
        let data = try JSONEncoder().encode(groups)
        let decoded = try JSONDecoder().decode([RuleGroup].self, from: data)
        #expect(decoded == groups)
    }
}

@Suite("Rule amount thresholds")
struct RuleAmountThresholdTests {

    private func group(_ rules: [Rule]) -> [RuleGroup] {
        [RuleGroup(name: "Default", rules: rules)]
    }

    private func fires(_ value: String, op: RuleOperator, amount: Decimal) -> Bool {
        let flagged = GncGUID.random()
        let rule = Rule(name: "Large",
                        triggers: [RuleTrigger(field: .amount, op: op, value: value)],
                        actions: [.setAccount(flagged)])
        return RuleEngine.evaluate(group([rule]),
                                   context: RuleContext(description: "x", amount: amount))
            .accountID == flagged
    }

    @Test("A grouped threshold means what it says, not its first digit")
    func groupedThreshold() {
        // `Decimal(string: "1,000")` is 1 — it parses greedily and stops at
        // the comma — so this rule used to fire on everything over a dollar
        // while reading correctly in the editor.
        #expect(!fires("1,000", op: .greaterThan, amount: Decimal(500)))
        #expect(!fires("1,000", op: .greaterThan, amount: Decimal(999)))
        #expect(fires("1,000", op: .greaterThan, amount: Decimal(1001)))
    }

    @Test("Currency symbols, European grouping and parentheses all read")
    func otherNotations() {
        #expect(fires("$1,000.50", op: .lessThan, amount: Decimal(1000)))
        #expect(!fires("$1,000.50", op: .lessThan, amount: Decimal(1001)))
        // European: dot groups, comma decides the decimal.
        #expect(fires("1.000,50", op: .greaterThan, amount: Decimal(1001)))
        // A parenthesised threshold is negative.
        #expect(fires("(500)", op: .lessThan, amount: Decimal(-600)))
        #expect(!fires("(500)", op: .lessThan, amount: Decimal(-400)))
    }

    @Test("A threshold with no number in it matches nothing")
    func unparseableThreshold() {
        #expect(!fires("", op: .greaterThan, amount: Decimal(1)))
        #expect(!fires("lots", op: .greaterThan, amount: Decimal(1)))
    }
}
