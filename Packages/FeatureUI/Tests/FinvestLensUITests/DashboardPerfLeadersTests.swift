//
//  DashboardPerfLeadersTests.swift
//  FinvestLens — FeatureUI
//
//  The performance card's top/bottom-performer footer: each holding's return
//  since the beginning of the timescale, ranked, with the two groups disjoint.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensUI

@MainActor
@Suite("Dashboard performance leaders")
struct DashboardPerfLeadersTests {

    private func point(_ series: String, _ pct: Double, day: Int = 2,
                       portfolio: Bool = false) -> DashboardView.PerfPoint {
        DashboardView.PerfPoint(date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                                series: series, returnPct: pct, isPortfolio: portfolio)
    }

    @Test("Ranks by the LAST sample — the return since the start of the timescale")
    func usesFinalSample() {
        let points = [
            point("BHP", -0.50, day: 1),   // mid-window dip, superseded
            point("BHP", 0.18, day: 2),
            point("CSL", 0.02, day: 2),
        ]
        let leaders = DashboardView.rankPerfLeaders(points)
        #expect(leaders.top.map(\.series) == ["BHP", "CSL"])
        #expect(leaders.top.first?.pct == 0.18)
        #expect(leaders.bottom.isEmpty)   // ≤3 holdings: one row, nothing twice
    }

    @Test("Top three and bottom three are disjoint slices of one ordering")
    func topAndBottom() {
        let returns = [("A", 0.30), ("B", 0.20), ("C", 0.10), ("D", 0.05),
                       ("E", -0.02), ("F", -0.10), ("G", -0.25)]
        let leaders = DashboardView.rankPerfLeaders(returns.map { point($0.0, $0.1) })
        #expect(leaders.top.map(\.series) == ["A", "B", "C"])
        #expect(leaders.bottom.map(\.series) == ["E", "F", "G"])   // worst-last, reads as a ranking
        #expect(Set(leaders.top.map(\.series)).isDisjoint(with: leaders.bottom.map(\.series)))
    }

    @Test("Five holdings: three on top, the remaining two below — no overlap")
    func fiveHoldings() {
        let returns = [("A", 0.30), ("B", 0.20), ("C", 0.10), ("D", -0.05), ("E", -0.15)]
        let leaders = DashboardView.rankPerfLeaders(returns.map { point($0.0, $0.1) })
        #expect(leaders.top.map(\.series) == ["A", "B", "C"])
        #expect(leaders.bottom.map(\.series) == ["D", "E"])
    }

    @Test("The portfolio series never ranks among the holdings")
    func portfolioExcluded() {
        let points = [point("Portfolio", 0.99, portfolio: true), point("BHP", 0.10)]
        let leaders = DashboardView.rankPerfLeaders(points)
        #expect(leaders.top.map(\.series) == ["BHP"])
    }
}
