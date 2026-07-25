//
//  PeriodExpression.swift
//  FinvestLens — CLI
//
//  Ledger's smart dates and period expressions
//  (docs/ledger-cli-reference.md §4): `[INTERVAL] [from|since SPEC]
//  [to|until SPEC]`, or a bare/`in` SPEC meaning that whole span. Note that
//  ledger's `-e/--end` is EXCLUSIVE; the pipeline absorbs the difference so
//  the user sees ledger's convention.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum PeriodInterval: String, Sendable, CaseIterable {
    case daily, weekly, biweekly, monthly, bimonthly, quarterly, yearly

    var component: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly, .biweekly: .weekOfYear
        case .monthly, .bimonthly: .month
        case .quarterly: .month
        case .yearly: .year
        }
    }

    var step: Int {
        switch self {
        case .daily, .weekly, .monthly, .yearly: 1
        case .biweekly, .bimonthly: 2
        case .quarterly: 3
        }
    }
}

/// A resolved period: an optional interval plus optional bounds. `end` is
/// ledger-exclusive.
public struct ResolvedPeriod: Sendable {
    public var interval: PeriodInterval?
    public var begin: Date?
    public var end: Date?

    public init(interval: PeriodInterval? = nil, begin: Date? = nil, end: Date? = nil) {
        self.interval = interval
        self.begin = begin
        self.end = end
    }
}

public enum PeriodExpression {

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    static let monthNames = ["january", "february", "march", "april", "may", "june",
                             "july", "august", "september", "october", "november", "december"]

    /// Parses a full period expression ("monthly from 2026/01 until oct").
    public static func parse(_ text: String, today: Date) -> ResolvedPeriod {
        var period = ResolvedPeriod()
        let words = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        var index = 0
        var pendingSpec: [String] = []
        var target: WritableKeyPath<ResolvedPeriod, Date?>?

        func flushSpec() {
            guard !pendingSpec.isEmpty else { return }
            let span = self.span(of: pendingSpec, today: today)
            if let target {
                // `from SPEC` starts at the span's start; `to/until SPEC`
                // ends BEFORE it — ledger's ends are exclusive, so
                // "to 2026/04" means everything before April.
                period[keyPath: target] = span?.start
            } else if let span {
                period.begin = span.start
                period.end = span.end
            }
            pendingSpec = []
        }

        while index < words.count {
            let word = words[index]
            index += 1
            switch word {
            case "every":
                // `every N units` / `every unit`
                var count = 1
                if index < words.count, let number = Int(words[index]) { count = number; index += 1 }
                guard index < words.count else { break }
                let unit = words[index]; index += 1
                period.interval = interval(unit: unit, count: count)
            case "daily", "weekly", "biweekly", "monthly", "bimonthly", "quarterly", "yearly":
                period.interval = PeriodInterval(rawValue: word)
            case "from", "since":
                flushSpec(); target = \ResolvedPeriod.begin
            case "to", "until":
                flushSpec(); target = \ResolvedPeriod.end
            case "in":
                flushSpec(); target = nil
            default:
                pendingSpec.append(word)
            }
        }
        flushSpec()
        return period
    }

    static func interval(unit: String, count: Int) -> PeriodInterval? {
        switch unit {
        case "day", "days": count == 1 ? .daily : nil
        case "week", "weeks": count == 2 ? .biweekly : (count == 1 ? .weekly : nil)
        case "month", "months": count == 2 ? .bimonthly : (count == 3 ? .quarterly : (count == 1 ? .monthly : nil))
        case "quarter", "quarters": .quarterly
        case "year", "years": .yearly
        default: nil
        }
    }

    /// A smart date used as a bound: the START of the named span.
    public static func date(_ text: String, today: Date) -> Date? {
        span(of: text.lowercased().split(separator: " ").map(String.init), today: today)?.start
    }

    /// The half-open span a spec names (`2026` → that year; `oct` → October;
    /// `last month`; `3 weeks ago`; `2026/07/04` → that day).
    public static func span(of words: [String], today: Date) -> (start: Date, end: Date)? {
        guard !words.isEmpty else { return nil }
        let calendar = utc
        let joined = words.joined(separator: " ")

        // Explicit dates first: 2026, 2026/07, 2026/07/04 (also - and .).
        if let explicit = explicitSpan(joined, calendar: calendar) { return explicit }

        func dayStart(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        func spanOf(_ component: Calendar.Component, containing date: Date) -> (Date, Date)? {
            guard let interval = calendar.dateInterval(of: component, for: date) else { return nil }
            return (interval.start, interval.end)
        }

        switch joined {
        case "today": return (dayStart(today), calendar.date(byAdding: .day, value: 1, to: dayStart(today))!)
        case "tomorrow":
            let start = calendar.date(byAdding: .day, value: 1, to: dayStart(today))!
            return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        case "yesterday", "yday":
            let start = calendar.date(byAdding: .day, value: -1, to: dayStart(today))!
            return (start, dayStart(today))
        default: break
        }

        // `this|last|next PERIOD`
        if words.count == 2, ["this", "last", "next"].contains(words[0]) {
            let offset = words[0] == "last" ? -1 : (words[0] == "next" ? 1 : 0)
            let component: Calendar.Component?
            switch words[1] {
            case "day": component = .day
            case "week": component = .weekOfYear
            case "month": component = .month
            case "quarter": component = .quarter
            case "year": component = .year
            default: component = nil
            }
            if let component {
                let unit: Calendar.Component = component == .quarter ? .month : component
                let step = component == .quarter ? 3 * offset : offset
                let anchor = calendar.date(byAdding: unit, value: step, to: today) ?? today
                if component == .quarter {
                    return quarterSpan(containing: anchor, calendar: calendar)
                }
                return spanOf(component, containing: anchor)
            }
            // `last august` — the most recent past instance of that month.
            if let month = monthIndex(words[1]) {
                let year = calendar.component(.year, from: today)
                let currentMonth = calendar.component(.month, from: today)
                var target = year
                if words[0] == "last", month >= currentMonth { target -= 1 }
                if words[0] == "next", month <= currentMonth { target += 1 }
                return monthSpan(year: target, month: month, calendar: calendar)
            }
        }

        // `N units ago|hence`
        if words.count == 3, let count = Int(words[0]),
           ["ago", "hence"].contains(words[2]) {
            let sign = words[2] == "ago" ? -1 : 1
            let component: Calendar.Component?
            switch words[1] {
            case "day", "days": component = .day
            case "week", "weeks": component = .weekOfYear
            case "month", "months": component = .month
            case "quarter", "quarters": component = .month
            case "year", "years": component = .year
            default: component = nil
            }
            if let component {
                let step = words[1].hasPrefix("quarter") ? count * 3 * sign : count * sign
                let anchor = calendar.date(byAdding: component, value: step, to: today) ?? today
                return (dayStart(anchor), calendar.date(byAdding: .day, value: 1, to: dayStart(anchor))!)
            }
        }

        // A bare month name → that month of the current year.
        if words.count == 1, let month = monthIndex(words[0]) {
            return monthSpan(year: calendar.component(.year, from: today),
                             month: month, calendar: calendar)
        }
        return nil
    }

    static func explicitSpan(_ text: String, calendar: Calendar) -> (Date, Date)? {
        let normalized = text.replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: ".", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        switch parts.count {
        case 1:
            guard parts[0].count == 4, let year = Int(parts[0]) else { return nil }
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            return (start, calendar.date(byAdding: .year, value: 1, to: start)!)
        case 2:
            guard let year = Int(parts[0]), let month = Int(parts[1]),
                  parts[0].count == 4, (1...12).contains(month) else { return nil }
            return monthSpan(year: year, month: month, calendar: calendar)
        case 3:
            guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  let start = calendar.date(from: DateComponents(year: year, month: month, day: day))
            else { return nil }
            return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        default: return nil
        }
    }

    static func monthSpan(year: Int, month: Int, calendar: Calendar) -> (Date, Date) {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    static func quarterSpan(containing date: Date, calendar: Calendar) -> (Date, Date) {
        let month = calendar.component(.month, from: date)
        let firstMonth = ((month - 1) / 3) * 3 + 1
        let start = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: date), month: firstMonth, day: 1))!
        return (start, calendar.date(byAdding: .month, value: 3, to: start)!)
    }

    static func monthIndex(_ word: String) -> Int? {
        if let exact = monthNames.firstIndex(of: word) { return exact + 1 }
        guard word.count >= 3 else { return nil }
        let prefix = String(word.prefix(3))
        return monthNames.firstIndex { $0.hasPrefix(prefix) }.map { $0 + 1 }
    }

    /// The half-open buckets an interval produces across `[start, end)`.
    public static func buckets(interval: PeriodInterval, from start: Date, to end: Date)
        -> [(start: Date, end: Date)] {
        let calendar = utc
        var result: [(Date, Date)] = []
        var cursor = alignedStart(interval: interval, date: start, calendar: calendar)
        var guardCount = 0
        while cursor < end, guardCount < 10_000 {
            guardCount += 1
            let next = calendar.date(byAdding: interval.component,
                                     value: interval.step, to: cursor) ?? end
            result.append((cursor, min(next, end)))
            cursor = next
        }
        return result
    }

    /// Intervals align to natural period starts (ledger's rule).
    static func alignedStart(interval: PeriodInterval, date: Date, calendar: Calendar) -> Date {
        switch interval {
        case .daily: calendar.startOfDay(for: date)
        case .weekly, .biweekly:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .monthly, .bimonthly:
            calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        case .quarterly: quarterSpan(containing: date, calendar: calendar).0
        case .yearly:
            calendar.date(from: calendar.dateComponents([.year], from: date)) ?? date
        }
    }
}
