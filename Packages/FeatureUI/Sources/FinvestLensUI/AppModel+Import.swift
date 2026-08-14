//
//  AppModel+Import.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange
import FinvestLensRules

/// Supported bank-file import formats. `pdf` statements are read by Apple
/// Intelligence (`FR-AI-01`) before reaching the shared review flow;
/// `mt940` covers SWIFT MT940/MT942, `camt` ISO 20022 CAMT.053/052
/// (`FR-XIO-04`).
public enum BankFileFormat: String, Sendable, CaseIterable, Identifiable {
    case csv, qif, ofx, mt940, camt, pdf
    public var id: String { rawValue }

    public static func forExtension(_ ext: String) -> BankFileFormat? {
        switch ext.lowercased() {
        case "csv": return .csv
        case "qif": return .qif
        case "ofx", "qfx": return .ofx
        case "sta", "mt940", "940", "mt942", "942", "fin": return .mt940
        case "camt", "c52", "c53", "c54": return .camt
        case "pdf": return .pdf
        default: return nil
        }
    }

    /// Detects the format from the extension, falling back to sniffing the
    /// content — a `.xml` file may be a CAMT statement, a `.txt` an MT940.
    public static func detect(_ data: Data, extension ext: String) -> BankFileFormat? {
        if let known = forExtension(ext) { return known }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.contains("<BkToCstmrStmt") || head.contains("<BkToCstmrAcctRpt")
            || head.contains("urn:iso:std:iso:20022:tech:xsd:camt.05") {
            return .camt
        }
        if head.contains("OFXHEADER") || head.contains("<OFX") { return .ofx }
        if head.contains(":20:"), head.contains(":25:") { return .mt940 }
        if head.contains("!Type:") { return .qif }
        return nil
    }
}

/// Where the import sheet's pre-filled account came from, so the sheet can say
/// so. A silently-guessed target posts a statement into the wrong account, and
/// the user has no way to tell a guess from their own earlier choice.
public enum ImportTargetSource: Sendable, Equatable {
    /// The statement carries an account id this book has seen before.
    case rememberedIdentifier
    case fileName
    case currentRegister
}

/// Matches a statement's own account identifier against the `online_id` a
/// previous import stamped on an account.
///
/// Ported from GnuCash's `test_acct_online_id_match`
/// (`gnucash/import-export/import-account-matcher.cpp`), including the part
/// that matters: the comparison is by **prefix**, not equality. Banks are not
/// consistent about how much of the identifier they put in a file — a card
/// statement may carry only the account number where a bank statement prefixes
/// the routing number — so a stored id that is a prefix of the incoming one
/// still identifies the account. Where several accounts match, the **longest**
/// stored id wins, and two equally-long matches are ambiguous and refused.
enum OnlineIDMatch {

    /// GnuCash trims one trailing space from either side before comparing;
    /// some exporters pad the field.
    private static func normalised(_ id: String) -> String {
        var text = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    static func account(forIdentifier identifier: String,
                        in candidates: [(id: GncGUID, onlineID: String)]) -> GncGUID? {
        let incoming = normalised(identifier)
        guard !incoming.isEmpty else { return nil }

        var best: (id: GncGUID, length: Int)?
        var ambiguous = false
        for candidate in candidates {
            let stored = normalised(candidate.onlineID)
            guard !stored.isEmpty, incoming.hasPrefix(stored) else { continue }
            if stored == incoming { return candidate.id }   // exact wins outright
            if let current = best {
                if stored.count > current.length {
                    best = (candidate.id, stored.count)
                    ambiguous = false                        // a longer prefix settles it
                } else if stored.count == current.length {
                    ambiguous = true
                }
            } else {
                best = (candidate.id, stored.count)
            }
        }
        return ambiguous ? nil : best?.id
    }
}

/// Matches a downloaded statement's file name to one account.
///
/// Banks name exports after the account ("ANZ VISA.ofx") often enough to be
/// worth reading, and around it they put words that mean nothing — the format,
/// the word "statement", the date, the export sequence number. Those are
/// stripped; what remains is compared to account names in three tiers of
/// decreasing confidence.
///
/// **It abstains on a tie.** Two accounts matching equally well means the file
/// name did not identify one, and offering either would be a coin toss with
/// someone's ledger — the same rule the smart categoriser follows when two
/// payees fit.
enum ImportFileNameMatch {

    /// Words that appear in export file names and never identify an account.
    private static let noise: Set<String> = [
        "statement", "statements", "transaction", "transactions", "export",
        "exports", "download", "downloads", "data", "history", "account",
        "accounts", "activity", "copy", "final", "new", "csv", "ofx", "qfx",
        "qif", "pdf", "xls", "xlsx", "txt", "sta", "camt", "mt940",
    ]

    static func tokens(_ text: String) -> [String] {
        // Reassembled into a String before splitting: mapping over a String
        // yields [Character], whose split gives ArraySlice<Character>, and
        // String.init has no unambiguous overload for that.
        let cleaned = String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").map(String.init)
    }

    /// The file name's identifying words: no extension, no noise, no bare
    /// numbers (dates, sequence numbers, masked account digits).
    static func significantTokens(inFileNamed fileName: String) -> Set<String> {
        let base = (fileName as NSString).deletingPathExtension
        return Set(tokens(base).filter { token in
            token.count >= 2 && !noise.contains(token)
                && !token.allSatisfy(\.isNumber)
        })
    }

    /// The single account this file name identifies, or `nil` if none or more
    /// than one does.
    static func account(forFileNamed fileName: String,
                        in candidates: [(id: GncGUID, name: String)]) -> GncGUID? {
        let file = significantTokens(inFileNamed: fileName)
        guard !file.isEmpty else { return nil }

        // Tier 1 the account's name *is* the file name; tier 2 the file names
        // part of one account ("ANZ" when only one ANZ account exists); tier 3
        // the file name carries the whole account name plus extra words.
        var tiers: [Int: [GncGUID]] = [:]
        for candidate in candidates {
            let name = Set(tokens(candidate.name).filter { $0.count >= 2 })
            guard !name.isEmpty else { continue }
            let tier: Int?
            if name == file { tier = 1 }
            else if file.isSubset(of: name) { tier = 2 }
            else if name.isSubset(of: file) { tier = 3 }
            else { tier = nil }
            if let tier { tiers[tier, default: []].append(candidate.id) }
        }
        guard let best = tiers.keys.min(), let hits = tiers[best] else { return nil }
        return hits.count == 1 ? hits[0] : nil
    }
}

@MainActor
extension AppModel {

    /// Accounts a bank statement can post to. Excludes income/expense/equity:
    /// a statement imported into an Expense account is never what was meant,
    /// and suggesting one would be worse than suggesting nothing.
    public var statementTargetAccounts: [AccountNode] {
        postableAccounts.filter { $0.isType(.bank, .credit, .cash, .asset, .liability) }
    }

    /// The account identifier a statement file carries, where its format has
    /// one. QIF, CSV and extracted PDFs do not.
    public func bankFileAccountID(_ data: Data, format: BankFileFormat) -> String? {
        switch format {
        case .ofx: return OFXImporter.accountIdentifier(data)
        case .camt: return CAMTImporter.accountIdentifier(data)
        case .mt940: return MT940Importer.accountIdentifier(data)
        case .csv, .qif, .pdf: return nil
        }
    }

    /// The account an import should open on, and why.
    ///
    /// The statement's own account identifier comes first where the book has
    /// seen it before: it is the bank's name for the account rather than a
    /// guess, so it survives the file being renamed and does not care which
    /// register was open. Then the file name, then that register.
    public func suggestedImportTarget(forFileNamed fileName: String?,
                                      accountIdentifier: String? = nil)
        -> (id: GncGUID, source: ImportTargetSource)? {
        let candidates = statementTargetAccounts
        if let accountIdentifier, let book {
            let known = candidates.compactMap { node -> (id: GncGUID, onlineID: String)? in
                guard let stored = book.account(with: node.id)?.onlineID else { return nil }
                return (id: node.id, onlineID: stored)
            }
            if let matched = OnlineIDMatch.account(forIdentifier: accountIdentifier, in: known) {
                return (matched, .rememberedIdentifier)
            }
        }
        if let fileName,
           let matched = ImportFileNameMatch.account(
               forFileNamed: fileName,
               in: candidates.map { (id: $0.id, name: $0.name) }) {
            return (matched, .fileName)
        }
        if let current = selectedAccountID, candidates.contains(where: { $0.id == current }) {
            return (current, .currentRegister)
        }
        return nil
    }

    /// Remembers that this statement's account is that book account, so the
    /// next file from the same bank account needs no choosing.
    ///
    /// Only ever *adds* an identifier: an account that already carries one
    /// keeps it, because overwriting would silently re-point a mapping the
    /// user established, and a longer stored id is the one the prefix matcher
    /// relies on to break ties.
    public func rememberImportAccount(_ identifier: String, for accountID: GncGUID) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let book, let account = book.account(with: accountID),
              account.onlineID == nil
        else { return }
        editingAccounts([accountID], named: "Remember Import Account") {
            account.onlineID = trimmed
        }
    }

    /// Parses a bank file into staged transactions (`FR-XIO-01/02/03`).
    public func parseBankFile(_ data: Data, format: BankFileFormat,
                              csvMapping: CSVColumnMapping? = nil) -> [StagedTransaction] {
        switch format {
        case .csv: return CSVTransactionImporter.parse(data, mapping: csvMapping ?? CSVColumnMapping(date: 0))
        case .qif: return QIFImporter.parse(data)
        case .ofx: return OFXImporter.parse(data)
        case .mt940: return MT940Importer.parse(data)
        case .camt: return CAMTImporter.parse(data)
        // PDF rows are extracted asynchronously by Apple Intelligence before
        // the review sheet opens (see ImportPayload.prestaged).
        case .pdf: return []
        }
    }

    /// Matches staged rows against a target account (`FR-XIO-05`), then lets
    /// categorisation rules override the history-based suggestion (`FR-RULE-01`).
    public func matchStaged(_ staged: [StagedTransaction], intoAccountID id: GncGUID) -> [MatchResult] {
        guard let book, let account = book.account(with: id) else { return [] }
        // Security transactions (QIF `!Type:Invst`, OFX investment blocks) are
        // not cash movements — they take the Stock-Assistant path, not the cash
        // matcher, so they never post to the wrong account here.
        let cash = staged.filter { !$0.isInvestment }
        var results = ImportMatcher.match(cash, into: account, book: book)

        let groups = ruleGroups
        for index in results.indices {
            // A detected transfer counterpart outranks rules and heuristics:
            // the amount + date + wash-leg evidence is stronger than any payee
            // text, and re-categorising it would duplicate the transaction.
            guard results[index].transferSplitID == nil else { continue }
            let staged = results[index].staged
            let name = staged.payee.isEmpty ? staged.memo : staged.payee
            // Rules take precedence.
            if !groups.isEmpty {
                let outcome = RuleEngine.evaluate(groups, context: RuleContext(
                    description: name, memo: staged.memo, amount: staged.amount))
                if let account = outcome.accountID {
                    results[index].suggestedAccountID = account
                    continue
                }
            }
            // Heuristic fallback when history + rules didn't assign one.
            if results[index].suggestedAccountID == nil,
               let categoryName = MerchantHeuristics.category(for: name),
               let account = self.account(named: categoryName) {
                results[index].suggestedAccountID = account
            }
        }
        return results
    }

    /// The investment (security) rows among a staged batch, in file order.
    public func investmentRows(from staged: [StagedTransaction]) -> [StagedTransaction] {
        staged.filter(\.isInvestment)
    }

    /// A security account whose name or commodity ticker matches a staged
    /// investment row's security label, for pre-selecting it in the review.
    public func matchingSecurityAccount(for row: StagedTransaction) -> GncGUID? {
        guard let book, let inv = row.investment, !inv.security.isEmpty else { return nil }
        let needle = inv.security.lowercased()
        return book.accounts.first { account in
            guard account.type == .stock || account.type == .mutualFund else { return false }
            return account.name.lowercased() == needle
                || account.commodity.mnemonic.lowercased() == needle
        }?.guid
    }

    /// Creates a stock transaction from a staged investment row (`FR-XIO-01/02`),
    /// mapping its action to the Stock Assistant. Returns the new transaction's
    /// id, or `nil` for an action that can't be posted (e.g. `.other`).
    @discardableResult
    public func recordStagedInvestment(
        _ row: StagedTransaction, securityID: GncGUID?, settlementID: GncGUID?,
        incomeID: GncGUID? = nil, commissionID: GncGUID? = nil
    ) throws -> GncGUID? {
        guard let inv = row.investment else { return nil }
        let action: StockActionKind
        switch inv.action {
        case .buy: action = .buy
        case .sell: action = .sell
        case .dividend: action = .dividend
        case .reinvestDividend: action = .reinvestDividend
        case .returnOfCapital: action = .returnOfCapital
        case .other: return nil
        }

        // A commission needs a commission account to post to and stay balanced.
        // When none is given (the common import case), fold the fee into the
        // per-share cost — it becomes part of the buy's cost basis, or nets off a
        // sell's proceeds — so the transaction still balances.
        var price = inv.pricePerShare
        var commission = inv.commission
        if commissionID == nil, commission != 0, inv.quantity != 0,
           action == .buy || action == .sell {
            let perShare = commission / inv.quantity
            price += (action == .buy) ? perShare : -perShare
            commission = 0
        }

        return try recordStockTransaction(
            action: action, securityID: securityID, settlementID: settlementID,
            incomeID: incomeID, commissionID: commissionID,
            shares: inv.quantity, pricePerShare: price,
            amount: abs(row.amount), commission: commission,
            date: row.date,
            description: inv.security.isEmpty ? "Imported investment" : inv.security,
            memo: row.memo,
            reference: row.reference)
    }

    /// The broker references (`FITID`s) already posted as investment
    /// transactions — built once per review batch so re-importing an
    /// overlapping broker file can flag each already-recorded trade instead of
    /// silently offering it again (investment rows bypass the cash matcher,
    /// which is the only other duplicate gate).
    public func importedInvestmentReferences() -> Set<String> {
        guard let book else { return [] }
        var references = Set<String>()
        for txn in book.transactions {
            for split in txn.splits {
                if case let .string(id)? = split.kvp["online_id"], !id.isEmpty {
                    references.insert(id)
                }
            }
        }
        return references
    }

    /// Finds a non-placeholder account by (case-insensitive) name.
    private func account(named name: String) -> GncGUID? {
        book?.accounts.first {
            !$0.isPlaceholder && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.guid
    }

    /// Posts accepted rows into the book as balanced transactions: the target
    /// account gets the signed amount, the assigned (or suggested) account the
    /// opposite. Duplicates are skipped (stamping their statement reference on
    /// the matched split for exact re-import matching); a row that completes a
    /// cross-account transfer re-points the existing wash leg here instead of
    /// posting a mirror duplicate; rows without a destination go to the book's
    /// imbalance account when `fallbackToImbalance` (so the Uncategorised
    /// review can sweep them), else are skipped.
    ///
    /// - Returns: the number of rows imported (created + transfer-completed).
    @discardableResult
    public func importMatched(_ results: [MatchResult], intoAccountID id: GncGUID,
                              assignments: [UUID: GncGUID] = [:],
                              skipDuplicates: Bool = true,
                              fallbackToImbalance: Bool = false) -> Int {
        guard let book, let target = book.account(with: id) else { return 0 }
        let imbalance = fallbackToImbalance ? imbalanceFallback(for: target) : nil
        var created: [Transaction] = []
        // Existing wash legs to re-point at the target (the other half of a
        // transfer the counterpart statement already created), and existing
        // matched splits to stamp with the incoming statement reference.
        var healed: [(split: Split, staged: StagedTransaction)] = []
        var referenced: [(split: Split, reference: String)] = []
        for result in results {
            if skipDuplicates && result.isDuplicate {
                if !result.staged.reference.isEmpty, let matchID = result.matchedSplitID,
                   let split = book.split(with: matchID), split.kvp["online_id"] == nil {
                    referenced.append((split, result.staged.reference))
                }
                continue
            }
            let staged = result.staged

            // Transfer completion: re-point the counterpart transaction's wash
            // leg at this account — unless the user overrode the destination,
            // which turns the row back into an ordinary new transaction.
            if let washID = result.transferSplitID,
               assignments[staged.id] == nil || assignments[staged.id] == result.suggestedAccountID,
               let wash = book.split(with: washID), wash.transaction != nil,
               let washAccount = wash.account, ImportMatcher.isWash(washAccount) {
                healed.append((wash, staged))
                continue
            }
            let rawName = staged.payee.isEmpty ? staged.memo : staged.payee
            // Tidy the statement line for the transaction description. The raw
            // narrative goes into the money leg's memo (the smart categoriser's
            // convention) so cleaning never loses it — history matching and
            // future re-imports rely on the raw text surviving somewhere.
            let name = MerchantHeuristics.cleanMerchant(rawName)
            let narrative = staged.memo.isEmpty ? rawName : staged.memo

            // A split record (QIF `S`/`E`/`$`) posts one leg per category, when
            // every category resolves to an account; otherwise it falls back to
            // the single assigned/suggested destination below.
            if staged.isSplit {
                let legs = staged.splits.map { ($0, account(named: $0.category).flatMap { book.account(with: $0) }) }
                if legs.allSatisfy({ $0.1 != nil }) {
                    let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                                  number: staged.reference,
                                                  description: name.isEmpty ? rawName : name)
                    let targetSplit = transaction.addSplit(
                        account: target, value: staged.amount,
                        memo: name == rawName ? staged.memo : narrative)
                    if !staged.reference.isEmpty {
                        targetSplit.kvp["online_id"] = .string(staged.reference)
                    }
                    for (leg, categoryAccount) in legs {
                        transaction.addSplit(account: categoryAccount!, value: -leg.amount, memo: leg.memo)
                    }
                    // Only accept the split when the legs actually sum to the row
                    // total; a malformed file (legs ≠ `T`) falls back to the
                    // single-destination path rather than posting an imbalance.
                    if transaction.isBalanced {
                        created.append(transaction)
                        continue
                    }
                }
            }

            let destinationID = assignments[staged.id] ?? result.suggestedAccountID
            guard let destination = destinationID.flatMap({ book.account(with: $0) }) ?? imbalance
            else { continue }

            let transaction = Transaction(currency: target.commodity, datePosted: staged.date,
                                          number: staged.reference,
                                          description: name.isEmpty ? rawName : name)
            let targetSplit = transaction.addSplit(
                account: target, value: staged.amount,
                memo: name == rawName ? staged.memo : narrative)
            // Record the bank's FITID in the split's `online_id` slot, GnuCash's
            // convention, so a re-import (here or in GnuCash) recognises it.
            if !staged.reference.isEmpty {
                targetSplit.kvp["online_id"] = .string(staged.reference)
            }
            transaction.addSplit(account: destination, value: -staged.amount)
            created.append(transaction)
        }
        let imported = created.count + healed.count
        let touched = created.map(\.guid)
            + healed.compactMap { $0.split.transaction?.guid }
            + referenced.compactMap { $0.split.transaction?.guid }
        if !touched.isEmpty {
            editing(touched, named: "Import Transactions") {
                for transaction in created { book.addTransaction(transaction) }
                for (split, staged) in healed {
                    split.account = target
                    if split.memo.trimmingCharacters(in: .whitespaces).isEmpty {
                        split.memo = staged.memo.isEmpty
                            ? (staged.payee.isEmpty ? staged.memo : staged.payee)
                            : staged.memo
                    }
                    if !staged.reference.isEmpty {
                        split.kvp["online_id"] = .string(staged.reference)
                    }
                }
                for (split, reference) in referenced {
                    split.kvp["online_id"] = .string(reference)
                }
            }
        }
        return imported
    }

    /// The book's existing `Imbalance-<CUR>` account matching the target's
    /// currency, for parking rows nothing categorised. Lookup only — import
    /// never creates accounts.
    func imbalanceFallback(for target: Account) -> Account? {
        book?.accounts.first {
            $0.isImbalanceOrOrphan && !$0.isPlaceholder && $0.commodity == target.commodity
        }
    }
}
