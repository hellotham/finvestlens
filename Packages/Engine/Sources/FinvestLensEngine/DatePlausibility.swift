//
//  DatePlausibility.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  One definition of "a year a person could have meant", because there were
//  two and they disagreed.
//

import Foundation

/// Whether a posting date is a year anyone could have intended.
///
/// This exists for one failure mode, which is quiet by construction: a mistyped
/// year leaves a transaction perfectly well-formed. It still balances, still
/// reconciles, still exports — it simply leaves the period it belongs to. Every
/// report that bounds by date stops showing it, and no total ever looks wrong,
/// so nothing draws attention to it. A real book carried `1525-01-31` for a
/// year, entered ninety seconds after its December neighbour and ninety before
/// its February one.
///
/// Two things had a notion of an implausible year and neither could see the
/// other: the QIF importer rejected anything before **1500** (to stop `yyyy`
/// reading `26` as year 26 and stealing the two-digit pattern's turn), and the
/// register's date parser preferred a reading of **1000** or later. Neither
/// would have flagged 1525. This is now the single answer both ask.
public enum DatePlausibility {

    /// The years a book's transactions may be posted in.
    ///
    /// The floor is deliberately far above the year a two-digit slip produces
    /// (`0025`, `1525`) and far below any date a personal or small-business
    /// ledger would legitimately carry. The ceiling leaves room for genuinely
    /// forward-dated entries — a cheque written ahead, a scheduled instance
    /// materialised early — without admitting a transposed millennium.
    ///
    /// Widening this is a real decision: everything outside it is *reported*,
    /// never altered or dropped, so the cost of a tight range is a false
    /// report, and the cost of a loose one is a transaction nobody ever finds.
    public static let years = 1900...2200

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    public static func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    public static func isPlausible(_ date: Date) -> Bool {
        years.contains(year(of: date))
    }

    /// How the year reads in a report — the bare number, since a date this
    /// wrong is best shown as the thing that is wrong with it.
    public static func describe(_ date: Date) -> String {
        "in year \(year(of: date))"
    }
}
