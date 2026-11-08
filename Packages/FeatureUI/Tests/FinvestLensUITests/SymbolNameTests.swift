//
//  SymbolNameTests.swift
//  FinvestLens — FeatureUI
//
//  Every SF Symbol name the app spells is one the system can draw. A name SF
//  Symbols does not have compiles, draws nothing, and is noticed only as a
//  blank and a "No symbol named …" line in the log: Payable Aging's
//  `building.2.crop.circle.badge.clock` shipped that way in 1.2 (4 Nov 2026).
//  The report icons were checked after that; the other 180-odd names in the
//  app — sidebar destinations, toolbar buttons, chart keys, the widgets — were
//  not, and a test that listed them would miss the next one added. So the
//  sources are read, and every literal in a symbol position is checked: the
//  argument of a `systemName:`, `systemImage:`, `symbol:` or `icon:` label —
//  a `? :` choice wrapped onto the next line included — and what a property
//  or function named like `symbol` or `icon` returns. A name handed to a
//  helper without one of those labels is out of its sight, so helpers take
//  theirs as `symbol:` (`RegisterSheet`'s did not, and eight names went
//  unchecked). Asked of AppKit's own symbol set, so it runs where the package
//  suite does.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import FinvestLensUI

@Suite("Symbol names are real symbols")
struct SymbolNameTests {

    @Test("Each report kind's icon names a symbol the system draws", arguments: ReportKind.allCases)
    func reportIcon(kind: ReportKind) {
        #expect(NSImage(systemSymbolName: kind.icon, accessibilityDescription: nil) != nil,
                "\(kind.rawValue): \(kind.icon)")
    }

    @Test("Every symbol name spelled in the app's sources is one the system draws")
    func everySymbolInTheSources() throws {
        let found = try SourceSymbols.scan()
        // A scan that has stopped seeing names passes vacuously; there were
        // 186 distinct names when this was written.
        #expect(found.count > 150, "the scan found only \(found.count) symbol names")
        for symbol in found where NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil) == nil {
            Issue.record("\(symbol.at): no symbol named \(symbol.name)")
        }
    }

    @Test("The scan takes the names in symbol positions, and nothing else")
    func scanner() {
        let source = #"""
        Image(systemName: isOn ? "eye" : "eye.slash")
        Image(systemName: expanded
              ? "chevron.down" : "chevron.right")
            .imageScale(.small)
        row(count: 1, icon: "rectangle.dashed",
            title: "not.this.one")
        Label("Delete", systemImage: "trash")
        Image(systemName: "\(base).fill")
        ChartKeyMark("Average cost", symbol: "minus", colour: .secondary)
        UserDefaults.standard.set(true, forKey: "appearance.accent")
        var symbol: String {
            switch glyph {
            case "c", "y": "checkmark.circle"   // "nope" is a comment
            /* "also.nope" */
            default: "circle.dotted"
            }
        }
        var title: String { "not.a.symbol.position" }
        """#
        let names = SourceSymbols.names(in: source, file: "Fixture.swift").map(\.name)
        #expect(names == ["eye", "eye.slash", "chevron.down", "chevron.right", "rectangle.dashed", "trash", "minus",
                          "checkmark.circle", "circle.dotted"])
    }
}

/// Reads the app's Swift sources for SF Symbol names: the argument of a
/// `systemName:`, `systemImage:`, `symbol:` or `icon:` label, and whatever a
/// property or function named like `symbol` or `icon` returns as a `String`.
/// Comments are skipped, so is an interpolated name, and so is a `case`
/// pattern's literal (it is the value switched on, not a symbol).
enum SourceSymbols {
    struct Found: Equatable {
        let name: String
        let at: String
    }

    /// Every distinct name in the shipped UI sources, with where it was first seen.
    static func scan() throws -> [Found] {
        // …/Packages/FeatureUI/Tests/FinvestLensUITests/SymbolNameTests.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        var found: [Found] = []
        var seen = Set<String>()
        for directory in ["Packages/FeatureUI/Sources", "finvestlens", "FinvestLensWidgets", "FinvestLensQuickLook"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let file = String(url.path.dropFirst(root.path.count + 1))
                for symbol in names(in: try String(contentsOf: url, encoding: .utf8), file: file)
                where seen.insert(symbol.name).inserted {
                    found.append(symbol)
                }
            }
        }
        return found
    }

    /// The names in one source text, in order of appearance.
    static func names(in text: String, file: String) -> [Found] {
        let bytes = Array(text.utf8)
        let (code, literals) = mask(bytes)
        var spans: [Range<Int>] = []

        // `systemName: …`, `systemImage: …`, `symbol: …` — the argument, to the
        // comma, parenthesis or line end that closes it.
        for label in ["systemName:", "systemImage:", "symbol:", "icon:"] {
            for start in occurrences(of: Array(label.utf8), in: code) where !isIdentifier(code, before: start) {
                let from = start + label.utf8.count
                spans.append(from..<argumentEnd(code, from: from))
            }
        }
        // `var symbol: String { … }`, `func icon(for …) -> String { … }`.
        let returning = ["symbol", "selectedSymbol", "keySymbol", "icon", "handleSymbol", "systemImage"]
        for keyword in ["var ", "func "] {
            for start in occurrences(of: Array(keyword.utf8), in: code) where !isIdentifier(code, before: start) {
                var cursor = start + keyword.utf8.count
                while cursor < code.count, code[cursor] == UInt8(ascii: " ") { cursor += 1 }
                var nameEnd = cursor
                while nameEnd < code.count, isIdentifierByte(code[nameEnd]) { nameEnd += 1 }
                guard returning.contains(String(decoding: code[cursor..<nameEnd], as: UTF8.self)),
                      let brace = code[nameEnd...].firstIndex(where: { [UInt8(ascii: "{"), UInt8(ascii: "="), UInt8(ascii: "\n")].contains($0) }),
                      code[brace] == UInt8(ascii: "{"),
                      String(decoding: code[nameEnd..<brace], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces).hasSuffix("String")
                else { continue }
                spans.append(brace..<blockEnd(code, from: brace))
            }
        }

        var found: [Found] = []
        for literal in literals where spans.contains(where: { $0.contains(literal.offset) }) {
            guard !literal.value.contains("\\("), isSymbolShaped(literal.value),
                  !isCasePattern(code, at: literal.offset) else { continue }
            let line = bytes[..<literal.offset].count { $0 == UInt8(ascii: "\n") } + 1
            found.append(Found(name: literal.value, at: "\(file):\(line)"))
        }
        return found
    }

    /// The source with comments blanked and string contents replaced, so
    /// brackets in either cannot unbalance a count; and the string literals,
    /// by the offset of their opening quote. Single-line literals only —
    /// a symbol name is never a multi-line string.
    private static func mask(_ bytes: [UInt8]) -> (code: [UInt8], literals: [(offset: Int, value: String)]) {
        var code = bytes
        var literals: [(offset: Int, value: String)] = []
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), quote = UInt8(ascii: "\""),
            newline = UInt8(ascii: "\n"), backslash = UInt8(ascii: "\\")
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == slash, next == slash {
                while index < bytes.count, bytes[index] != newline { code[index] = UInt8(ascii: " "); index += 1 }
            } else if byte == slash, next == star {
                var depth = 0
                repeat {
                    if bytes[index] == slash, index + 1 < bytes.count, bytes[index + 1] == star { depth += 1 }
                    if bytes[index] == star, index + 1 < bytes.count, bytes[index + 1] == slash {
                        depth -= 1
                        code[index] = UInt8(ascii: " "); code[index + 1] = UInt8(ascii: " ")
                        index += 2
                        continue
                    }
                    if bytes[index] != newline { code[index] = UInt8(ascii: " ") }
                    index += 1
                } while index < bytes.count && depth > 0
            } else if byte == quote {
                var end = index + 1
                while end < bytes.count, bytes[end] != quote, bytes[end] != newline {
                    end += bytes[end] == backslash ? 2 : 1
                }
                end = min(end, bytes.count)
                literals.append((index, String(decoding: bytes[(index + 1)..<end], as: UTF8.self)))
                for inner in (index + 1)..<end { code[inner] = UInt8(ascii: "_") }
                index = end + 1
            } else {
                index += 1
            }
        }
        return (code, literals)
    }

    private static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard needle.count <= haystack.count else { return [] }
        return (0...(haystack.count - needle.count)).filter { start in
            haystack[start] == needle[0] && Array(haystack[start..<(start + needle.count)]) == needle
        }
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_")
    }

    private static func isIdentifier(_ code: [UInt8], before index: Int) -> Bool {
        index > 0 && isIdentifierByte(code[index - 1])
    }

    /// Where an argument stops: a comma or closing bracket at its own depth,
    /// or the end of the line — unless a `? :` choice goes on to the next.
    private static func argumentEnd(_ code: [UInt8], from start: Int) -> Int {
        var depth = 0
        var index = start
        while index < code.count {
            switch code[index] {
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                if depth == 0 { return index }
                depth -= 1
            case UInt8(ascii: ","):
                if depth == 0 { return index }
            case UInt8(ascii: "\n"):
                if depth == 0, !continuesOnNextLine(code, at: index) { return index }
            default: break
            }
            index += 1
        }
        return index
    }

    /// Whether the expression at a line break goes on: a `? :` choice wrapped
    /// onto the next line, by either of its operators, or a label whose value
    /// starts on the next line.
    private static func continuesOnNextLine(_ code: [UInt8], at newline: Int) -> Bool {
        let blank: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        let operators: Set<UInt8> = [UInt8(ascii: "?"), UInt8(ascii: ":")]
        var before = newline - 1
        while before >= 0, blank.contains(code[before]) { before -= 1 }
        var after = newline + 1
        while after < code.count, blank.contains(code[after]) { after += 1 }
        return (before >= 0 && operators.contains(code[before]))
            || (after < code.count && operators.contains(code[after]))
    }

    /// The offset after the brace that closes the one at `start`.
    private static func blockEnd(_ code: [UInt8], from start: Int) -> Int {
        var depth = 0
        for index in start..<code.count {
            if code[index] == UInt8(ascii: "{") { depth += 1 }
            if code[index] == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
        }
        return code.count
    }

    /// SF Symbols names are lower case, dot-separated words and numbers.
    private static func isSymbolShaped(_ text: String) -> Bool {
        !text.isEmpty && text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) }
        }
    }

    /// Whether the literal is part of a `case` pattern: `case` earlier on its
    /// line, and no colon between the two.
    private static func isCasePattern(_ code: [UInt8], at offset: Int) -> Bool {
        let lineStart = code[..<offset].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        let before = String(decoding: code[lineStart..<offset], as: UTF8.self)
        guard let range = before.range(of: "case ", options: .backwards) else { return false }
        return !before[range.upperBound...].contains(":")
    }
}
#endif
