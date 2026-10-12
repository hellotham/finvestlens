//
//  FigureGrounding.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The dispose half of "the model proposes; deterministic code disposes",
//  for prose: every number a narrator writes must be a number it was given.
//
//  This began as the review slide's validator, which read numbers the way
//  English prints them and was the only narrator that checked at all. Both
//  were found wanting on 12 October 2026, when the narrators were first run
//  on the macOS 27 model in each of the app's languages with synthetic
//  figures:
//    • the *report* narrator, unchecked, wrote in English that "Income
//      exceeds expenses by 24,000.98 AUD" for a net income of 24,032.68, and
//      in Chinese quoted two percentages it had worked out itself, one wrong;
//    • French wrote "66 611 AUD" and "8,4 %", Spanish "66.611 AUD" — true
//      figures, rejected because a space or a dot was not a thousands
//      separator here and a comma was not a decimal point;
//    • Japanese and Chinese forecasts turned "15 Aug" into "15月15日".
//  So the check is shared by all three narrators, and reads a number every
//  way its language could have meant it.
//
//  A review the same day then ran the first version of this file against
//  figures nobody had given it, and it passed most of them. Three rules came
//  out of that, and they are what the code below is organised around:
//
//    1. **A number is read with its unit.** "67%" is a percentage and has to
//       be one of the percentages given; "66.6k" is thousands and is checked
//       as 66,600. The first version tried every scaling on every number, so
//       a figure of 66,610.82 made a bare "67" true — and an invented "67%"
//       with it, which is exactly the share-of-total a model works out for
//       itself.
//    2. **A number that cannot be read is not thereby true.** "24.000,98" has
//       no English reading; the first version skipped it, so the one figure
//       this file's header records as invented passed once it was written
//       the continental way.
//    3. **Separators are tried as separators first, and as punctuation
//       second.** "66 611" is one number in French and "26 450" is two in
//       "FY 2025–26 450 AUD"; a Chinese sentence puts "，" between a balance
//       and a date. Each run is read as one number wherever it is validly
//       one and that number is a fact; otherwise it is taken apart at one
//       of its separators and each side has to be a fact on its own.
//

import Foundation

enum FigureGrounding {

    /// What follows a number, as far as it changes what the number means.
    enum Unit: Equatable {
        case none
        /// "%", "percent", "Prozent", "百分之…".
        case percent
        /// The request's currency — a code after the number or a symbol
        /// before it. An amount, so never a day, a month or a year.
        case currency
        /// "k", "thousand", "mil", "Tsd", "千": the number counts thousands.
        case thousands
        /// "m", "million", "Mio", "百万".
        case millions
        /// "万".
        case myriads
        /// "億" / "亿".
        case hundredMillions
        /// "月": a month number.
        case month
        /// "日" / "号": a day of the month.
        case day
        /// "年": a calendar year.
        case year

        /// What one of the number is worth, for the units that scale.
        var scale: Decimal? {
            switch self {
            case .thousands: 1_000
            case .millions: 1_000_000
            case .myriads: 10_000
            case .hundredMillions: 100_000_000
            default: nil
            }
        }
    }

    /// One reading of a run of digits.
    struct Token: Equatable {
        var value: Decimal
        var decimalPlaces: Int
        var hasGrouping = false
    }

    /// A run of digits and the separators inside it, as it stood in the text.
    struct Run: Equatable {
        /// Digits and the separators between them.
        var text: String
        var unit: Unit
        /// Where it stood, in characters of the normalised text — so two
        /// runs with only a 万 between them can be read as one number.
        var start = 0
        var end = 0
    }

    /// What a narrator was given, as far as numbers go.
    struct Facts {
        /// Amounts that may be quoted — as they are, rounded, or in
        /// thousands, millions, 万 or 億 *when the prose says so*.
        var figures: [Decimal] = []
        /// Percentages that may be quoted; nothing else may carry a "%".
        var percentages: [Decimal] = []
        /// Whole numbers that are not amounts: a horizon in days, how many
        /// lines a list has.
        var counts: [Int] = []
        /// The request's own words — a period label, an account name, the
        /// figure labels. Numbers in them are text to repeat, not figures.
        var quotableText: String = ""
        /// Dates the prose may name; their day, month and year are quotable.
        var dates: [Date] = []
        /// The currency the figures are in, so "2027 AUD" is read as an
        /// amount and not as a year.
        var currencyCode: String = ""
    }

    /// Whether every number in `text` is one the facts support.
    static func isGrounded(_ text: String, facts: Facts, locale: Locale = LanguageModels.personLocale) -> Bool {
        let continental = writesDecimalComma(locale)
        let figures = facts.figures.map { abs($0) }
        let percentages = facts.percentages.map { abs($0) }
        let counts = Set(facts.counts.map { Decimal(abs($0)) })

        // Numbers in the request's own words, read every way they can be,
        // each with the unit it carries there: an account called "Term
        // Deposit 4.75%" makes "4.75%" quotable, and one called "Fidelity
        // 401k" makes "401k" quotable — and neither makes a bare 4.75 or a
        // 26% out of the "26" in "FY 2025–26".
        let labelled: [(token: Token, unit: Unit)] =
            runs(in: facts.quotableText, currencyCode: facts.currencyCode).flatMap { run in
                (readings(of: run.text, continental: continental) + parts(of: run.text))
                    .map { (token: $0, unit: run.unit) }
            }

        // Calendar years are quotable only when the request's own words name
        // them: the label's years (with "FY 2024–25" expanded to 2025) plus a
        // ±1 neighbourhood for natural year-on-year prose. A blanket
        // 1900–2100 exemption once let fabricated figures like "$2,000" or
        // "2050" through ungrounded — the failure this check exists to stop.
        var namedYears: [Int] = []
        var suffixes: [Int] = []
        for (token, _) in labelled where token.decimalPlaces == 0 && !token.hasGrouping {
            let value = NSDecimalNumber(decimal: token.value).intValue
            if (1900...2100).contains(value) { namedYears.append(value) }
            else if (0...99).contains(value) { suffixes.append(value) }
        }
        // The forecast prints its dates in the Gregorian calendar, in the
        // process's own zone, so that is how they are read back.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var months: Set<Decimal> = []
        var days: Set<Decimal> = []
        for date in facts.dates {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            if let year = components.year { namedYears.append(year) }
            if let month = components.month { months.insert(Decimal(month)) }
            if let day = components.day { days.insert(Decimal(day)) }
        }
        var years: Set<Decimal> = []
        for year in namedYears {
            for delta in -1...1 { years.insert(Decimal(year + delta)) }
            for suffix in suffixes {
                let expanded = (year / 100) * 100 + suffix
                if (1900...2100).contains(expanded) { years.insert(Decimal(expanded)) }
            }
        }

        func tokenSupported(_ token: Token, _ unit: Unit) -> Bool {
            let tolerance = halfUnit(at: token.decimalPlaces)
            let whole = token.decimalPlaces == 0 && !token.hasGrouping
            // The request's own words may be repeated, unit and all.
            if labelled.contains(where: {
                $0.unit == unit && $0.token.value == token.value && $0.token.decimalPlaces == token.decimalPlaces
            }) {
                return true
            }
            let isFigure = figures.contains { abs($0 - token.value) <= tolerance }
            let isPercentage = percentages.contains { abs($0 - token.value) <= tolerance }
            switch unit {
            case .percent:
                // One of the percentages given, and nothing else: not a
                // figure in thousands (66,610.82 does not make "67%" true),
                // and not an amount with a percent sign put after it.
                return isPercentage
            case .thousands, .millions, .myriads, .hundredMillions:
                guard let scale = unit.scale else { return false }
                return figures.contains { abs($0 - token.value * scale) <= tolerance * scale }
            case .currency:
                // An amount, so not a day, a month, a year or a count.
                return isFigure
            case .month:
                // "15月" must be a month the forecast names. Where no dates
                // were given at all, it is a number like any other.
                if !facts.dates.isEmpty { return whole && months.contains(token.value) }
            case .day:
                // "15日" is a day the forecast names — or, since 日 also
                // counts days, the horizon: "今後90日間".
                if !facts.dates.isEmpty {
                    return whole && (days.contains(token.value) || counts.contains(token.value))
                }
            case .year, .none:
                break
            }
            if isFigure || isPercentage { return true }
            guard whole else { return false }
            return counts.contains(token.value) || years.contains(token.value)
                || days.contains(token.value) || months.contains(token.value)
        }

        /// `text` as one number, read each way its separators allow — or as
        /// two runs either side of one of those separators, each of them
        /// supported in turn. The unit belongs to the last number: in
        /// "3105，8月" it is the 8 that is a month.
        func runSupported(_ text: Substring, _ unit: Unit) -> Bool {
            if readings(of: String(text), continental: continental).contains(where: { tokenSupported($0, unit) }) {
                return true
            }
            for index in text.indices where !isDigit(text[index]) {
                let left = text[..<index]
                let right = text[text.index(after: index)...]
                guard !left.isEmpty, !right.isEmpty else { continue }
                if runSupported(left, .none), runSupported(right, unit) { return true }
            }
            return false
        }

        let found = runs(in: text, currencyCode: facts.currencyCode)
        var index = 0
        while index < found.count {
            // "6万6611" and "1億2000万" are one number written in two or
            // three runs; where the whole is a figure, that is what it is.
            if let (total, count) = myriadCompound(found, from: index),
               figures.contains(where: { abs($0 - total) <= halfUnit(at: 0) }) {
                index += count
                continue
            }
            let run = found[index]
            guard runSupported(Substring(run.text), run.unit) else { return false }
            index += 1
        }
        return true
    }

    /// The value of a number written across adjacent runs in ten-thousands
    /// and hundred-millions — "6万6611" is 66,611 — and how many runs it
    /// took, or `nil` if the run at `index` does not start one.
    private static func myriadCompound(_ runs: [Run], from index: Int) -> (total: Decimal, count: Int)? {
        var total = Decimal(0)
        var cursor = index
        var lastScale = Decimal.greatestFiniteMagnitude
        while cursor < runs.count {
            let run = runs[cursor]
            // Adjacent means exactly one character — the unit — in between.
            if cursor > index, run.start != runs[cursor - 1].end + 1 { break }
            guard let value = readings(of: run.text, continental: false).first?.value else { break }
            if let scale = run.unit.scale, run.unit == .myriads || run.unit == .hundredMillions,
               scale < lastScale {
                total += value * scale
                lastScale = scale
                cursor += 1
            } else {
                // The units, which close the number: fewer than ten thousand,
                // and not themselves counted in anything ("6万6611万" is not
                // a number).
                if cursor > index, run.unit.scale == nil, value < 10_000 { total += value; cursor += 1 }
                break
            }
        }
        return cursor - index >= 2 ? (total, cursor - index) : nil
    }

    /// Whether prose in this locale's language writes "8,4" for eight and
    /// four tenths. Asked of the language as well as the region: a model told
    /// to answer in German writes "90.643,5" for a reader in Zürich, whose
    /// own region would have put an apostrophe and a point there.
    static func writesDecimalComma(_ locale: Locale) -> Bool {
        if locale.decimalSeparator == "," { return true }
        guard let language = locale.language.languageCode?.identifier else { return false }
        return Locale(identifier: language).decimalSeparator == ","
    }

    // MARK: - Finding numbers

    /// Each run of digits in `text`, with the separators inside it and the
    /// unit after it.
    ///
    /// Inside a run: "." and "," always; an apostrophe or a thin, narrow or
    /// no-break space before a digit; and an ordinary space only between a
    /// group of one to three digits and a group of exactly three, which is
    /// the only place it can be a thousands separator ("66 611", never
    /// "2025 150").
    static func runs(in text: String, currencyCode: String = "") -> [Run] {
        let characters = Array(normalised(text))
        var found: [Run] = []
        var index = 0
        while index < characters.count {
            guard isDigit(characters[index]) else { index += 1; continue }
            let start = index
            var end = index            // one past the last digit taken
            var groupLength = 0        // digits since the last separator
            while index < characters.count {
                let character = characters[index]
                if isDigit(character) {
                    groupLength += 1
                    index += 1
                    end = index
                } else if character == "." || character == ",", index + 1 < characters.count,
                          isDigit(characters[index + 1]) {
                    groupLength = 0
                    index += 1
                } else if isGroupingMark(character), index + 1 < characters.count,
                          isDigit(characters[index + 1]) {
                    groupLength = 0
                    index += 1
                } else if character == " ", (1...3).contains(groupLength),
                          digitCount(characters, from: index + 1) == 3 {
                    groupLength = 0
                    index += 1
                } else {
                    break
                }
            }
            index = end
            found.append(Run(text: String(characters[start..<end]),
                             unit: unit(characters, before: start, after: end, currencyCode: currencyCode),
                             start: start, end: end))
        }
        return found
    }

    /// `run` as one number, each way it can validly be one.
    ///
    /// English always: comma groups of three, a point before the decimals.
    /// The continental reading — point groups, a decimal comma — where the
    /// language writes it. Space and apostrophe groups with either decimal
    /// mark. A run that is none of these has no reading as one number.
    static func readings(of run: String, continental: Bool) -> [Token] {
        var tokens: [Token] = []
        func add(_ token: Token?) {
            if let token, !tokens.contains(token) { tokens.append(token) }
        }
        let hasSpaceGroups = run.contains(where: { $0 == " " || isGroupingMark($0) })
        if hasSpaceGroups {
            // "66 610,82" and "66’610.82": the groups are the spaces'; one
            // other mark, at most, is the decimal point.
            let collapsed = String(run.map { $0 == " " || isGroupingMark($0) ? "_" : $0 })
            add(token(collapsed, grouping: "_", decimal: "."))
            add(token(collapsed, grouping: "_", decimal: ","))
        } else {
            add(token(run, grouping: ",", decimal: "."))
            if continental { add(token(run, grouping: ".", decimal: ",")) }
        }
        return tokens
    }

    /// The digit groups of `run` as separate whole numbers — what it is when
    /// its separators were punctuation after all.
    static func parts(of run: String) -> [Token] {
        run.split(whereSeparator: { !isDigit($0) }).compactMap { digits in
            Decimal(string: String(digits), locale: Locale(identifier: "en_US_POSIX"))
                .map { Token(value: $0, decimalPlaces: 0) }
        }
    }

    /// `run` read with one grouping mark and one decimal mark, or `nil` if it
    /// is not a number written that way: groups are of three after a first of
    /// one to three, and there is one decimal mark at most.
    private static func token(_ run: String, grouping: Character, decimal: Character) -> Token? {
        let halves = run.split(separator: decimal, omittingEmptySubsequences: false)
        guard halves.count <= 2, let wholePart = halves.first, !wholePart.isEmpty else { return nil }
        let fraction = halves.count == 2 ? String(halves[1]) : ""
        guard fraction.allSatisfy(isDigit), halves.count == 1 || !fraction.isEmpty else { return nil }
        let groups = wholePart.split(separator: grouping, omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) else { return nil }
        if groups.count > 1 {
            guard (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else {
                return nil
            }
        }
        let literal = groups.joined() + (fraction.isEmpty ? "" : "." + fraction)
        guard let value = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return Token(value: value, decimalPlaces: fraction.count, hasGrouping: groups.count > 1)
    }

    // MARK: - Units

    private static let percentWords = ["%", "percent", "per cent", "prozent", "pour cent", "por ciento",
                                       "por cento", "per cento", "パーセント"]
    private static let thousandWords = ["thousand", "tausend", "tsd", "mille", "milliers", "mila", "千"]
    private static let millionWords = ["million", "mio", "millón", "millones", "milhão", "milhões",
                                       "milione", "milioni", "百万"]

    /// The unit a number carries, from what follows it — and, for the two
    /// that are written in front, what precedes it.
    private static func unit(_ characters: [Character], before start: Int, after end: Int,
                             currencyCode: String) -> Unit {
        // Up to a dozen characters either side are enough for every unit
        // here; spaces between a number and its unit are skipped.
        var cursor = end
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\u{00A0}"
                || characters[cursor] == "\u{202F}" { cursor += 1 }
        let after = String(characters[cursor..<min(characters.count, cursor + 12)]).lowercased()
        var back = start
        while back > 0, characters[back - 1] == " " || characters[back - 1] == "\u{00A0}" { back -= 1 }
        let before = String(characters[max(0, back - 6)..<back]).lowercased()

        if percentWords.contains(where: after.hasPrefix) || before.hasSuffix("百分之") || before.hasSuffix("%") {
            return .percent
        }
        if after.hasPrefix("万") || after.hasPrefix("萬") { return .myriads }
        if after.hasPrefix("億") || after.hasPrefix("亿") { return .hundredMillions }
        if after.hasPrefix("月") { return .month }
        if after.hasPrefix("日") || after.hasPrefix("号") || after.hasPrefix("號") { return .day }
        if after.hasPrefix("年") { return .year }
        // Millions first: "millones", "milhões" and "milioni" all begin with
        // the Spanish and Portuguese word for a thousand.
        if millionWords.contains(where: after.hasPrefix) { return .millions }
        if thousandWords.contains(where: after.hasPrefix) || after == "mil" || after.hasPrefix("mil ") {
            return .thousands
        }
        // A lone "k" or "m" — "66.6k AUD", "1.2M" — but not the first letter
        // of a word ("3 months", "5 km").
        if let first = after.first, first == "k" || first == "m" {
            let next = after.dropFirst().first
            if next == nil || !(next!.isLetter) { return first == "k" ? .thousands : .millions }
        }
        let code = currencyCode.lowercased()
        if !code.isEmpty, after.hasPrefix(code) || before.hasSuffix(code) { return .currency }
        if let symbol = before.last, "$€£¥₹₩".contains(symbol) { return .currency }
        if after.hasPrefix("澳元") || after.hasPrefix("美元") || after.hasPrefix("欧元") || after.hasPrefix("円")
            || after.hasPrefix("元") || after.hasPrefix("ドル") { return .currency }
        return .none
    }

    // MARK: - Characters

    /// Full-width digits, letters and punctuation as their ASCII forms:
    /// "６６，６１１" is "66,611" and "％" is "%".
    ///
    /// Only that block (U+FF01…FF5E, which mirrors ASCII), and the
    /// ideographic space. Foundation's full-to-half-width transform does the
    /// same and then goes on to turn katakana into its half-width forms, so
    /// "パーセント" stopped being the word this file looks for after a number.
    private static func normalised(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E: folded.append(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
            case 0x3000: folded.append(" ")
            default: folded.append(scalar)
            }
        }
        return String(folded)
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Marks that group thousands and are never sentence punctuation between
    /// two digits: the apostrophe, and the thin, narrow and no-break spaces.
    private static func isGroupingMark(_ character: Character) -> Bool {
        character == "\u{00A0}" || character == "\u{202F}" || character == "\u{2009}"
            || character == "'" || character == "’"
    }

    /// How many digits start at `index`.
    private static func digitCount(_ characters: [Character], from index: Int) -> Int {
        var count = 0
        while index + count < characters.count, isDigit(characters[index + count]) { count += 1 }
        return count
    }

    /// Half of the last quoted decimal place, plus a hair for Decimal noise —
    /// "3.83" matches anything in 3.825…3.835.
    static func halfUnit(at places: Int) -> Decimal {
        var unit = Decimal(1)
        for _ in 0..<places { unit /= 10 }
        return unit / 2 + Decimal(string: "0.0001")!
    }
}
