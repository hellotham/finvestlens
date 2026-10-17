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
        /// "k", "thousand", "mil", "Tsd", "T€", "千": the number counts thousands.
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
        /// Of `figures`, the balances at a moment — a closing balance, a net
        /// worth — which a word of change beside them would make the size of
        /// a change (FigureAttribution.swift). Empty: nothing is held to it.
        var levels: [Decimal] = []
        /// Of `figures`, the ones that are the size of a change and may be
        /// said as one: "rose by 1,351".
        var changes: [Decimal] = []
        /// The sizes of the changes that go up — a rise, money in, a gain —
        /// and of those that go down, so a change said the other way can be
        /// told (FigureAttribution.swift). Empty: not held to it.
        var rises: [Decimal] = []
        var falls: [Decimal] = []
    }

    /// Whether `text` states one of `percentages` — as a percentage, in any
    /// of the forms a percentage is read in, rounded or not.
    static func quotesPercentage(_ text: String, anyOf percentages: [Decimal],
                                 locale: Locale = LanguageModels.personLocale) -> Bool {
        let continental = writesDecimalComma(locale)
        let wanted = percentages.map { abs($0) }
        return runs(in: text).contains { run in
            run.unit == .percent && readings(of: run.text, continental: continental).contains { token in
                wanted.contains { agrees($0, with: token.value, places: token.decimalPlaces) }
            }
        }
    }

    /// Whether `written`, a number given to `places` decimals and counting
    /// `scale` each, is `fact` as someone would write it at that precision:
    /// rounded to it, or cut off at it.
    ///
    /// Cut off, as well as rounded, because that is how figures are
    /// shortened in practice and it invents nothing: 31,150.40 is "31.2k"
    /// rounded and "31.1k" with the rest dropped, and 66,610.82 is "66,611"
    /// and "66,610". Holding the model to rounding alone declined twelve of
    /// forty-eight drafts of one slide on 12 October 2026 for a "31.1k",
    /// with every other number in them right. What it still does not admit
    /// is a figure *above* what rounding gives — "12.49k" for 12,480.55 —
    /// or one that is simply somewhere near.
    static func agrees(_ fact: Decimal, with written: Decimal, places: Int, scale: Decimal = 1) -> Bool {
        let difference = fact - written * scale
        if abs(difference) <= halfUnit(at: places) * scale { return true }
        var lastPlace = Decimal(1)
        for _ in 0..<places { lastPlace /= 10 }
        return difference >= 0 && difference < lastPlace * scale
    }

    /// A number as the check read it: where its digits stand in the
    /// normalised text, the unit it was read with, and the readings that made
    /// it a fact — none, where nothing did.
    ///
    /// One number may be a run taken apart at a separator ("9420，8月" is an
    /// amount and a month) or several runs read as one ("6万6611"); each
    /// comes out as the number it was decided to be, so that what a sentence
    /// says *about* a number is read off the same numbers the check
    /// accepted (FigureAttribution.swift).
    struct Resolved {
        /// The first and one-past-the-last character of its digits.
        var start: Int
        var end: Int
        var unit: Unit
        /// Each value it was read as, counted in `scale`.
        var readings: [Token]
        var scale: Decimal
        var supported: Bool
    }

    /// Whether every number in `text` is one the facts support. Stops at the
    /// first that is not: nothing after it can make the text true, and taking
    /// a long run of numbers apart is the costly part of the check.
    static func isGrounded(_ text: String, facts: Facts, locale: Locale = LanguageModels.personLocale) -> Bool {
        resolve(text, facts: facts, locale: locale, stoppingAtUnsupported: true).allSatisfy(\.supported)
    }

    /// Every number in `text`, in order, as the check decides to read it —
    /// up to and including the first the facts do not support, when
    /// `stoppingAtUnsupported`.
    static func resolve(_ text: String, facts: Facts,
                        locale: Locale = LanguageModels.personLocale,
                        stoppingAtUnsupported: Bool = false) -> [Resolved] {
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
            let whole = token.decimalPlaces == 0 && !token.hasGrouping
            // The request's own words may be repeated, unit and all.
            if labelled.contains(where: {
                $0.unit == unit && $0.token.value == token.value && $0.token.decimalPlaces == token.decimalPlaces
            }) {
                return true
            }
            let isFigure = figures.contains { agrees($0, with: token.value, places: token.decimalPlaces) }
            let isPercentage = percentages.contains { agrees($0, with: token.value, places: token.decimalPlaces) }
            switch unit {
            case .percent:
                // One of the percentages given, and nothing else: not a
                // figure in thousands (66,610.82 does not make "67%" true),
                // and not an amount with a percent sign put after it.
                return isPercentage
            case .thousands, .millions, .myriads, .hundredMillions:
                guard let scale = unit.scale else { return false }
                return figures.contains {
                    agrees($0, with: token.value, places: token.decimalPlaces, scale: scale)
                }
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
            case .year:
                // "2025–26年度": the label's own years, the second written
                // short, as the label writes it. Read as the year 26, four of
                // the Chinese report notes in the 17 October survey were
                // declined for repeating their own period.
                if whole, suffixes.contains(where: { Decimal($0) == token.value }) { return true }
            case .none:
                break
            }
            if isFigure || isPercentage { return true }
            guard whole else { return false }
            return counts.contains(token.value) || years.contains(token.value)
                || days.contains(token.value) || months.contains(token.value)
        }

        /// The characters `lower..<upper` of a run as one number, read each
        /// way its separators allow — or as two numbers either side of one of
        /// those separators, each of them supported in turn. The unit belongs
        /// to the last number: in "3105，8月" it is the 8 that is a month.
        /// `nil` when no reading is supported; otherwise the numbers it was
        /// decided to be.
        ///
        /// Each stretch of the run is decided once (`memo`): taken apart
        /// afresh at every separator, a run of twenty numbers none of which
        /// is a fact took 25 seconds to refuse (review of 17 October 2026);
        /// remembered, the same refusal is a few hundred stretches.
        struct Stretch: Hashable { var lower: Int; var upper: Int }
        func decompose(_ characters: [Character], _ lower: Int, _ upper: Int, of run: Run,
                       memo: inout [Stretch: [Resolved]?]) -> [Resolved]? {
            let stretch = Stretch(lower: lower, upper: upper)
            if let decided = memo[stretch] { return decided }
            let unit = upper == characters.count ? run.unit : .none
            var decided: [Resolved]?
            let supported = readings(of: String(characters[lower..<upper]), continental: continental)
                .filter { tokenSupported($0, unit) }
            if !supported.isEmpty {
                decided = [Resolved(start: run.start + lower, end: run.start + upper, unit: unit,
                                    readings: supported, scale: unit.scale ?? 1, supported: true)]
            } else {
                for split in stride(from: lower + 1, to: upper - 1, by: 1) where !isDigit(characters[split]) {
                    if let first = decompose(characters, lower, split, of: run, memo: &memo),
                       let second = decompose(characters, split + 1, upper, of: run, memo: &memo) {
                        decided = first + second
                        break
                    }
                }
            }
            memo.updateValue(decided, forKey: stretch)
            return decided
        }

        let found = runs(in: text, currencyCode: facts.currencyCode)
        var resolved: [Resolved] = []
        var index = 0
        while index < found.count {
            // "6万6611" and "1億2000万" are one number written in two or
            // three runs; where the whole is a figure, that is what it is.
            if let (total, count) = myriadCompound(found, from: index),
               figures.contains(where: { abs($0 - total) <= halfUnit(at: 0) }) {
                let last = found[index + count - 1]
                resolved.append(Resolved(start: found[index].start, end: last.end, unit: last.unit,
                                         readings: [Token(value: total, decimalPlaces: 0)], scale: 1,
                                         supported: true))
                index += count
                continue
            }
            let run = found[index]
            let characters = Array(run.text)
            var memo: [Stretch: [Resolved]?] = [:]
            if let parts = decompose(characters, 0, characters.count, of: run, memo: &memo) {
                resolved += parts
            } else {
                resolved.append(Resolved(start: run.start, end: run.end, unit: run.unit, readings: [],
                                         scale: run.unit.scale ?? 1, supported: false))
                if stoppingAtUnsupported { return resolved }
            }
            index += 1
        }
        return resolved
    }

    /// Where the unit after a number ends, from `end`, the character after its
    /// last digit: the scale word ("k", "mil", "Tsd.", "Millionen", "万"),
    /// then the currency ("AUD", "A$", "ドル", "T$", "TAUD", "de AUD"), each
    /// with the spaces before it.
    ///
    /// Built from the vocabulary ``unit(_:before:after:currencyCode:)``
    /// reads — the scale words, the spaces, the German thousands — so that
    /// what one calls a unit the other steps over. Where it did not, the
    /// words after "0,38 Millionen AUD" began "millionen", and every check
    /// that reads what follows a number missed it (review of 17 October
    /// 2026).
    static func tail(after end: Int, in characters: [Character], currencyCode: String) -> Int {
        func skipSpaces(_ index: Int) -> Int {
            var index = index
            while index < characters.count, isUnitSpace(characters[index]) { index += 1 }
            return index
        }
        func isCJK(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { $0.value >= 0x3000 }
        }
        func matches(_ word: String, at index: Int, wordEnding: Bool) -> Int? {
            let length = word.count
            guard index + length <= characters.count,
                  String(characters[index..<(index + length)]).lowercased() == word.lowercased() else { return nil }
            // A word ends where a letter of its own script does not go on:
            // "AUDに対し" is AUD and then Japanese.
            if wordEnding, index + length < characters.count, characters[index + length].isLetter,
               !isCJK(characters[index + length]) { return nil }
            return index + length
        }
        /// The currency at `index`, and where it ends: German thousands
        /// ("T$", "TEUR", "TAUD"), the code, a dollar written with its country
        /// ("A$"), a symbol, or a CJK currency word.
        func currency(at index: Int) -> Int? {
            let code = currencyCode.uppercased()
            if index < characters.count, characters[index] == "T", code != "TOP" {
                let rest = index + 1
                if rest < characters.count, germanThousandsSymbols.contains(characters[rest]) { return rest + 1 }
                for word in ["EUR"] + (code.isEmpty ? [] : [code]) {
                    if let next = matches(word, at: rest, wordEnding: true) { return next }
                }
            }
            if !code.isEmpty, let next = matches(code, at: index, wordEnding: true) { return next }
            for word in dollarForms {
                if let next = matches(word, at: index, wordEnding: false) { return next }
            }
            if index < characters.count, currencySymbols.contains(characters[index]) { return index + 1 }
            for word in currencyWords {
                if let next = matches(word, at: index, wordEnding: false) { return next }
            }
            return nil
        }

        var cursor = skipSpaces(end)
        // The scale: a word ("thousand", "mil", "Mio."), a lone "k" or "m",
        // or a CJK unit character. A long word goes on to its inflection —
        // "Millionen", "millions", "thousands" — as ``unit`` reads it by its
        // beginning; "mil", "mio" and "tsd" are whole words or abbreviations.
        for word in scaleWordsAfter {
            let cjk = word.unicodeScalars.allSatisfy { $0.value >= 0x3000 }
            let inflects = !cjk && word.count >= 5
            guard var next = matches(word, at: cursor, wordEnding: !cjk && !inflects) else { continue }
            if inflects {
                while next < characters.count, characters[next].isLetter, !isCJK(characters[next]) { next += 1 }
            }
            cursor = next
            if cursor < characters.count, characters[cursor] == "." { cursor += 1 }
            // "millones de AUD", "milhões de AUD", "millions d'AUD": the
            // currency after the preposition is part of the unit.
            let preposition = skipSpaces(cursor)
            for word in ["de", "d'", "d’"] {
                guard let afterWord = matches(word, at: preposition, wordEnding: word == "de") else { continue }
                if let end = currency(at: word == "de" ? skipSpaces(afterWord) : afterWord) { return end }
            }
            break
        }
        return currency(at: skipSpaces(cursor)) ?? cursor
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

    static let percentWords = ["%", "percent", "per cent", "prozent", "pour cent", "por ciento",
                               "por cento", "per cento", "パーセント"]
    static let thousandWords = ["thousand", "tausend", "tsd", "mille", "milliers", "mila", "千"]
    static let millionWords = ["million", "mio", "millón", "millones", "milhão", "milhões",
                               "milione", "milioni", "百万"]
    static let myriadWords = ["万", "萬"]
    static let hundredMillionWords = ["億", "亿"]
    /// Every word that scales the number before it, longest first, as
    /// ``tail(after:in:currencyCode:)`` steps over them: the words above, and
    /// the "mil", "k" and "m" ``unit(_:before:after:currencyCode:)`` reads
    /// on their own.
    static let scaleWordsAfter = (millionWords + thousandWords + ["mil", "k", "m"]
                                  + myriadWords + hundredMillionWords).sorted { $0.count > $1.count }
    /// The currency symbols read before a number.
    static let currencySymbols = "$€£¥₹₩"
    /// The symbols German accounts write after a "T" for thousands of the
    /// currency: "66,6 T€", "66.61 T$". Not every symbol: no one writes
    /// "T₹", and pooled with ``currencySymbols`` it made "2024 T₹" an amount
    /// in thousands (review of 17 October 2026).
    static let germanThousandsSymbols = "$€£¥"
    /// A dollar written with its country, as German and French put it after
    /// the number and English before it: "9.420 A$", "A$ 9,420".
    static let dollarForms = ["au$", "a$", "us$"]
    /// Currencies written as a word after the number in Chinese and Japanese.
    static let currencyWords = ["澳元", "美元", "欧元", "円", "元", "ドル"]

    /// The spaces that can stand between a number and its unit: the
    /// ordinary one, and the no-break, narrow and thin spaces French and
    /// German typesetting put there.
    static func isUnitSpace(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}" || character == "\u{202F}" || character == "\u{2009}"
    }

    /// The unit a number carries, from what follows it — and, for the two
    /// that are written in front, what precedes it.
    private static func unit(_ characters: [Character], before start: Int, after end: Int,
                             currencyCode: String) -> Unit {
        // Up to a dozen characters either side are enough for every unit
        // here; spaces between a number and its unit are skipped.
        var cursor = end
        while cursor < characters.count, isUnitSpace(characters[cursor]) { cursor += 1 }
        let after = String(characters[cursor..<min(characters.count, cursor + 12)]).lowercased()
        var back = start
        while back > 0, isUnitSpace(characters[back - 1]) { back -= 1 }
        let before = String(characters[max(0, back - 6)..<back]).lowercased()

        if percentWords.contains(where: after.hasPrefix) || before.hasSuffix("百分之") || before.hasSuffix("%") {
            return .percent
        }
        if myriadWords.contains(where: after.hasPrefix) { return .myriads }
        if hundredMillionWords.contains(where: after.hasPrefix) { return .hundredMillions }
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
        // of a word ("3 months", "5 km"). A Chinese or Japanese character
        // after it starts the next word, as ``tail(after:in:currencyCode:)``
        // reads it: "31.1k増加" is 31,100 and then "increase" — read as no
        // unit, a true Japanese headline was declined (17 October survey).
        if let first = after.first, first == "k" || first == "m" {
            let next = after.dropFirst().first
            if next == nil || !(next!.isLetter) || next!.unicodeScalars.allSatisfy({ $0.value >= 0x3000 }) {
                return first == "k" ? .thousands : .millions
            }
        }
        let code = currencyCode.lowercased()
        // German accounts count thousands with a capital T in front of the
        // currency: "66,6 T€", "250 TEUR", "66.61 T$". Asked for thousands
        // "as k", the 27 model wrote a German reader "66.61 T$" in two drafts
        // of eight (12 October 2026) and both were declined as figures
        // nobody had listed. Read from the text as written, capitals and
        // all, so that no word beginning with a t is taken for it — and not
        // in a book kept in paʻanga, whose own symbol is T$.
        if code != "top", cursor < characters.count, characters[cursor] == "T" {
            let rest = String(characters[(cursor + 1)..<min(characters.count, cursor + 5)])
            if let symbol = rest.first, germanThousandsSymbols.contains(symbol) { return .thousands }
            if rest.hasPrefix("EUR") || (!code.isEmpty && rest.hasPrefix(code.uppercased())) { return .thousands }
        }
        if !code.isEmpty, after.hasPrefix(code) || before.hasSuffix(code) { return .currency }
        if let symbol = before.last, currencySymbols.contains(symbol) { return .currency }
        if currencyWords.contains(where: after.hasPrefix) { return .currency }
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
    ///
    /// Not private: the attribution checks (FigureAttribution.swift) read
    /// the words around a run, and a run's position counts characters of
    /// this text, not of the original.
    static func normalised(_ text: String) -> String {
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
