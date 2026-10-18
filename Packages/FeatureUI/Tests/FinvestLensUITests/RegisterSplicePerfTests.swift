//
//  RegisterSplicePerfTests.swift
//  FinvestLens — FeatureUI
//
//  What the iPad register's per-keystroke splice costs at the size of the
//  whole-book journal (R10b): 46k transactions in Journal style is ~150k
//  rows. Synthetic rows, no book. Skipped unless FL_PERF_SPLICE is set:
//
//      FL_PERF_SPLICE=1 swift test -c release --filter RegisterSplicePerfTests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@Suite("Register splice — cost at journal size")
struct RegisterSplicePerfTests {

    private func heading(_ txn: GncGUID, _ index: Int) -> RegisterTableRow {
        RegisterTableRow(id: .txn(txn), selected: false, editable: false, kind: .main(
            RegisterMainRowData(
                id: txn, isHeadingOnly: false, reconcile: "n", hasDocument: false, drafting: false,
                handle: .hidden, date: Date(timeIntervalSince1970: Double(index) * 3_600),
                description: "Transaction number \(index) at a shop", transferIsCombo: true,
                transferAccountID: nil, transferName: "Expenses:Groceries:Supermarket",
                transferStatic: "", amount: Decimal(index), amountEditText: nil,
                imbalance: 0, runningBalance: Decimal(index * 2))))
    }

    private func detail(_ txn: GncGUID, _ text: String) -> RegisterTableRow {
        RegisterTableRow(id: .notes(txn), selected: false, editable: false,
                         kind: .detail(RegisterDetailRowData(field: .notes, text: text)))
    }

    @Test("One keystroke's splice into the whole-book journal")
    func spliceCost() {
        guard ProcessInfo.processInfo.environment["FL_PERF_SPLICE"] != nil else { return }
        let count = 50_000
        var transactions: [GncGUID] = []
        var rows: [RegisterTableRow] = []
        rows.reserveCapacity(count * 3)
        for index in 0..<count {
            let txn = GncGUID.random()
            transactions.append(txn)
            rows.append(heading(txn, index))
            rows.append(detail(txn, "Memo line for \(index)"))
            rows.append(detail(txn, "Another line for \(index)"))
        }
        let target = transactions[count / 2]
        let fresh = [heading(target, -1), detail(target, "edited"), detail(target, "edited too")]

        let clock = ContinuousClock()
        func median(_ body: () -> Void) -> Duration {
            var times: [Duration] = []
            for _ in 0..<20 { times.append(clock.measure(body)) }
            return times.sorted()[times.count / 2]
        }

        // Finding the block: a map built once, against walking every row.
        var blocks = RegisterBlocks(rows)
        let mapBuild = median { blocks = RegisterBlocks(rows) }
        let block = try! #require(blocks.block(of: target))

        // The splice while the table still holds the last pass's rows (a
        // copy of the array is forced), and with nothing else holding them.
        var current = rows
        var shown = current
        let held = median {
            shown = current
            current.replaceSubrange(block, with: fresh)
        }
        var alone = rows
        let unshared = median { alone.replaceSubrange(block, with: fresh) }
        // The wrapper the old tests pin, which builds the map itself.
        var wrapped = rows
        let wrapper = median { wrapped = wrapped.replacingBlock(of: target, with: fresh) ?? wrapped }

        print("""

        === register splice, \(rows.count) rows ===
        block map, built once      : \(mapBuild)
        splice, last rows held     : \(held)
        splice, rows not shared    : \(unshared)
        replacingBlock (map + copy): \(wrapper)

        """)
        #expect(current.count == rows.count && alone.count == rows.count && shown.count == rows.count)
    }
}
