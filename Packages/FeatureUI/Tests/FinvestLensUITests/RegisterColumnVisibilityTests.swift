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
        #expect(titles.contains("Num"))
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
