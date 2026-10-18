//
//  LiveCategorisePerfTests.swift
//  FinvestLens — FeatureUI
//
//  Auto-Categorise against a **real** book supplied via FL_PERF_FILE; skipped
//  when unset. Run as:
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test -c release --filter LiveCategorisePerfTests
//
//  A categorised book has little left to categorise, so the harness parks the
//  counter-leg of every fortieth simple bank transaction in an Imbalance
//  account first — on a copy, never saved — and asks the categoriser to put
//  them back. It prints counts, timings and a fingerprint of the plans (a
//  hash, so two runs can be compared without anything of the book on screen),
//  and checks the plans are the same on a second call and off the main actor.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LiveCategorisePerfTests {

    @Test("smartCategoryPlans cost and fingerprint")
    func categoriseCost() async throws {
        guard let perfPath else { return }

        // Work on a copy: the harness must never touch the live book.
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flperf-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let model = AppModel()
        try await model.open(at: copy)
        defer { model.close() }
        let book = try #require(model.book)

        // Uncategorise a sample: two-leg, single-currency, a bank leg and a
        // category leg.
        let imbalanceID = try #require(model.addAccount(name: "Imbalance-AUD", type: .bank))
        let imbalance = try #require(book.account(with: imbalanceID))
        var parked: [Split] = []
        var seen = 0
        for transaction in book.transactions where transaction.splits.count == 2 {
            let accounts = transaction.splits.compactMap(\.account)
            guard accounts.count == 2,
                  accounts.allSatisfy({ $0.commodity == transaction.currency }),
                  let category = transaction.splits.first(where: {
                      $0.account?.type == .expense || $0.account?.type == .income }),
                  transaction.splits.contains(where: { $0.account?.type == .bank })
            else { continue }
            seen += 1
            if seen % 40 == 0 { parked.append(category) }
        }
        model.editing(parked.compactMap { $0.transaction?.guid }, named: "Harness") {
            for split in parked { split.account = imbalance }
        }

        let clock = ContinuousClock()
        let items = model.uncategorizedItems()
        var plans: [GncGUID: AppModel.CategoryPlan] = [:]
        let mainActorTime = clock.measure { plans = model.smartCategoryPlans(for: items) }

        var again: [GncGUID: AppModel.CategoryPlan] = [:]
        _ = clock.measure { again = model.smartCategoryPlans(for: items) }
        var detached: [GncGUID: AppModel.CategoryPlan] = [:]
        let offMainTime = await clock.measure { detached = await model.smartCategoryPlansOffMain(for: items) }
        let copyTime = clock.measure { _ = model.smartCategorizerInput(for: items) }

        // The same transactions give the same plans, every time and wherever
        // the work runs.
        #expect(fingerprint(again) == fingerprint(plans))
        #expect(fingerprint(detached) == fingerprint(plans))

        print("""

        === smartCategoryPlans ===
        transactions          : \(book.transactions.count)
        parked / items        : \(parked.count) / \(items.count)
        plans                 : \(plans.count)
        main actor            : \(mainActorTime)
        off main (total)      : \(offMainTime)
        copy on the main actor: \(copyTime)
        fingerprint           : \(fingerprint(plans).prefix(16))

        """)
    }

    /// Every field a plan proposes, in a fixed order, hashed.
    private func fingerprint(_ plans: [GncGUID: AppModel.CategoryPlan]) -> String {
        var text = ""
        for plan in plans.values.sorted(by: { $0.transactionID.description < $1.transactionID.description }) {
            text += "\(plan.transactionID)|\(plan.newDescription ?? "-")|\(plan.templateDescription)|"
            text += String(format: "%.9f", plan.confidence) + "|"
            text += plan.anchorSplitIDs.map(\.description).joined(separator: ",") + "|"
            for leg in plan.legs { text += "\(leg.accountID):\(leg.value):\(leg.memo);" }
            text += "\n"
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
