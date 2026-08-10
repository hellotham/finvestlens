//
//  DateDisplay.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The user's date-format preference (Settings ▸ General ▸ Dates): just the
//  component order — Australian D/M/Y, US M.D.Y, or Japanese Y-M-D. The app
//  chooses how much to write out per context: `short` (numeric) in dense
//  tables, `long` (month spelled out) in labels and documents, `full` (with
//  weekday) where a single date headlines and space allows, and compact
//  partials (`monthDay`, `monthYear`) where the year or day is implied.
//  Published through the environment by ``AppearanceModifier`` so every
//  displayed date re-renders when the preference changes; non-view contexts
//  (report documents, printing, the clipboard) read ``AppDateFormat/current``.
//

import Foundation
import SwiftUI

/// Which component comes first — the regional convention. The only choice the
/// user makes; styles are picked by context.
public enum DateOrder: String, CaseIterable, Identifiable, Sendable {
    case dmy   // 16/12/2025 — Australian
    case mdy   // 12.16.2025 — United States
    case ymd   // 2025-12-16 — Japanese

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dmy: "D/M/Y — Australian"
        case .mdy: "M.D.Y — United States"
        case .ymd: "Y-M-D — Japanese"
        }
    }
}

/// The resolved date-format preference. Value type so it can sit in the
/// environment and equality-drive re-renders.
public struct AppDateFormat: Equatable, Sendable {
    public var order: DateOrder

    public init(order: DateOrder = .dmy) {
        self.order = order
    }

    // MARK: Preference storage

    public static let orderKey = "finvestlens.dateOrder"

    /// The stored preference — for contexts outside the view tree (report
    /// documents, check printing, pasteboard text). Views should read
    /// `\.appDateFormat` instead so they re-render on change.
    public static var current: AppDateFormat {
        AppDateFormat(order: UserDefaults.standard.string(forKey: orderKey)
            .flatMap(DateOrder.init(rawValue:)) ?? .dmy)
    }

    // MARK: Formatting

    private var shortPattern: String {
        switch order {
        case .dmy: "d/M/yyyy"
        case .mdy: "M.d.yyyy"
        case .ymd: "yyyy-MM-dd"
        }
    }

    /// Numeric — for dense tables and lists: 16/12/2025, 12.16.2025, 2025-12-16.
    public func short(_ date: Date) -> String {
        Self.formatted(date, pattern: shortPattern)
    }

    private var compactPattern: String {
        switch order {
        case .dmy: "d/M/yy"
        case .mdy: "M.d.yy"
        case .ymd: "yy-MM-dd"
        }
    }

    /// The same date with a two-digit year — 16/12/25 — for a register too
    /// narrow to spend four characters on the century.
    ///
    /// This is as far as the compression goes. Dropping the year entirely
    /// would fit anything, and would also make a register spanning several
    /// years unreadable at exactly the moment the running balance depends on
    /// knowing which year a row is in. Two digits is the conventional
    /// shortening; no digits is a different, worse document.
    public func compact(_ date: Date) -> String {
        Self.formatted(date, pattern: compactPattern)
    }

    /// Reads back either form — a date typed as `16/12/25` or `16/12/2025`.
    /// The register edits in place, so whatever it *shows* must be typeable.
    ///
    /// The obvious implementation — try `yyyy`, fall back to `yy` — is wrong,
    /// and wrong in the worst way for a ledger: `DateFormatter` is lenient
    /// about year width, so `d/M/yyyy` reads `16/12/25` as **16 December
    /// 0025** and reports success. The fallback never runs, no error is
    /// raised, and a transaction moves two thousand years. That became
    /// reachable the moment the register started *showing* two-digit years:
    /// open a narrow register, click into a date, press Return.
    ///
    /// So neither pattern's success is taken as proof it read the year the way
    /// the person typed it. The round trip is the proof — the pattern that
    /// reproduces the typed text is the pattern the text was typed in.
    public func parseAny(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let full = Self.formatter(pattern: shortPattern)
        let two = Self.formatter(pattern: compactPattern)

        for formatter in [full, two] {
            if let date = formatter.date(from: trimmed),
               formatter.string(from: date) == trimmed {
                return date
            }
        }
        // Nothing round-trips exactly — `06/12/25` and other zero-padded or
        // odd-width spellings land here. Prefer a reading that yields a year a
        // person could have meant over one that does not.
        if let date = full.date(from: trimmed),
           Self.gregorian.component(.year, from: date) >= 1000 {
            return date
        }
        return two.date(from: trimmed) ?? full.date(from: trimmed)
    }

    /// Parses a date typed in the short form back to a `Date` — the inverse of
    /// ``short(_:)``, for in-place register editing. `nil` when it doesn't read
    /// as a date in the chosen order.
    public func parseShort(_ string: String) -> Date? {
        Self.formatter(pattern: shortPattern)
            .date(from: string.trimmingCharacters(in: .whitespaces))
    }

    /// Month spelled out — for labels, sentences and documents:
    /// 16 December 2025, December 16, 2025, 2025 December 16.
    public func long(_ date: Date) -> String {
        let pattern = switch order {
        case .dmy: "d MMMM yyyy"
        case .mdy: "MMMM d, yyyy"
        case .ymd: "yyyy MMMM d"
        }
        return Self.formatted(date, pattern: pattern)
    }

    // MARK: Choosing a form

    /// The forms a date can take, **richest first**.
    ///
    /// The user chooses only the *order* — d/m/y, m.d.y, y-m-d. Which of these
    /// to render is the app's job, decided by the context and the room it has,
    /// so a heading with a whole line to itself can spell the month out while a
    /// register cell four characters narrower still shows a complete date
    /// instead of an ellipsis.
    public enum Form: CaseIterable, Sendable {
        /// Tuesday, 16 December 2025
        case full
        /// 16 December 2025
        case long
        /// 16/12/2025 — the dense default
        case short
        /// 16/12/25 — when four characters of century cannot be afforded
        case compact

        /// The richest form a dense, scannable table will use, however wide the
        /// window gets.
        ///
        /// Named rather than written as `.short` at each call site because it
        /// is a *decision*, and it has to be the same decision in two places
        /// that cannot see each other: the AppKit register sheet and every
        /// SwiftUI ``AdaptiveDate``. `16 December 2025` down a column of a
        /// thousand rows is harder to scan than `16/12/2025`, not easier —
        /// spelled-out months belong to headings and documents, which set a
        /// higher ceiling of their own.
        public static let table: Self = .short
    }

    public func string(_ date: Date, _ form: Form) -> String {
        switch form {
        case .full: full(date)
        case .long: long(date)
        case .short: short(date)
        case .compact: compact(date)
        }
    }

    /// The richest form that fits `width`, measured by the caller in its own
    /// font — falling back to the narrowest if even that will not fit, because
    /// a truncated date is worse than a terse one.
    ///
    /// `ceiling` is the context: a dense table asks for `.short` and never
    /// spells the month out however wide the window; a single headline date
    /// asks for `.full`. Space then chooses downward from there.
    public func fitting(_ date: Date, width: CGFloat, ceiling: Form = .full,
                        measure: (String) -> CGFloat) -> String {
        let ladder = Form.allCases.drop { $0 != ceiling }
        for form in ladder where measure(string(date, form)) <= width {
            return string(date, form)
        }
        return string(date, ladder.last ?? .compact)
    }

    /// The richest form that fits every one of `dates` — what a *column* needs,
    /// since a column whose rows disagree about their format reads as a fault
    /// rather than as a fit.
    public func fittingForm(for dates: [Date], width: CGFloat, ceiling: Form = .table,
                            measure: (String) -> CGFloat) -> Form {
        let ladder = Array(Form.allCases.drop { $0 != ceiling })
        for form in ladder where dates.allSatisfy({ measure(string($0, form)) <= width }) {
            return form
        }
        return ladder.last ?? .compact
    }

    /// Weekday and month spelled out — where one date headlines and there is
    /// room: Tuesday, 16 December 2025 …
    public func full(_ date: Date) -> String {
        let pattern = switch order {
        case .dmy: "EEEE, d MMMM yyyy"
        case .mdy: "EEEE, MMMM d, yyyy"
        case .ymd: "EEEE, yyyy MMMM d"
        }
        return Self.formatted(date, pattern: pattern)
    }

    /// A compact month-and-day (abbreviated month), ordered per the preference —
    /// for tight dashboard rows where the year is implied.
    public func monthDay(_ date: Date) -> String {
        Self.formatted(date, pattern: order == .dmy ? "d MMM" : "MMM d")
    }

    /// A month-and-year (abbreviated month), ordered per the preference — for
    /// report columns labelled by month.
    public func monthYear(_ date: Date) -> String {
        Self.formatted(date, pattern: order == .ymd ? "yyyy MMM" : "MMM yyyy")
    }

    // MARK: Formatter cache

    /// One configured `DateFormatter` per pattern. Formatters are expensive to
    /// build and (post-configuration) safe to share; the lock guards the
    /// dictionary itself.
    /// The calendar every pattern is parsed in — matched to `formatter(pattern:)`
    /// so a year read out here is the same year that was read in.
    static let gregorian = Calendar(identifier: .gregorian)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    private static func formatter(pattern: String) -> DateFormatter {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[pattern] { return hit }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern
        cache[pattern] = formatter
        return formatter
    }

    private static func formatted(_ date: Date, pattern: String) -> String {
        formatter(pattern: pattern).string(from: date)
    }
}

/// A date that writes itself out as fully as its column allows.
///
/// The SwiftUI half of the same rule the register applies in AppKit: the user
/// chose the *order*, the app chooses the *form*, and the deciding input is the
/// room actually offered. `ViewThatFits` is the framework's own spelling of
/// that ladder — it proposes the available width to each candidate in turn and
/// takes the first that does not need to shrink — so a Date column dragged
/// narrow steps 16/12/2025 → 16/12/25 instead of truncating to `16/12/20…`.
///
/// Ellipsis is the failure this replaces. A truncated date is not a shorter
/// date; it is an unreadable one, and in a register it hides the year the
/// running balance depends on.
public struct AdaptiveDate: View {
    private let date: Date
    private let ceiling: AppDateFormat.Form
    private let floor: AppDateFormat.Form

    @Environment(\.appDateFormat) private var dateFormat

    /// - Parameters:
    ///   - ceiling: the richest form this context would ever want. A table cell
    ///     asks for `.short` (numeric, dense); a heading can ask for `.full`.
    ///   - floor: how far it may compress before it stops trying. Defaults to
    ///     `.compact`; pass `.short` where a two-digit year would be wrong.
    public init(_ date: Date, ceiling: AppDateFormat.Form = .table,
                floor: AppDateFormat.Form = .compact) {
        self.date = date
        self.ceiling = ceiling
        self.floor = floor
    }

    private var ladder: [AppDateFormat.Form] {
        let all = AppDateFormat.Form.allCases
        guard let top = all.firstIndex(of: ceiling),
              let bottom = all.firstIndex(of: floor), top <= bottom
        else { return [ceiling] }
        return Array(all[top...bottom])
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(ladder, id: \.self) { form in
                Text(dateFormat.string(date, form)).lineLimit(1).fixedSize()
            }
        }
        // The last rung is what `ViewThatFits` falls back to, and it is still a
        // whole date — but VoiceOver should hear the unabbreviated one however
        // narrow the column happens to be.
        .accessibilityLabel(Text(dateFormat.long(date)))
    }
}

/// Environment plumbing (mirrors `\.appFontScale`).
private struct AppDateFormatKey: EnvironmentKey {
    static let defaultValue = AppDateFormat()
}

public extension EnvironmentValues {
    var appDateFormat: AppDateFormat {
        get { self[AppDateFormatKey.self] }
        set { self[AppDateFormatKey.self] = newValue }
    }
}
