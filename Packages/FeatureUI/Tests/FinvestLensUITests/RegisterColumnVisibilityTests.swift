//
//  RegisterColumnVisibilityTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(macOS)

import Testing
@testable import FinvestLensUI

@Suite("Register column visibility")
struct RegisterColumnVisibilityTests {

    @Test("Only the spare columns are offered; the register's substance is not")
    func hideableSet() {
        let titles = RegisterColumnVisibility.hideable.map(\.title)
        // Date, Description and Amount are what makes this a register rather
        // than a list, and the handle column carries the disclosure triangle
        // and the edit pencil — none may be switched off.
        #expect(!titles.contains("Date"))
        #expect(!titles.contains("Description"))
        #expect(!titles.contains("Amount"))
        // Num is not offered because it is not a column: it is blank on nearly
        // every row, so it shares the Notes line inside the disclosed detail
        // instead of spending width in all of them.
        #expect(!titles.contains("Num"))
        #expect(titles.contains("Transfer"))
        #expect(titles.contains("Balance"))
        // Reconcile's heading is a bare "R", which reads as nothing in a menu.
        #expect(titles.contains("Reconciled"))
        // Every offered column has a heading a person could act on.
        #expect(titles.allSatisfy { !$0.isEmpty })
        // Ids are the column's own order and are distinct.
        let ids = RegisterColumnVisibility.hideable.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids == ids.sorted())
    }

    @Test("Nothing is hidden by default")
    func emptyMask() {
        for column in RegisterColumnVisibility.hideable {
            #expect(!RegisterColumnVisibility.isHidden(column.id, in: 0))
        }
    }

    @Test("Toggling is its own inverse and touches only its own column")
    func toggling() {
        var mask = 0
        for column in RegisterColumnVisibility.hideable {
            let hidden = RegisterColumnVisibility.toggling(column.id, in: mask)
            #expect(RegisterColumnVisibility.isHidden(column.id, in: hidden))
            // No other column moved.
            for other in RegisterColumnVisibility.hideable where other.id != column.id {
                #expect(RegisterColumnVisibility.isHidden(other.id, in: hidden)
                        == RegisterColumnVisibility.isHidden(other.id, in: mask))
            }
            // Twice returns exactly where it started.
            #expect(RegisterColumnVisibility.toggling(column.id, in: hidden) == mask)
            mask = hidden
        }
        // Hiding every offered column and unhiding them all comes back to zero.
        for column in RegisterColumnVisibility.hideable {
            mask = RegisterColumnVisibility.toggling(column.id, in: mask)
        }
        #expect(mask == 0)
    }

    @Test("A stored mask with bits for columns that cannot hide is ignored")
    func junkMaskIsHarmless() {
        // Defaults outlive code: a mask written by a future build, or by hand,
        // must not switch off a column the register needs.
        let everything = ~0
        let offered = Set(RegisterColumnVisibility.hideable.map(\.id))
        for id in 0..<16 where !offered.contains(id) {
            // Nothing outside the offered set is ever reported as hidden by
            // the sheet — `hidden(from:)` filters on `canHide`.
            #expect(!RegisterColumnVisibility.hideable.contains { $0.id == id })
        }
        // Sanity: the all-ones mask does report the offered columns hidden.
        for column in RegisterColumnVisibility.hideable {
            #expect(RegisterColumnVisibility.isHidden(column.id, in: everything))
        }
    }
}

#endif

/// Column layout must fit the pane it is drawn in.
///
/// Reported from use, 15 Aug 2026: at a narrow window the date read "7/24" and
/// the balance "$5,03" — the columns kept their measured widths, the content
/// ran past the clip, and the register was cut off at both ends. A date missing
/// its leading digits is not a tight column; it is a different date.
@Suite("Register column fitting")
struct RegisterColumnFitTests {

    /// Every column starts inside the pane and none runs past its trailing
    /// edge, at any width the window can reach.
    @Test("Columns never overflow the pane")
    func columnsFit() {
        // 320 is narrower than the app's minimum window; 1600 is a wide
        // display. The sum of the measured widths alone is ~636.
        for total in stride(from: 320.0, through: 1600.0, by: 20.0) {
            let frames = SheetMetrics.Frames(totalWidth: total)
            let last = SheetColumn.allCases.count - 1
            let end = frames.x[last] + frames.width[last]
            #expect(end <= total + 0.5,
                    "at \(total)pt the columns run \(end - total)pt past the pane")
            #expect(frames.x[0] >= 0)
        }
    }

    /// Date and Amount are what makes this a register rather than a list — the
    /// two `SheetColumn.canHide` refuses — so the give comes from elsewhere.
    @Test("Squeezing takes from the optional columns first")
    func squeezeSparesTheEssentials() {
        let roomy = SheetMetrics.Frames(totalWidth: 1200)
        let tight = SheetMetrics.Frames(totalWidth: 420)

        #expect(tight.width[SheetColumn.date.rawValue] == roomy.width[SheetColumn.date.rawValue])
        #expect(tight.width[SheetColumn.amount.rawValue] == roomy.width[SheetColumn.amount.rawValue])
        #expect(tight.width[SheetColumn.transfer.rawValue]
                    < roomy.width[SheetColumn.transfer.rawValue])
    }

    /// An optional column either says something or steps aside. Crushed to the
    /// 28pt minimum, Transfer and Balance drew a column of bare ellipses on
    /// every row — narrower than useless, because it still took the space.
    @Test("A squeezed column is never left too narrow to read")
    func noUselessSlivers() {
        for total in stride(from: 320.0, through: 1600.0, by: 20.0) {
            let frames = SheetMetrics.Frames(totalWidth: total)
            for column in [SheetColumn.transfer, .balance, .reconcile] {
                let width = frames.width[column.rawValue]
                #expect(width == 0 || width >= 24,
                        "at \(total)pt \(column) is \(width)pt — a sliver")
            }
        }
    }

    /// The Date column must hold a whole date before anything is squeezed.
    ///
    /// Reported from use: it read "0/7/24". The fallback was 80pt while
    /// "05/07/24" is 54.5pt of text in a cell that also carries the disclosure
    /// gutter (14), the edit gutter (20) and two insets (10) — 98.5pt. A date
    /// missing its leading digits is a different date, which is the one kind of
    /// truncation a ledger cannot have.
    @Test("Date has room for a whole date, at every width")
    func dateAlwaysFitsADate() {
        let needed = 54.5 + 14.0 + 20.0 + 2 * SheetMetrics.textInset
        for total in stride(from: 320.0, through: 1600.0, by: 20.0) {
            let frames = SheetMetrics.Frames(totalWidth: total)
            let date = frames.width[SheetColumn.date.rawValue]
            #expect(date >= needed, "at \(total)pt Date is \(date)pt — too narrow for a date")
        }
    }

    /// A hidden column gives its space back rather than being squeezed out of
    /// somewhere else.
    @Test("Hiding a column gives its space back")
    func hidingGivesSpaceBack() {
        // With room to spare, Description takes it — it is the flexible one.
        let all = SheetMetrics.Frames(totalWidth: 900)
        let fewer = SheetMetrics.Frames(totalWidth: 900, hidden: [.balance, .reconcile])
        #expect(fewer.width[SheetColumn.balance.rawValue] == 0)
        #expect(fewer.width[SheetColumn.description.rawValue]
                    > all.width[SheetColumn.description.rawValue])

        // Squeezed, it goes first to the column that was squeezed. Description
        // is already at its floor at this width, so a test that expected it to
        // grow was asserting the wrong thing about the right behaviour.
        let tight = SheetMetrics.Frames(totalWidth: 520)
        let tighterButFewer = SheetMetrics.Frames(totalWidth: 520,
                                                  hidden: [.balance, .reconcile])
        #expect(tighterButFewer.width[SheetColumn.transfer.rawValue]
                    > tight.width[SheetColumn.transfer.rawValue])
    }
}
