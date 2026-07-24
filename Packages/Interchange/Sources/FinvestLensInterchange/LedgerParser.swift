//
//  LedgerParser.swift
//  FinvestLens — Interchange
//
//  Parser for the Ledger 3 journal format (FR-XIO-09), written against
//  docs/ledger-format-reference.md. Line-based, dispatching on the first
//  character like ledger's own reader; collects file:line diagnostics and
//  recovers by skipping the offending entry, so one bad transaction never
//  hides the rest of the file (FR-IMP-07). Resolution — elided amounts,
//  balance assignments, bucket balancing, per-transaction zero-sum checks,
//  and file-order balance assertions — runs as each transaction completes.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum LedgerParser {

    // MARK: Public entry points

    /// Parses journal text. `fileName` labels diagnostics; `today` anchors
    /// yearless dates when no `year` directive has run; `includes` resolves
    /// `include PATH` (nil → includes warn and are skipped).
    public static func parse(text: String,
                             fileName: String = "journal",
                             today: Date = Date(),
                             includes: ((String) -> String?)? = nil) -> LedgerParseResult {
        var state = State(today: today, includeResolver: includes)
        state.parse(text: text, fileName: fileName)
        state.finish()
        return LedgerParseResult(journal: state.journal, diagnostics: state.diagnostics)
    }

    /// Parses a journal file, resolving `include` (with `*` globs) relative
    /// to each including file, with cycle protection.
    public static func parse(fileAt url: URL, today: Date = Date()) throws -> LedgerParseResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        var visited: Set<String> = [url.standardizedFileURL.path]
        let base = url.deletingLastPathComponent()
        func resolver(_ path: String) -> String? {
            let expanded = NSString(string: path).expandingTildeInPath
            let target = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : base.appendingPathComponent(expanded)
            let standard = target.standardizedFileURL.path
            guard !visited.contains(standard) else { return nil }
            visited.insert(standard)
            return try? String(contentsOf: target, encoding: .utf8)
        }
        // Glob expansion happens in the directive handler via this hook.
        var state = State(today: today, includeResolver: resolver)
        state.globLister = { pattern in
            let expanded = NSString(string: pattern).expandingTildeInPath
            let directoryURL = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded).deletingLastPathComponent()
                : base.appendingPathComponent(expanded).deletingLastPathComponent()
            let namePattern = (expanded as NSString).lastPathComponent
            guard let names = try? FileManager.default
                .contentsOfDirectory(atPath: directoryURL.path) else { return [] }
            return names.filter { Self.matchesGlob($0, pattern: namePattern) }
                .sorted()
                .map { directoryURL.appendingPathComponent($0).path }
        }
        _ = base   // captured by the closures above
        state.parse(text: text, fileName: url.lastPathComponent)
        state.finish()
        return LedgerParseResult(journal: state.journal, diagnostics: state.diagnostics)
    }

    static func matchesGlob(_ name: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return name == pattern }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map(String.init)
        var remainder = Substring(name)
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            guard let range = remainder.range(of: part) else { return false }
            if index == 0, range.lowerBound != remainder.startIndex { return false }
            remainder = remainder[range.upperBound...]
        }
        if let last = parts.last, !last.isEmpty, !pattern.hasSuffix("*"),
           !name.hasSuffix(last) { return false }
        return true
    }

    // MARK: - Parser state

    struct State {
        var journal = LedgerJournal()
        var diagnostics: [LedgerDiagnostic] = []
        let today: Date
        var includeResolver: ((String) -> String?)?
        var globLister: ((String) -> [String])?

        // Directive state.
        var defaultYear: Int?
        var yearStack: [Int?] = []           // `apply year`
        var accountPrefixStack: [String] = []
        var tagStack: [(tag: String?, metadata: LedgerMetadata?)] = []
        var aliases: [String: String] = [:]
        var payeeAliases: [(regex: NSRegularExpression, name: String)] = []
        var bucketAccount: String?
        var decimalCommaDefault = false

        // Running balances for assertions/assignments, in FILE order.
        // Keyed "account\u{1}commodity"; real and virtual domains separate.
        var realBalances: [String: Decimal] = [:]
        var virtualBalances: [String: Decimal] = [:]

        var file = "journal"

        mutating func warn(_ line: Int, _ message: String) {
            diagnostics.append(LedgerDiagnostic(.warning, file: file, line: line, message: message))
        }
        mutating func error(_ line: Int, _ message: String) {
            diagnostics.append(LedgerDiagnostic(.error, file: file, line: line, message: message))
        }

        // MARK: Main loop

        mutating func parse(text: String, fileName: String) {
            let previousFile = file
            file = fileName
            defer { file = previousFile }

            let lines = text.components(separatedBy: "\n")
            var index = 0
            var inCommentBlock = false

            while index < lines.count {
                let raw = lines[index]
                let lineNo = index + 1
                index += 1
                if raw.isEmpty || raw.allSatisfy(\.isWhitespace) { continue }

                if inCommentBlock {
                    let word = raw.trimmingCharacters(in: .whitespaces)
                    if word == "end comment" || word == "end test" { inCommentBlock = false }
                    continue
                }

                let first = raw[raw.startIndex]

                if first.isNumber {
                    index = parseTransaction(lines: lines, startIndex: index - 1)
                    continue
                }
                if first == " " || first == "\t" {
                    error(lineNo, "unexpected indented line outside a transaction")
                    continue
                }
                switch first {
                case ";", "#", "%", "|", "*":
                    continue   // file-level comment
                case "~", "=":
                    index = captureRawEntry(lines: lines, startIndex: index - 1,
                                            periodic: first == "~")
                    continue
                case "-":
                    handleOptionLine(raw, line: lineNo)
                    continue
                default:
                    break
                }

                var directiveLine = raw
                if first == "@" || first == "!" {   // deprecated prefixes
                    directiveLine = String(raw.dropFirst())
                }
                index = handleDirective(directiveLine, lines: lines,
                                        startIndex: index - 1,
                                        inCommentBlock: &inCommentBlock)
            }
        }

        mutating func finish() {
            // Nothing global yet: assertions verify as transactions complete.
        }

        // MARK: Option lines

        mutating func handleOptionLine(_ raw: String, line: Int) {
            let option = raw.trimmingCharacters(in: .whitespaces)
            if option == "--decimal-comma" {
                decimalCommaDefault = true
            } else {
                warn(line, "option line '\(option)' ignored")
            }
        }

        // MARK: Raw periodic/automated capture

        mutating func captureRawEntry(lines: [String], startIndex: Int, periodic: Bool) -> Int {
            let header = lines[startIndex]
            var body: [String] = []
            var index = startIndex + 1
            while index < lines.count,
                  let first = lines[index].first, first == " " || first == "\t" {
                body.append(lines[index])
                index += 1
            }
            var entry = LedgerRawEntry(header: header, lines: body)
            entry.line = startIndex + 1
            if periodic {
                journal.periodicEntries.append(entry)
            } else {
                journal.automatedEntries.append(entry)
                warn(startIndex + 1,
                     "automated transaction parsed but not applied (design NG-L2)")
            }
            return index
        }

        // MARK: Directives

        mutating func handleDirective(_ raw: String, lines: [String], startIndex: Int,
                                      inCommentBlock: inout Bool) -> Int {
            let lineNo = startIndex + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let word = trimmed.prefix(while: { !$0.isWhitespace })
            let rest = trimmed.dropFirst(word.count).trimmingCharacters(in: .whitespaces)

            func subLines() -> ([String], Int) {
                var body: [String] = []
                var index = startIndex + 1
                while index < lines.count,
                      let first = lines[index].first, first == " " || first == "\t" {
                    body.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                return (body, index)
            }

            switch word {
            case "comment", "test":
                inCommentBlock = true
                return startIndex + 1

            case "include":
                handleInclude(rest, line: lineNo)
                return startIndex + 1

            case "year":
                defaultYear = Int(rest)
                if defaultYear == nil { error(lineNo, "invalid year '\(rest)'") }
                return startIndex + 1

            case "Y":   // legacy single-char came through the word path ("Y 2004")
                defaultYear = Int(rest)
                return startIndex + 1

            case "apply":
                let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                switch parts.first {
                case "account":
                    accountPrefixStack.append(parts.count > 1 ? parts[1] : "")
                case "tag":
                    let payload = parts.count > 1 ? parts[1] : ""
                    if let colon = payload.firstIndex(of: ":"),
                       payload.index(after: colon) < payload.endIndex {
                        let key = String(payload[..<colon])
                        let value = payload[payload.index(after: colon)...]
                            .trimmingCharacters(in: .whitespaces)
                        tagStack.append((nil, LedgerMetadata(key: key, value: value)))
                    } else {
                        tagStack.append((payload.trimmingCharacters(in: CharacterSet(charactersIn: ":")), nil))
                    }
                case "year":
                    yearStack.append(defaultYear)
                    defaultYear = parts.count > 1 ? Int(parts[1]) : nil
                case "fixed", "rate":
                    warn(lineNo, "'apply \(parts.first ?? "")' ignored")
                    accountPrefixStack.append("")   // keep end-balance
                default:
                    warn(lineNo, "unknown apply directive '\(rest)' ignored")
                    accountPrefixStack.append("")
                }
                return startIndex + 1

            case "end":
                let what = rest.split(separator: " ").map(String.init)
                if what.first == "apply" || what.isEmpty || rest.isEmpty {
                    let kind = what.count > 1 ? what[1] : nil
                    switch kind {
                    case "account": if !accountPrefixStack.isEmpty { accountPrefixStack.removeLast() }
                    case "tag": if !tagStack.isEmpty { tagStack.removeLast() }
                    case "year": if let restored = yearStack.popLast() { defaultYear = restored }
                    default:
                        // plain `end`: innermost apply of any kind
                        if !tagStack.isEmpty { tagStack.removeLast() }
                        else if !accountPrefixStack.isEmpty { accountPrefixStack.removeLast() }
                        else if let restored = yearStack.popLast() { defaultYear = restored }
                        else { warn(lineNo, "'end' with nothing open") }
                    }
                } else {
                    warn(lineNo, "'end \(rest)' ignored")
                }
                return startIndex + 1

            case "alias":
                if let equals = rest.firstIndex(of: "=") {
                    let short = String(rest[..<equals]).trimmingCharacters(in: .whitespaces)
                    let full = String(rest[rest.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    aliases[short] = full
                } else {
                    error(lineNo, "alias needs NAME=FULL:NAME")
                }
                return startIndex + 1

            case "bucket", "A":
                bucketAccount = rest.isEmpty ? nil : rest
                return startIndex + 1

            case "account":
                var directive = LedgerAccountDirective(name: rest)
                directive.line = lineNo
                let (body, next) = subLines()
                for sub in body {
                    let subWord = sub.prefix(while: { !$0.isWhitespace })
                    let subRest = sub.dropFirst(subWord.count).trimmingCharacters(in: .whitespaces)
                    switch subWord {
                    case "note": directive.note = subRest
                    case "alias":
                        directive.aliases.append(subRest)
                        aliases[subRest] = rest
                    default: directive.extraLines.append(sub)
                    }
                }
                journal.accountDirectives.append(directive)
                return next

            case "commodity":
                var directive = LedgerCommodityDirective(symbol: Self.unquote(rest))
                directive.line = lineNo
                let (body, next) = subLines()
                for sub in body {
                    let subWord = sub.prefix(while: { !$0.isWhitespace })
                    let subRest = sub.dropFirst(subWord.count).trimmingCharacters(in: .whitespaces)
                    switch subWord {
                    case "note": directive.note = subRest
                    case "format":
                        directive.format = subRest
                        var styles = journal.styles
                        _ = LedgerAmountSyntax.parse(subRest,
                                                     decimalCommaDefault: decimalCommaDefault,
                                                     styles: &styles, observe: true)
                        journal.styles = styles
                    case "nomarket": directive.noMarket = true
                    default: directive.extraLines.append(sub)
                    }
                }
                journal.commodityDirectives.append(directive)
                return next

            case "payee":
                let name = rest
                let (body, next) = subLines()
                for sub in body {
                    let subWord = sub.prefix(while: { !$0.isWhitespace })
                    let subRest = sub.dropFirst(subWord.count).trimmingCharacters(in: .whitespaces)
                    if subWord == "alias",
                       let regex = try? NSRegularExpression(pattern: subRest,
                                                            options: [.caseInsensitive]) {
                        payeeAliases.append((regex, name))
                    }
                    // `uuid` and others: recorded nowhere in v1.
                }
                return next

            case "D":
                // Default commodity style: observe the sample amount.
                var styles = journal.styles
                _ = LedgerAmountSyntax.parse(rest, decimalCommaDefault: decimalCommaDefault,
                                             styles: &styles, observe: true)
                journal.styles = styles
                return startIndex + 1

            case "N":
                var directive = LedgerCommodityDirective(symbol: Self.unquote(rest))
                directive.noMarket = true
                directive.line = lineNo
                journal.commodityDirectives.append(directive)
                return startIndex + 1

            case "P":
                handlePriceLine(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces),
                                line: lineNo)
                return startIndex + 1

            case "C", "capture", "define", "def", "assert", "check",
                 "expr", "eval", "value", "python", "import",
                 "i", "I", "o", "O", "b", "h", "tag":
                warn(lineNo, "directive '\(word)' ignored")
                // Consume any indented block so its lines don't error.
                let (_, next) = subLines()
                return next

            default:
                error(lineNo, "unknown directive '\(word)'")
                let (_, next) = subLines()
                return next
            }
        }

        mutating func handleInclude(_ path: String, line: Int) {
            guard !path.isEmpty else { error(line, "include needs a path"); return }
            if path.contains("*"), let lister = globLister {
                for match in lister(path) {
                    if let text = includeResolver?(match) {
                        parse(text: text, fileName: (match as NSString).lastPathComponent)
                    }
                }
                return
            }
            guard let resolver = includeResolver else {
                warn(line, "include '\(path)' ignored (no file context)")
                return
            }
            guard let text = resolver(path) else {
                error(line, "cannot include '\(path)' (missing, unreadable, or already included)")
                return
            }
            parse(text: text, fileName: (path as NSString).lastPathComponent)
        }

        mutating func handlePriceLine(_ rest: String, line: Int) {
            // P DATE [TIME] SYMBOL PRICE
            var tokens = Self.splitOnWhitespace(rest)
            guard tokens.count >= 3 else { error(line, "malformed P line"); return }
            let dateToken = tokens.removeFirst()
            var time: String?
            if let next = tokens.first, next.contains(":") {
                time = tokens.removeFirst()
            }
            guard let date = parseDate(dateToken, time: time) else {
                error(line, "invalid date in P line"); return
            }
            // The symbol may be quoted (and contain spaces); the price is the
            // final amount token(s).
            var symbol: String
            if tokens.first?.hasPrefix("\"") == true {
                var joined = tokens.removeFirst()
                while !joined.hasSuffix("\"") || joined == "\"" {
                    guard !tokens.isEmpty else { error(line, "unterminated symbol in P line"); return }
                    joined += " " + tokens.removeFirst()
                }
                symbol = Self.unquote(joined)
            } else {
                guard !tokens.isEmpty else { error(line, "malformed P line"); return }
                symbol = tokens.removeFirst()
            }
            var styles = journal.styles
            guard let price = LedgerAmountSyntax.parse(tokens.joined(separator: " "),
                                                       decimalCommaDefault: decimalCommaDefault,
                                                       styles: &styles, observe: false) else {
                error(line, "invalid price in P line"); return
            }
            var entry = LedgerPriceEntry(date: date, symbol: symbol, price: price)
            entry.line = line
            journal.prices.append(entry)
        }

        // MARK: Transactions

        mutating func parseTransaction(lines: [String], startIndex: Int) -> Int {
            let headerLine = startIndex + 1
            guard var transaction = parseHeader(lines[startIndex], line: headerLine) else {
                // Skip the whole entry.
                var index = startIndex + 1
                while index < lines.count,
                      let first = lines[index].first, first == " " || first == "\t" { index += 1 }
                return index
            }

            var index = startIndex + 1
            var lastPostingIndex: Int?
            var broken = false

            while index < lines.count,
                  let first = lines[index].first, first == " " || first == "\t" {
                let content = lines[index].trimmingCharacters(in: .whitespaces)
                let lineNo = index + 1
                index += 1
                if content.isEmpty { continue }
                if content.hasPrefix(";") {
                    let note = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if let postingIndex = lastPostingIndex {
                        transaction.postings[postingIndex].noteLines.append(note)
                        absorb(note: note, intoPosting: &transaction.postings[postingIndex])
                    } else {
                        transaction.noteLines.append(note)
                        absorb(note: note, intoTransaction: &transaction)
                    }
                    continue
                }
                if let posting = parsePosting(content, line: lineNo) {
                    transaction.postings.append(posting)
                    lastPostingIndex = transaction.postings.count - 1
                } else {
                    broken = true
                }
            }

            // Applied tag/metadata blocks.
            for entry in tagStack {
                if let tag = entry.tag, !tag.isEmpty, !transaction.tags.contains(tag) {
                    transaction.tags.append(tag)
                }
                if let metadata = entry.metadata { transaction.metadata.append(metadata) }
            }

            guard !broken else { return index }   // diagnostics already emitted
            guard !transaction.postings.isEmpty else {
                error(headerLine, "transaction has no postings")
                return index
            }
            resolveAndAppend(&transaction, headerLine: headerLine)
            return index
        }

        mutating func parseHeader(_ raw: String, line: Int) -> LedgerTransaction? {
            var s = Substring(raw)
            let dateToken = s.prefix(while: { !$0.isWhitespace })
            s = s.dropFirst(dateToken.count).drop(while: { $0 == " " || $0 == "\t" })

            var primaryToken = String(dateToken)
            var auxToken: String?
            if let equals = primaryToken.firstIndex(of: "=") {
                auxToken = String(primaryToken[primaryToken.index(after: equals)...])
                primaryToken = String(primaryToken[..<equals])
            }
            guard let date = parseDate(primaryToken, time: nil) else {
                error(line, "invalid transaction date '\(primaryToken)'")
                return nil
            }
            var auxDate: Date?
            if let auxToken {
                auxDate = parseDate(auxToken, time: nil)
                if auxDate == nil { error(line, "invalid auxiliary date '\(auxToken)'"); return nil }
            }

            var state = LedgerState.uncleared
            if s.first == "*" { state = .cleared; s = s.dropFirst().drop(while: { $0 == " " }) }
            else if s.first == "!" { state = .pending; s = s.dropFirst().drop(while: { $0 == " " }) }

            var code: String?
            if s.first == "(" , let close = s.firstIndex(of: ")") {
                code = String(s[s.index(after: s.startIndex)..<close])
                s = s[s.index(after: close)...].drop(while: { $0 == " " })
            }

            // Payee runs to a hard-separated `;` note, if any.
            var payee = String(s)
            var inlineNote: String?
            if let range = Self.hardSeparatedNoteRange(in: payee) {
                inlineNote = String(payee[range]).trimmingCharacters(in: .whitespaces)
                payee = String(payee[..<range.lowerBound])
            }
            payee = payee.trimmingCharacters(in: .whitespaces)
            for (regex, name) in payeeAliases {
                let whole = NSRange(payee.startIndex..., in: payee)
                if regex.firstMatch(in: payee, range: whole) != nil { payee = name; break }
            }

            var transaction = LedgerTransaction(date: date, payee: payee)
            transaction.auxDate = auxDate
            transaction.state = state
            transaction.code = code
            transaction.line = line
            if let inlineNote {
                let text = inlineNote.hasPrefix(";")
                    ? String(inlineNote.dropFirst()).trimmingCharacters(in: .whitespaces)
                    : inlineNote
                transaction.noteLines.append(text)
                absorb(note: text, intoTransaction: &transaction)
            }
            return transaction
        }

        /// The range of a `  ; note` tail (hard separator then semicolon).
        static func hardSeparatedNoteRange(in text: String) -> Range<String.Index>? {
            var index = text.startIndex
            while index < text.endIndex {
                if text[index] == ";" {
                    // Preceded by a tab or two spaces?
                    var back = index
                    var spaces = 0
                    while back > text.startIndex {
                        back = text.index(before: back)
                        if text[back] == "\t" { return index..<text.endIndex }
                        if text[back] == " " { spaces += 1; if spaces >= 2 { return index..<text.endIndex } }
                        else { break }
                    }
                }
                index = text.index(after: index)
            }
            return nil
        }

        // MARK: Postings

        mutating func parsePosting(_ content: String, line: Int) -> LedgerPosting? {
            var s = Substring(content)

            var state: LedgerState?
            if s.first == "*" , s.dropFirst().first == " " { state = .cleared; s = s.dropFirst(2) }
            else if s.first == "!", s.dropFirst().first == " " { state = .pending; s = s.dropFirst(2) }
            s = s.drop(while: { $0 == " " })

            // Split account from the rest at the first hard separator.
            var accountEnd: Substring.Index?
            var index = s.startIndex
            while index < s.endIndex {
                let character = s[index]
                if character == "\t" { accountEnd = index; break }
                if character == " " {
                    let next = s.index(after: index)
                    if next < s.endIndex, s[next] == " " { accountEnd = index; break }
                }
                index = s.index(after: index)
            }

            var accountText: String
            var remainder: Substring
            if let accountEnd {
                accountText = String(s[..<accountEnd]).trimmingCharacters(in: .whitespaces)
                remainder = s[accountEnd...].drop(while: { $0 == " " || $0 == "\t" })
            } else {
                accountText = String(s).trimmingCharacters(in: .whitespaces)
                remainder = Substring("")
            }

            var virtualKind = LedgerVirtualKind.real
            if accountText.hasPrefix("("), accountText.hasSuffix(")") {
                virtualKind = .unbalanced
                accountText = String(accountText.dropFirst().dropLast())
            } else if accountText.hasPrefix("["), accountText.hasSuffix("]") {
                virtualKind = .balanced
                accountText = String(accountText.dropFirst().dropLast())
            }
            if let full = aliases[accountText] { accountText = full }
            // Nested `apply account` blocks stack: A then B → `A:B:account`.
            let prefixes = accountPrefixStack.filter { !$0.isEmpty }
            if !prefixes.isEmpty {
                accountText = (prefixes + [accountText]).joined(separator: ":")
            }
            guard !accountText.isEmpty else {
                error(line, "posting has no account")
                return nil
            }

            var posting = LedgerPosting(account: accountText)
            posting.virtualKind = virtualKind
            posting.state = state
            posting.line = line

            // Inline note first (so `;` never confuses the amount scanner).
            var body = String(remainder)
            if let semicolon = body.firstIndex(of: ";") {
                let note = String(body[body.index(after: semicolon)...])
                    .trimmingCharacters(in: .whitespaces)
                posting.note = note
                absorb(note: note, intoPosting: &posting)
                body = String(body[..<semicolon])
            }
            body = body.trimmingCharacters(in: .whitespaces)

            // `= ASSERT` tail (single `=`, spaced).
            if let range = body.range(of: " = ") {
                let assertionText = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var styles = journal.styles
                guard let assertion = LedgerAmountSyntax.parse(
                    assertionText, decimalCommaDefault: decimalCommaDefault,
                    styles: &styles, observe: false) else {
                    error(line, "invalid balance assertion '\(assertionText)'")
                    return nil
                }
                posting.assertion = assertion
            } else if body.hasPrefix("= ") {
                // Assignment on an amount-less posting: `Account  = $500.00`.
                let assertionText = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                var styles = journal.styles
                guard let assertion = LedgerAmountSyntax.parse(
                    assertionText, decimalCommaDefault: decimalCommaDefault,
                    styles: &styles, observe: false) else {
                    error(line, "invalid balance assignment '\(assertionText)'")
                    return nil
                }
                posting.assertion = assertion
                posting.isAssignment = true
                body = ""
            }

            // `@`/`@@` cost (spaced), incl. virtual `(@)`/`(@@)`.
            if !body.isEmpty {
                for marker in [" (@@) ", " (@) ", " @@ ", " @ "] {
                    if let range = body.range(of: marker) {
                        let costText = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                        var styles = journal.styles
                        guard let costAmount = LedgerAmountSyntax.parse(
                            costText, decimalCommaDefault: decimalCommaDefault,
                            styles: &styles, observe: false) else {
                            error(line, "invalid cost '\(costText)'")
                            return nil
                        }
                        guard costAmount.quantity >= 0 else {
                            error(line, "a cost may not be negative")
                            return nil
                        }
                        let total = marker.contains("@@")
                        posting.cost = LedgerCost(kind: total ? .total : .perUnit,
                                                  amount: costAmount,
                                                  isVirtual: marker.contains("("))
                        break
                    }
                }
            }

            // Lot annotations after the amount: preserve raw.
            if !body.isEmpty {
                var annotation = ""
                while let open = body.firstIndex(where: { "{[".contains($0) }) {
                    let close: Character = body[open] == "{" ? "}" : "]"
                    guard let closeIndex = body[open...].firstIndex(of: close) else {
                        error(line, "unterminated lot annotation")
                        return nil
                    }
                    annotation += (annotation.isEmpty ? "" : " ")
                        + body[open...closeIndex]
                    body.removeSubrange(open...closeIndex)
                }
                if !annotation.isEmpty {
                    posting.lotAnnotation = annotation
                    warn(line, "lot annotation '\(annotation)' preserved but not priced")
                    body = body.trimmingCharacters(in: .whitespaces)
                }
            }

            if !body.isEmpty {
                var styles = journal.styles
                guard let amount = LedgerAmountSyntax.parse(
                    body, decimalCommaDefault: decimalCommaDefault,
                    styles: &styles, observe: true) else {
                    error(line, "invalid amount '\(body)'")
                    return nil
                }
                journal.styles = styles
                posting.amount = amount
            }
            return posting
        }

        /// Extracts tags, metadata, and bracketed date overrides from a note.
        func absorb(note: String, intoPosting posting: inout LedgerPosting) {
            var tags: [String] = []
            var metadata: [LedgerMetadata] = []
            var dates: (Date?, Date?) = (nil, nil)
            Self.scanNote(note, defaultYear: defaultYear, today: today,
                          tags: &tags, metadata: &metadata, dates: &dates)
            posting.tags.append(contentsOf: tags.filter { !posting.tags.contains($0) })
            posting.metadata.append(contentsOf: metadata)
            if let date = dates.0 { posting.dateOverride = date }
            if let aux = dates.1 { posting.auxDateOverride = aux }
        }

        func absorb(note: String, intoTransaction transaction: inout LedgerTransaction) {
            var tags: [String] = []
            var metadata: [LedgerMetadata] = []
            var dates: (Date?, Date?) = (nil, nil)
            Self.scanNote(note, defaultYear: defaultYear, today: today,
                          tags: &tags, metadata: &metadata, dates: &dates)
            transaction.tags.append(contentsOf: tags.filter { !transaction.tags.contains($0) })
            transaction.metadata.append(contentsOf: metadata)
        }

        static func scanNote(_ note: String, defaultYear: Int?, today: Date,
                             tags: inout [String], metadata: inout [LedgerMetadata],
                             dates: inout (Date?, Date?)) {
            let trimmed = note.trimmingCharacters(in: .whitespaces)
            // `[DATE]`, `[=EDATE]`, `[DATE=EDATE]`
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let inner = String(trimmed.dropFirst().dropLast())
                let parts = inner.split(separator: "=", maxSplits: 1,
                                        omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 {
                    dates.0 = parts[0].isEmpty ? nil
                        : LedgerDateParsing.parse(parts[0], defaultYear: defaultYear, today: today)
                    dates.1 = LedgerDateParsing.parse(parts[1], defaultYear: defaultYear, today: today)
                } else if parts.count == 1 {
                    dates.0 = LedgerDateParsing.parse(parts[0], defaultYear: defaultYear, today: today)
                }
                return
            }
            // `Key: value` / `Key:: value`
            if let colon = trimmed.firstIndex(of: ":"),
               colon != trimmed.startIndex,
               !trimmed[..<colon].contains(" ") {
                let afterColon = trimmed.index(after: colon)
                let isTyped = afterColon < trimmed.endIndex && trimmed[afterColon] == ":"
                let valueStart = isTyped ? trimmed.index(after: afterColon) : afterColon
                if valueStart < trimmed.endIndex, trimmed[valueStart] == " " {
                    let key = String(trimmed[..<colon])
                    let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
                    metadata.append(LedgerMetadata(key: key, value: value, isTyped: isTyped))
                    return
                }
            }
            // `:tag1:tag2:` runs anywhere in the note.
            for word in trimmed.split(separator: " ") {
                guard word.count >= 3, word.hasPrefix(":"), word.hasSuffix(":") else { continue }
                let inner = word.dropFirst().dropLast()
                guard !inner.isEmpty else { continue }
                for tag in inner.split(separator: ":") where !tag.isEmpty {
                    tags.append(String(tag))
                }
            }
        }

        // MARK: Resolution

        mutating func resolveAndAppend(_ transaction: inout LedgerTransaction, headerLine: Int) {
            // Contribution an explicit posting makes to its balance group.
            func contribution(of posting: LedgerPosting) -> LedgerAmount? {
                guard let amount = posting.amount else { return nil }
                guard let cost = posting.cost else { return amount }
                switch cost.kind {
                case .perUnit:
                    return LedgerAmount(commodity: cost.amount.commodity,
                                        quantity: amount.quantity * cost.amount.quantity)
                case .total:
                    let sign: Decimal = amount.quantity < 0 ? -1 : 1
                    return LedgerAmount(commodity: cost.amount.commodity,
                                        quantity: sign * cost.amount.quantity)
                }
            }

            // 1. Balance assignments become concrete amounts (file order).
            for index in transaction.postings.indices where transaction.postings[index].isAssignment {
                let posting = transaction.postings[index]
                guard let target = posting.assertion else { continue }
                let key = balanceKey(posting.account, target.commodity)
                let current = domainBalances(for: posting.virtualKind)[key] ?? 0
                let amount = LedgerAmount(commodity: target.commodity,
                                          quantity: target.quantity - current)
                transaction.postings[index].amount = amount
                journal.assignmentsResolved += 1
            }

            // 2. Elision per balance group (real; balanced-virtual).
            for group: LedgerVirtualKind in [.real, .balanced] {
                let members = transaction.postings.indices.filter {
                    transaction.postings[$0].virtualKind == group
                }
                guard !members.isEmpty else { continue }
                let elided = members.filter { transaction.postings[$0].amount == nil }
                var sums: [String: Decimal] = [:]
                for index in members {
                    if let contribution = contribution(of: transaction.postings[index]) {
                        sums[contribution.commodity, default: 0] += contribution.quantity
                    }
                }
                if elided.count > 1 {
                    error(headerLine, "only one posting may elide its amount")
                    return
                }
                if let elidedIndex = elided.first {
                    let amounts = sums.filter { $0.value != 0 }
                        .sorted { $0.key < $1.key }
                        .map { LedgerAmount(commodity: $0.key, quantity: -$0.value) }
                    transaction.postings[elidedIndex].resolvedAmounts = amounts
                    for amount in amounts { sums[amount.commodity, default: 0] += amount.quantity }
                } else if group == .real,
                          let residualCommodity = sums.first(where: { $0.value != 0 })?.key,
                          let bucket = bucketAccount {
                    // 3. Bucket balancing for an unbalanced real group.
                    var synthesized = LedgerPosting(account: bucket)
                    synthesized.isSynthesized = true
                    synthesized.line = headerLine
                    synthesized.resolvedAmounts = sums.filter { $0.value != 0 }
                        .sorted { $0.key < $1.key }
                        .map { LedgerAmount(commodity: $0.key, quantity: -$0.value) }
                    for amount in synthesized.resolvedAmounts {
                        sums[amount.commodity, default: 0] += amount.quantity
                    }
                    transaction.postings.append(synthesized)
                    _ = residualCommodity
                }

                let residual = sums.first { $0.value != 0 }
                if group == .real, let residual {
                    error(headerLine, "transaction does not balance (off by "
                        + "\(residual.value) \(residual.key.isEmpty ? "" : residual.key))")
                    return
                }
                if group == .balanced, let residual {
                    error(headerLine, "balanced-virtual postings do not balance (off by "
                        + "\(residual.value) \(residual.key.isEmpty ? "" : residual.key))")
                    return
                }
            }

            // 4. Fill resolvedAmounts for explicit postings.
            for index in transaction.postings.indices {
                if transaction.postings[index].resolvedAmounts.isEmpty,
                   let amount = transaction.postings[index].amount {
                    transaction.postings[index].resolvedAmounts = [amount]
                }
            }

            // 5. Update running balances and verify assertions in file order.
            for posting in transaction.postings {
                let isVirtual = posting.virtualKind != .real
                for amount in posting.resolvedAmounts {
                    let key = balanceKey(posting.account, amount.commodity)
                    if isVirtual { virtualBalances[key, default: 0] += amount.quantity }
                    else { realBalances[key, default: 0] += amount.quantity }
                }
                if let assertion = posting.assertion, !posting.isAssignment {
                    journal.assertionsChecked += 1
                    let key = balanceKey(posting.account, assertion.commodity)
                    let balances = posting.virtualKind == .real ? realBalances : virtualBalances
                    if assertion.commodity.isEmpty, assertion.quantity == 0 {
                        // `= 0` asserts every commodity of the account is zero.
                        let prefix = posting.account + "\u{1}"
                        let nonZero = balances.first {
                            $0.key.hasPrefix(prefix) && $0.value != 0
                        }
                        if let nonZero {
                            error(posting.line, "balance assertion failed for "
                                + "\(posting.account): "
                                + "\(nonZero.value) \(nonZero.key.split(separator: "\u{1}").last.map(String.init) ?? "") remains")
                        }
                    } else if (balances[key] ?? 0) != assertion.quantity {
                        error(posting.line, "balance assertion failed for \(posting.account): "
                            + "expected \(assertion.quantity) \(assertion.commodity), "
                            + "have \(balances[key] ?? 0)")
                    }
                }
            }

            journal.transactions.append(transaction)
        }

        func domainBalances(for kind: LedgerVirtualKind) -> [String: Decimal] {
            kind == .real ? realBalances : virtualBalances
        }

        func balanceKey(_ account: String, _ commodity: String) -> String {
            account + "\u{1}" + commodity
        }

        // MARK: Dates

        func parseDate(_ token: String, time: String?) -> Date? {
            LedgerDateParsing.parse(token, time: time, defaultYear: defaultYear, today: today)
        }

        static func splitOnWhitespace(_ text: String) -> [String] {
            text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }

        static func unquote(_ text: String) -> String {
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                return String(text.dropFirst().dropLast())
            }
            return text
        }
    }
}

/// Ledger date parsing (format ref §10): `/`, `-`, `.` separators normalise
/// to `/`; forms `%Y/%m/%d`, `%y/%m/%d`, `%Y/%m`, `%m/%d`; the yearless form
/// takes the `year` directive's year, else today's. Dates are UTC midnights
/// (the convention every importer in this package shares).
enum LedgerDateParsing {

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    static func parse(_ token: String, time: String? = nil,
                      defaultYear: Int?, today: Date) -> Date? {
        let normalized = token.replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: ".", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }

        var components = DateComponents()
        let calendar = utc
        switch parts.count {
        case 3:
            guard var year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
            else { return nil }
            if parts[0].count <= 2 {   // %y: strptime pivot 69
                year = year >= 69 ? 1900 + year : 2000 + year
            }
            components.year = year; components.month = month; components.day = day
        case 2:
            guard let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
            if parts[0].count == 4 {   // %Y/%m → first of the month
                components.year = a; components.month = b; components.day = 1
            } else {                   // %m/%d + inferred year
                components.year = defaultYear ?? calendar.component(.year, from: today)
                components.month = a; components.day = b
            }
        default:
            return nil
        }
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day) else { return nil }

        if let time {
            let bits = time.split(separator: ":").map(String.init)
            guard bits.count == 3, let hour = Int(bits[0]), let minute = Int(bits[1]),
                  let second = Int(bits[2]) else { return nil }
            components.hour = hour; components.minute = minute; components.second = second
        }
        return calendar.date(from: components)
    }

    static func format(_ date: Date, includeTime: Bool = false) -> String {
        let calendar = utc
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        guard includeTime else { return day }
        return day + String(format: " %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
