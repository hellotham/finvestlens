//
//  AppModel+SmartCategorize.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Rule-based auto-categorisation: reuse the categorisation of an existing,
//  very similar transaction — including its full split structure. This is what
//  makes recurring salary and dividend payments (usually split across gross
//  income, tax, super, franking credits, …) categorise correctly without the
//  on-device model, which only ever proposes a single category.
//

import Foundation
import FinvestLensEngine
import FinvestLensInterchange

@MainActor
extension AppModel {

    /// A proposed categorisation for one uncategorised transaction, copied from a
    /// similar existing transaction. Replaces the transaction's Imbalance/Orphan
    /// leg(s) with `legs`, scaled so the whole transaction still balances.
    public struct CategoryPlan: Sendable, Identifiable {
        public var id: GncGUID { transactionID }
        public let transactionID: GncGUID
        public let date: Date
        /// The transaction's current description (usually the raw bank narrative).
        public let transactionDescription: String
        public let currencyCode: String
        /// The categorised legs to post (in place of the uncategorised legs).
        public let legs: [PlannedLeg]
        /// The description of the transaction this plan was learned from.
        public let templateDescription: String
        /// How closely the descriptions matched (0…1), for surfacing confidence.
        public let confidence: Double
        /// The friendly description to rename the transaction to (the template's),
        /// when the template is a cleaner label than the raw narrative. `nil`
        /// leaves the description untouched.
        public let newDescription: String?
        /// The anchor (bank) legs whose memo should receive the raw narrative when
        /// renaming, so the imported detail is preserved rather than lost.
        public let anchorSplitIDs: [GncGUID]

        /// What the transaction will read as after applying: the friendly rename
        /// if any, else its current description.
        public var displayDescription: String { newDescription ?? transactionDescription }

        public struct PlannedLeg: Sendable, Identifiable {
            public let id = UUID()
            public let accountID: GncGUID
            public let accountName: String
            public let value: Decimal
            public let memo: String
        }
    }

    /// For each uncategorised transaction among `items`, finds the most similar
    /// fully-categorised transaction and, if the match is confident, returns a
    /// plan that reproduces its split structure (scaled to this transaction's
    /// amount). Keyed by transaction GUID. Transactions with no confident match
    /// are absent — those fall through to the on-device model or manual choice.
    public func smartCategoryPlans(for items: [UncategorizedItem]) -> [GncGUID: CategoryPlan] {
        guard let input = smartCategorizerInput(for: items) else { return [:] }
        return SmartCategorizer.plans(input)
    }

    /// ``smartCategoryPlans(for:)`` with the work off the main actor: only the
    /// copy of what the categoriser reads is taken here. Tokenising every
    /// narrative in the targets' accounts and scoring each target against them
    /// is the cost, and the Auto-Categorise sheet's spinner froze while the
    /// main actor did it (P6).
    public func smartCategoryPlansOffMain(for items: [UncategorizedItem]) async -> [GncGUID: CategoryPlan] {
        guard let book, let input = smartCategorizerInput(for: items) else { return [:] }
        let plans = await Task.detached(priority: .userInitiated) { SmartCategorizer.plans(input) }.value
        // Learned from a book reverted or reloaded meanwhile — the same
        // GUIDs, other history — they are not this book's plans.
        guard self.book === book else { return [:] }
        return plans
    }

    /// The transactions to place and every transaction posting to the
    /// accounts they post to, copied into values. Only those accounts matter:
    /// a target is only ever compared with what was learned in its own
    /// accounts. `book.splits(for:)` lists an account's splits in book order,
    /// the order the corpus was always built in, so ties still go to the
    /// earliest example.
    func smartCategorizerInput(for items: [UncategorizedItem]) -> SmartCategorizer.Input? {
        guard let book else { return nil }
        // The transactions needing a home, de-duplicated (an item is per split).
        var seenTargets = Set<GncGUID>()
        let targets = items.compactMap { item -> Transaction? in
            guard seenTargets.insert(item.transactionID).inserted else { return nil }
            return book.transaction(with: item.transactionID)
        }
        guard !targets.isEmpty else { return nil }

        var accounts: [GncGUID: SmartCategorizer.AccountFacts] = [:]
        func copy(_ transaction: Transaction) -> SmartCategorizer.Entry {
            SmartCategorizer.Entry(
                guid: transaction.guid, date: transaction.datePosted,
                description: transaction.transactionDescription, currency: transaction.currency,
                legs: transaction.splits.map { split in
                    if let account = split.account, accounts[account.guid] == nil {
                        accounts[account.guid] = SmartCategorizer.AccountFacts(account)
                    }
                    return SmartCategorizer.Leg(splitID: split.guid, accountID: split.account?.guid,
                                                value: split.value, memo: split.memo)
                })
        }

        var anchorAccounts: [Account] = []
        var seenAnchors = Set<GncGUID>()
        for target in targets {
            for split in target.splits {
                guard let account = split.account, !account.isWash,
                      SmartCategorizer.isMoneyAnchor(account.type),
                      seenAnchors.insert(account.guid).inserted else { continue }
                anchorAccounts.append(account)
            }
        }

        var history: [SmartCategorizer.Entry] = []
        var historyIndex: [GncGUID: Int] = [:]
        var postings: [GncGUID: [SmartCategorizer.Posting]] = [:]
        for account in anchorAccounts {
            var list: [SmartCategorizer.Posting] = []
            for split in book.splits(for: account) {
                guard let transaction = split.transaction,
                      let leg = transaction.splits.firstIndex(where: { $0 === split }) else { continue }
                let index: Int
                if let known = historyIndex[transaction.guid] {
                    index = known
                } else {
                    index = history.count
                    historyIndex[transaction.guid] = index
                    history.append(copy(transaction))
                }
                list.append(SmartCategorizer.Posting(entry: index, leg: leg))
            }
            postings[account.guid] = list
        }
        return SmartCategorizer.Input(targets: targets.map(copy), history: history,
                                      postings: postings, accounts: accounts)
    }

    /// Applies accepted plans and single-account assignments as one undoable edit.
    /// Plans replace a transaction's uncategorised legs with categorised ones;
    /// assignments simply move a single leg. A split belonging to a planned
    /// transaction is skipped by the assignment pass so the two never collide.
    @discardableResult
    public func applyCategorization(plans: [CategoryPlan],
                                    assignments: [GncGUID: GncGUID]) -> Int {
        guard let book else { return 0 }
        let plannedTxns = Set(plans.map(\.transactionID))

        // The sheet works its plans out when it opens, and the book can move
        // before Apply — another window, another device. A plan is applied
        // only while it still fits its transaction, and a leg is moved only
        // while it is still waiting for a category.
        let validPlans = plans.filter { plan in
            book.transaction(with: plan.transactionID).map { SmartCategorizer.stillFits(plan, $0) } ?? false
        }
        let moves = assignments.compactMap { splitID, accountID -> (split: Split, account: Account)? in
            guard let split = book.split(with: splitID), split.account?.isWash ?? false,
                  let account = book.account(with: accountID),
                  let txn = split.transaction, !plannedTxns.contains(txn.guid)
            else { return nil }
            return (split, account)
        }

        var touched = Set<GncGUID>()
        for plan in validPlans { touched.insert(plan.transactionID) }
        for move in moves { if let id = move.split.transaction?.guid { touched.insert(id) } }
        guard !touched.isEmpty else { return 0 }

        var applied = 0
        editing(Array(touched), named: "Categorise Transactions") {
            for plan in validPlans {
                guard let txn = book.transaction(with: plan.transactionID) else { continue }
                // Rename to the friendly description, moving the raw narrative into
                // the bank leg's memo (only when that memo is empty, so nothing the
                // user typed is overwritten).
                if let friendly = plan.newDescription, friendly != txn.transactionDescription {
                    let narrative = txn.transactionDescription
                    for id in plan.anchorSplitIDs {
                        guard let split = book.split(with: id),
                              split.memo.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        split.memo = narrative
                    }
                    txn.transactionDescription = friendly
                }
                for split in txn.splits where split.account?.isWash ?? false {
                    txn.removeSplit(split)
                }
                for leg in plan.legs {
                    guard let account = book.account(with: leg.accountID) else { continue }
                    txn.addSplit(account: account, value: leg.value, memo: leg.memo)
                }
                applied += 1
            }
            for move in moves { move.split.account = move.account; applied += 1 }
        }
        return applied
    }

    // MARK: - Description similarity

    /// Alphabetic tokens worth matching on: lowercased, punctuation-split, with
    /// pure numbers (reference/date noise), common filler, and month-year
    /// compounds ("VAP DST JAN23") dropped. Delegates to the matcher's shared
    /// tokeniser so the two narrative pipelines can never drift again.
    nonisolated static func significantTokens(_ text: String) -> Set<String> {
        ImportMatcher.narrativeTokens(text, droppingDateTokens: true)
    }
}

/// The categoriser itself, over values: no `Book`, no actor. What it reads is
/// copied out by ``AppModel/smartCategorizerInput(for:)`` on the main actor,
/// so the tokenising and scoring can run anywhere — and give the same plans
/// wherever they run.
enum SmartCategorizer {

    struct Leg: Sendable {
        let splitID: GncGUID
        let accountID: GncGUID?
        let value: Decimal
        let memo: String
    }

    /// One transaction, as the categoriser sees it.
    struct Entry: Sendable {
        let guid: GncGUID
        let date: Date
        let description: String
        let currency: Commodity
        let legs: [Leg]
    }

    struct AccountFacts: Sendable {
        let fullName: String
        let type: AccountType
        let isWash: Bool
        let commodity: Commodity

        init(_ account: Account) {
            fullName = account.fullName
            type = account.type
            isWash = account.isWash
            commodity = account.commodity
        }
    }

    /// A leg of a history entry posted to one of the targets' accounts.
    struct Posting: Sendable {
        let entry: Int
        let leg: Int
    }

    struct Input: Sendable {
        let targets: [Entry]
        /// Every transaction with a leg in one of the targets' money accounts.
        let history: [Entry]
        /// Per money account, its legs in `history`, in book order.
        let postings: [GncGUID: [Posting]]
        let accounts: [GncGUID: AccountFacts]
    }

    /// A match must clear this share of a template's distinctive content…
    static let scoreThreshold = 0.6
    /// …and win by this factor over the next distinct payee, or it is ambiguous…
    static let ambiguityMargin = 1.25
    /// …and be carried by at least one token this distinctive (roughly: present in
    /// under ~60% of the account's entries)…
    static let distinctiveIdf = 0.5
    /// …with the shared tokens carrying at least this much total weight, so a lone
    /// weak token can't anchor a match.
    static let minSharedWeight = 1.0

    /// A balance-sheet account a register is opened on — the kind that carries the
    /// bank/card narrative — as opposed to an income/expense category.
    static func isMoneyAnchor(_ type: AccountType) -> Bool {
        switch type {
        case .bank, .cash, .credit, .asset, .liability, .receivable, .payable, .stock, .mutualFund:
            return true
        case .income, .expense, .equity, .trading, .root:
            return false
        }
    }

    /// One learned example: a categorised transaction seen through the money leg
    /// posted to a particular account.
    private struct Example {
        let entry: Int
        /// The raw narrative's tokens (the money-leg memo, or the description
        /// when there is no memo yet), as this account's token numbers, ascending.
        let tokens: [Int]
        /// The sum of their weights, which no target changes — worked out once
        /// rather than once per target.
        let weight: Double
        /// Whether this example carries a distinct raw narrative in its memo, i.e.
        /// the label really is a cleaned-up rename (so adopting it is meaningful).
        let cleaned: Bool
    }

    /// Every learned example for one account, and how distinctive each of its
    /// tokens is.
    ///
    /// Tokens are numbered in the order their sorted spellings first appear,
    /// and every weight is summed in that order. A `Set`'s iteration order
    /// differs between two sets with the same contents, so summing over one
    /// gave the same example a score that differed in its last bits from call
    /// to call — and two near-equal candidates were then decided at random:
    /// on the reference book, two runs of Auto-Categorise over the same
    /// transactions proposed different plans.
    private struct AccountCorpus {
        var examples: [Example] = []
        var numbers: [String: Int] = [:]
        /// Per token number, the inverse document frequency: ~0 for a token in
        /// most examples, larger for a rare, distinctive one.
        var idf: [Double] = []

        init(_ postings: [Posting], history: [Entry], accounts: [GncGUID: AccountFacts]) {
            var raw: [(entry: Int, tokens: [Int], cleaned: Bool)] = []
            var documentFrequency: [Int] = []
            for posting in postings {
                let entry = history[posting.entry]
                guard SmartCategorizer.isTemplate(entry, accounts) else { continue }
                let leg = entry.legs[posting.leg]
                let text = leg.memo.isEmpty ? entry.description : leg.memo
                let spelled = AppModel.significantTokens(text).sorted()
                guard !spelled.isEmpty else { continue }
                var tokens: [Int] = []
                tokens.reserveCapacity(spelled.count)
                for token in spelled {
                    let number: Int
                    if let known = numbers[token] {
                        number = known
                    } else {
                        number = numbers.count
                        numbers[token] = number
                        documentFrequency.append(0)
                    }
                    documentFrequency[number] += 1
                    tokens.append(number)
                }
                tokens.sort()
                raw.append((posting.entry, tokens,
                            !leg.memo.isEmpty && leg.memo != entry.description))
            }
            let count = Double(raw.count + 1)
            idf = documentFrequency.map { max(0, log(count / Double($0 + 1))) }
            examples = raw.map { item in
                Example(entry: item.entry, tokens: item.tokens,
                        weight: item.tokens.reduce(0.0) { $0 + idf[$1] }, cleaned: item.cleaned)
            }
        }

        /// A target's tokens as this account's numbers, ascending; a token the
        /// account has never seen cannot be shared with any of its examples.
        func numbered(_ tokens: Set<String>) -> [Int] {
            tokens.compactMap { numbers[$0] }.sorted()
        }
    }

    /// A candidate to learn from: balanced, at least two legs, every leg posting
    /// to a real (non-Imbalance/Orphan) account, and single-currency throughout
    /// so scaling a value scales its quantity 1:1.
    static func isTemplate(_ entry: Entry, _ accounts: [GncGUID: AccountFacts]) -> Bool {
        guard entry.legs.count >= 2 else { return false }
        for leg in entry.legs {
            guard let id = leg.accountID, let account = accounts[id], !account.isWash else { return false }
            if account.commodity != entry.currency { return false }
        }
        let total = entry.legs.reduce(Decimal(0)) { $0 + $1.value }
        return Money(total, entry.currency).isZero
    }

    static func plans(_ input: Input) -> [GncGUID: AppModel.CategoryPlan] {
        var corpora: [GncGUID: AccountCorpus] = [:]
        for (accountID, postings) in input.postings {
            let corpus = AccountCorpus(postings, history: input.history, accounts: input.accounts)
            if !corpus.examples.isEmpty { corpora[accountID] = corpus }
        }
        guard !corpora.isEmpty else { return [:] }

        var plans: [GncGUID: AppModel.CategoryPlan] = [:]
        for target in input.targets {
            if let plan = bestPlan(for: target, corpora: corpora, input: input) {
                plans[target.guid] = plan
            }
        }
        return plans
    }

    private static func bestPlan(for target: Entry, corpora: [GncGUID: AccountCorpus],
                                 input: Input) -> AppModel.CategoryPlan? {
        // The target's real (anchor) legs — usually the single bank/card leg — and
        // the value they net to. The uncategorised legs will be replaced.
        let anchorLegs = target.legs.filter { leg in
            leg.accountID.flatMap { input.accounts[$0] }.map { !$0.isWash } ?? false
        }
        var anchorAccounts: [GncGUID] = []
        for leg in anchorLegs where !anchorAccounts.contains(leg.accountID!) {
            anchorAccounts.append(leg.accountID!)
        }
        let anchorValue = anchorLegs.reduce(Decimal(0)) { $0 + $1.value }
        guard !anchorAccounts.isEmpty, anchorValue != 0 else { return nil }
        // Single-currency only, matching the template requirement.
        guard anchorLegs.allSatisfy({ input.accounts[$0.accountID!]?.commodity == target.currency })
        else { return nil }

        // The target's raw text: its description plus any narrative already sitting
        // in its own money-leg memos.
        var targetTokens = AppModel.significantTokens(target.description)
        for leg in anchorLegs { targetTokens.formUnion(AppModel.significantTokens(leg.memo)) }
        guard !targetTokens.isEmpty else { return nil }

        // Score every learned example in the target's anchor account(s): the share
        // of that example's distinctive (idf-weighted) content the target covers.
        // A match must be carried by at least one distinctive token, never by
        // ubiquitous ones alone.
        var scored: [(example: Example, score: Double)] = []
        for accountID in anchorAccounts {
            guard let corpus = corpora[accountID] else { continue }
            let wanted = corpus.numbered(targetTokens)
            guard !wanted.isEmpty else { continue }
            for example in corpus.examples where example.weight > 0 {
                let entry = input.history[example.entry]
                guard entry.guid != target.guid, entry.currency == target.currency else { continue }
                // The shared tokens, by merging the two ascending lists.
                var sharedWeight = 0.0
                var distinctive = false
                var i = 0, j = 0
                while i < wanted.count, j < example.tokens.count {
                    let a = wanted[i], b = example.tokens[j]
                    if a == b {
                        let weight = corpus.idf[a]
                        sharedWeight += weight
                        if weight >= distinctiveIdf { distinctive = true }
                        i += 1; j += 1
                    } else if a < b {
                        i += 1
                    } else {
                        j += 1
                    }
                }
                // An absolute floor as well as the ratio: a single weak shared
                // token (e.g. just "anz") shouldn't carry a match on its own.
                guard distinctive, sharedWeight >= minSharedWeight else { continue }
                scored.append((example, sharedWeight / example.weight))
            }
        }

        // Best score per distinct payee, then the ambiguity guard: only propose
        // when one payee clearly wins. A narrative that fits several payees equally
        // (every PayPal debit reads the same bar the reference) is left to the user.
        var bestByFriendly: [String: (score: Double, example: Example)] = [:]
        var order: [String] = []
        for item in scored where item.score >= scoreThreshold {
            let friendly = input.history[item.example.entry].description
            if let existing = bestByFriendly[friendly] {
                if existing.score >= item.score { continue }
            } else {
                order.append(friendly)
            }
            bestByFriendly[friendly] = (item.score, item.example)
        }
        // Stable over the order payees were first seen, so equal scores rank the
        // same way every time.
        let ranked = order.compactMap { bestByFriendly[$0] }.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score
                                                           : $0.offset < $1.offset }
            .map(\.element)
        guard let winner = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].score * ambiguityMargin > winner.score { return nil }

        return buildPlan(for: target, from: winner.example, anchorLegs: anchorLegs,
                         anchorAccounts: Set(anchorAccounts), anchorValue: anchorValue,
                         confidence: winner.score, input: input)
    }

    private static func buildPlan(for target: Entry, from example: Example,
                                  anchorLegs: [Leg], anchorAccounts: Set<GncGUID>,
                                  anchorValue: Decimal, confidence: Double,
                                  input: Input) -> AppModel.CategoryPlan? {
        let template = input.history[example.entry]
        let isAnchor = { (leg: Leg) in leg.accountID.map(anchorAccounts.contains) ?? false }
        let templateAnchorValue = template.legs.filter(isAnchor).reduce(Decimal(0)) { $0 + $1.value }
        // Scale must be positive: a deposit-shaped template shouldn't categorise
        // a withdrawal-shaped transaction (and vice versa).
        guard templateAnchorValue != 0, (templateAnchorValue > 0) == (anchorValue > 0) else { return nil }
        let scale = anchorValue / templateAnchorValue

        let categoryLegs = template.legs.filter { !isAnchor($0) }
        guard !categoryLegs.isEmpty else { return nil }

        let currency = target.currency
        var legs: [AppModel.CategoryPlan.PlannedLeg] = categoryLegs.compactMap { leg in
            guard let id = leg.accountID, let account = input.accounts[id] else { return nil }
            return AppModel.CategoryPlan.PlannedLeg(
                accountID: id, accountName: account.fullName,
                value: currency.round(leg.value * scale), memo: leg.memo)
        }
        guard legs.count == categoryLegs.count, !legs.isEmpty else { return nil }

        // The categorised legs must net to -anchorValue for the transaction to
        // balance; rounding leaves a residual, which the largest leg absorbs.
        let plannedSum = legs.reduce(Decimal(0)) { $0 + $1.value }
        let residual = -anchorValue - plannedSum
        if residual != 0, let biggest = legs.indices.max(by: { abs(legs[$0].value) < abs(legs[$1].value) }) {
            let leg = legs[biggest]
            legs[biggest] = AppModel.CategoryPlan.PlannedLeg(
                accountID: leg.accountID, accountName: leg.accountName,
                value: leg.value + residual, memo: leg.memo)
        }

        // Adopt the learned friendly label when this example is a genuine rename
        // (its raw narrative lives in the money-leg memo, distinct from the label).
        // The target's own raw narrative is then preserved in its money-leg memo
        // rather than discarded, matching how the user hand-categorises these.
        let friendly = template.description.trimmingCharacters(in: .whitespaces)
        let newDescription: String? = (example.cleaned && !friendly.isEmpty
                                        && friendly != target.description) ? friendly : nil

        return AppModel.CategoryPlan(
            transactionID: target.guid, date: target.date,
            transactionDescription: target.description,
            currencyCode: currency.mnemonic, legs: legs,
            templateDescription: template.description, confidence: confidence,
            newDescription: newDescription, anchorSplitIDs: anchorLegs.map(\.splitID))
    }

    /// Whether a plan worked out earlier can still be applied: the transaction
    /// still has a leg waiting for a category, and its real legs still net to
    /// what the planned legs balance. A transaction categorised or re-valued
    /// since — in another window, on another device — is left alone rather
    /// than given legs that would unbalance it.
    @MainActor
    static func stillFits(_ plan: AppModel.CategoryPlan, _ transaction: Transaction) -> Bool {
        let parked = { (split: Split) in split.account?.isWash ?? false }
        guard transaction.splits.contains(where: parked) else { return false }
        // What applying leaves: every leg but the parked ones, plus the plan's.
        let kept = transaction.splits.filter { !parked($0) }.reduce(Decimal(0)) { $0 + $1.value }
        let planned = plan.legs.reduce(Decimal(0)) { $0 + $1.value }
        return Money(kept + planned, transaction.currency).isZero
    }
}
