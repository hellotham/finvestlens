//
//  AppModel+Reconciliation.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes
import FinvestLensReports

// Phase I6 of the Investments hub (docs/investments-design.md §8.3, §8.4): the
// join between what a provider says the issuer declared and what the book
// records, plus the outlier check over stored prices.
//
// This is the layer where the two halves finally meet — the sidecar's declared
// dividends (I5) against the book's own income, and both against the holding
// periods (I1). Nothing here corrects anything: every finding is a discrepancy
// to look at, and the person decides.

@MainActor
extension AppModel {

    /// Everything I6 can say about one security, memoised on the book revision
    /// and the sidecar's.
    ///
    /// Keyed on both because it depends on both: a fresh dividend list must
    /// re-run the comparison even though the book has not moved, and a
    /// newly-entered income transaction must re-run it even though the sidecar
    /// has not.
    public func reconciliation(for commodity: Commodity) -> SecurityReconciliation? {
        guard let detail = securityDetail(for: commodity) else { return nil }
        let key = "recon:\(commodity.namespace)|\(commodity.mnemonic):\(fundamentalsRevision)"
        return cachedReport(key) { [self] in
            let cached = fundamentals(for: commodity)

            // Units held on a date, read from the book's own movements. Built
            // once as a running balance rather than summing the whole history
            // per query — a ten-year dividend list would otherwise walk every
            // movement ten times over.
            let movements = detail.events
                .filter { $0.units != 0 }
                .map { (date: $0.date, units: $0.units) }
                .sorted { $0.date < $1.date }
            func unitsOn(_ date: Date) -> Decimal {
                var balance = Decimal(0)
                for movement in movements where movement.date <= date {
                    balance += movement.units
                }
                return balance
            }

            return SecurityReconciliation(
                dividends: FinancialReports.reconcileDividends(
                    declared: (cached?.dividends?.value ?? []).map {
                        DeclaredPayment(date: $0.date, perUnit: $0.amount)
                    },
                    events: detail.events,
                    holdingPeriods: detail.holdingPeriods,
                    unitsOn: unitsOn),
                splits: FinancialReports.reconcileSplits(
                    declared: (cached?.splits?.value ?? []).compactMap { split in
                        // `ratio` is optional — a zero denominator has none —
                        // so a nonsense split is dropped rather than dividing
                        // by it.
                        split.ratio.map { DeclaredCapitalChange(date: split.date, ratio: $0) }
                    },
                    unitsOn: unitsOn,
                    holdingPeriods: detail.holdingPeriods),
                // The outlier check needs no provider at all — it compares the
                // book's prices with each other — so it works on a security
                // nothing has ever fetched company data for.
                outliers: FinancialReports.priceOutliers(detail.prices))
        }
    }

    /// Securities whose reconciliation has something to say, for the overview's
    /// worklist.
    ///
    /// Only over securities with declared data cached or enough price history
    /// to judge: running the full comparison across ninety securities on every
    /// visit to the hub would cost more than the page is worth, and would
    /// report nothing for the eighty that have never been fetched.
    public func reconciliationSummary() -> (securities: [Commodity], findings: Int) {
        var securities: [Commodity] = []
        var findings = 0
        for commodity in pricableSecurities {
            guard let result = reconciliation(for: commodity), !result.isClean else { continue }
            securities.append(commodity)
            findings += result.count
        }
        return (securities, findings)
    }
}
