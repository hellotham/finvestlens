//
//  Renderers.swift
//  FinvestLens — CLI
//
//  The core-80 command outputs, in ledger's layouts
//  (docs/ledger-cli-reference.md §2): balance's right-justified 20-column
//  totals with 2-space tree indent, single-child chain elision and the
//  20-dash separator; register's date/payee/account/amount/running-total
//  columns with width distribution; cleared's three columns; print via the
//  shared canonical writer. Familiar, not byte-identical (design G-L4) —
//  these layouts are pinned by golden tests so they cannot drift.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange

public enum Renderers {

    // MARK: Shared formatting

    /// Ledger prints amounts as `SYMBOL AMOUNT` with thousands separators —
    /// e.g. `$ 1,396.00`, `10 BHP`.
    public static func amount(_ value: Decimal, _ commodity: Commodity) -> String {
        let fraction = max(1, commodity.smallestFraction)
        var digits = 0
        var scale = fraction
        while scale > 1 { scale /= 10; digits += 1 }

        let rounded = commodity.round(value)
        var text = NSDecimalNumber(decimal: abs(rounded)).stringValue
        var parts = text.split(separator: ".", maxSplits: 1).map(String.init)
        var integer = parts.first ?? "0"
        var fractionText = parts.count > 1 ? parts[1] : ""
        while fractionText.count < digits { fractionText.append("0") }
        if integer.count > 3 {
            var grouped = ""
            for (offset, character) in integer.reversed().enumerated() {
                if offset > 0, offset % 3 == 0 { grouped.append(",") }
                grouped.append(character)
            }
            integer = String(grouped.reversed())
        }
        text = integer + (fractionText.isEmpty ? "" : "." + fractionText)
        let sign = rounded < 0 ? "-" : ""
        parts = []
        let symbol = commodity.mnemonic
        // Currency-ish symbols lead; tickers follow the number, as ledger does.
        if symbol.count == 1 || symbol.hasSuffix("$") {
            return "\(sign)\(symbol) \(text)"
        }
        return "\(sign)\(text) \(symbol)"
    }

    static func multiAmount(_ amounts: [String: Decimal], book: Book) -> [String] {
        amounts.filter { $0.value != 0 }
            .sorted { $0.key < $1.key }
            .map { mnemonic, value in
                let commodity = book.commodities.first { $0.mnemonic == mnemonic }
                    ?? Commodity(namespace: .currency, mnemonic: mnemonic,
                                 fullName: mnemonic, smallestFraction: 100)
                return amount(value, commodity)
            }
    }

    public static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    public static func padRight(_ text: String, to width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }

    /// Ledger's register date style: `26-Jul-04`.
    static func registerDate(_ date: Date, format: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format ?? "yy-MMM-dd"
        return formatter.string(from: date)
    }

    /// Abbreviates a long account path from the left, ledger-style:
    /// `Ex:Food:Groceries`.
    static func abbreviate(_ path: String, to width: Int) -> String {
        guard path.count > width else { return path }
        var components = path.split(separator: ":").map(String.init)
        var index = 0
        while components.joined(separator: ":").count > width, index < components.count - 1 {
            let component = components[index]
            if component.count > 2 { components[index] = String(component.prefix(2)) }
            index += 1
        }
        let joined = components.joined(separator: ":")
        return joined.count <= width ? joined : String(joined.suffix(width))
    }

    // MARK: balance

    public static func balance(_ pipeline: ReportPipeline, book: Book) -> String {
        let options = pipeline.request.options
        var totals = pipeline.balances()

        // Roll subtree totals up into every ancestor.
        var rolled: [String: [String: Decimal]] = [:]
        for (path, amounts) in totals {
            var components = path.split(separator: ":").map(String.init)
            while !components.isEmpty {
                let ancestor = components.joined(separator: ":")
                for (mnemonic, value) in amounts {
                    rolled[ancestor, default: [:]][mnemonic, default: 0] += value
                }
                components.removeLast()
            }
        }
        if options.flat {
            rolled = totals   // own activity only, full names
        }
        var ownActivity = Set(totals.keys)
        totals = [:]

        // `--depth N` folds every account deeper than N path components into
        // its N-component ancestor (a display fold, not a filter).
        if let maximum = options.depth, maximum > 0 {
            func truncate(_ path: String) -> String {
                let components = path.split(separator: ":").map(String.init)
                return components.prefix(maximum).joined(separator: ":")
            }
            var folded: [String: [String: Decimal]] = [:]
            for (path, amounts) in rolled {
                let components = path.split(separator: ":").count
                guard components <= maximum else { continue }   // already in an ancestor
                for (mnemonic, value) in amounts {
                    folded[path, default: [:]][mnemonic, default: 0] += value
                }
            }
            rolled = folded
            ownActivity = Set(ownActivity.map(truncate))
        }

        var lines: [String] = []

        func isEmpty(_ amounts: [String: Decimal]) -> Bool {
            amounts.values.allSatisfy { $0 == 0 }
        }

        if options.flat {
            for path in rolled.keys.sorted() {
                let amounts = rolled[path] ?? [:]
                if !options.empty, isEmpty(amounts) { continue }
                lines.append(contentsOf: row(path: path, display: path, depth: 0,
                                             amounts: amounts, book: book))
            }
        } else {
            // Tree walk with single-child chain elision.
            let allPaths = Set(rolled.keys)
            func children(of path: String) -> [String] {
                let prefix = path.isEmpty ? "" : path + ":"
                let depth = path.isEmpty ? 1 : path.split(separator: ":").count + 1
                return allPaths.filter {
                    $0.hasPrefix(prefix) && $0.split(separator: ":").count == depth
                }.sorted()
            }
            func walk(_ path: String, display: String, depth: Int) {
                let amounts = rolled[path] ?? [:]
                let kids = children(of: path)
                if !options.empty, isEmpty(amounts), kids.isEmpty { return }
                // Elision: an intermediate account with no postings of its own
                // and exactly one child prints as `Parent:Child`.
                if kids.count == 1, !ownActivity.contains(path) {
                    let child = kids[0]
                    let tail = child.split(separator: ":").last.map(String.init) ?? child
                    walk(child, display: display + ":" + tail, depth: depth)
                    return
                }
                lines.append(contentsOf: row(path: path, display: display, depth: depth,
                                             amounts: amounts, book: book))
                for child in kids {
                    let tail = child.split(separator: ":").last.map(String.init) ?? child
                    walk(child, display: tail, depth: depth + 1)
                }
            }
            for root in children(of: "") {
                walk(root, display: root, depth: 0)
            }
        }

        var out = lines.joined(separator: "\n")
        if !options.noTotal {
            var grand: [String: Decimal] = [:]
            for (path, amounts) in rolled where !path.contains(":") {
                for (mnemonic, value) in amounts { grand[mnemonic, default: 0] += value }
            }
            if options.flat {
                grand = [:]
                for amounts in rolled.values {
                    for (mnemonic, value) in amounts { grand[mnemonic, default: 0] += value }
                }
            }
            if !lines.isEmpty { out += "\n" }
            out += String(repeating: "-", count: 20) + "\n"
            let totalLines = multiAmount(grand, book: book)
            out += totalLines.isEmpty ? pad("0", to: 20)
                                      : totalLines.map { pad($0, to: 20) }.joined(separator: "\n")
        }
        return out.isEmpty ? "" : out + "\n"
    }

    static func row(path: String, display: String, depth: Int,
                    amounts: [String: Decimal], book: Book) -> [String] {
        let indent = String(repeating: " ", count: depth * 2)
        let rendered = multiAmount(amounts, book: book)
        guard !rendered.isEmpty else { return [pad("0", to: 20) + "  " + indent + display] }
        // Multi-commodity: stack, account name on the last line.
        return rendered.enumerated().map { index, text in
            index == rendered.count - 1
                ? pad(text, to: 20) + "  " + indent + display
                : pad(text, to: 20)
        }
    }

    // MARK: register

    public static func register(_ pipeline: ReportPipeline, book: Book) -> String {
        let options = pipeline.request.options
        let width = options.columns ?? terminalWidth()
        let dateWidth = options.dateWidth ?? 9
        let payeeWidth = options.payeeWidth ?? max(12, Int(Double(width) * 0.263))
        let amountWidth = options.amountWidth ?? max(12, Int(Double(width) * 0.158))
        let accountWidth = options.accountWidth
            ?? max(12, width - dateWidth - payeeWidth - amountWidth * 2 - 4)

        var lines: [String] = []
        var lastTransaction: GncGUID?

        let postings = pipeline.postings()
        if let interval = pipeline.interval {
            return periodicRegister(postings, interval: interval, pipeline: pipeline,
                                    book: book, widths: (dateWidth, payeeWidth, accountWidth, amountWidth))
        }
        if options.subtotal {
            return subtotalRegister(postings, book: book,
                                    widths: (dateWidth, payeeWidth, accountWidth, amountWidth))
        }

        for posting in postings {
            let running = posting.runningTotals
            let sameTransaction = lastTransaction == posting.transaction.guid
            lastTransaction = posting.transaction.guid

            let dateText = sameTransaction ? "" : registerDate(posting.date, format: options.dateFormat)
            let payeeText = sameTransaction ? "" : posting.transaction.transactionDescription
            let accountText = abbreviate(posting.account?.fullName ?? "<none>", to: accountWidth)
            let amountText = amount(posting.amount, posting.commodity)
            let totals = multiAmount(running, book: book)

            var line = padRight(dateText, to: dateWidth) + " "
                + padRight(payeeText, to: payeeWidth) + " "
                + padRight(accountText, to: accountWidth) + " "
                + pad(amountText, to: amountWidth) + " "
                + pad(totals.last ?? "0", to: amountWidth)
            // Extra running-total commodities stack under the total column.
            if totals.count > 1 {
                let prefixWidth = dateWidth + payeeWidth + accountWidth + amountWidth + 4
                for extra in totals.dropLast() {
                    line += "\n" + String(repeating: " ", count: prefixWidth) + pad(extra, to: amountWidth)
                }
            }
            lines.append(line)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func subtotalRegister(_ postings: [ReportPosting], book: Book,
                                 widths: (Int, Int, Int, Int)) -> String {
        var byAccount: [String: [String: Decimal]] = [:]
        for posting in postings {
            byAccount[posting.account?.fullName ?? "<none>", default: [:]][posting.commodity.mnemonic, default: 0]
                += posting.amount
        }
        var lines: [String] = []
        for account in byAccount.keys.sorted() {
            let rendered = multiAmount(byAccount[account] ?? [:], book: book)
            for text in rendered {
                lines.append(padRight("", to: widths.0) + " "
                    + padRight("", to: widths.1) + " "
                    + padRight(abbreviate(account, to: widths.2), to: widths.2) + " "
                    + pad(text, to: widths.3))
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func periodicRegister(_ postings: [ReportPosting], interval: PeriodInterval,
                                 pipeline: ReportPipeline, book: Book,
                                 widths: (Int, Int, Int, Int)) -> String {
        guard let first = postings.first?.date, let last = postings.last?.date else { return "" }
        let bounds = pipeline.window
        let start = bounds.begin ?? first
        let end = bounds.end ?? PeriodExpression.utc.date(byAdding: .day, value: 1, to: last)!
        let buckets = PeriodExpression.buckets(interval: interval, from: start, to: end)

        var lines: [String] = []
        for bucket in buckets {
            let inBucket = postings.filter { $0.date >= bucket.start && $0.date < bucket.end }
            guard !inBucket.isEmpty else { continue }
            var byAccount: [String: [String: Decimal]] = [:]
            for posting in inBucket {
                byAccount[posting.account?.fullName ?? "<none>", default: [:]][posting.commodity.mnemonic, default: 0]
                    += posting.amount
            }
            var first = true
            for account in byAccount.keys.sorted() {
                for text in multiAmount(byAccount[account] ?? [:], book: book) {
                    let label = first
                        ? registerDate(bucket.start, format: nil)
                        : ""
                    let payee = first
                        ? "- " + registerDate(PeriodExpression.utc.date(byAdding: .day, value: -1,
                                                                        to: bucket.end)!, format: nil)
                        : ""
                    lines.append(padRight(label, to: widths.0) + " "
                        + padRight(payee, to: widths.1) + " "
                        + padRight(abbreviate(account, to: widths.2), to: widths.2) + " "
                        + pad(text, to: widths.3))
                    first = false
                }
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: print / csv

    public static func print(_ pipeline: ReportPipeline, book: Book,
                             extras: SourceExtras) -> String {
        let options = pipeline.request.options
        if options.raw, let journal = extras.journals.first {
            return LedgerWriter.write(journal)
        }
        // Only the matched transactions, in report order, through the
        // canonical writer. Built from the postings rather than by filtering
        // a whole-book export: that both respects the query (the export
        // writes its guid as a note line, so a metadata filter matched
        // nothing and kept everything) and skips converting 46,000
        // transactions to print five. Forecast rows come along for free.
        var seen = Set<GncGUID>()
        var journal = LedgerJournal()
        journal.styles = LedgerExport.styles(for: book)
        for posting in pipeline.postings()
        where seen.insert(posting.transaction.guid).inserted {
            journal.transactions.append(LedgerExport.ledgerTransaction(posting.transaction))
        }
        return LedgerWriter.write(journal)
    }

    public static func csv(_ pipeline: ReportPipeline) -> String {
        var lines: [String] = []
        for posting in pipeline.postings() {
            let state: String
            switch posting.split.reconcileState {
            case .reconciled: state = "*"
            case .cleared: state = "!"
            default: state = ""
            }
            let fields = [
                LedgerDateFormatting.iso(posting.date),
                posting.transaction.number,
                posting.transaction.transactionDescription,
                posting.account?.fullName ?? "",
                posting.commodity.mnemonic,
                NSDecimalNumber(decimal: posting.amount).stringValue,
                state,
                posting.split.memo,
            ]
            lines.append(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: ","))
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: list commands

    public static func accounts(_ pipeline: ReportPipeline) -> String {
        list(pipeline.postings().map { $0.account?.fullName ?? "" },
             count: pipeline.request.options.count)
    }

    public static func payees(_ pipeline: ReportPipeline) -> String {
        list(pipeline.postings().map(\.transaction.transactionDescription),
             count: pipeline.request.options.count)
    }

    public static func commodities(_ pipeline: ReportPipeline) -> String {
        list(pipeline.postings().map(\.commodity.mnemonic),
             count: pipeline.request.options.count)
    }

    static func list(_ values: [String], count: Bool) -> String {
        var counts: [String: Int] = [:]
        for value in values where !value.isEmpty { counts[value, default: 0] += 1 }
        let names = counts.keys.sorted()
        guard !names.isEmpty else { return "" }
        return names.map { count ? "\($0)  \(counts[$0] ?? 0)" : $0 }
            .joined(separator: "\n") + "\n"
    }

    // MARK: prices

    public static func prices(_ pipeline: ReportPipeline, book: Book, asDatabase: Bool) -> String {
        let options = pipeline.request.options
        let predicate = pipeline.request.query.predicate
        let bounds = pipeline.window
        var entries = book.prices.filter { price in
            if let begin = bounds.begin, price.date < begin { return false }
            if let end = bounds.end, price.date >= end { return false }
            switch predicate {
            case .all: return true
            default:
                // Bare terms filter commodities here, as ledger does.
                return matchesCommodity(predicate, mnemonic: price.commodity.mnemonic)
            }
        }
        entries.sort { ($0.date, $0.commodity.mnemonic) < ($1.date, $1.commodity.mnemonic) }
        if options.latest {
            var latest: [String: Price] = [:]
            for price in entries {
                if let existing = latest[price.commodity.mnemonic], existing.date >= price.date { continue }
                latest[price.commodity.mnemonic] = price
            }
            entries = latest.values.sorted { $0.commodity.mnemonic < $1.commodity.mnemonic }
        }
        guard !entries.isEmpty else { return "" }
        return entries.map { price in
            let symbol = LedgerAmountSyntax.needsQuoting(price.commodity.mnemonic)
                ? "\"\(price.commodity.mnemonic)\"" : price.commodity.mnemonic
            let value = amount(price.value, price.currency)
            return asDatabase
                ? "P \(LedgerDateFormatting.isoWithTime(price.date)) \(symbol) \(value)"
                : "\(LedgerDateFormatting.iso(price.date)) \(symbol) \(value)"
        }.joined(separator: "\n") + "\n"
    }

    static func matchesCommodity(_ node: QueryNode, mnemonic: String) -> Bool {
        switch node {
        case .all: true
        case .account(let matcher): matcher.matches(mnemonic)
        case .and(let lhs, let rhs):
            matchesCommodity(lhs, mnemonic: mnemonic) && matchesCommodity(rhs, mnemonic: mnemonic)
        case .or(let lhs, let rhs):
            matchesCommodity(lhs, mnemonic: mnemonic) || matchesCommodity(rhs, mnemonic: mnemonic)
        case .not(let inner): !matchesCommodity(inner, mnemonic: mnemonic)
        default: false
        }
    }

    // MARK: stats

    public static func stats(_ pipeline: ReportPipeline, book: Book, sources: [String]) -> String {
        let postings = pipeline.postings()
        let dates = postings.map(\.date).sorted()
        let accounts = Set(postings.compactMap { $0.account?.fullName })
        let payees = Set(postings.map(\.transaction.transactionDescription))
        let transactions = Set(postings.map(\.transaction.guid))
        let uncleared = postings.filter { $0.split.reconcileState != .reconciled }.count
        var lines = ["Time period: " + (dates.first.map { LedgerDateFormatting.iso($0) } ?? "(none)")
                     + " to " + (dates.last.map { LedgerDateFormatting.iso($0) } ?? "(none)")]
        lines.append("Files these postings came from:")
        for source in sources { lines.append("  " + source) }
        lines.append("Unique payees:          \(payees.count)")
        lines.append("Unique accounts:        \(accounts.count)")
        lines.append("Number of transactions: \(transactions.count)")
        lines.append("Number of postings:     \(postings.count) (\(uncleared) uncleared)")
        if let last = dates.last {
            let days = Calendar(identifier: .gregorian)
                .dateComponents([.day], from: last, to: pipeline.request.today).day ?? 0
            lines.append("Days since last post:   \(max(0, days))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: equity / cleared

    public static func equity(_ pipeline: ReportPipeline, book: Book) -> String {
        let totals = pipeline.balances()
        var journal = LedgerJournal()
        journal.styles = LedgerExport.styles(for: book)
        var entry = LedgerTransaction(date: pipeline.request.today, payee: "Opening Balances")
        entry.state = .cleared
        var equityTotals: [String: Decimal] = [:]
        for path in totals.keys.sorted() {
            for (mnemonic, value) in (totals[path] ?? [:]).sorted(by: { $0.key < $1.key })
            where value != 0 {
                var posting = LedgerPosting(account: path)
                posting.amount = LedgerAmount(commodity: mnemonic, quantity: value)
                entry.postings.append(posting)
                equityTotals[mnemonic, default: 0] += value
            }
        }
        for (mnemonic, value) in equityTotals.sorted(by: { $0.key < $1.key }) where value != 0 {
            var posting = LedgerPosting(account: "Equity:Opening Balances")
            posting.amount = LedgerAmount(commodity: mnemonic, quantity: -value)
            entry.postings.append(posting)
        }
        guard !entry.postings.isEmpty else { return "" }
        journal.transactions = [entry]
        return LedgerWriter.write(journal)
    }

    public static func cleared(_ pipeline: ReportPipeline, book: Book) -> String {
        var totals: [String: Decimal] = [:]
        var clearedTotals: [String: Decimal] = [:]
        var lastCleared: [String: Date] = [:]
        var commodities: [String: Commodity] = [:]
        for posting in pipeline.postings() {
            guard let account = posting.account else { continue }
            totals[account.fullName, default: 0] += posting.amount
            commodities[account.fullName] = posting.commodity
            if posting.split.reconcileState == .reconciled {
                clearedTotals[account.fullName, default: 0] += posting.amount
                let existing = lastCleared[account.fullName] ?? .distantPast
                lastCleared[account.fullName] = max(existing, posting.date)
            }
        }
        var lines: [String] = []
        for path in totals.keys.sorted() {
            let commodity = commodities[path] ?? book.baseCurrency
            let date = lastCleared[path].map { registerDate($0, format: nil) } ?? ""
            lines.append(pad(amount(totals[path] ?? 0, commodity), to: 16) + "  "
                + pad(amount(clearedTotals[path] ?? 0, commodity), to: 18) + "    "
                + padRight(date, to: 9) + "  " + path)
        }
        guard !lines.isEmpty else { return "" }
        let separator = String(repeating: "-", count: 16) + "  "
            + String(repeating: "-", count: 18) + "    " + String(repeating: "-", count: 9)
        let grand = totals.values.reduce(0, +)
        let grandCleared = clearedTotals.values.reduce(0, +)
        lines.append(separator)
        lines.append(pad(amount(grand, book.baseCurrency), to: 16) + "  "
            + pad(amount(grandCleared, book.baseCurrency), to: 18))
        return lines.joined(separator: "\n") + "\n"
    }

    static func terminalWidth() -> Int {
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"], let width = Int(columns) {
            return width
        }
        return 80
    }
}

/// Date shapes the renderers share.
enum LedgerDateFormatting {
    static func iso(_ date: Date) -> String {
        formatter("yyyy/MM/dd").string(from: date)
    }
    static func isoWithTime(_ date: Date) -> String {
        formatter("yyyy/MM/dd HH:mm:ss").string(from: date)
    }
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
