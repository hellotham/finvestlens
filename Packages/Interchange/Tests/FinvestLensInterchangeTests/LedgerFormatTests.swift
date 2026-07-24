//
//  LedgerFormatTests.swift
//  FinvestLens — Interchange
//
//  P10a exit criteria (docs/ledger-design.md §7): the manual's own examples
//  parse and reprint stably, every documented error case reports file:line,
//  and parse → write → parse is a fixed point.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Ledger journal parsing")
struct LedgerParsingTests {

    @Test("The manual's KFC transaction: dates, state, code, notes, elision")
    func kfc() {
        let result = LedgerParser.parse(text: """
        2012-03-10=2012-03-08 * (#100) KFC  ; xact note
            ; more xact note
            Expenses:Food                $20.00  ; posting #1 note
            Assets:Cash
        """)
        #expect(!result.hasErrors)
        let txn = result.journal.transactions[0]
        #expect(txn.date == utcDay(2012, 3, 10))
        #expect(txn.auxDate == utcDay(2012, 3, 8))
        #expect(txn.state == .cleared)
        #expect(txn.code == "#100")
        #expect(txn.payee == "KFC")
        #expect(txn.noteLines == ["xact note", "more xact note"])
        #expect(txn.postings[0].note == "posting #1 note")
        #expect(txn.postings[0].amount == LedgerAmount(commodity: "$", quantity: dec("20.00")))
        // Elided posting absorbs the inverse.
        #expect(txn.postings[1].amount == nil)
        #expect(txn.postings[1].resolvedAmounts ==
                [LedgerAmount(commodity: "$", quantity: dec("-20.00"))])
    }

    @Test("Multi-commodity elision copies the null posting per commodity")
    func multiCommodityElision() {
        let result = LedgerParser.parse(text: """
        2012/03/10 KFC
            Expenses:Food                $20.00
            Expenses:Tips                 $2.00
            Assets:Cash              -10.00 EUR
            Liabilities:Credit
        """)
        #expect(!result.hasErrors)
        let elided = result.journal.transactions[0].postings[3]
        #expect(Set(elided.resolvedAmounts) == [
            LedgerAmount(commodity: "$", quantity: dec("-22.00")),
            LedgerAmount(commodity: "EUR", quantity: dec("10.00")),
        ])
    }

    @Test("Costs balance: @ multiplies, @@ is the total with the amount's sign")
    func costs() {
        let perUnit = LedgerParser.parse(text: """
        2026/01/10 Broker
            Assets:Brokerage        10 AAPL @ $50.00
            Assets:Cash                     $-500.00
        """)
        #expect(!perUnit.hasErrors)

        let total = LedgerParser.parse(text: """
        2026/01/11 Broker sell
            Assets:Brokerage       -10 AAPL @@ $520.00
            Assets:Cash                      $520.00
        """)
        #expect(!total.hasErrors)

        let negativeCost = LedgerParser.parse(text: """
        2026/01/12 Bad
            A  10 AAPL @ $-50.00
            B
        """)
        #expect(negativeCost.hasErrors)
        #expect(negativeCost.diagnostics.contains { $0.message.contains("cost may not be negative") })
    }

    @Test("Balance assertions verify in file order; failures name the account")
    func assertions() {
        let passing = LedgerParser.parse(text: """
        2026/01/01 Open
            Assets:Cash              $500.00
            Equity:Opening
        2026/01/02 Spend
            Expenses:Food             $20.00
            Assets:Cash              $-20.00 = $480.00
        """)
        #expect(!passing.hasErrors)

        let failing = LedgerParser.parse(text: """
        2026/01/01 Open
            Assets:Cash              $500.00
            Equity:Opening
        2026/01/02 Spend
            Expenses:Food             $20.00
            Assets:Cash              $-20.00 = $999.00
        """, fileName: "test.ledger")
        #expect(failing.hasErrors)
        let diagnostic = failing.diagnostics.first { $0.severity == .error }
        #expect(diagnostic?.file == "test.ledger")
        #expect(diagnostic?.line == 6)
        #expect(diagnostic?.message.contains("Assets:Cash") == true)
    }

    @Test("A balance assignment materialises the running-balance delta")
    func assignment() {
        let result = LedgerParser.parse(text: """
        2026/01/01 Open
            Assets:Cash              $520.00
            Equity:Opening
        2026/01/05 Adjustment
            Assets:Cash                       = $500.00
            Equity:Adjustments
        """)
        #expect(!result.hasErrors)
        let adjustment = result.journal.transactions[1]
        #expect(adjustment.postings[0].isAssignment)
        #expect(adjustment.postings[0].amount ==
                LedgerAmount(commodity: "$", quantity: dec("-20.00")))
        #expect(adjustment.postings[1].resolvedAmounts ==
                [LedgerAmount(commodity: "$", quantity: dec("20.00"))])
    }

    @Test("Virtual postings: (unbalanced) skip the check, [balanced] must sum to zero")
    func virtuals() {
        let budget = LedgerParser.parse(text: """
        2012/03/10 * KFC
            Expenses:Food                $20.00
            Assets:Cash
            [Budget:Food]               $-20.00
            [Equity:Budgets]             $20.00
            (Notes:OnTheSly)            $999.00
        """)
        #expect(!budget.hasErrors)
        let postings = budget.journal.transactions[0].postings
        #expect(postings[2].virtualKind == .balanced)
        #expect(postings[4].virtualKind == .unbalanced)

        let broken = LedgerParser.parse(text: """
        2012/03/10 KFC
            Expenses:Food                $20.00
            Assets:Cash
            [Budget:Food]               $-20.00
        """)
        #expect(broken.hasErrors)
        #expect(broken.journal.transactions.isEmpty)
        #expect(broken.diagnostics.contains { $0.message.contains("balanced-virtual") })
    }

    @Test("Tags, metadata, typed metadata, and posting date overrides")
    func notesAndMetadata() {
        let result = LedgerParser.parse(text: """
        2026/02/01 Rent  ; :home:monthly:
            ; guid: a1b2c3
            ; AuxDate:: [2012/02/30]
            Expenses:Rent            $800.00
              ; [2026/02/03=2026/02/05]
            Assets:Cash
        """)
        #expect(!result.hasErrors)
        let txn = result.journal.transactions[0]
        #expect(txn.tags == ["home", "monthly"])
        #expect(txn.metadata.contains { $0.key == "guid" && $0.value == "a1b2c3" && !$0.isTyped })
        #expect(txn.metadata.contains { $0.key == "AuxDate" && $0.isTyped })
        #expect(txn.postings[0].dateOverride == utcDay(2026, 2, 3))
        #expect(txn.postings[0].auxDateOverride == utcDay(2026, 2, 5))
    }

    @Test("Directives: year inference, alias, apply account, apply tag, bucket")
    func directives() {
        let result = LedgerParser.parse(text: """
        year 2004
        alias Checking=Assets:Credit Union:Joint Checking Account
        bucket Assets:Checking
        apply account Personal
        apply tag Trip: NYC
        4/09 Grocery
            Expenses:Food             $30.00
        end apply tag
        end apply account
        12/01 Direct
            Checking                 $100.00
            Equity:Opening
        """)
        #expect(!result.hasErrors, "\(result.diagnostics)")
        let grocery = result.journal.transactions[0]
        #expect(grocery.date == utcDay(2004, 4, 9))
        #expect(grocery.postings[0].account == "Personal:Expenses:Food")
        #expect(grocery.metadata.contains { $0.key == "Trip" && $0.value == "NYC" })
        // Bucket absorbed the imbalance (the account prefix applies to the
        // written posting, not the bucket).
        #expect(grocery.postings[1].isSynthesized)
        #expect(grocery.postings[1].account == "Assets:Checking")
        #expect(grocery.postings[1].resolvedAmounts ==
                [LedgerAmount(commodity: "$", quantity: dec("-30.00"))])

        let direct = result.journal.transactions[1]
        #expect(direct.postings[0].account == "Assets:Credit Union:Joint Checking Account")
    }

    @Test("P price lines, with time of day and quoted symbols")
    func priceLines() {
        let result = LedgerParser.parse(text: """
        P 2004/06/21 02:17:58 TWCUX $27.76
        P 2026/01/05 "BRK.B" 480.10 USD
        """)
        #expect(!result.hasErrors)
        #expect(result.journal.prices.count == 2)
        #expect(result.journal.prices[0].symbol == "TWCUX")
        #expect(result.journal.prices[0].price ==
                LedgerAmount(commodity: "$", quantity: dec("27.76")))
        #expect(result.journal.prices[1].symbol == "BRK.B")
        #expect(result.journal.prices[1].date == utcDay(2026, 1, 5))
    }

    @Test("Includes resolve through the hook; missing files are errors")
    func includes() {
        let library = [
            "opening.ledger": """
            2026/01/01 Opening
                Assets:Cash    $100.00
                Equity:Opening
            """,
        ]
        let result = LedgerParser.parse(text: """
        include opening.ledger
        include missing.ledger
        """, includes: { library[$0] })
        #expect(result.journal.transactions.count == 1)
        #expect(result.diagnostics.contains {
            $0.severity == .error && $0.message.contains("missing.ledger")
        })
    }

    @Test("Decimal comma: the option line and the lone-comma inference")
    func decimalComma() {
        let option = LedgerParser.parse(text: """
        --decimal-comma
        2026/01/05 Cafe
            Expenses:Coffee          10,5 EUR
            Assets:Cash             -10,5 EUR
        """)
        #expect(!option.hasErrors)
        #expect(option.journal.transactions[0].postings[0].amount?.quantity == dec("10.5"))

        // Without the option a non-3-digit trailing group still reads as a
        // decimal comma (format ref §9), and the style latches per commodity.
        let inferred = LedgerParser.parse(text: """
        2026/01/05 Cafe
            Expenses:Coffee          1.234,56 EUR
            Assets:Cash             -1.234,56 EUR
        """)
        #expect(!inferred.hasErrors)
        #expect(inferred.journal.transactions[0].postings[0].amount?.quantity == dec("1234.56"))
        #expect(inferred.journal.styles.style(for: "EUR").decimalComma)
        #expect(inferred.journal.styles.style(for: "EUR").thousands)
    }

    @Test("Periodic and automated entries are captured raw, never applied")
    func rawEntries() {
        let result = LedgerParser.parse(text: """
        ~ Monthly
            Expenses:Rent               $500.00
            Assets

        = /^Income/
            (Liabilities:Tithe Owed)     -0.1

        2026/01/01 Pay
            Assets:Cash     $100.00
            Income:Salary
        """)
        #expect(result.journal.periodicEntries.count == 1)
        #expect(result.journal.automatedEntries.count == 1)
        #expect(result.journal.transactions.count == 1)
        // Automated entries warn (parsed, not applied) — no postings added.
        #expect(result.journal.transactions[0].postings.count == 2)
        #expect(result.diagnostics.contains {
            $0.severity == .warning && $0.message.contains("not applied")
        })
    }

    @Test("Error cases report file:line and skip only the offending entry")
    func errorRecovery() {
        let result = LedgerParser.parse(text: """
        2026/01/01 Unbalanced
            Expenses:Food    $20.00
            Assets:Cash      $-19.00
        2026/01/02 Fine
            Expenses:Food    $5.00
            Assets:Cash
        2026/13/40 Bad date
            A  $1.00
            B
        """, fileName: "bad.ledger")
        #expect(result.hasErrors)
        #expect(result.journal.transactions.count == 1)
        #expect(result.journal.transactions[0].payee == "Fine")
        #expect(result.diagnostics.contains {
            $0.line == 1 && $0.message.contains("does not balance")
        })
        #expect(result.diagnostics.contains {
            $0.line == 7 && $0.message.contains("date")
        })

        let doubleElided = LedgerParser.parse(text: """
        2026/01/01 Two blanks
            Expenses:Food    $20.00
            Assets:Cash
            Assets:Wallet
        """)
        #expect(doubleElided.hasErrors)
        #expect(doubleElided.diagnostics.contains { $0.message.contains("only one posting") })
    }

    @Test("Amount styles are learned from observed amounts")
    func styleLearning() {
        let result = LedgerParser.parse(text: """
        2026/01/01 Style
            Expenses:One         $1,519.95
            Expenses:Two         20.00 AUD
            Assets:Cash          $-1,519.95
            Assets:Bank         -20.00 AUD
        """)
        #expect(!result.hasErrors)
        let dollar = result.journal.styles.style(for: "$")
        #expect(dollar.isPrefix && !dollar.spaced && dollar.thousands && dollar.precision == 2)
        let aud = result.journal.styles.style(for: "AUD")
        #expect(!aud.isPrefix && aud.spaced && aud.precision == 2)
    }
}

@Suite("Ledger journal writing")
struct LedgerWritingTests {

    @Test("Canonical output for a small transaction")
    func canonicalShape() {
        let result = LedgerParser.parse(text: """
        2012-03-10=2012-03-08 * (#100) KFC  ; note
            Expenses:Food                $20.00
            Assets:Cash
        """)
        let text = LedgerWriter.write(result.journal)
        // Amounts start two spaces after the 34-character account cell.
        #expect(text == """
        2012/03/10=2012/03/08 * (#100) KFC
            ; note
            Expenses:Food                       $20.00
            Assets:Cash

        """)
    }

    @Test("Parse → write → parse is a fixed point on a rich journal")
    func fixedPoint() {
        let source = """
        commodity AUD
            format 1,000.00 AUD

        P 2026/01/05 BHP 42.10 AUD

        ~ Monthly
            Expenses:Rent    800.00 AUD
            Assets

        2026/01/01 * (42) Opening  ; :setup:
            ; guid: deadbeef
            Assets:Cash              1,000.00 AUD
            Equity:Opening

        2026/01/10 ! Broker
            Assets:Brokerage         10 BHP @@ 421.00 AUD
            Assets:Cash               -421.00 AUD  ; settlement
            [Budget:Investing]        -421.00 AUD
            [Equity:Budgets]           421.00 AUD
        """
        let first = LedgerParser.parse(text: source)
        #expect(!first.hasErrors, "\(first.diagnostics)")
        let onceWritten = LedgerWriter.write(first.journal)
        let second = LedgerParser.parse(text: onceWritten)
        #expect(!second.hasErrors, "\(second.diagnostics)")
        let twiceWritten = LedgerWriter.write(second.journal)
        #expect(onceWritten == twiceWritten)

        // And the round-tripped journal means the same thing.
        #expect(second.journal.transactions.count == 2)
        #expect(second.journal.transactions[1].postings[0].cost?.kind == .total)
        #expect(second.journal.prices.count == 1)
        #expect(second.journal.periodicEntries.count == 1)
    }
}
