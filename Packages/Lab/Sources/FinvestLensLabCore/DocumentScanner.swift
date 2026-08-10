//
//  DocumentScanner.swift
//  FinvestLens — Lab
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit

/// A file worth offering to the matcher, and the date we believe it belongs to.
struct ScannedDocument: Sendable, Equatable {
    var url: URL
    var date: Date?
    /// How the date was worked out — reported so a wrong window is diagnosable
    /// without re-deriving it by hand.
    var dateSource: DocumentDate.Source
    var bytes: Int64
}

/// Works out which period a document belongs to, from its name.
///
/// This exists because modification time lies. In the Finance tree most
/// genuine January–April 2026 statements carry May–July mtimes (they were
/// bulk-downloaded later), while a pile of 2024–2025 statements carry January
/// 2026 mtimes (they were bulk-downloaded then). Sorting on mtime gets both
/// halves wrong.
///
/// Names, by contrast, are written by the institution that issued the document
/// and say what the document *is*. So the rules below run most-semantic first,
/// and a bare `YYYY-MM-DD` anywhere in the name is deliberately near the
/// bottom: registries suffix a download timestamp, and a Plato statement
/// called `…period end 31 january 2026 eft-…-2026-05-01_17-25-58.pdf` belongs
/// to January whatever the tail says.
enum DocumentDate {

    enum Source: String, Sendable, Equatable {
        case leadingDate       = "leading date"
        case periodEnd         = "period end"
        case underscoreDate    = "advice date"
        case compactDate       = "compact date"
        case spelledDate       = "spelled date"
        case anyISODate        = "date in name"
        case folderMonth       = "folder month"
        case modified          = "modified time"
        case none              = "unknown"
    }

    /// The date a document belongs to, and how we decided.
    static func infer(name: String, folder: String, modified: Date?) -> (date: Date?, source: Source) {
        // 1. `2026-01-02 Woolworths.png` — the naming convention used for
        //    receipts, and the most reliable date there is.
        if let date = match(Pattern.leadingISO, in: name, order: .ymd) {
            return (date, .leadingDate)
        }
        // 2. `…period end 31 January 2026…` — the registry's own statement of
        //    which period this is, and it outranks any timestamp beside it.
        if let range = name.range(of: "period end", options: .caseInsensitive) {
            let tail = String(name[range.upperBound...])
            if let date = spelledDate(in: tail) { return (date, .periodEnd) }
        }
        // 3. `CBA_Dividend_Advice_2026_03_30.pdf`, `YMAX_Distribution_Advice_2026_04_20.pdf`
        if let date = match(Pattern.underscore, in: name, order: .ymd) {
            return (date, .underscoreDate)
        }
        // 4. `Statements20260111.pdf` — but not `img20260207_20452286.png`.
        //    A flatbed scanner stamps the moment it scanned, which is not the
        //    date of the thing it scanned: that receipt is filed under
        //    `2026-01 VISA` and was put on the glass three weeks later. Same
        //    trap as the download stamp above, so it gets the same answer —
        //    fall through and let the folder say which month this belongs to.
        if !isScannerStamp(name),
           let date = match(Pattern.compact, in: name, order: .ymd) {
            return (date, .compactDate)
        }
        // 5. `17 Mar 2026 Dist payt.pdf`, `19 Jan 2026 dist payt.pdf`
        if let date = spelledDate(in: name) { return (date, .spelledDate) }
        // 6. Any ISO date in the name — usually a download stamp, so last of
        //    the name-derived rules.
        if let date = match(Pattern.anyISO, in: name, order: .ymd) {
            return (date, .anyISODate)
        }
        // 7. `2026-01 VISA` — the folder the person filed it under.
        if let date = match(Pattern.folderMonth, in: folder, order: .ym) {
            return (date, .folderMonth)
        }
        if let modified { return (modified, .modified) }
        return (nil, .none)
    }

    /// `img20260207_20452286.png` — a flatbed scanner's own filename.
    ///
    /// Matched narrowly, on the whole shape rather than the `img` prefix
    /// alone: `Statements20260111.pdf` is also letters followed by eight
    /// digits, and that one genuinely is the statement's date.
    private static func isScannerStamp(_ name: String) -> Bool {
        guard let regex = Pattern.scannerStamp else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private enum Order { case ymd, ym }

    /// The name patterns, compiled once.
    ///
    /// `infer` runs per file over a whole document tree, and each rule it tried
    /// used to compile its pattern afresh — up to seven `NSRegularExpression`
    /// builds per file, none of which the scan needs to repeat.
    private enum Pattern {
        static let leadingISO = regex(#"^(\d{4})-(\d{2})-(\d{2})"#)
        static let underscore = regex(#"(\d{4})_(\d{2})_(\d{2})"#)
        static let compact = regex(#"(?<!\d)(20\d{2})(\d{2})(\d{2})(?!\d)"#)
        static let anyISO = regex(#"(\d{4})-(\d{2})-(\d{2})"#)
        static let folderMonth = regex(#"(\d{4})-(\d{2})(?!\d)"#)
        static let scannerStamp = regex(#"(?i)^img\d{8}_\d{6,}"#)
        static let spelled = regex(
            #"(?i)(?:(\d{1,2})\s+)?([a-z]{3,9})\.?\s+(?:(\d{1,2}),?\s+)?(\d{4})"#)

        private static func regex(_ pattern: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern)
        }
    }

    private static func match(_ regex: NSRegularExpression?, in text: String, order: Order) -> Date? {
        guard let regex,
              let hit = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ index: Int) -> Int? {
            guard let range = Range(hit.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
        guard let year = group(1), let month = group(2) else { return nil }
        let day = order == .ymd ? group(3) : 1
        return date(year: year, month: month, day: day ?? 1)
    }

    private static let monthNames = ["january", "february", "march", "april", "may", "june",
                                     "july", "august", "september", "october", "november", "december"]

    /// `31 January 2026` or `17 Mar 2026`, in either order.
    private static func spelledDate(in text: String) -> Date? {
        guard let regex = Pattern.spelled else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        for hit in regex.matches(in: text, range: whole) {
            func group(_ index: Int) -> String? {
                guard let range = Range(hit.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
            // The month name must start with the word, which accepts both the
            // full name and any abbreviation of it ("mar", "sept"). The
            // converse test — the word starting with the month's first three
            // letters — accepted any word that merely opened that way, so
            // "Marsh 2026.pdf" was filed as 1 March and "Decision 2026.pdf" as
            // 1 December, with `dateSource` reporting "spelled date" as though
            // the filename had said so.
            guard let monthWord = group(2)?.lowercased(),
                  let index = monthNames.firstIndex(where: { $0.hasPrefix(monthWord) }),
                  let year = group(4).flatMap(Int.init)
            else { continue }
            let day = (group(1) ?? group(3)).flatMap(Int.init) ?? 1
            if let date = date(year: year, month: index + 1, day: day) { return date }
        }
        return nil
    }

    private static func date(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (1900...2200).contains(year) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        // `date(from:)` is lenient — 31 February rolls forward to 3 March, and
        // a filename naming a day that does not exist has not told us a date.
        // Round-trip it rather than trust the roll-over.
        guard let date = Calendar.current.date(from: components) else { return nil }
        let back = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }
}

/// Finds the documents in a folder tree that belong to a period, once each.
enum DocumentScanner {

    static let readableExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"]

    /// Filename tokens that mark a document as an income event rather than a
    /// purchase. Used only to *select* files for a run; what the document
    /// actually is remains the extractor's call.
    static let dividendTokens = ["dividend", "distribution", "dist ", "advice", "payment", "payt", "drp"]

    enum Kind: String, Sendable { case any, invoice, dividend }

    /// Every readable document under `root` whose inferred date falls inside
    /// the window, deduplicated by content.
    ///
    /// Deduplication is not a nicety here: the Invoices tree keeps 97 byte-identical
    /// copies of January and March receipts loose in its root alongside the
    /// filed originals. Matching both copies of a receipt would claim two
    /// different transactions for one purchase — the second necessarily wrong.
    static func scan(root: URL, since: Date?, until: Date?, kind: Kind = .any,
                     limit: Int? = nil) throws -> (documents: [ScannedDocument], duplicates: Int, outOfPeriod: Int) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw LabError.notFound(root)
        }

        var found: [ScannedDocument] = []
        var outOfPeriod = 0
        for case let url as URL in walker {
            guard readableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }

            let name = url.lastPathComponent
            if kind != .any {
                let lowered = name.lowercased()
                let looksLikeDividend = dividendTokens.contains { lowered.contains($0) }
                if (kind == .dividend) != looksLikeDividend { continue }
            }

            let folder = url.deletingLastPathComponent().lastPathComponent
            let (date, source) = DocumentDate.infer(name: name, folder: folder,
                                                    modified: values?.contentModificationDate)
            if let date {
                if let since, date < since { outOfPeriod += 1; continue }
                // `until` is inclusive of the whole day.
                if let until, date >= Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until {
                    outOfPeriod += 1; continue
                }
            } else if since != nil || until != nil {
                outOfPeriod += 1
                continue
            }
            found.append(ScannedDocument(url: url, date: date, dateSource: source,
                                         bytes: Int64(values?.fileSize ?? 0)))
        }

        // Deepest path wins a tie: a receipt filed under `2026-01 VISA` is the
        // one the person meant to keep; the copy loose in the root is spill.
        found.sort {
            let leftDepth = $0.url.pathComponents.count, rightDepth = $1.url.pathComponents.count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return $0.url.path < $1.url.path
        }

        // Hash every candidate. A size-first shortcut would be faster but
        // wrong in the one case that matters — two different receipts that
        // happen to share a byte count would collide — and these trees are
        // tens of megabytes, where the whole scan costs less than one OCR.
        var seen: Set<String> = []
        var unique: [ScannedDocument] = []
        var duplicates = 0
        for document in found {
            guard let digest = try? contentHash(of: document.url) else {
                unique.append(document)          // unreadable: let the matcher report it
                continue
            }
            if seen.insert(digest).inserted {
                unique.append(document)
            } else {
                duplicates += 1
            }
        }

        unique.sort { ($0.date ?? .distantPast, $0.url.path) < ($1.date ?? .distantPast, $1.url.path) }
        if let limit, unique.count > limit { unique = Array(unique.prefix(limit)) }
        return (unique, duplicates, outOfPeriod)
    }

    private static func contentHash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
