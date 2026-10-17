//
//  FigureAttribution.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  A number can be one of the facts and still be said of the wrong thing.
//  The number check (`FigureGrounding.isGrounded`) asks only whether each
//  number is one the narrator was given, and the surveys of 12 and 17 October
//  2026 found narrations that pass it and are wrong all the same — each here
//  in the model's own words:
//
//    • a balance given as the size of a change: of the headlines written for
//      a balance that rises from 8,069 to 9,420, four said it would end
//      higher *by* 9,420 ("supera el saldo inicial en 9420 AUD", "è
//      superiore di 9420 rispetto al saldo iniziale"); a bridge slide had
//      the total "superou o início do período em 381.200 AUD";
//    • a sign the figures do not have: a German headline gave a balance
//      whose lowest point is 2,480 "einen negativen Saldo";
//    • a comparison its own two figures contradict: Portuguese drafts put
//      expenses of 66.6k "acima do valor inicial de 381,2 mil AUD", and all
//      four Japanese drafts of one slide had expenses above income
//      ("収入90,643.5 AUDに対し支出66,610.82 AUDが上回った").
//
//  These are checks of words, as `ReviewStoryValidator.contradictsAListedChange`
//  is, and are kept as narrow: each reads a construction the model was seen
//  to write, in the app's eight languages, and declines a draft — it never
//  repairs one. They read the numbers the number check read, resolved the same
//  way against the same facts (`FigureGrounding.resolve`), so the two cannot
//  disagree about which numbers a sentence holds. They are the backstop, not
//  the remedy: the prompts give each figure's direction and relations in
//  words, which is what stops most of these being written (see
//  docs/intelligence-prompts.md). What each check leaves alone is said
//  beside it.
//
//  A review of 17 October 2026 ran each check against sentences built to
//  break it, and the words were tightened where they matched too much or too
//  little: a negation is read in the language of the words it negates and
//  only as a word ("未来" is "the next…", not "not yet"), "by 1,351 to 9,420"
//  is a change and its end and not a range, a minus sign on a figure is read,
//  and a line break in a Windows file ends a sentence.
//

import Foundation

extension FigureGrounding.Facts {

    // MARK: - What each figure is

    /// Files a narrator's figures by what each is (`FigureRole`): the levels
    /// a word of change must not be put beside, the changes it may, and which
    /// way each change goes. One definition for the narrators that know what
    /// their figures are, so a role means the same to the checks wherever it
    /// is given.
    ///
    /// A figure that is one listed figure less another (`FigureRelation`) is
    /// a change too, going the way its sign says — a net surplus is income
    /// less expenses — unless it is a balance. A balance that is one balance
    /// less another (net worth: assets less liabilities) is filed as a
    /// difference with no direction, and so is the balance taken from it:
    /// "net worth is 200,000 less than assets" is as true as "liabilities are
    /// 200,000", and neither is a rise or a fall.
    mutating func attribute(_ figures: [(String, Decimal)], roles: [String: FigureRole],
                            relations: [String: FigureRelation] = [:]) {
        for (label, amount) in figures {
            let role = roles[label]
            attribute(amount, as: role)
            guard let relation = relations[label] else { continue }
            switch role {
            case .balance?, .openingBalance?:
                changes.append(amount)
                if let taken = figures.first(where: { $0.0 == relation.subtrahend })?.1 { changes.append(taken) }
            case nil:
                changes.append(amount)
                signed(amount)
            case .change?, .inflow?, .outflow?, .gain?, .loss?:
                break
            }
        }
    }

    /// Files one figure by its role; a figure with none is filed as nothing.
    mutating func attribute(_ amount: Decimal, as role: FigureRole?) {
        switch role {
        case .balance?, .openingBalance?: levels.append(amount)
        case .change?: changes.append(amount); signed(amount)
        case .inflow?, .gain?: changes.append(amount); rises.append(abs(amount))
        case .outflow?, .loss?: changes.append(amount); falls.append(abs(amount))
        case nil: break
        }
    }

    /// A change going the way its sign says; one of nothing goes neither way.
    private mutating func signed(_ amount: Decimal) {
        if amount > 0 { rises.append(amount) } else if amount < 0 { falls.append(abs(amount)) }
    }
}

extension FigureGrounding {

    // MARK: - Amounts in their places

    /// An amount the number check accepted, where it stands, and the words
    /// either side of it within its sentence.
    struct PlacedAmount {
        var readings: [Token]
        var scale: Decimal
        /// The first character of its digits, in the normalised text.
        var start: Int
        /// One past its unit and currency: where the sentence goes on.
        var tailEnd: Int
        /// The first character of its sentence.
        var sentenceStart: Int
        /// From the start of its sentence up to it, lowercased.
        var before: String
        /// From the end of its unit to the end of its sentence, lowercased.
        var after: String
        /// Written with a minus sign: "-480 AUD", "A$ −480".
        var writtenNegative: Bool

        /// The facts it can be — as written, rounded or cut off — as
        /// magnitudes.
        func agrees(with facts: [Decimal]) -> [Decimal] {
            facts.map { abs($0) }.filter { fact in
                readings.contains {
                    FigureGrounding.agrees(fact, with: $0.value, places: $0.decimalPlaces, scale: scale)
                }
            }
        }
    }

    /// A text's amounts in their places, read once for every check.
    struct Placement {
        /// The normalised text, lowercased.
        var characters: [Character]
        var amounts: [PlacedAmount]
    }

    /// How a text is read: the languages its words are read in, and the
    /// book's currency code, lowercased.
    private struct Reading {
        var languages: [String]
        var code: String

        init(_ facts: Facts, locale: Locale) {
            languages = FigureGrounding.languagesRead(for: locale)
            code = facts.currencyCode.lowercased()
        }

        /// What may stand between a word and the number after it: a
        /// currency, and the spaces either side.
        var currencyBeforeNumber: String { #"\s*"# + FigureGrounding.currencyAlternation(code) + #"?\s*$"# }
    }

    /// The amounts in `text` that the number check accepted against `facts`,
    /// in order, each read as the check read it — a run taken apart at a
    /// separator, or "6万6611" taken whole — with the lowercased text they sit
    /// in.
    static func placedAmounts(in text: String, facts: Facts, locale: Locale) -> Placement {
        let original = Array(normalised(text))
        let lowered = lowercasedInPlace(original)
        let code = facts.currencyCode.lowercased()
        let amounts = resolve(text, facts: facts, locale: locale).compactMap { number -> PlacedAmount? in
            guard number.supported else { return nil }
            switch number.unit {
            case .none, .currency, .thousands, .millions, .myriads, .hundredMillions: break
            case .percent, .month, .day, .year: return nil
            }
            var sentenceStart = number.start
            while sentenceStart > 0, !isSentenceBreak(lowered, at: sentenceStart - 1) { sentenceStart -= 1 }
            var sentenceEnd = number.end
            while sentenceEnd < lowered.count, !isSentenceBreak(lowered, at: sentenceEnd) { sentenceEnd += 1 }
            let tailEnd = min(tail(after: number.end, in: original, currencyCode: facts.currencyCode), sentenceEnd)
            let before = String(lowered[sentenceStart..<number.start])
            return PlacedAmount(readings: number.readings, scale: number.scale,
                                start: number.start, tailEnd: tailEnd,
                                sentenceStart: sentenceStart,
                                before: before,
                                after: String(lowered[tailEnd..<sentenceEnd]),
                                writtenNegative: isWrittenNegative(before, code: code))
        }
        return Placement(characters: lowered, amounts: amounts)
    }

    /// Whether the words before a number end in a minus sign — before a
    /// currency or after it — and not in the hyphen of a range ("8069-9420").
    private static func isWrittenNegative(_ before: String, code: String) -> Bool {
        let currency = currencyAlternation(code)
        let pattern = #"(?<![\d])[-−]\s*"# + currency + #"?\s*$|"# + currency + #"\s*[-−]\s*$"#
        return before.range(of: pattern, options: .regularExpression) != nil
    }

    /// Each character lowercased where that leaves it one character, so a
    /// number's position in the text is its position here too.
    private static func lowercasedInPlace(_ characters: [Character]) -> [Character] {
        characters.map { character in
            let lowered = character.lowercased()
            return lowered.count == 1 ? Character(lowered) : character
        }
    }

    /// What ends a sentence: a full stop before a space or the end — not the
    /// point inside "66.6", after an abbreviation ("66,6 Tsd. AUD", "ca."),
    /// or after a month in a date ("21. Aug.", "21 ago. 2026") — a question
    /// or exclamation mark, a semicolon, a line break of any kind ("\r\n" is
    /// one character, and not "\n"), and the survey's "‖" between a headline
    /// and its insight. Read from lowercased text.
    private static func isSentenceBreak(_ characters: [Character], at index: Int) -> Bool {
        let character = characters[index]
        if character.isNewline || "!?;。！？；‖".contains(character) { return true }
        guard character == ".", index + 1 == characters.count || characters[index + 1].isWhitespace else {
            return false
        }
        guard index + 1 < characters.count else { return true }
        // The word the point ends, and the one after it.
        var start = index
        while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber { start -= 1 }
        let word = String(characters[start..<index])
        if abbreviations.contains(word) { return false }
        var next = index + 1
        while next < characters.count, characters[next].isWhitespace { next += 1 }
        var end = next
        while end < characters.count, characters[end].isLetter { end += 1 }
        let following = String(characters[next..<end])
        // A month's short name, only where it is a month: after a day or
        // before a number. "Out", "set" and "ago" are Portuguese, Italian
        // and Spanish months and English words, and "…go out. The balance…"
        // is two sentences.
        if monthAbbreviations.contains(word) {
            var back = start
            while back > 0, characters[back - 1].isWhitespace || characters[back - 1] == "." { back -= 1 }
            var day = back
            while day > 0, characters[day - 1].isNumber { day -= 1 }
            let afterDay = (1...2).contains(back - day)
            let beforeNumber = next < characters.count && characters[next].isNumber
            if afterDay || beforeNumber { return false }
        }
        let isDay = (1...2).contains(word.count) && word.allSatisfy(\.isNumber)
        return !(isDay && months.contains(where: following.hasPrefix))
    }

    /// Words a point shortens rather than ends, wherever they stand: units
    /// and Latin abbreviations.
    private static let abbreviations: Set<String> = [
        "tsd", "mio", "mrd", "bzw", "ca", "vs", "etc", "approx",
    ]

    /// Months' short names, in the forms the narrators use; a point after
    /// one ends nothing only in a date.
    private static let monthAbbreviations: Set<String> = [
        "jan", "feb", "mär", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "okt", "oct", "nov", "dez", "dec",
        "janv", "févr", "fév", "avr", "juil", "déc", "ene", "abr", "ago", "dic", "gen", "mag", "giu", "lug",
        "ott", "set", "out", "fev", "mai",
    ]

    /// The beginnings of month names, lowercased, for "21. Aug.".
    private static let months = [
        "jan", "feb", "mär", "mar", "apr", "mai", "may", "jun", "jul", "aug", "sep", "okt", "oct", "nov",
        "dez", "dec",
    ]

    /// The languages whose words are read: the person's, and English, which
    /// the model sometimes answers in whatever it was asked.
    static func languagesRead(for locale: Locale) -> [String] {
        let code = locale.language.languageCode?.identifier ?? "en"
        return code == "en" ? ["en"] : [code, "en"]
    }

    /// A currency where a number may carry one in front of it — a symbol,
    /// "A$", "AU$", "US$", or the book's own code — as one regex alternative.
    /// The symbols are ``currencySymbols`` and the dollars ``dollarForms``,
    /// the sets the number check reads.
    static func currencyAlternation(_ code: String) -> String {
        var alternatives = ["[" + NSRegularExpression.escapedPattern(for: currencySymbols) + "]"]
            + dollarForms.map { NSRegularExpression.escapedPattern(for: $0) }
        if !code.isEmpty { alternatives.append(NSRegularExpression.escapedPattern(for: code.lowercased())) }
        return "(?:" + alternatives.joined(separator: "|") + ")"
    }

    // MARK: - Every check at once

    /// Whether `text` says one of the facts' numbers of the wrong thing: a
    /// level as the size of a change, a change the other way from the one it
    /// quotes, or a comparison its figures contradict. The three checks the
    /// narrators share, reading the text's numbers once between them.
    static func misattributes(_ text: String, facts: Facts,
                              locale: Locale = LanguageModels.personLocale) -> Bool {
        let placement = placedAmounts(in: text, facts: facts, locale: locale)
        let reading = Reading(facts, locale: locale)
        return givesALevelAsAChange(placement, facts: facts, reading)
            || saysAChangeTheWrongWay(placement, facts: facts, reading)
            || contradictsAComparison(placement, facts: facts, reading)
    }

    // MARK: - Words beside a number

    /// Whether a word in `before` stands right before the number, a currency
    /// aside, or one in `after` right after its unit — in any language read.
    private static func isSaid(_ amount: PlacedAmount, before: [String: [String]], after: [String: [String]],
                               _ reading: Reading) -> Bool {
        reading.languages.contains { language in
            (before[language] ?? []).contains {
                amount.before.range(of: "(?:" + $0 + ")" + reading.currencyBeforeNumber,
                                    options: .regularExpression) != nil
            } || (after[language] ?? []).contains {
                amount.after.range(of: #"^\s*(?:"# + $0 + ")", options: .regularExpression) != nil
            }
        }
    }

    private static func isSaidAsAChange(_ amount: PlacedAmount, _ reading: Reading) -> Bool {
        isSaid(amount, before: changeWordsBefore, after: changeWordsAfter, reading)
    }

    /// Whether the number opens a range — "de 8069 a 9420", "von 9.420 auf
    /// 6.105", "8069から9420" — and so is where something starts, not by how
    /// much it moves. The other end has to be an amount, the next one in the
    /// sentence: "en 9420 AUD a 15 de agosto" is a date after a figure, not
    /// a range. And not after a word that can only mean "by": in "falls by
    /// 1,351 to 9,420", "sinkt um 1.351 auf 9.420" and "下降1351至9420" the
    /// number is the change and what follows is where it ends. French "de"
    /// is both "by" and "from", and is left a range.
    private static func opensARange(_ index: Int, in placement: Placement, facts: Facts,
                                    _ reading: Reading) -> Bool {
        let amount = placement.amounts[index]
        let pattern = #"^\s*(?:to|auf|bis|à|a|al|hasta|fino\s+a|para|até|に|へ|まで|から|至|到)\s*"#
            + currencyAlternation(reading.code) + #"?\s*\d"#
        guard amount.after.range(of: pattern, options: .regularExpression) != nil,
              index + 1 < placement.amounts.count else { return false }
        let other = placement.amounts[index + 1]
        guard other.sentenceStart == amount.sentenceStart, !other.agrees(with: facts.figures).isEmpty else {
            return false
        }
        return !isSaid(amount, before: byWords, after: [:], reading)
    }

    /// The words before a number that can only mean "by how much".
    private static let byWords: [String: [String]] = [
        "en": [#"\bby"#],
        "de": [#"\bum"#],
        "es": [#"\ben"#],
        "it": [#"\bdi"#],
        "pt": [#"\bem"#],
        "zh": [#"(?:增长|增加|上升|提高|上涨|下降|减少|降低|下跌|下滑|回落)了?"#],
    ]

    // MARK: - A level given as the size of a change

    /// Whether `text` gives one of `facts.levels` — a balance at a moment —
    /// as the size of a change: "higher by 9,420" of a balance that ends at
    /// 9,420 and rises by 1,351.
    ///
    /// A number is said as a change when a word of change stands right
    /// beside it: a preposition of difference after a word of rising,
    /// falling or exceeding ("rise by", "um", "augmenter de", "supera … en",
    /// "superiore di", "superou … em"), a noun of change with its "of" ("an
    /// increase of", "una caída de"), a verb with the number as its object
    /// ("caerá 3315 AUD", "增长1351"), or a comparative after it ("1,351
    /// higher", "1351の増加"). Such a number has to be one of `facts.changes`;
    /// one that can only be a level declines the text.
    ///
    /// Left alone: a number reached *to* ("aumenta a 9420", "增长至9420",
    /// "9420に増加"); a range ("cai de 9420 para 6105", "von 9.420 auf
    /// 6.105"); a level after a preposition that also means "of" or "at",
    /// with no word of change before it ("un mínimo proyectado en 2480", "su
    /// punto más bajo en 3105"); and "dépasse … de", where French cannot tell
    /// "by" from "of". A narrator that names no levels is not checked.
    static func givesALevelAsAChange(_ text: String, facts: Facts,
                                     locale: Locale = LanguageModels.personLocale) -> Bool {
        givesALevelAsAChange(placedAmounts(in: text, facts: facts, locale: locale), facts: facts,
                             Reading(facts, locale: locale))
    }

    private static func givesALevelAsAChange(_ placement: Placement, facts: Facts, _ reading: Reading) -> Bool {
        guard !facts.levels.isEmpty else { return false }
        return placement.amounts.indices.contains { index in
            let amount = placement.amounts[index]
            guard isSaidAsAChange(amount, reading),
                  !opensARange(index, in: placement, facts: facts, reading) else { return false }
            return amount.agrees(with: facts.changes).isEmpty && !amount.agrees(with: facts.levels).isEmpty
        }
    }

    /// What stands right before a number said as the size of a change, by
    /// language — as the model wrote it in the October surveys, or as its
    /// language says the same. Each ends the text before the number, a
    /// currency aside. Chinese puts its verb here too: "增长1351". A noun of
    /// change may have two words between it and its preposition: "une
    /// réduction des dépenses de". The union of the three lists below: the
    /// words that say no direction, and those that say up or down.
    private static let changeWordsBefore: [String: [String]] =
        neutralChangeWords.merging(risingWordsBefore, uniquingKeysWith: +)
            .merging(fallingWordsBefore, uniquingKeysWith: +)

    /// Words of change that say how much but not which way: "by", "um",
    /// "superiore di", "supera … en", "a variation of". In Spanish and
    /// Portuguese, "más bajo en" is "lower by" after a figure and "lowest
    /// at" after the noun it is the lowest of ("su punto más bajo en 3105"),
    /// and only the first is a change; and the words between "supera" and
    /// its "en" are its object, not a second clause ("supera al inicial y se
    /// sitúa en 9420" sets a level, 17 October review).
    private static let neutralChangeWords: [String: [String]] = [
        "en": [#"\bby"#, #"\b(?:change|swing)\s+of"#],
        "de": [#"\bum"#, #"\b(?:veränderung|änderung|differenz)(?:\s+\p{L}+){0,2}\s+(?:von|um)"#],
        "fr": [#"\b(?:plus\s+élevée?|plus\s+bas(?:se)?|supérieure?|inférieure?)(?:\s+\p{L}+)?\s+de"#,
               #"\bvariation(?:\s+\p{L}+){0,2}\s+de"#],
        "es": [#"\b(?:mayor|menor|superior|inferior)\s+en"#,
               superlativeExcluded(["el", "la", "lo", "su", "punto", "nivel", "valor", "saldo", "momento", "registro", "mínimo"])
                   + #"\bmás\s+(?:alt|baj)[oa]\s+en"#,
               #"\b(?:supera|superará|superó|supere|superar|excede|excederá|excedió|exceda)\b"#
                   + #"(?:(?!\b(?:y|e|que|pero|aunque|mientras)\b)[^\d.;:!?,]){0,40}?\s+en"#,
               #"\bvariación(?:\s+\p{L}+){0,2}\s+de"#],
        "it": [#"\b(?:superiore|inferiore)\s+di"#, #"\bvariazione(?:\s+\p{L}+){0,2}\s+di"#],
        "pt": [#"\b(?:maior|menor|superior|inferior)\s+em"#,
               superlativeExcluded(["o", "a", "seu", "sua", "ponto", "nível", "valor", "saldo", "patamar", "mínimo"])
                   + #"\bmais\s+(?:alt|baix)[oa]\s+em"#,
               #"\b(?:supera|superará|superou|supere|superar|excede|excederá|excedeu)\b"#
                   + #"(?:(?!\b(?:e|que|mas|enquanto|embora)\b)[^\d.;:!?,]){0,40}?\s+em"#,
               #"\bvariação(?:\s+\p{L}+){0,2}\s+de"#],
        "zh": [#"(?:多出|高出)了?"#],
    ]

    /// Lookbehinds that refuse a comparative right after one of `words` —
    /// where it is a superlative, "the lowest", not "lower by".
    private static func superlativeExcluded(_ words: [String]) -> String {
        words.map { "(?<!" + $0 + #"\s)"# }.joined()
    }

    /// Spanish and Portuguese verbs of rising and falling, in the forms the
    /// model writes them; each is read before "en"/"em" ("aumenta en") and
    /// with the number as its object ("caerá 3315 AUD"), and the infinitive
    /// only before its preposition.
    private static let spanishRising = "aumenta|aumentará|aumentó|crece|crecerá|creció|sube|subirá|subió"
    private static let spanishFalling = "disminuye|disminuirá|disminuyó|baja|bajará|bajó|cae|caerá|cayó|desciende|descenderá|descendió"
    private static let portugueseRising = "aumenta|aumentará|aumentou|cresce|crescerá|cresceu|sobe|subirá|subiu"
    private static let portugueseFalling = "diminui|diminuirá|diminuiu|cai|cairá|caiu|recua|recuará|recuou"

    /// Words of change that say it went up.
    private static let risingWordsBefore: [String: [String]] = [
        "en": [#"\b(?:increase|rise|gain|growth|jump|climb|improvement)\s+of"#, #"\bup"#, #"\bup\s+by"#,
               #"\b(?:rise|rises|rose|risen|rising|increase|increases|increased|increasing|grow|grows|grew|grown|growing|climb|climbs|climbed|climbing|gain|gains|gained|gaining|jump|jumps|jumped|jumping|improve|improves|improved|improving)\s+by"#],
        "de": [#"\b(?:anstieg|zuwachs|wachstum|plus|zunahme|steigerung)(?:\s+\p{L}+){0,2}\s+(?:von|um)"#,
               #"\b(?:steigt|stieg|gestiegen|steigen|wird\s+steigen|wächst|wuchs|gewachsen|wachsen|erhöht|erhöhte|zunehmen|nimmt\s+zu)\s+um"#],
        "fr": [#"\b(?:augmente|augmentent|augmentera|augmenter|augmenté|augmentée|augmentés|augmentées|progresse|progressera|progresser)(?:\s+\p{L}+)?\s+de"#,
               #"\b(?:hausse|croissance|augmentation|progression|amélioration)(?:\s+\p{L}+){0,2}\s+de"#],
        "es": [#"\b(?:"# + spanishRising + #"|aumentar|crecer|subir)\s+en"#,
               #"\b(?:aumento|incremento|subida|crecimiento|mejora|alza)(?:\s+\p{L}+){0,2}\s+de"#,
               #"\b(?:"# + spanishRising + ")"],
        "it": [#"\b(?:aumenta|aumenterà|aumentato|aumentata|aumentati|aumentate|aumentare|cresce|crescerà|cresciuto|cresciuta|cresciuti|cresciute|crescere|sale|salirà|salito|salita|saliti|salite|in\s+aumento|in\s+crescita|in\s+rialzo)\s+di"#,
               #"\b(?:aumento|incremento|crescita|rialzo|miglioramento)(?:\s+\p{L}+){0,2}\s+di"#],
        "pt": [#"\b(?:"# + portugueseRising + #"|aumentar|crescer|subir)\s+em"#,
               #"\b(?:aumento|crescimento|alta|elevação|melhora|acréscimo)(?:\s+\p{L}+){0,2}\s+de"#,
               #"\b(?:"# + portugueseRising + ")"],
        "zh": [#"(?:增长|增加|上升|提高|上涨)了?"#],
    ]

    /// Words of change that say it went down.
    private static let fallingWordsBefore: [String: [String]] = [
        "en": [#"\b(?:drop|fall|decline|decrease|reduction|loss|dip)\s+of"#, #"\bdown"#, #"\bdown\s+by"#,
               #"\b(?:fall|falls|fell|fallen|falling|drop|drops|dropped|dropping|decline|declines|declined|declining|decrease|decreases|decreased|decreasing|dip|dips|dipped|dipping|shrink|shrinks|shrank|shrunk|shrinking|sink|sinks|sank|sunk|sinking|slip|slips|slipped|slipping|reduce|reduces|reduced|reducing)\s+by"#],
        "de": [#"\b(?:rückgang|minus|verlust|abnahme|verringerung|einbruch)(?:\s+\p{L}+){0,2}\s+(?:von|um)"#,
               #"\b(?:sinkt|sank|gesunken|sinken|fällt|fiel|gefallen|fallen|verringert|verringerte|abnehmen|nimmt\s+ab)\s+um"#],
        "fr": [#"\b(?:diminue|diminuera|diminuer|diminué|diminuée|diminués|diminuées|baisse|baissera|baisser|baissé|recule|reculera|reculer|reculé)(?:\s+\p{L}+)?\s+de"#,
               #"\b(?:chute|diminution|réduction|baisse|recul)(?:\s+\p{L}+){0,2}\s+de"#],
        "es": [#"\b(?:"# + spanishFalling + #"|disminuir|bajar|caer)\s+en"#,
               #"\b(?:caída|disminución|descenso|bajada|reducción|baja)(?:\s+\p{L}+){0,2}\s+de"#,
               #"\b(?:"# + spanishFalling + ")"],
        "it": [#"\b(?:diminuisce|diminuirà|diminuito|diminuita|diminuiti|diminuite|diminuire|cala|calerà|calato|calata|calati|calate|scende|scenderà|sceso|scesa|scesi|scese|in\s+calo|in\s+diminuzione|in\s+ribasso)\s+di"#,
               #"\b(?:calo|diminuzione|riduzione|ribasso|peggioramento|flessione|contrazione)(?:\s+\p{L}+){0,2}\s+di"#],
        "pt": [#"\b(?:"# + portugueseFalling + #"|diminuir|cair)\s+em"#,
               #"\b(?:queda|redução|diminuição|baixa|recuo|piora)(?:\s+\p{L}+){0,2}\s+de"#,
               #"\b(?:"# + portugueseFalling + ")"],
        "zh": [#"(?:下降|减少|降低|下跌|下滑|回落)了?"#],
    ]

    /// What stands right after a number said as the size of a change, its
    /// unit aside: "1,351 higher", "9.420 höher", "1351の増加", "3315ドル減少".
    /// Not "above", "up" or "über": "9,420 up from 8,069" is a level, and
    /// "9420 AUD über 90 Tage" a balance over ninety days. The union of the
    /// comparatives, which say by how much one thing exceeds another, and the
    /// words that say a change went up or down.
    private static let changeWordsAfter: [String: [String]] =
        comparativesAfter.merging(risingWordsAfter, uniquingKeysWith: +)
            .merging(fallingWordsAfter, uniquingKeysWith: +)

    /// A difference, after its number, that names no direction of change:
    /// "1,100 more than income" is spending over income, not a rise —
    /// "支出が収入を1100 AUD上回っています" is true of a balance that falls.
    private static let comparativesAfter: [String: [String]] = [
        "en": [#"(?:higher|lower|more|less)\b"#],
        "de": [#"(?:höher|niedriger|mehr|weniger)\b"#],
        "ja": [#"(?:多い|少ない|多く|少なく|高い|低い|高く|低く|上回|下回)"#],
    ]

    private static let risingWordsAfter: [String: [String]] = [
        "ja": [#"の?(?:増加|上昇|増え|増|改善|プラス)"#],
    ]

    private static let fallingWordsAfter: [String: [String]] = [
        "ja": [#"の?(?:減少|下落|減っ|減り|減|悪化|マイナス)"#],
    ]

    // MARK: - A change said the other way

    /// Whether `text` says a change went the other way from the change it
    /// quotes: "tras una disminución de 31.150,4 AUD" of a net worth that
    /// rose by exactly that (17 October 2026), or a rise by the size of a
    /// fall.
    ///
    /// A number is said as rising or falling by a word of direction right
    /// beside it — "an increase of", "fell by", "will decline by", "下降",
    /// "1351の増加". It is held to `facts.rises` and `facts.falls`: one said
    /// rising that can only be the size of a fall declines the text, and the
    /// other way round.
    ///
    /// Left alone: a number said with both, or with a word that names no
    /// direction ("by", "a change of"); a range; and a number that is the
    /// size of a rise and of a fall alike. A total said to have fallen by
    /// itself — "le spese sono scese di 66.610,82" — is not this: money out
    /// goes down, and "expenses fell" and "net worth fell by expenses" are
    /// the same words about different things, which no reading here can tell
    /// apart.
    static func saysAChangeTheWrongWay(_ text: String, facts: Facts,
                                       locale: Locale = LanguageModels.personLocale) -> Bool {
        saysAChangeTheWrongWay(placedAmounts(in: text, facts: facts, locale: locale), facts: facts,
                               Reading(facts, locale: locale))
    }

    private static func saysAChangeTheWrongWay(_ placement: Placement, facts: Facts, _ reading: Reading) -> Bool {
        guard !facts.rises.isEmpty || !facts.falls.isEmpty else { return false }
        return placement.amounts.indices.contains { index in
            let amount = placement.amounts[index]
            let rising = isSaid(amount, before: risingWordsBefore, after: risingWordsAfter, reading)
            let falling = isSaid(amount, before: fallingWordsBefore, after: fallingWordsAfter, reading)
            guard rising != falling, !opensARange(index, in: placement, facts: facts, reading) else { return false }
            let up = amount.agrees(with: facts.rises), down = amount.agrees(with: facts.falls)
            return rising ? up.isEmpty && !down.isEmpty : down.isEmpty && !up.isEmpty
        }
    }

    // MARK: - A comparison its own figures contradict

    /// Whether `text` compares two of `facts.figures` and says the wrong one
    /// is larger: expenses of 66.6k "acima do valor inicial de 381,2 mil
    /// AUD"; "収入90,643.5 AUDに対し支出66,610.82 AUDが上回った".
    ///
    /// Read only where the comparison is plainly between the two: the first
    /// is its subject — a comma or a verb of being after it ("66.6k, above",
    /// "66.6k were below"), or a verb that compares by itself ("90.6k
    /// exceeded") — and the second follows within a few words. Japanese has
    /// two orders: "AはBを上回った", where the second stands right before the
    /// comparison, and "AにたいしBが上回った", where the first is what the
    /// second is measured against. A figure written with a minus sign is
    /// compared as the negative number it is: "-480 is below 300" is true.
    ///
    /// Left alone: a figure right beside "above" or "higher than", which is
    /// the size of a difference ("6.1k above last year's"); either figure
    /// said as a change ("exceeded expenses by 24.0k"); "more than double"
    /// and its like; a comparison with a negation in it; and any number that
    /// is not one of the figures, which is the number check's to decline.
    static func contradictsAComparison(_ text: String, facts: Facts,
                                       locale: Locale = LanguageModels.personLocale) -> Bool {
        contradictsAComparison(placedAmounts(in: text, facts: facts, locale: locale), facts: facts,
                               Reading(facts, locale: locale))
    }

    private static func contradictsAComparison(_ placement: Placement, facts: Facts, _ reading: Reading) -> Bool {
        let amounts = placement.amounts
        for index in amounts.indices.dropFirst() {
            let first = amounts[index - 1], second = amounts[index]
            guard first.sentenceStart == second.sentenceStart, first.tailEnd <= second.start else { continue }
            let between = String(placement.characters[first.tailEnd..<second.start])
            // A figure said as a change is not what is compared: in "rose by
            // 31.2k, above the opening 381.2k" it is net worth that is above.
            guard let firstIsLarger = comparison(between: between, second: second, languages: reading.languages),
                  !isSaidAsAChange(first, reading), !isSaidAsAChange(second, reading) else { continue }
            let a = values(first, among: facts.figures), b = values(second, among: facts.figures)
            guard !a.isEmpty, !b.isEmpty else { continue }
            let holds = a.contains { x in b.contains { y in firstIsLarger ? x > y : x < y } }
            if !holds { return true }
        }
        return false
    }

    /// The figures an amount can be, as compared: as magnitudes, the way a
    /// figure is written, and negative where it is written with a minus.
    private static func values(_ amount: PlacedAmount, among figures: [Decimal]) -> [Decimal] {
        amount.agrees(with: figures).map { amount.writtenNegative ? -$0 : $0 }
    }

    /// Whether `between` — the words from one figure's unit to the next
    /// figure — compares the two, and if so whether it says the first is the
    /// larger.
    private static func comparison(between: String, second: PlacedAmount, languages: [String]) -> Bool? {
        if languages.contains("ja"), let firstIsLarger = japaneseComparison(between: between, second: second) {
            return firstIsLarger
        }
        if languages.contains("zh"), let firstIsLarger = chineseComparison(between: between, second: second) {
            return firstIsLarger
        }
        for language in languages where language != "ja" {
            for entry in comparisons[language] ?? [] {
                guard let match = match(between, entry: entry, language: language) else { continue }
                // Beside the first figure with nothing between, "above" is
                // the size of a difference: "6.1k above last year's".
                if !entry.isVerb, match.subject.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
                return isPlainPhrase(match.phrase, cjk: language == "zh") ? entry.larger : nil
            }
        }
        return nil
    }

    /// The comparison at the start of `gap`, after a comma or a verb of
    /// being: the part before it, and the words after it up to the second
    /// figure.
    private static func match(_ gap: String, entry: Comparison,
                              language: String) -> (subject: String, phrase: String)? {
        let cjk = language == "zh"
        let copula = copulas[language].map { "(?:(?:" + $0 + ")" + (cjk ? #"\s*)?"# : #"\s+)?"#) } ?? ""
        let intensity = #"(?:(?:"# + intensifiers + (cjk ? #")\s*)?"# : #")\s+)?"#)
        // A marker that ends in an apostrophe — "au-dessus d'un" — runs
        // straight on into the next word.
        let ending = cjk ? "" : #"(?:(?<=['’])|(?!\p{L}))"#
        // A closing bracket may end the first figure: "Expenses (66,610.82
        // AUD) exceeded income (90,643.50 AUD)" — the model's own style, read
        // as no comparison at all until the 17 October review.
        let pattern = #"^(\s*[)）\]】]?\s*(?:[,，、;；:：—–-]\s*)?"# + copula + intensity + ")(?:" + entry.pattern + ")"
            + ending + #"(\D*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let found = expression.firstMatch(in: gap, range: NSRange(gap.startIndex..., in: gap)),
              let subject = Range(found.range(at: 1), in: gap),
              let phrase = Range(found.range(at: 2), in: gap) else { return nil }
        return (String(gap[subject]), String(gap[phrase]))
    }

    /// Whether the words between a comparison and its second figure are a
    /// few plain ones — "the opening value of", "期初的" — with no "double"
    /// or "half" in them to change what is being compared.
    private static func isPlainPhrase(_ phrase: String, cjk: Bool) -> Bool {
        if hasMultiplier(phrase) { return false }
        if cjk { return phrase.count <= 8 }
        return phrase.split(whereSeparator: \.isWhitespace).count <= 6
    }

    /// The two Japanese orders. "AはBを上回った": the first is the subject,
    /// joined by a particle, and the comparison follows the second.
    /// "AにたいしBが上回った": the first is what the second is measured against,
    /// and the second is the subject.
    private static func japaneseComparison(between gap: String, second: PlacedAmount) -> Bool? {
        guard !hasMultiplier(gap) else { return nil }
        let next = second.after.drop { $0.isWhitespace || ")）".contains($0) }
        func negated(after word: String, in text: Substring) -> Bool {
            let rest = String(text.dropFirst(word.count).prefix(8))
            return rest.range(of: japaneseNegation, options: .regularExpression) != nil
        }
        if gap.range(of: #"^[)）\s]*[はがでも、，,\s]+\D{0,10}$"#, options: .regularExpression) != nil {
            for (word, firstIsLarger) in japaneseComparisons where next.hasPrefix(word) {
                return negated(after: word, in: next) ? nil : firstIsLarger
            }
        }
        if gap.range(of: #"^[)）\s]*(?:に対し(?:て)?|に比べ(?:て)?|と比べ(?:て)?|と比較して|より)[、，,\s]*\D{0,10}$"#,
                     options: .regularExpression) != nil,
           let particle = next.first, particle == "が" || particle == "は" {
            let rest = next.dropFirst()
            for (word, secondIsLarger) in japaneseSubjectComparisons where rest.hasPrefix(word) {
                return negated(after: word, in: rest) ? nil : !secondIsLarger
            }
        }
        return nil
    }

    /// Chinese "A比B多": "比" between the two figures, and after the second
    /// the word that says which is larger. "不比" negates it.
    private static func chineseComparison(between gap: String, second: PlacedAmount) -> Bool? {
        guard gap.range(of: #"^[)）\s]*[，,、]?\s*(?:还|也|都|要)?比\D{0,8}$"#, options: .regularExpression) != nil,
              !hasMultiplier(gap) else { return nil }
        let next = second.after.drop { $0.isWhitespace || ")）".contains($0) }
        guard let word = next.first else { return nil }
        if "多高大".contains(word) { return true }
        if "少低小".contains(word) { return false }
        return nil
    }

    private struct Comparison {
        var pattern: String
        var larger: Bool
        /// Compares by itself, without a verb of being: "exceeded".
        var isVerb = false
    }

    /// The comparisons, by language, and whether each says the first figure
    /// is the larger.
    private static let comparisons: [String: [Comparison]] = [
        "en": [
            Comparison(pattern: #"above|higher than|greater than|more than|in excess of"#, larger: true),
            Comparison(pattern: #"exceed(?:s|ed|ing)?|surpass(?:es|ed|ing)?"#, larger: true, isVerb: true),
            Comparison(pattern: #"below|under|beneath|lower than|less than|short of"#, larger: false),
        ],
        "de": [
            Comparison(pattern: #"über|oberhalb|höher als|größer als|mehr als"#, larger: true),
            Comparison(pattern: #"übersteigt|überstieg|übertrifft|übertraf|überschreitet|überschritt"#,
                       larger: true, isVerb: true),
            Comparison(pattern: #"unter|unterhalb|niedriger als|geringer als|weniger als|kleiner als"#,
                       larger: false),
        ],
        "fr": [
            Comparison(pattern: #"au-dessus d(?:e|u|es|'|’)|au-delà d(?:e|u|es|'|’)|supérieure?s? (?:à|au|aux)|plus élevée?s? que|plus (?:que|de)"#,
                       larger: true),
            Comparison(pattern: #"dépass(?:e|ent|ait|aient|era|eront|ant)"#, larger: true, isVerb: true),
            Comparison(pattern: #"au-dessous d(?:e|u|es|'|’)|en[- ]dessous d(?:e|u|es|'|’)|inférieure?s? (?:à|au|aux)|plus bas(?:se)?s? que|moins (?:que|de)"#,
                       larger: false),
        ],
        "es": [
            Comparison(pattern: #"por encima de(?:l)?|superior(?:es)? a(?:l)?|mayor(?:es)? que|más (?:que|de)|más alt[oa]s? que"#,
                       larger: true),
            Comparison(pattern: #"supera(?:n|ba|ban|rá|rán)?|superó|superaron|excede(?:n|rá)?|excedió"#,
                       larger: true, isVerb: true),
            Comparison(pattern: #"por debajo de(?:l)?|inferior(?:es)? a(?:l)?|menor(?:es)? que|menos (?:que|de)|más baj[oa]s? que"#,
                       larger: false),
        ],
        "it": [
            Comparison(pattern: #"al di sopra d(?:i|el|ella|ei|egli|elle)|sopra|superiore a(?:l|lla|i|gli|lle)?|maggiore d(?:i|el|ella)|più alt[oa] d(?:i|el|ella)|più d(?:i|el|ella)"#,
                       larger: true),
            Comparison(pattern: #"supera(?:no|va|vano|rà|ranno)?|superato"#, larger: true, isVerb: true),
            Comparison(pattern: #"al di sotto d(?:i|el|ella|ei)|sotto|inferiore a(?:l|lla|i|gli|lle)?|minore d(?:i|el|ella)|più bass[oa] d(?:i|el|ella)|meno d(?:i|el|ella)"#,
                       larger: false),
        ],
        "pt": [
            Comparison(pattern: #"acima d(?:e|o|a|os|as)|superior(?:es)? a(?:o|os|s)?|maior(?:es)? (?:do )?que|mais (?:do )?que|mais de|mais alt[oa]s? (?:do )?que"#,
                       larger: true),
            Comparison(pattern: #"supera(?:m|va|vam|rá|rão)?|superou|superaram|excede(?:u|rá)?"#,
                       larger: true, isVerb: true),
            Comparison(pattern: #"abaixo d(?:e|o|a|os|as)|inferior(?:es)? a(?:o|os|s)?|menor(?:es)? (?:do )?que|menos (?:do )?que|menos de|mais baix[oa]s? (?:do )?que"#,
                       larger: false),
        ],
        // Chinese puts the comparison straight after the first figure —
        // "支出66,611澳元高于收入" — so each compares by itself. Read as
        // needing a comma first, "A高于B" was never read (17 October review).
        "zh": [
            Comparison(pattern: #"高于|超过了?|多于|大于|超出了?"#, larger: true, isVerb: true),
            Comparison(pattern: #"低于|少于|小于|不足"#, larger: false, isVerb: true),
        ],
    ]

    /// "AはBを上回った": the word after the second figure, and whether it says
    /// the first is the larger. "より少な", not "より少": the な is the
    /// adjective's own, and a negation read after "より少" found the ない of
    /// 少ない and let "支出より少ない" of a larger income pass (17 October
    /// review).
    private static let japaneseComparisons: [(String, Bool)] = [
        ("を上回", true), ("より多", true), ("より高", true), ("を超え", true), ("を超過", true),
        ("を下回", false), ("より少な", false), ("より低", false), ("未満", false),
    ]

    /// "AにたいしBが上回った": the word after the second figure's が, and
    /// whether it says the second is the larger.
    private static let japaneseSubjectComparisons: [(String, Bool)] = [
        ("上回", true), ("多い", true), ("多く", true), ("高い", true), ("高く", true), ("超え", true),
        ("大き", true),
        ("下回", false), ("少な", false), ("低い", false), ("低く", false), ("小さ", false),
    ]

    /// Verbs of being between the first figure and the comparison.
    private static let copulas: [String: String] = [
        "en": #"is|was|were|are|remains|remained|stands|stood|sits|sat|comes in|came in|ends|ended|lies|lay"#,
        "de": #"ist|war|sind|waren|liegt|lag|liegen|lagen|bleibt|blieb|steht|stand"#,
        "fr": #"est|était|sont|étaient|reste|restait|se situe|se situait|demeure"#,
        "es": #"es|fue|era|son|fueron|eran|está|estuvo|estaba|queda|quedó|se sitúa|se situó|resulta|resultó"#,
        "it": #"è|era|sono|erano|resta|restava|rimane|rimaneva|si attesta|si attestava|risulta|risultava"#,
        "pt": #"é|foi|era|são|foram|eram|está|esteve|estava|fica|ficou|permanece|permaneceu"#,
        "zh": #"是|为|仍然|依然|仍"#,
    ]

    private static let intensifiers = #"well|far|slightly|just|considerably|significantly|deutlich|weit|knapp|leicht|bien|largement|légèrement|muy|ligeramente|bastante|ben|leggermente|molto|muito|ligeiramente|bem|远|略|明显"#

    /// Whether `text` holds a word that makes a comparison of something
    /// other than the two figures — a half, a double, a fraction. As whole
    /// words: "quarterly" is not a quarter, "sometimes" ("a veces", "às
    /// vezes", "a volte", "parfois") is not times, and 上半期 is the first
    /// half of a year, not a half (17 October review).
    private static func hasMultiplier(_ text: String) -> Bool {
        text.range(of: multipliers, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let multipliers = [
        #"\b(?:half|halves|double|twice|triple|thrice|times|thirds?|quarters?|fifths?|sixths?|sevenths?|eighths?|ninths?|tenths?)\b"#,
        #"\bhalb|\p{L}*fach\b|\b(?:doppelt\p{L}*|drittel|viertel|fünftel|sechstel|zehntel)\b"#,
        #"\b(?:moitié|double|fois|tiers|quarts?|cinquième|sixième|dixième)\b"#,
        #"\b(?:mitad|doble|tercio|tercera|cuart[oa]|quint[oa]|sext[oa]|décim[oa])\b|(?<!\ba\s)\bveces\b"#,
        #"\b(?:metà|doppio|terzo|quarto|quinto|sesto|decimo)\b|(?<!\ba\s)\bvolte\b"#,
        #"\b(?:metade|dobro|terço|quinto|sexto|décimo)\b|(?<!às\s)\bvezes\b"#,
        #"倍|一半|分の|分之|(?<![上下])半(?![期年])"#,
    ].joined(separator: "|")

    // MARK: - A negative balance that is not

    /// Whether `text` says a balance is, or goes, below zero: "einen
    /// negativen Saldo", "saldo negativo", "overdrawn", "残高がマイナス".
    /// The caller knows whether one is; this only reads the words.
    ///
    /// The balance, not anything else that is negative: "einen negativen
    /// Saldoänderungstrend" — a falling trend — is true of a falling balance,
    /// and is not this. Nor a sentence that negates it: "the balance never
    /// falls below zero" is the true thing to say of a forecast that stays
    /// above it.
    ///
    /// A negation counts only in the language of the words it negates —
    /// English "no" is not the Portuguese "no" of "no final de agosto" — and,
    /// in Chinese and Japanese, which write no spaces, only as a word near
    /// them: before the words in Chinese ("不会出现负余额"), after them in
    /// Japanese ("マイナスになることはない"). "未来90天" ("the next ninety
    /// days"), "不断" ("steadily"), "はず" ("expected to") and "わずか"
    /// ("slightly") hold the characters of a negation and negate nothing
    /// (17 October review).
    ///
    /// Nor a flow: "un saldo negativo de 1100 AUD al mes" is the monthly net
    /// the prompt gives, "una variazione in negativo di 3.315 AUD" the change
    /// — the same words as a balance below zero, said of an amount that
    /// moved (17 October review). A sentence that says it of a period ("al
    /// mes", "monatlich", "每月"), or of an amount right after it that is
    /// one of `facts.changes` and none of its levels, is left alone.
    static func saysABalanceIsNegative(_ text: String, facts: Facts? = nil,
                                       locale: Locale = LanguageModels.personLocale) -> Bool {
        let languages = languagesRead(for: locale)
        let characters = lowercasedInPlace(Array(normalised(text)))
        let amounts = facts.map { placedAmounts(in: text, facts: $0, locale: locale).amounts } ?? []
        var sentences: [(offset: Int, text: String)] = []
        var start = 0
        for index in characters.indices where isSentenceBreak(characters, at: index) {
            sentences.append((start, String(characters[start..<index])))
            start = index + 1
        }
        sentences.append((start, String(characters[start...])))
        return sentences.contains { entry in
            let sentence = entry.text
            guard sentence.range(of: periodWords, options: .regularExpression) == nil else { return false }
            return languages.contains { language in
                (negativeBalances[language] ?? []).contains { pattern in
                    guard let found = sentence.range(of: pattern, options: .regularExpression) else { return false }
                    let end = entry.offset + sentence.distance(from: sentence.startIndex, to: found.upperBound)
                    let saidOfAFlow = facts.map { facts in
                        amounts.contains { amount in
                            amount.start >= end && amount.start - end <= 24
                                && !amount.agrees(with: facts.changes).isEmpty && amount.agrees(with: facts.levels).isEmpty
                        }
                    } ?? false
                    return !saidOfAFlow && !isNegated(found, in: sentence, language: language)
                }
            }
        }
    }

    /// Words that put what they are said of in a period — a month — and so
    /// make it a flow, not a balance.
    private static let periodWords =
        #"\b(?:a|per)\s+month\b|\bmonthly\b|\bmonatlich|\bpro\s+monat\b|\bpar\s+mois\b|\bmensuel|\bal\s+mes\b|\bmensual|\bal\s+mese\b|\bmensil|\bpor\s+m[eê]s\b|\bmensal|毎月|月平均|每月|月均"#

    /// Whether the words at `found` are negated in `sentence`, in `language`.
    private static func isNegated(_ found: Range<String.Index>, in sentence: String, language: String) -> Bool {
        switch language {
        case "zh":
            let from = sentence.index(found.lowerBound, offsetBy: -4, limitedBy: sentence.startIndex)
                ?? sentence.startIndex
            return sentence[from..<found.upperBound].range(of: chineseNegation, options: .regularExpression) != nil
        case "ja":
            let to = sentence.index(found.upperBound, offsetBy: 14, limitedBy: sentence.endIndex)
                ?? sentence.endIndex
            return sentence[found.lowerBound..<to].range(of: japaneseNegation, options: .regularExpression) != nil
        default:
            return negations[language].map { sentence.range(of: $0, options: .regularExpression) != nil } ?? false
        }
    }

    private static let negativeBalances: [String: [String]] = [
        "en": [#"\bnegative\s+balance"#,
               #"\bbalance\s+(?:is|was|will\s+be|would\s+be|turns|goes|becomes|falls|dips|drops)\s+(?:into\s+)?negative"#,
               #"\boverdrawn\b"#, #"\bbelow\s+zero\b"#, #"\b(?:in|into)\s+the\s+red\b"#],
        "de": [#"\bnegativ\w*\s+(?:saldo|kontostand|stand)\b"#,
               #"\b(?:saldo|kontostand)\s+(?:ist|wird|bleibt|wäre|würde)\s+(?:\p{L}+\s+)?negativ"#,
               #"\b(?:im|ins)\s+minus\b"#, #"\büberzogen"#],
        "fr": [#"\bsolde\s+négatif"#, #"\bsolde\s+(?:est|sera|devient|deviendra|serait)\s+négatif"#,
               #"\bà\s+découvert\b"#, #"\bdans\s+le\s+rouge\b"#],
        "es": [#"\bsaldo\s+negativo"#, #"\bsaldo\s+(?:es|será|sería|queda|quedará)\s+negativo"#,
               #"\bnúmeros\s+rojos\b"#, #"\ben\s+descubierto\b"#],
        "it": [#"\bsaldo\s+negativo"#, #"\bsaldo\s+(?:è|sarà|diventa|diventerà)\s+negativo"#,
               #"\b(?:in|andrà\s+in|va\s+in|finirà\s+in)\s+(?:rosso|negativo)\b"#],
        "pt": [#"\bsaldo\s+negativo"#, #"\bsaldo\s+(?:é|será|fica|ficará)\s+negativo"#,
               #"\bno\s+vermelho\b"#, #"\ba\s+descoberto\b"#],
        "ja": [#"残高.{0,6}マイナス"#, #"マイナス.{0,2}残高"#],
        "zh": [#"余额.{0,3}为负"#, #"负余额"#, #"余额.{0,3}负数"#, #"透支"#],
    ]

    /// A Japanese negation: the endings a sentence is negated in, and none
    /// of the words that only hold their characters — はず ("expected"),
    /// わずか ("slightly"), まず ("first"), 必ず ("certainly"), ずっと
    /// ("throughout").
    private static let japaneseNegation =
        #"ない|なかっ|ません|(?<![はわま必])ず(?!っと|か)|ことはな|ことがな"#

    /// A Chinese negation, as a word: not 不断 ("steadily"), 不仅 ("not
    /// only"), 不论/无论 ("whatever"), 不过 ("but"), 不少 ("many"), 不同
    /// ("different"), 不久 ("soon"), 不管 ("however"), 不错 ("good"), or
    /// 未来 ("the next…").
    private static let chineseNegation =
        #"不(?!断|仅|论|过|少|同|久|管|错)|没|未(?!来)|无(?!论)|無(?!論)|并非|避免"#

    /// Words that turn a sentence round, by language. The apostrophe either
    /// way: the model writes "won’t" as often as "won't".
    private static let negations: [String: String] = [
        "en": #"\b(?:not|never|no|nor|without|cannot)\b|n['’]t\b"#,
        "de": #"\b(?:nicht|nie|niemals|kein\w*|ohne)\b"#,
        "fr": #"\b(?:ne|pas|jamais|aucun\w*|sans)\b|\bn['’]"#,
        "es": #"\b(?:no|nunca|jamás|ningún|ninguna|sin)\b"#,
        "it": #"\b(?:non|mai|nessun\w*|senza)\b"#,
        "pt": #"\b(?:não|nunca|nenhum\w*|nem|sem)\b"#,
    ]
}
