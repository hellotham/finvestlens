//
//  LedgerBookMapping.swift
//  FinvestLens — Interchange
//
//  Book ⟷ Ledger-journal mapping (FR-XIO-09/10), per the table in
//  docs/ledger-design.md §4: colon account paths map 1:1; auxiliary dates
//  carry `statementDate`; security/FX legs export as `@@` total-cost
//  postings (exactly the split's quantity/value pair); GUIDs, account
//  types/commodities, split actions and reconcile detail ride in
//  ledger-legal `key: value` metadata comment lines, so a FinvestLens book
//  round-trips while the journal stays valid for the real `ledger` binary.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

// MARK: - Export

public enum LedgerExport {

    /// The whole book as a deterministic Ledger journal: account and
    /// commodity directives (metadata in their notes), `P` price lines,
    /// scheduled/budget templates as periodic entries would be P10d — then
    /// every transaction ordered by (date, book order).
    public static func journal(from book: Book) -> LedgerJournal {
        var journal = LedgerJournal()

        // Commodities: suffix style with a space, precision from the
        // smallest fraction — unambiguous and locale-free (design §4).
        // Sorted by mnemonic: registration order is not stable across a
        // round-trip (the base currency registers first on import), and the
        // export must be byte-stable for an unchanged book.
        for commodity in book.commodities.sorted(by: { $0.mnemonic < $1.mnemonic }) {
            var style = LedgerCommodityStyle()
            style.isPrefix = false
            style.spaced = true
            style.precision = precision(of: commodity.smallestFraction)
            style.quoted = LedgerAmountSyntax.needsQuoting(commodity.mnemonic)
            journal.styles.declare(commodity.mnemonic, style: style)

            var directive = LedgerCommodityDirective(symbol: commodity.mnemonic)
            directive.format = LedgerAmountSyntax.format(
                LedgerAmount(commodity: commodity.mnemonic, quantity: 0),
                styles: journal.styles)
            directive.note = commodityNote(commodity)
            journal.commodityDirectives.append(directive)
        }

        for account in book.accounts {
            var directive = LedgerAccountDirective(name: account.fullName)
            directive.note = accountNote(account)
            journal.accountDirectives.append(directive)
        }

        for price in book.prices.sorted(by: { ($0.date, $0.commodity.mnemonic) < ($1.date, $1.commodity.mnemonic) }) {
            journal.prices.append(LedgerPriceEntry(
                date: price.date,
                symbol: price.commodity.mnemonic,
                price: LedgerAmount(commodity: price.currency.mnemonic, quantity: price.value)))
        }

        let ordered = book.transactions.enumerated().sorted {
            ($0.element.datePosted, $0.offset) < ($1.element.datePosted, $1.offset)
        }
        for (_, transaction) in ordered {
            journal.transactions.append(ledgerTransaction(transaction))
        }
        return journal
    }

    /// Canonical journal text for the whole book — `finlens print` and
    /// File ▸ Export share this single path.
    public static func text(from book: Book) -> String {
        LedgerWriter.write(journal(from: book))
    }

    static func precision(of smallestFraction: Int) -> Int {
        var fraction = max(1, smallestFraction)
        var digits = 0
        while fraction > 1 { fraction /= 10; digits += 1 }
        return digits
    }

    /// `key=value`, quoting values that carry spaces or quotes — real books
    /// have commodities like `AT&T Top-up`, and an unquoted value would be
    /// truncated at the first space when read back.
    static func token(_ key: String, _ value: String) -> String {
        guard value.contains(" ") || value.contains("\"") else { return "\(key)=\(value)" }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key)=\"\(escaped)\""
    }

    static func commodityNote(_ commodity: Commodity) -> String {
        let namespace: String
        switch commodity.namespace {
        case .currency: namespace = "currency"
        case .security(let name): namespace = "security:\(name)"
        case .other(let name): namespace = "other:\(name)"
        }
        return "finvestlens " + token("namespace", namespace)
            + " | " + commodity.fullName
    }

    static func accountNote(_ account: Account) -> String {
        var tokens = ["finvestlens",
                      token("type", account.type.rawValue),
                      token("guid", account.guid.hexString),
                      token("commodity", account.commodity.mnemonic)]
        if !account.code.isEmpty { tokens.append(token("code", account.code)) }
        if account.isPlaceholder { tokens.append("placeholder") }
        if account.isHidden { tokens.append("hidden") }
        var note = tokens.joined(separator: " ")
        if !account.accountDescription.isEmpty {
            note += " | " + account.accountDescription
        }
        return note
    }

    static func ledgerTransaction(_ transaction: FinvestLensEngine.Transaction) -> LedgerTransaction {
        var entry = LedgerTransaction(date: transaction.datePosted,
                                      payee: transaction.transactionDescription)
        entry.auxDate = transaction.statementDate
        entry.code = transaction.number.isEmpty ? nil : transaction.number

        // A uniform non-default state hoists to the transaction flag
        // (ledger's `*` is shorthand for clearing every posting).
        let states = Set(transaction.splits.map(\.reconcileState))
        var hoisted: LedgerState?
        if states == [.reconciled] { hoisted = .cleared }
        else if states == [.cleared] { hoisted = .pending }
        if let hoisted { entry.state = hoisted }

        // User notes first, then machine metadata lines the parser reads back.
        for line in transaction.notes.split(separator: "\n", omittingEmptySubsequences: false)
        where !transaction.notes.isEmpty {
            entry.noteLines.append(String(line))
        }
        if !transaction.tags.isEmpty {
            entry.noteLines.append(":" + transaction.tags.joined(separator: ":") + ":")
        }
        entry.noteLines.append("guid: \(transaction.guid.hexString)")

        for split in transaction.splits {
            entry.postings.append(posting(for: split, in: transaction, hoisted: hoisted))
        }
        return entry
    }

    static func posting(for split: Split, in transaction: FinvestLensEngine.Transaction,
                        hoisted: LedgerState?) -> LedgerPosting {
        let account = split.account
        var posting = LedgerPosting(account: account?.fullName ?? "Orphan")

        if case .string("balanced")? = split.kvp["ledger/virtual"] {
            posting.virtualKind = .balanced
        }

        if hoisted == nil {
            switch split.reconcileState {
            case .reconciled: posting.state = .cleared
            case .cleared: posting.state = .pending
            default: break
            }
        }

        let currency = transaction.currency.mnemonic
        let accountCommodity = account?.commodity
        let sameCommodity = accountCommodity == transaction.currency
        if sameCommodity, split.quantity == split.value {
            posting.amount = LedgerAmount(commodity: currency, quantity: split.value)
        } else if split.quantity != 0 {
            // The split's (quantity, value) pair, exactly: `10 BHP @@ 421.00 AUD`.
            posting.amount = LedgerAmount(commodity: accountCommodity?.mnemonic ?? currency,
                                          quantity: split.quantity)
            posting.cost = LedgerCost(kind: .total,
                                      amount: LedgerAmount(commodity: currency,
                                                           quantity: abs(split.value)))
        } else {
            // Zero quantity (a currency-valued leg on a foreign account).
            posting.amount = LedgerAmount(commodity: currency, quantity: split.value)
        }

        if !split.memo.isEmpty { posting.note = split.memo }
        if !split.action.isEmpty { posting.noteLines.append("action: \(split.action)") }
        if let reconciled = split.reconcileDate {
            posting.noteLines.append("reconciled: \(LedgerDateParsing.format(reconciled))")
        }
        switch split.reconcileState {
        case .voided: posting.noteLines.append("voided: true")
        case .frozen: posting.noteLines.append("frozen: true")
        default: break
        }
        return posting
    }
}

// MARK: - Import

public struct LedgerImportSummary: Sendable {
    public var transactions = 0
    public var splitTransactions = 0      // multi-commodity entries split per group
    public var accountsCreated = 0
    public var pricesImported = 0
    public var assertionsChecked = 0
    public var assertionsFailed = 0
    public var assignmentsResolved = 0
    public var unbalancedVirtualsSkipped = 0
    public var periodicIgnored = 0
    public var automatedIgnored = 0
    public var diagnostics: [LedgerDiagnostic] = []
}

public struct LedgerImportResult {
    public let book: Book
    public let summary: LedgerImportSummary
}

public enum LedgerImport {

    /// Parses journal text and maps it onto a fresh `Book` per design §4.
    public static func importBook(text: String, fileName: String = "journal",
                                  today: Date = Date()) -> LedgerImportResult {
        let parsed = LedgerParser.parse(text: text, fileName: fileName, today: today)
        return importBook(parsed: parsed)
    }

    public static func importBook(parsed: LedgerParseResult) -> LedgerImportResult {
        let journal = parsed.journal
        var summary = LedgerImportSummary()
        summary.diagnostics = parsed.diagnostics
        summary.assertionsChecked = journal.assertionsChecked
        summary.assertionsFailed = parsed.diagnostics
            .filter { $0.message.contains("balance assertion failed") }.count
        summary.assignmentsResolved = journal.assignmentsResolved
        summary.periodicIgnored = journal.periodicEntries.count
        summary.automatedIgnored = journal.automatedEntries.count

        var mapper = Mapper(journal: journal)
        let book = mapper.build(summary: &summary)
        return LedgerImportResult(book: book, summary: summary)
    }

    // MARK: Mapper

    struct Mapper {
        let journal: LedgerJournal
        var commodities: [String: Commodity] = [:]
        var accountMetadata: [String: (type: AccountType?, guid: GncGUID?,
                                       commodity: String?, code: String?,
                                       placeholder: Bool, hidden: Bool,
                                       description: String?)] = [:]
        var accountsByPath: [String: Account] = [:]
        /// For accounts with no `commodity=` metadata: the commodity their
        /// own postings are denominated in. A foreign journal's
        /// `Assets:Brokerage  10 BHP @@ 421.00 AUD` makes that account
        /// BHP-denominated, which is what the reports need.
        var commodityHints: [String: String] = [:]

        init(journal: LedgerJournal) {
            self.journal = journal
        }

        mutating func build(summary: inout LedgerImportSummary) -> Book {
            for directive in journal.commodityDirectives {
                commodities[directive.symbol] = commodity(for: directive)
            }
            for directive in journal.accountDirectives {
                accountMetadata[directive.name] = Self.parseAccountNote(directive.note)
            }

            // Postings whose own amount differs from the transaction's
            // balancing commodity name their account's commodity.
            for transaction in journal.transactions {
                for posting in transaction.postings {
                    guard let cost = posting.cost, let amount = posting.amount,
                          !amount.commodity.isEmpty,
                          amount.commodity != cost.amount.commodity else { continue }
                    commodityHints[posting.account] = amount.commodity
                }
            }

            let book = Book(baseCurrency: baseCurrency())

            // A `commodity` directive is a declaration: register it even when
            // nothing posts to it, or a re-export would silently drop it.
            for directive in journal.commodityDirectives {
                if let commodity = commodities[directive.symbol] {
                    book.registerCommodity(commodity)
                }
            }

            for directive in journal.accountDirectives {
                _ = account(named: directive.name, in: book, summary: &summary)
            }

            for transaction in journal.transactions {
                importTransaction(transaction, into: book, summary: &summary)
            }

            for price in journal.prices {
                let commodity = self.commodity(symbol: price.symbol)
                let currency = self.commodity(symbol: price.price.commodity)
                book.addPrice(Price(commodity: commodity, currency: currency,
                                    date: price.date, value: price.price.quantity,
                                    source: "ledger:import"))
                summary.pricesImported += 1
            }
            return book
        }

        // MARK: Commodities

        static let isoCurrencyCodes: Set<String> = [
            "AUD", "USD", "EUR", "GBP", "JPY", "NZD", "SGD", "MYR", "HKD", "CNY",
            "THB", "IDR", "INR", "CHF", "CAD", "KRW", "VND", "SEK", "NOK", "DKK",
            "PLN", "CZK", "HUF", "RON", "BGN", "TRY", "ILS", "AED", "SAR", "QAR",
            "ZAR", "BRL", "MXN", "ARS", "CLP", "COP", "PEN", "PHP", "TWD", "PKR",
            "BDT", "LKR", "NPR", "KES", "NGN", "EGP", "MAD", "RUB", "UAH", "ISK",
            "FJD", "PGK", "WST", "TOP", "VUV", "SBD", "XPF",
        ]

        mutating func commodity(for directive: LedgerCommodityDirective) -> Commodity {
            let (namespace, fullName) = Self.parseCommodityNote(directive.note)
            let resolved = namespace ?? Self.inferNamespace(directive.symbol)
            // The `format` sub-directive is the declared display precision —
            // authoritative over the precision learned from postings, which
            // can be finer (a whole-unit security still holding 52.5 units).
            let precision = Self.declaredPrecision(directive.format)
                ?? journal.styles.style(for: directive.symbol).precision
            return Commodity(namespace: resolved,
                             mnemonic: directive.symbol,
                             fullName: fullName ?? directive.symbol,
                             smallestFraction: Self.fraction(forPrecision: precision))
        }

        /// The decimal places in a `format` sample, e.g. `0.00 AUD` → 2.
        static func declaredPrecision(_ format: String?) -> Int? {
            guard let format else { return nil }
            var styles = LedgerAmountStyles()
            guard LedgerAmountSyntax.parse(format, decimalCommaDefault: false,
                                           styles: &styles, observe: true) != nil,
                  let observed = styles.byCommodity.values.first else { return nil }
            return observed.precision
        }

        mutating func commodity(symbol: String) -> Commodity {
            if let existing = commodities[symbol] { return existing }
            let style = journal.styles.style(for: symbol)
            let created = Commodity(namespace: Self.inferNamespace(symbol),
                                    mnemonic: symbol,
                                    fullName: symbol,
                                    smallestFraction: Self.fraction(forPrecision: max(style.precision, symbol == "$" ? 2 : style.precision)))
            commodities[symbol] = created
            return created
        }

        static func inferNamespace(_ symbol: String) -> CommodityNamespace {
            if isoCurrencyCodes.contains(symbol) || symbol.count == 1 {
                return .currency   // ISO code, or a symbol like $/€/£
            }
            return .security("LEDGER")
        }

        static func fraction(forPrecision precision: Int) -> Int {
            var fraction = 1
            for _ in 0..<max(0, min(precision, 9)) { fraction *= 10 }
            return max(fraction, 1)
        }

        /// The most frequently used currency across posting contributions.
        mutating func baseCurrency() -> Commodity {
            var counts: [String: Int] = [:]
            for transaction in journal.transactions {
                for posting in transaction.postings {
                    let symbol = posting.cost?.amount.commodity
                        ?? posting.resolvedAmounts.first?.commodity
                        ?? posting.amount?.commodity
                    if let symbol, !symbol.isEmpty { counts[symbol, default: 0] += 1 }
                }
            }
            let currencySymbols = counts.keys.filter {
                if case .currency = (commodities[$0]?.namespace ?? Self.inferNamespace($0)) { return true }
                return false
            }
            let best = currencySymbols.max {
                (counts[$0] ?? 0, $1) < (counts[$1] ?? 0, $0)   // count, then name
            }
            guard let best else { return .aud }
            return commodity(symbol: best)
        }

        // MARK: Accounts

        /// Splits `finvestlens key=value key="value with spaces" flag` into
        /// (key, value) pairs; a bare flag yields an empty value.
        static func tokens(in text: String) -> [(String, String)] {
            var pairs: [(String, String)] = []
            var key = ""
            var value = ""
            var inKey = true
            var quoted = false
            var escaped = false
            var started = false

            func flush() {
                if started, !key.isEmpty, key != "finvestlens" { pairs.append((key, value)) }
                key = ""; value = ""; inKey = true; quoted = false; started = false
            }
            for character in text {
                if escaped { value.append(character); escaped = false; continue }
                if quoted {
                    if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                    else { value.append(character) }
                    continue
                }
                if character == " " { flush(); continue }
                started = true
                if inKey {
                    if character == "=" { inKey = false } else { key.append(character) }
                } else if character == "\"", value.isEmpty {
                    quoted = true
                } else {
                    value.append(character)
                }
            }
            flush()
            return pairs
        }

        static func parseAccountNote(_ note: String?)
            -> (type: AccountType?, guid: GncGUID?, commodity: String?, code: String?,
                placeholder: Bool, hidden: Bool, description: String?) {
            guard let note, note.hasPrefix("finvestlens") else {
                return (nil, nil, nil, nil, false, false, note)
            }
            let parts = note.split(separator: "|", maxSplits: 1).map(String.init)
            let description = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            var type: AccountType?
            var guid: GncGUID?
            var commodity: String?
            var code: String?
            var placeholder = false
            var hidden = false
            for (key, value) in Self.tokens(in: parts[0]) {
                switch key {
                case "placeholder": placeholder = true
                case "hidden": hidden = true
                case "type": type = AccountType(rawValue: value)
                case "guid": guid = GncGUID(hex: value)
                case "commodity": commodity = value
                case "code": code = value
                default: break
                }
            }
            return (type, guid, commodity, code, placeholder, hidden, description)

        }

        static func parseCommodityNote(_ note: String?) -> (CommodityNamespace?, String?) {
            guard let note, note.hasPrefix("finvestlens") else { return (nil, nil) }
            let parts = note.split(separator: "|", maxSplits: 1).map(String.init)
            let fullName = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            var namespace: CommodityNamespace?
            for (key, value) in Self.tokens(in: parts[0]) where key == "namespace" {
                if value == "currency" { namespace = .currency }
                else if value.hasPrefix("security:") {
                    namespace = .security(String(value.dropFirst("security:".count)))
                } else if value.hasPrefix("other:") {
                    namespace = .other(String(value.dropFirst("other:".count)))
                }
            }
            return (namespace, fullName)
        }

        /// Root-name inference for journals without our metadata — the
        /// convention ledger files follow anyway.
        static func inferredType(forRoot root: String) -> AccountType {
            switch root.lowercased() {
            case "assets", "asset": .asset
            case "bank": .bank
            case "cash": .cash
            case "liabilities", "liability": .liability
            case "income", "revenue", "revenues": .income
            case "expenses", "expense": .expense
            case "equity": .equity
            default: .asset
            }
        }

        mutating func account(named path: String, in book: Book,
                              summary: inout LedgerImportSummary) -> Account {
            if let existing = accountsByPath[path] { return existing }
            let components = path.split(separator: ":").map(String.init)
            var parent: Account?
            var walked: [String] = []
            for component in components {
                walked.append(component)
                let currentPath = walked.joined(separator: ":")
                if let existing = accountsByPath[currentPath] {
                    parent = existing
                    continue
                }
                let metadata = accountMetadata[currentPath]
                let type = metadata?.type
                    ?? parent?.type
                    ?? Self.inferredType(forRoot: components[0])
                let commoditySymbol = metadata?.commodity ?? commodityHints[currentPath]
                let accountCommodity = commoditySymbol.map { commodity(symbol: $0) }
                    ?? parent?.commodity
                    ?? book.baseCurrency
                let account = Account(
                    guid: metadata?.guid ?? .random(),
                    name: component,
                    type: type,
                    commodity: accountCommodity,
                    code: metadata?.code ?? "",
                    description: metadata?.description ?? "",
                    isPlaceholder: metadata?.placeholder ?? false,
                    isHidden: metadata?.hidden ?? false)
                book.addAccount(account, under: parent)
                accountsByPath[currentPath] = account
                summary.accountsCreated += 1
                parent = account
            }
            return parent!
        }

        // MARK: Transactions

        static let machineKeys: Set<String> = ["guid", "action", "reconciled",
                                               "voided", "frozen"]

        static func isMachineLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":"), trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                return true   // a pure tag list
            }
            guard let colon = trimmed.firstIndex(of: ":") else { return false }
            return machineKeys.contains(String(trimmed[..<colon]))
        }

        mutating func importTransaction(_ entry: LedgerTransaction, into book: Book,
                                        summary: inout LedgerImportSummary) {
            // Expand each posting into (posting, contribution amount, splitAmount)
            // triples; elided postings contribute one entry per resolved amount.
            struct Piece {
                var posting: LedgerPosting
                var groupCommodity: String
                var amount: LedgerAmount      // the posting's own amount
                var value: Decimal            // contribution in group commodity
            }
            var pieces: [Piece] = []
            for posting in entry.postings {
                if posting.virtualKind == .unbalanced {
                    summary.unbalancedVirtualsSkipped += 1
                    continue
                }
                if let cost = posting.cost, let amount = posting.amount {
                    let value: Decimal
                    switch cost.kind {
                    case .perUnit: value = amount.quantity * cost.amount.quantity
                    case .total: value = (amount.quantity < 0 ? -1 : 1) * cost.amount.quantity
                    }
                    pieces.append(Piece(posting: posting, groupCommodity: cost.amount.commodity,
                                        amount: amount, value: value))
                } else {
                    for amount in posting.resolvedAmounts {
                        pieces.append(Piece(posting: posting, groupCommodity: amount.commodity,
                                            amount: amount, value: amount.quantity))
                    }
                }
            }
            guard !pieces.isEmpty else { return }

            let groups = Dictionary(grouping: pieces, by: \.groupCommodity)
                .sorted { $0.key < $1.key }
            if groups.count > 1 {
                summary.splitTransactions += 1
                summary.diagnostics.append(LedgerDiagnostic(
                    .warning, file: "journal", line: entry.line,
                    message: "multi-commodity entry '\(entry.payee)' imported as \(groups.count) transactions (one per commodity)"))
            }

            let guid = entry.metadata.first { $0.key == "guid" }
                .flatMap { GncGUID(hex: $0.value) }
            let notes = entry.noteLines.filter { !Self.isMachineLine($0) }
                .joined(separator: "\n")

            for (offset, group) in groups.enumerated() {
                let currency = commodity(symbol: group.key)
                let transaction = FinvestLensEngine.Transaction(
                    guid: (offset == 0 ? guid : nil) ?? .random(),
                    currency: currency,
                    datePosted: entry.date,
                    number: entry.code ?? "",
                    description: entry.payee,
                    notes: notes)
                transaction.statementDate = entry.auxDate
                if !entry.tags.isEmpty { transaction.tags = entry.tags }

                for piece in group.value {
                    let posting = piece.posting
                    let account = account(named: posting.account, in: book, summary: &summary)
                    let quantity: Decimal
                    if posting.cost != nil {
                        quantity = piece.amount.quantity
                    } else if piece.amount.commodity == account.commodity.mnemonic
                                || piece.amount.commodity.isEmpty {
                        quantity = piece.amount.quantity
                    } else {
                        quantity = 0   // currency-valued leg on a foreign account
                    }
                    var kvp = KvpFrame()
                    if posting.virtualKind == .balanced {
                        kvp["ledger/virtual"] = .string("balanced")
                    }
                    let state: ReconcileState
                    if posting.metadata.contains(where: { $0.key == "voided" }) {
                        state = .voided
                    } else if posting.metadata.contains(where: { $0.key == "frozen" }) {
                        state = .frozen
                    } else {
                        switch posting.state ?? Self.hoistedState(entry.state) {
                        case .cleared: state = .reconciled
                        case .pending: state = .cleared
                        default: state = .notReconciled
                        }
                    }
                    let reconcileDate = posting.metadata.first { $0.key == "reconciled" }
                        .flatMap { LedgerDateParsing.parse($0.value, defaultYear: nil, today: entry.date) }
                    let action = posting.metadata.first { $0.key == "action" }?.value ?? ""
                    transaction.addSplit(Split(
                        account: account,
                        value: piece.value,
                        quantity: quantity,
                        reconcileState: state,
                        reconcileDate: reconcileDate,
                        memo: posting.note ?? "",
                        action: action,
                        kvp: kvp))
                }
                book.addTransaction(transaction)
                summary.transactions += 1
            }
        }

        static func hoistedState(_ state: LedgerState) -> LedgerState? {
            state == .uncleared ? nil : state
        }
    }
}
