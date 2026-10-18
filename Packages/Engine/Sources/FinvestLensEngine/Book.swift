//
//  Book.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The top-level container for a set of accounts, transactions, and commodities
/// — the in-memory source of truth (Architecture §3).
///
/// `Book` owns the object graph: the root account (and its subtree), all
/// transactions (which own their splits), and the commodity table. Balances are
/// computed here because the `Book` is the only object that sees every split.
public final class Book {

    /// Stable identity, preserved across GnuCash round-trips.
    public let guid: GncGUID

    /// The invisible root of the account tree.
    public let rootAccount: Account

    /// All transactions in the book.
    public private(set) var transactions: [Transaction]

    /// Known commodities (currencies and securities).
    public private(set) var commodities: [Commodity]

    /// The price database (`FR-ENG-09`).
    ///
    /// Every mutation goes through the methods under *Prices* below, which
    /// keep the lookup index in step: an added price is inserted into its two
    /// buckets in date order, a removed one is taken out of them. This used to
    /// be a `didSet` that dropped the index on any change, so each price
    /// edit — one quote refresh, one exchange rate — was followed by a full
    /// rebuild (bucket and sort 163k prices) inside the next account-tree
    /// refresh: 0.35 s on the reference book for a 20 ms refresh. The index is
    /// still built lazily, so loading a book (100k appends before any lookup)
    /// inserts nothing; and a wholesale replacement still drops it.
    public private(set) var prices: [Price]

    /// Preserved book-level key-value slots.
    public var kvp: KvpFrame

    // MARK: Business objects (`FR-BUS-*`)

    public internal(set) var customers: [Customer]
    public internal(set) var vendors: [Vendor]
    public internal(set) var employees: [Employee]
    public internal(set) var jobs: [Job]
    public internal(set) var invoices: [Invoice]
    public internal(set) var billTerms: [BillTerm]
    public internal(set) var taxTables: [TaxTable]
    /// Business lots (A/R / A/P), keyed nowhere special — walked by account.
    public internal(set) var lots: [Lot]

    /// Designated initialiser adopting an existing root account (used when
    /// importing, so the root's GnuCash GUID is preserved).
    public init(
        guid: GncGUID = .random(),
        rootAccount: Account,
        kvp: KvpFrame = KvpFrame()
    ) {
        self.guid = guid
        self.rootAccount = rootAccount
        self.transactions = []
        self.commodities = []
        self.prices = []
        self.kvp = kvp
        self.customers = []
        self.vendors = []
        self.employees = []
        self.jobs = []
        self.invoices = []
        self.billTerms = []
        self.taxTables = []
        self.lots = []
    }

    /// Creates an empty book with a fresh root account denominated in
    /// `baseCurrency`.
    public convenience init(
        guid: GncGUID = .random(),
        baseCurrency: Commodity = .aud,
        kvp: KvpFrame = KvpFrame()
    ) {
        let root = Account(name: "Root Account", type: .root, commodity: baseCurrency)
        self.init(guid: guid, rootAccount: root, kvp: kvp)
        registerCommodity(baseCurrency)
    }

    // MARK: Accounts

    /// All accounts in the tree, excluding the invisible root.
    public var accounts: [Account] { rootAccount.descendants }

    /// The book's base currency: the root account's commodity when it is a
    /// currency, falling back to the first registered currency. This is the
    /// one authoritative derivation — `commodities.first` alone is
    /// registration-order dependent and can disagree with the root account's
    /// actual denomination on a loaded book.
    public var baseCurrency: Commodity {
        if rootAccount.commodity.namespace == .currency { return rootAccount.commodity }
        return commodities.first { $0.namespace == .currency } ?? .aud
    }

    /// Adds `account` under `parent` (default: the root account).
    @discardableResult
    public func addAccount(_ account: Account, under parent: Account? = nil) -> Account {
        (parent ?? rootAccount).addChild(account)
        registerCommodity(account.commodity)
        return account
    }

    /// Looks up an account by GUID — any account in the tree, never the root.
    ///
    /// From an index, not by walking: the walk built `rootAccount.descendants`
    /// — a fresh array per node — and searched it, about 100 µs a call on the
    /// reference book's 559 accounts, and the Overview's performance card asks
    /// 864 times a pass (86 ms, Performance Review R5b). The tree changes
    /// under the book's feet (accounts are added and moved on each other), so
    /// a hit is checked against it — still in the tree, by its parents — and
    /// a miss, or a hit that has left the tree, rebuilds the index once. An
    /// account moved within the tree is still the same object, so it stays.
    public func account(with guid: GncGUID) -> Account? {
        if let hit = accountIndex?[guid], isInTree(hit) { return hit }
        rebuildAccountIndex()
        return accountIndex?[guid]
    }

    private func isInTree(_ account: Account) -> Bool {
        guard account !== rootAccount else { return false }
        var node = account
        while let parent = node.parent { node = parent }
        return node === rootAccount
    }

    /// Pre-order, as `descendants` lists them, so that of two accounts with
    /// one GUID (a damaged book) the one the walk found first still wins.
    private func rebuildAccountIndex() {
        var index: [GncGUID: Account] = [:]
        index.reserveCapacity(accountIndex?.count ?? 64)
        func visit(_ account: Account) {
            for child in account.children {
                if index[child.guid] == nil { index[child.guid] = child }
                visit(child)
            }
        }
        visit(rootAccount)
        accountIndex = index
    }

    // MARK: Commodities

    /// Removes a commodity from the table — only when no account, price or
    /// transaction refers to it, which is the state a just-added security is
    /// in when its addition is undone. Returns whether it was removed.
    @discardableResult
    public func unregisterCommodity(_ commodity: Commodity) -> Bool {
        guard !accounts.contains(where: { $0.commodity == commodity }),
              !prices.contains(where: { $0.commodity == commodity || $0.currency == commodity }),
              !transactions.contains(where: { $0.currency == commodity })
        else { return false }
        let count = commodities.count
        commodities.removeAll { $0 == commodity }
        return commodities.count != count
    }

    /// Adds a commodity to the table if not already present.
    public func registerCommodity(_ commodity: Commodity) {
        if !commodities.contains(commodity) {
            commodities.append(commodity)
        }
    }

    // MARK: Prices

    /// Updates a commodity's display metadata (name / fraction / exchange code)
    /// across every account, price and the commodity table. Identity (namespace
    /// + mnemonic) is unchanged, so prices and quotes stay linked (`FR-INV-07`).
    ///
    /// - Parameter exchangeCode: GnuCash's `cmdty:xcode` — an ISIN for a bond,
    ///   an exchange ticker for a share (`FR-INV-32`). Passing an empty string
    ///   clears it; passing `nil` leaves it alone. Those have to differ, because
    ///   "no ISIN" is a thing a person needs to be able to say and the field is
    ///   how the FIIG provider finds a bond at all.
    public func updateCommodityMetadata(_ commodity: Commodity, fullName: String?,
                                        smallestFraction: Int?, exchangeCode: String? = nil) {
        func apply(_ c: inout Commodity) {
            if let fullName, !fullName.isEmpty { c.fullName = fullName }
            if let smallestFraction, smallestFraction >= 1 { c.smallestFraction = smallestFraction }
            if let exchangeCode { c.exchangeCode = exchangeCode.isEmpty ? nil : exchangeCode }
        }
        for account in accounts where account.commodity == commodity { apply(&account.commodity) }
        for index in prices.indices where prices[index].commodity == commodity { apply(&prices[index].commodity) }
        for index in commodities.indices where commodities[index] == commodity { apply(&commodities[index]) }
        // The index is keyed by commodity, and the keys just changed in place.
        invalidatePriceIndex()
    }

    /// Adds a price to the database (and registers its commodities).
    @discardableResult
    public func addPrice(_ price: Price) -> Price {
        registerCommodity(price.commodity)
        registerCommodity(price.currency)
        prices.append(price)
        indexInsert(price)
        priceChangeLog?.append(.added(price))
        unsavedPrices?.added(price.guid)
        return price
    }

    /// Adds every price in `incoming` that the book does not already hold,
    /// under GnuCash's own duplicate rule (see ``Price/Identity``), and returns
    /// the ones actually added. Duplicates *within* `incoming` are collapsed
    /// too — a fallback sweep can legitimately fetch the same day twice from
    /// two providers.
    ///
    /// Each candidate is checked against its own `(commodity, currency)`
    /// bucket of the lookup index — a binary search to its day, then the
    /// handful of prices on that day. This used to build a set of every
    /// price's identity first, and an identity is two calendar computations
    /// (`dayNeutral`), so one quote refresh of forty securities began with
    /// 163k calendar operations on the reference book.
    @discardableResult
    public func addPrices(deduplicating incoming: [Price]) -> [Price] {
        guard !incoming.isEmpty else { return [] }
        buildIndexIfNeeded()
        var seen: Set<Price.Identity> = []
        var added: [Price] = []
        for price in incoming {
            let identity = price.identity
            guard seen.insert(identity).inserted, !holdsPrice(matching: identity) else { continue }
            addPrice(price)
            added.append(price)
        }
        return added
    }

    /// Whether a price with this identity is already in the database.
    private func holdsPrice(matching identity: Price.Identity) -> Bool {
        let pair = PricePair(commodity: identity.commodity, currency: identity.currency)
        guard let bucket = pairIndex?[pair] else { return false }
        // Buckets are date-sorted and `dayNeutral` is monotonic in the date,
        // so a day's prices are one contiguous run: binary-search to its
        // start, then walk it.
        var low = 0, high = bucket.count
        while low < high {
            let mid = (low + high) / 2
            if Price.dayNeutral(bucket[mid].date) < identity.day { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < bucket.count, Price.dayNeutral(bucket[index].date) == identity.day {
            if bucket[index].value == identity.value { return true }
            index += 1
        }
        return false
    }

    /// Replaces the whole price database. Not an undo primitive any more —
    /// scoped price edits undo through ``PriceChange`` — but the one price
    /// mutation that is cheaper to follow with a lazy rebuild of the index
    /// than to mirror.
    public func replaceAllPrices(_ newPrices: [Price]) {
        if priceChangeLog != nil {
            priceChangeLog?.append(contentsOf: prices.map(PriceChange.removed))
            priceChangeLog?.append(contentsOf: newPrices.map(PriceChange.added))
        }
        prices = newPrices
        invalidatePriceIndex()
        unsavedPrices = nil         // the next save writes them all
    }

    /// Removes a price by GUID.
    public func removePrice(_ guid: GncGUID) {
        removePrices { $0.guid == guid }
    }

    /// Removes every price matching `predicate` in a single pass. Used to wipe a
    /// security's history before rebuilding it (a per-GUID loop would be O(n²)).
    @discardableResult
    public func removePrices(where predicate: (Price) -> Bool) -> Int {
        let before = prices.count
        if pairIndex == nil, priceChangeLog == nil, unsavedPrices == nil {
            prices.removeAll(where: predicate)
        } else {
            // One pass: the removed rows are collected as they go, for the
            // index and the change log.
            var removed: [Price] = []
            prices.removeAll { price in
                guard predicate(price) else { return false }
                removed.append(price)
                return true
            }
            guard !removed.isEmpty else { return 0 }
            indexRemove(removed)
            priceChangeLog?.append(contentsOf: removed.map(PriceChange.removed))
            for price in removed { unsavedPrices?.removed(price.guid) }
        }
        return before - prices.count
    }

    // MARK: Price change recording

    /// One price added or removed while the book was recording
    /// (``beginRecordingPriceChanges()``). An edit's undo is the inverse of
    /// its log — what it added is removed, what it removed is put back — so
    /// undo captures only what the edit changed, never the whole database:
    /// snapshotting `prices` cost a copy of 163k rows on the reference book
    /// the moment the edit appended to it.
    public enum PriceChange: Sendable, Equatable {
        case added(Price)
        case removed(Price)
    }

    private var priceChangeLog: [PriceChange]?

    /// Starts recording price mutations. Not reentrant: a nested begin
    /// restarts the log.
    public func beginRecordingPriceChanges() {
        priceChangeLog = []
    }

    /// Stops recording and returns what happened since the begin, in order.
    public func endRecordingPriceChanges() -> [PriceChange] {
        defer { priceChangeLog = nil }
        return priceChangeLog ?? []
    }

    /// Applies the inverse of `changes`: every added price is removed (by
    /// GUID, in one pass) and every removed price is added back, in the order
    /// they were logged — a removal pass logs them in database order, and
    /// within a day that order is what decides which price is latest, so it
    /// must come back as it was. Recorded like any other mutation when the
    /// book is recording, which is what makes an undo's own log the redo.
    public func revertPriceChanges(_ changes: [PriceChange]) {
        var addedGuids: Set<GncGUID> = []
        for case .added(let price) in changes { addedGuids.insert(price.guid) }
        if !addedGuids.isEmpty {
            removePrices { addedGuids.contains($0.guid) }
        }
        for case .removed(let price) in changes {
            addPrice(price)
        }
    }

    // MARK: Price index

    /// A quoted pair: what is priced, and what it is priced in.
    struct PricePair: Hashable {
        let commodity: Commodity
        let currency: Commodity
    }

    /// Prices bucketed by pair and by commodity, each bucket sorted by date.
    ///
    /// `latestPrice` used to scan the whole database — 26 ms on a 100k-price
    /// book — and the account tree asks for prices thousands of times per
    /// refresh, which is what made opening a real book take ~45s. Built lazily
    /// on first lookup and dropped whenever `prices` changes, so loading a book
    /// (100k appends) doesn't rebuild it once per price.
    private var pairIndex: [PricePair: [Price]]?
    private var commodityIndex: [Commodity: [Price]]?

    func invalidatePriceIndex() {
        pairIndex = nil
        commodityIndex = nil
    }

    /// Puts a just-appended price into both buckets, after every price of the
    /// same day already there — the position a rebuild from `prices` would
    /// give it, so "the last price recorded for the winning day" stays the
    /// latest arrival (see `latest(in:on:)`). Nothing to do while the index
    /// has not been built.
    private func indexInsert(_ price: Price) {
        guard pairIndex != nil, commodityIndex != nil else { return }
        // The position is computed on a temporary view of the bucket and the
        // insert goes through the dictionary's own in-place access — holding
        // a copy of the bucket across the insert would make the insert copy
        // it again first.
        func place<Key: Hashable>(_ key: Key, in index: inout [Key: [Price]]?) {
            let at = Self.insertionIndex(in: index?[key] ?? [], for: price.date)
            index?[key, default: []].insert(price, at: at)
        }
        place(PricePair(commodity: price.commodity, currency: price.currency), in: &pairIndex)
        place(price.commodity, in: &commodityIndex)
    }

    /// Takes removed prices out of their buckets: the removals are grouped by
    /// bucket and each affected bucket is filtered once, so a security's
    /// whole history going costs one pass over its own bucket, not one scan
    /// per removed price.
    private func indexRemove(_ removed: [Price]) {
        guard pairIndex != nil, commodityIndex != nil else { return }
        var byPair: [PricePair: Set<GncGUID>] = [:]
        var byCommodity: [Commodity: Set<GncGUID>] = [:]
        for price in removed {
            byPair[PricePair(commodity: price.commodity, currency: price.currency), default: []]
                .insert(price.guid)
            byCommodity[price.commodity, default: []].insert(price.guid)
        }
        // An emptied bucket goes, as a rebuild would never have made it:
        // `pricedAgainst` reads the keys as "pairs with a price".
        for (pair, guids) in byPair {
            pairIndex?[pair]?.removeAll { guids.contains($0.guid) }
            if pairIndex?[pair]?.isEmpty == true { pairIndex?.removeValue(forKey: pair) }
        }
        for (commodity, guids) in byCommodity {
            commodityIndex?[commodity]?.removeAll { guids.contains($0.guid) }
            if commodityIndex?[commodity]?.isEmpty == true {
                commodityIndex?.removeValue(forKey: commodity)
            }
        }
    }

    /// Where a price of `date` goes in a date-sorted bucket: after the last
    /// price on or before it. The same binary search as `latest(in:on:)`.
    private static func insertionIndex(in bucket: [Price], for date: Date) -> Int {
        var low = 0, high = bucket.count
        while low < high {
            let mid = (low + high) / 2
            if bucket[mid].date > date { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Sorts a bucket by date, keeping insertion order within a date — so
    /// "which of a day's prices is newest" stays answerable, since every price
    /// on a day carries the identical day-neutral instant and cannot be ranked
    /// by timestamp.
    private static func sortedByDate(_ bucket: [Price]) -> [Price] {
        bucket.enumerated()
            .sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset
                                                        : $0.element.date < $1.element.date }
            .map(\.element)
    }

    private func buildIndexIfNeeded() {
        guard pairIndex == nil || commodityIndex == nil else { return }
        var pairs: [PricePair: [Price]] = [:]
        var byCommodity: [Commodity: [Price]] = [:]
        for price in prices {
            pairs[PricePair(commodity: price.commodity, currency: price.currency), default: []]
                .append(price)
            byCommodity[price.commodity, default: []].append(price)
        }
        pairIndex = pairs.mapValues(Self.sortedByDate)
        commodityIndex = byCommodity.mapValues(Self.sortedByDate)
    }

    /// The latest price in a date-sorted `bucket` on or before `date`: the
    /// **last** price recorded for the winning day.
    ///
    /// Every price is stored day-neutral, so a day's prices all share one
    /// instant and nothing can order them by time. This used to rewind to the
    /// *first* of them, which made the earliest row of a day permanently
    /// authoritative: the 06:00 auto-refresh valued the portfolio for the whole
    /// day, and the evening close — correctly stored, plainly newer — could
    /// never be read. Later arrival is the only evidence of recency there is,
    /// so it decides.
    ///
    /// GnuCash breaks the same tie by GUID (`compare_prices_by_date`,
    /// `libgnucash/engine/gnc-pricedb.cpp`), which is arbitrary rather than
    /// wrong; insertion order is at least the answer a person would predict.
    private static func latest(in bucket: [Price], on date: Date?) -> Price? {
        // First index past the cut-off — the same search that places a new
        // price, so where a price is inserted and where a lookup expects it
        // cannot drift apart.
        let cut = date.map { insertionIndex(in: bucket, for: $0) } ?? bucket.count
        guard cut > 0 else { return nil }
        return bucket[cut - 1]
    }

    /// The date of the newest price of any commodity `include` accepts — one
    /// look per commodity in the index, where a pass over `prices` copied
    /// every row (164k on the reference book) to keep one date.
    public func newestPriceDate(where include: (Commodity) -> Bool) -> Date? {
        buildIndexIfNeeded()
        var newest: Date?
        for (commodity, bucket) in commodityIndex ?? [:] where include(commodity) {
            guard let date = bucket.last?.date else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    /// The most recent price of `commodity` in `currency` on or before `date`
    /// (or the latest overall when `date` is `nil`).
    public func latestPrice(of commodity: Commodity, in currency: Commodity,
                            on date: Date? = nil) -> Price? {
        buildIndexIfNeeded()
        guard let bucket = pairIndex?[PricePair(commodity: commodity, currency: currency)] else {
            return nil
        }
        return Self.latest(in: bucket, on: date)
    }

    /// The most recent price of `commodity` in any currency (index-backed
    /// counterpart of ``latestPrice(of:in:on:)``).
    func latestPricedAnyCurrency(of commodity: Commodity, on date: Date? = nil) -> Price? {
        buildIndexIfNeeded()
        guard let bucket = commodityIndex?[commodity] else { return nil }
        return Self.latest(in: bucket, on: date)
    }

    /// The price of `commodity` in `currency` *nearest in time* to `date` — the
    /// closer of the newest at-or-before and the oldest after, ties going to the
    /// earlier price. This is GnuCash's default report price source
    /// (`pricedb-nearest`, `gnc_pricedb_lookup_nearest_in_time`); valuations use
    /// it so a report as-of a date can pick a slightly-later quote.
    public func nearestPrice(of commodity: Commodity, in currency: Commodity,
                             on date: Date? = nil) -> Price? {
        buildIndexIfNeeded()
        guard let bucket = pairIndex?[PricePair(commodity: commodity, currency: currency)] else {
            return nil
        }
        return Self.nearest(in: bucket, on: date)
    }

    /// The nearest-in-time counterpart of ``latest(in:on:)``.
    private static func nearest(in bucket: [Price], on date: Date?) -> Price? {
        guard let date else { return latest(in: bucket, on: nil) }
        let before = latest(in: bucket, on: date)          // newest at-or-before
        // The oldest price strictly after `date`.
        var low = 0, high = bucket.count
        while low < high {
            let mid = (low + high) / 2
            if bucket[mid].date > date { high = mid } else { low = mid + 1 }
        }
        let after: Price? = low < bucket.count ? bucket[low] : nil
        switch (before, after) {
        case let (b?, a?):
            // Tie (equal distance) → the earlier price, matching GnuCash.
            return a.date.timeIntervalSince(date) < date.timeIntervalSince(b.date) ? a : b
        case let (b?, nil): return b
        case let (nil, a?): return a
        default: return nil
        }
    }

    /// Every commodity `commodity` has at least one price against, in either
    /// direction — the candidate intermediates for indirect FX conversion
    /// (GnuCash's `indirect_price_conversion` common-currency search).
    func pricedAgainst(_ commodity: Commodity) -> Set<Commodity> {
        buildIndexIfNeeded()
        var result: Set<Commodity> = []
        for pair in pairIndex?.keys ?? Dictionary<PricePair, [Price]>().keys {
            if pair.commodity == commodity { result.insert(pair.currency) }
            else if pair.currency == commodity { result.insert(pair.commodity) }
        }
        return result
    }

    /// Values `quantity` units of `commodity` in `currency` using the price
    /// database. Returns `quantity` unchanged when the commodities match, or
    /// `nil` when no price is available.
    public func value(of quantity: Decimal, commodity: Commodity,
                      in currency: Commodity, on date: Date? = nil) -> Decimal? {
        if commodity == currency { return quantity }
        guard let price = latestPrice(of: commodity, in: currency, on: date) else { return nil }
        return quantity * price.value
    }

    // MARK: Cost basis / lots

    /// The chronological acquisition/disposal events for a security `account`,
    /// derived from its non-voided splits (`FR-INV-04`).
    /// Driven from the account's own splits rather than by walking the whole
    /// book. The scanning form visited every transaction in the book **per
    /// account**, so a portfolio report over eighty security accounts walked
    /// 46,553 transactions eighty times; that, with the same pattern in
    /// ``splits(for:)``, was 4.76s of the Investments destination's first paint.
    ///
    /// The event order is unchanged: ``splits(for:)`` yields splits in
    /// transaction order and, within a transaction, in split order — exactly the
    /// order the nested scan produced. That matters more than the speed, since
    /// the lot engine consumes these in sequence and a reordering would move
    /// cost basis without failing anything loudly.
    public func lotEvents(for account: Account, asOf: Date = .distantFuture) -> [LotEvent] {
        var events: [LotEvent] = []
        // Brokerage is a property of the transaction, and a transaction can
        // carry two splits on the same account; compute it once each.
        var feeCache: [ObjectIdentifier: Decimal] = [:]

        for split in splits(for: account) {
            guard let transaction = split.transaction, transaction.datePosted <= asOf,
                  split.reconcileState != .voided,
                  split.quantity != 0 || split.action == "ReturnOfCapital"
            else { continue }

            let key = ObjectIdentifier(transaction)
            let feePerSecurity: Decimal
            if let cached = feeCache[key] {
                feePerSecurity = cached
            } else {
                // Brokerage/commission on the transaction: its expense-account
                // splits, shared equally across the transaction's security
                // splits (so a two-security swap doesn't double-count the fee).
                var brokerage = Decimal(0)
                var securitySplits = 0
                for other in transaction.splits where other.reconcileState != .voided {
                    if let type = other.account?.type {
                        if type == .expense { brokerage += other.value }
                        else if type.isSecurityType && other.quantity != 0 { securitySplits += 1 }
                    }
                }
                feePerSecurity = securitySplits > 0 ? brokerage / Decimal(securitySplits) : 0
                feeCache[key] = feePerSecurity
            }

            let isTrade = split.quantity != 0 && split.action != "Split"
            events.append(LotEvent(date: transaction.datePosted,
                                   quantity: split.quantity, value: split.value,
                                   isSplit: split.action == "Split",
                                   isReturnOfCapital: split.action == "ReturnOfCapital",
                                   fee: isTrade ? feePerSecurity : 0))
        }
        return events
    }

    /// Computes cost basis, open lots and realised gains for a security
    /// `account` under `method`.
    public func costBasis(
        for account: Account,
        asOf: Date = .distantFuture,
        method: CostBasisMethod = .fifo,
        longTermThresholdDays: Int = CostBasis.defaultLongTermThresholdDays,
        feeTreatment: FeeTreatment = .ignore,
        currencyFraction: Int? = nil
    ) -> CostBasisResult {
        CostBasis.compute(events: lotEvents(for: account, asOf: asOf), method: method,
                          longTermThresholdDays: longTermThresholdDays,
                          feeTreatment: feeTreatment, currencyFraction: currencyFraction)
    }

    // MARK: Transactions

    /// Adds a transaction to the book, last in its order.
    ///
    /// Built lookup indexes are kept, not dropped: the transaction is the
    /// book's last, so its legs go last in every account's list — where a
    /// rebuild would file them. Dropping them made the first lookup after
    /// every edit rebuild all three for the whole book (25 ms on the
    /// reference book, P5.4).
    @discardableResult
    public func addTransaction(_ transaction: Transaction) -> Transaction {
        registerCommodity(transaction.currency)
        transaction.owner = self
        transaction.bookOrder = nextBookOrder
        nextBookOrder += 1
        transactions.append(transaction)
        noteChanged(transaction.splits)
        unsavedTransactions?.insert(transaction.guid)
        if indexesBuilt { indexInsert(transaction) }
        return transaction
    }

    /// Removes a transaction (and detaches its splits), taking its legs out
    /// of built indexes rather than dropping them.
    public func removeTransaction(_ transaction: Transaction) {
        transactions.removeAll { $0 === transaction }
        if transaction.owner === self { transaction.owner = nil }
        noteChanged(transaction.splits)
        unsavedTransactions?.insert(transaction.guid)
        if indexesBuilt { indexRemove(transaction) }
        for split in transaction.splits { split.transaction = nil }
    }

    /// Brings built lookup indexes up to date with a transaction edited in
    /// place — legs added, removed, moved to another account — instead of
    /// dropping them (P5.4). The book cannot see a leg change on its
    /// transaction, so whoever edited it says so. `previous` is the legs as
    /// they were before the edit (an undo snapshot's copy holds them): their
    /// GUIDs and accounts are where the index still files the old ones.
    public func reindex(_ transaction: Transaction, previous: [Split]) {
        noteChanged(previous)
        noteChanged(transaction.splits)
        unsavedTransactions?.insert(transaction.guid)
        guard indexesBuilt, transactionIndex?[transaction.guid] === transaction else { return }
        let legs = previous + transaction.splits
        // The objects filed under the legs' GUIDs, by identity: a pass over an
        // account's legs that hashed each one's GUID, and loaded its weak
        // transaction, cost seconds when an edit re-filed two thousand
        // transactions in one busy account — a pointer compares in a cycle.
        var filed = Set<ObjectIdentifier>()
        var accounts = Set<ObjectIdentifier>()
        for leg in legs {
            if let account = leg.account { accounts.insert(ObjectIdentifier(account)) }
            guard let split = splitIndex?[leg.guid],
                  split.transaction === transaction || split.transaction == nil else { continue }
            filed.insert(ObjectIdentifier(split))
            splitIndex?.removeValue(forKey: leg.guid)
        }
        for account in accounts {
            splitsByAccount?[account]?.removeAll { filed.contains(ObjectIdentifier($0)) }
        }
        indexInsert(transaction)
    }

    /// Puts back a transaction ``removeTransaction(_:)`` took out — the object
    /// itself, its splits linked to it again — so whatever pointed at it (an
    /// invoice's posting, a lot's members) points at the book's own again.
    /// An undo's primitive: a copy put back would leave those pointing at
    /// objects no longer in the book.
    public func restoreTransaction(_ transaction: Transaction) {
        guard !transactions.contains(where: { $0 === transaction }) else { return }
        for split in transaction.splits { split.transaction = transaction }
        addTransaction(transaction)
    }

    // MARK: GUID lookup indexes
    //
    // `transaction(with:)` / `split(with:)` were linear scans over the whole
    // book — and the register asks per visible cell per render, which on a 46k-
    // transaction book made the UI visibly sluggish. Built lazily like the
    // price index. Splits are added/removed on their *transaction*, which the
    // book cannot observe, so a miss (or a stale hit — an indexed split that
    // has been detached) rebuilds once per generation; the app additionally
    // invalidates after every edit.
    private var accountIndex: [GncGUID: Account]?
    private var transactionIndex: [GncGUID: Transaction]?
    private var splitIndex: [GncGUID: Split]?
    /// Splits bucketed by the account they post to, in transaction order.
    private var splitsByAccount: [ObjectIdentifier: [Split]]?
    /// Every account the split index knows of, splits or none — so asking
    /// after an account with no splits is an answer, not a miss. A miss
    /// rebuilds the whole index, and the Overview's count of uncategorised
    /// legs asked after an empty Imbalance account on every revision.
    private var indexedAccounts: Set<ObjectIdentifier> = []
    private var lookupRetriedAfterMiss = false
    private var nextBookOrder = 0

    /// What the next save has to write (``takeUnsaved()``): `nil` — the
    /// state of a book nobody has marked persisted, or one changed in a way
    /// it could not follow — means everything.
    fileprivate var unsavedTransactions: Set<GncGUID>?
    fileprivate var unsavedPrices: UnsavedPrices?
    fileprivate var persistedOrderCeiling = 0

    /// The accounts whose splits changed since ``takeChangedAccounts()``
    /// last emptied this; `nil` when the book cannot say — nothing has asked
    /// yet, or the indexes were dropped — which means any of them.
    private var changedAccounts: [ObjectIdentifier: Account]?

    private var indexesBuilt: Bool {
        transactionIndex != nil && splitIndex != nil && splitsByAccount != nil
    }

    /// Drops the GUID lookup indexes. Called by the app after an edit that
    /// does not say what it changed (splits can change on a transaction
    /// without the book seeing it); an edit that does keeps them, through
    /// ``reindex(_:previous:)``.
    public func invalidateLookupIndexes() {
        dropLookupIndexes()
        // Something changed legs without saying which: the next save writes
        // every transaction.
        unsavedTransactions = nil
    }

    /// Drops the GUID lookup indexes, to be built again on the next lookup,
    /// and which accounts changed — but not what is unsaved, which every
    /// reported edit goes on recording. For an edit of so many transactions
    /// that re-filing them one at a time costs more than one rebuild (25 ms
    /// on the reference book), and for a book just read from its file, where
    /// nothing is unsaved to forget.
    public func dropLookupIndexes() {
        transactionIndex = nil
        splitIndex = nil
        splitsByAccount = nil
        indexedAccounts = []
        lookupRetriedAfterMiss = false
        changedAccounts = nil
    }

    /// The accounts whose splits changed since the last call — or `nil` when
    /// the book cannot say which, meaning any (the first call, or after the
    /// indexes were dropped). An account tree that keeps its balances asks
    /// this to recompute only those accounts, as GnuCash recomputes only an
    /// account marked `balance_dirty` (`xaccAccountRecomputeBalance`).
    public func takeChangedAccounts() -> [Account]? {
        defer { changedAccounts = [:] }
        return changedAccounts.map { Array($0.values) }
    }

    /// A transaction this book holds was changed in place, by whatever code:
    /// the next save writes it, and the accounts named — those whose balance
    /// the change can move — are recomputed. The edit wrappers say the same
    /// through ``reindex(_:previous:)``; this is what makes a change nobody
    /// reported a change the file still gets.
    func noteEdited(_ transaction: Transaction, accounts: [Account?] = []) {
        unsavedTransactions?.insert(transaction.guid)
        guard changedAccounts != nil else { return }
        for case let account? in accounts { changedAccounts?[ObjectIdentifier(account)] = account }
    }

    private func noteChanged(_ splits: [Split]) {
        guard changedAccounts != nil else { return }
        for split in splits {
            if let account = split.account { changedAccounts?[ObjectIdentifier(account)] = account }
        }
    }

    /// Files a transaction's legs: each at its place in its account's list —
    /// after the legs of every transaction before it in the book's order,
    /// which for one just added is the end. A leg already detached from its
    /// transaction in a list means something changed unreported, and the
    /// index cannot be trusted: it goes, to be rebuilt.
    private func indexInsert(_ transaction: Transaction) {
        transactionIndex?[transaction.guid] = transaction
        let order = transaction.bookOrder
        for split in transaction.splits {
            splitIndex?[split.guid] = split
            guard let account = split.account else { continue }
            let key = ObjectIdentifier(account)
            indexedAccounts.insert(key)
            let list = splitsByAccount?[key] ?? []
            // The common case — the newest transaction — without a search.
            if let last = list.last, let lastOrder = last.transaction?.bookOrder, lastOrder <= order {
                splitsByAccount?[key, default: []].append(split)
                continue
            }
            var low = 0, high = list.count
            while low < high {
                let mid = (low + high) / 2
                guard let other = list[mid].transaction else {
                    invalidateLookupIndexes()
                    return
                }
                if other.bookOrder <= order { low = mid + 1 } else { high = mid }
            }
            splitsByAccount?[key, default: []].insert(split, at: low)
        }
    }

    private func indexRemove(_ transaction: Transaction) {
        if transactionIndex?[transaction.guid] === transaction {
            transactionIndex?.removeValue(forKey: transaction.guid)
        }
        for split in transaction.splits {
            if splitIndex?[split.guid] === split { splitIndex?.removeValue(forKey: split.guid) }
            if let account = split.account {
                splitsByAccount?[ObjectIdentifier(account)]?.removeAll { $0 === split }
            }
        }
    }

    private func buildLookupIndexesIfNeeded() {
        guard !indexesBuilt else { return }
        let built = freshLookupIndexes()
        transactionIndex = built.transactions
        splitIndex = built.splits
        splitsByAccount = built.byAccount
        indexedAccounts = built.accounts
    }

    private func freshLookupIndexes() -> (transactions: [GncGUID: Transaction], splits: [GncGUID: Split],
                                          byAccount: [ObjectIdentifier: [Split]],
                                          accounts: Set<ObjectIdentifier>) {
        var txns = [GncGUID: Transaction](minimumCapacity: transactions.count)
        var splits = [GncGUID: Split](minimumCapacity: transactions.count * 2)
        var byAccount: [ObjectIdentifier: [Split]] = [:]
        var known: Set<ObjectIdentifier> = [ObjectIdentifier(rootAccount)]
        for account in accounts { known.insert(ObjectIdentifier(account)) }
        for transaction in transactions {
            txns[transaction.guid] = transaction
            for split in transaction.splits {
                splits[split.guid] = split
                if let account = split.account {
                    byAccount[ObjectIdentifier(account), default: []].append(split)
                    known.insert(ObjectIdentifier(account))
                }
            }
        }
        return (txns, splits, byAccount, known)
    }

    /// Whether the indexes kept up to date edit by edit are exactly the ones
    /// a rebuild would make: the same objects under the same keys, every
    /// account's legs in the same order. A check, for tests and the app's
    /// verification switch; unbuilt indexes agree.
    public func lookupIndexesMatchRebuild() -> Bool {
        guard indexesBuilt, let transactionIndex, let splitIndex, let splitsByAccount else { return true }
        let fresh = freshLookupIndexes()
        guard fresh.transactions.count == transactionIndex.count,
              fresh.transactions.allSatisfy({ transactionIndex[$0.key] === $0.value }),
              fresh.splits.count == splitIndex.count,
              fresh.splits.allSatisfy({ splitIndex[$0.key] === $0.value }) else { return false }
        for (account, list) in fresh.byAccount {
            let kept = splitsByAccount[account] ?? []
            guard kept.count == list.count, zip(kept, list).allSatisfy({ $0 === $1 }) else { return false }
        }
        // And nothing filed under an account the rebuild has no legs for.
        return splitsByAccount.allSatisfy { fresh.byAccount[$0.key] != nil || $0.value.isEmpty }
    }

    /// A miss can mean "genuinely absent" or "index built before this object
    /// appeared"; one rebuild per generation tells them apart without letting a
    /// repeatedly-queried stale GUID rebuild the index every call.
    private func rebuildOnceAfterMiss() -> Bool {
        guard !lookupRetriedAfterMiss else { return false }
        lookupRetriedAfterMiss = true
        transactionIndex = nil
        splitIndex = nil
        splitsByAccount = nil
        buildLookupIndexesIfNeeded()
        return true
    }

    /// Looks up a transaction by GUID.
    public func transaction(with guid: GncGUID) -> Transaction? {
        buildLookupIndexesIfNeeded()
        if let hit = transactionIndex?[guid] { return hit }
        guard rebuildOnceAfterMiss() else { return nil }
        return transactionIndex?[guid]
    }

    /// All distinct tags used across transactions, sorted (`FR-TAG-01`).
    public var allTags: [String] {
        var seen = Set<String>()
        for transaction in transactions {
            for tag in transaction.tags { seen.insert(tag) }
        }
        return seen.sorted()
    }

    /// Looks up a split by GUID across all transactions.
    public func split(with guid: GncGUID) -> Split? {
        buildLookupIndexesIfNeeded()
        // A detached split (removed from its transaction since the index was
        // built) is stale — fall through to a rebuild.
        if let hit = splitIndex?[guid], hit.transaction != nil { return hit }
        guard rebuildOnceAfterMiss() else { return nil }
        return splitIndex?[guid]
    }

    /// All splits posted to `account`, in transaction order.
    ///
    /// Served from the account index rather than by scanning. The scanning form
    /// — `transactions.flatMap(\.splits).filter { $0.account === account }` —
    /// walked every transaction in the book and allocated an array of every
    /// split in it, **per account asked about**. Callers that ask once per
    /// account turn that into quadratic work: on the reference book the
    /// advanced-portfolio report spent 4.76s here, almost all of it rebuilding
    /// the same intermediate array eighty times over.
    ///
    /// Order is preserved exactly — the index is filled by walking
    /// `transactions` in the same order the scan did — because callers such as
    /// the lot engine consume these in sequence and a reordering would silently
    /// change cost basis.
    public func splits(for account: Account) -> [Split] {
        buildLookupIndexesIfNeeded()
        let key = ObjectIdentifier(account)
        if let hit = splitsByAccount?[key] { return hit }
        // An account the index knows of with nothing filed has no splits.
        if indexedAccounts.contains(key) { return [] }
        // A miss is otherwise "index predates this account"; the same
        // one-rebuild-per-generation rule the GUID lookups use.
        guard rebuildOnceAfterMiss() else { return [] }
        return splitsByAccount?[key] ?? []
    }

    // MARK: Balances

    /// What ``balancesByAccount(filter:from:to:excludingClosing:)`` holds for
    /// one account with no window — its legs' quantities, voided ones left
    /// out — summed from the account's own list of legs instead of a walk of
    /// the whole book: GnuCash's `xaccAccountRecomputeBalance`, which walks
    /// one account's splits when that account alone is marked dirty
    /// (`libgnucash/engine/Account.cpp`). The same legs in the same order, so
    /// the same total.
    public func quantityTotal(of account: Account, filter: BalanceFilter = .all) -> Decimal {
        splits(for: account).reduce(Decimal(0)) { Self.matches($1, filter) ? $0 + $1.quantity : $0 }
    }

    /// Whether a split should be counted at a given reconcile filter.
    /// Voided splits never count toward a balance.
    private static func matches(_ split: Split, _ filter: BalanceFilter) -> Bool {
        guard split.reconcileState != .voided else { return false }
        switch filter {
        case .all:
            return true
        case .cleared:
            // GnuCash's cleared balance counts everything not unreconciled
            // (`NREC != reconciled`): cleared, reconciled, and frozen.
            return split.reconcileState != .notReconciled
        case .reconciled:
            // GnuCash's reconciled balance counts reconciled AND frozen
            // (`YREC == reconciled || FREC == reconciled`).
            return split.reconcileState == .reconciled || split.reconcileState == .frozen
        }
    }

    /// The balance of `account` in its own commodity, summing split quantities.
    ///
    /// - Parameters:
    ///   - account: the account to total.
    ///   - filter: which splits to include (all / cleared / reconciled).
    ///   - includingDescendants: also include child-account balances (only valid
    ///     when children share the same commodity).
    public func balance(
        of account: Account,
        filter: BalanceFilter = .all,
        includingDescendants: Bool = false
    ) -> Money {
        var total = Decimal(0)
        let targets = includingDescendants ? [account] + account.descendants : [account]
        let targetSet = Set(targets.map { ObjectIdentifier($0) })
        for transaction in transactions {
            for split in transaction.splits {
                guard let acct = split.account,
                      targetSet.contains(ObjectIdentifier(acct)),
                      Book.matches(split, filter)
                else { continue }
                total += split.quantity
            }
        }
        return Money(total, account.commodity)
    }

    /// ``balancesByAccount(filter:from:to:excludingClosing:)`` for several
    /// windows in one walk — the same totals, each window's map as if asked
    /// alone. A walk of the book is cache misses more than arithmetic, so
    /// three windows asked together cost about one.
    public func balancesByAccount(windows: [(from: Date?, to: Date?)], filter: BalanceFilter = .all,
                                  excludingClosing: Bool = false) -> [[ObjectIdentifier: Decimal]] {
        var totals = Array(repeating: [ObjectIdentifier: Decimal](), count: windows.count)
        // Outside every window is the common case — a year's windows over a
        // book of decades — so it is tested before the slot lookup that
        // finds a closing entry, as the one-window walk below does.
        let earliest = windows.contains { $0.from == nil } ? nil : windows.compactMap(\.from).min()
        let latest = windows.contains { $0.to == nil } ? nil : windows.compactMap(\.to).max()
        for transaction in transactions {
            let posted = transaction.datePosted
            if let earliest, posted < earliest { continue }
            if let latest, posted > latest { continue }
            if excludingClosing, FindTest.isClosing(transaction) { continue }
            for (index, window) in windows.enumerated() {
                if let from = window.from, posted < from { continue }
                if let to = window.to, posted > to { continue }
                for split in transaction.splits {
                    guard let account = split.account, Book.matches(split, filter) else { continue }
                    totals[index][ObjectIdentifier(account), default: 0] += split.quantity
                }
            }
        }
        return totals
    }

    /// Every account's own balance, in one pass over the splits.
    ///
    /// ``balance(of:filter:includingDescendants:)`` walks the whole book per
    /// call, so valuing a tree of accounts one at a time is quadratic — the
    /// account tree did exactly that and cost ~28s on a 46k-transaction book.
    /// Callers that need many balances at once should ask for them together.
    /// Accounts with no postings are absent; treat a miss as zero.
    /// - Parameter excludingClosing: Skip the transactions Close Book writes
    ///   (the `book_closing` slot). An income statement **must** set this: the
    ///   closing entries zero every income and expense account by design, so a
    ///   period that has been closed otherwise reports $0 across the board.
    ///   A balance sheet must not — retained earnings is exactly what those
    ///   entries produce. GnuCash draws the same distinction, with
    ///   `(list 'closing #t)` on the income-statement side only.
    public func balancesByAccount(filter: BalanceFilter = .all,
                                  from: Date? = nil, to: Date? = nil,
                                  excludingClosing: Bool = false) -> [ObjectIdentifier: Decimal] {
        var totals: [ObjectIdentifier: Decimal] = [:]
        for transaction in transactions {
            // Inclusive bounds, matching every per-account balance in the app.
            // The window is what lets a report ask for all 559 balances in one
            // walk instead of walking the book once per account — the shape
            // that made netWorthSeries 490× faster.
            if let from, transaction.datePosted < from { continue }
            if let to, transaction.datePosted > to { continue }
            if excludingClosing, FindTest.isClosing(transaction) { continue }
            for split in transaction.splits {
                guard let account = split.account, Book.matches(split, filter) else { continue }
                totals[ObjectIdentifier(account), default: 0] += split.quantity
            }
        }
        return totals
    }
}

/// Which splits to include when computing a balance.
public enum BalanceFilter: Sendable {
    /// Every split.
    case all
    /// Cleared or reconciled splits.
    case cleared
    /// Reconciled splits only.
    case reconciled
}

// MARK: - Replica

extension Book {

    /// A copy of the whole book that shares no object with it: every account,
    /// transaction, split, lot and business object is new, with the same
    /// guids, values, slots and order, and every reference between them is
    /// pointed at the copy's own objects. Prices, commodities and frames are
    /// values, so those are copied as they stand.
    ///
    /// The `Book` is a graph of classes edited on one actor, so no other
    /// thread may read it — but nothing else holds a replica, so a replica
    /// can be handed to another thread whole and read there while the
    /// original goes on being edited. That is how the work that only reads
    /// the book — an export, a report, an import's matching — leaves the main
    /// actor: taking the copy is the part that stays, and it is a fraction of
    /// any of them.
    public func replica() -> BookReplica {
        var accountCopies: [ObjectIdentifier: Account] = [:]
        func copy(_ account: Account) -> Account {
            Account(guid: account.guid, name: account.name, type: account.type,
                    commodity: account.commodity, code: account.code,
                    description: account.accountDescription, notes: account.notes,
                    isPlaceholder: account.isPlaceholder, isHidden: account.isHidden,
                    kvp: account.kvp)
        }

        // The tree, breadth-first: originals and their copies in two lists
        // at the same positions.
        let root = copy(rootAccount)
        accountCopies[ObjectIdentifier(rootAccount)] = root
        var originals: [Account] = [rootAccount]
        var copies: [Account] = [root]
        var next = 0
        while next < originals.count {
            let parentCopy = copies[next]
            for child in originals[next].children {
                let childCopy = copy(child)
                parentCopy.addChild(childCopy)
                accountCopies[ObjectIdentifier(child)] = childCopy
                originals.append(child)
                copies.append(childCopy)
            }
            next += 1
        }
        // An account no longer in the tree that something still points at is
        // copied too, outside the tree, as it is in the original — under its
        // own parent, which a subtree taken out of the tree keeps: its full
        // name, which the Ledger and CSV exports write, is read through them.
        // (Out of the tree all the way up: `removeChild` clears the parent.)
        // Held by the replica, since a parent is weak.
        var detached: [Account] = []
        func account(_ original: Account) -> Account {
            if let known = accountCopies[ObjectIdentifier(original)] { return known }
            let made = copy(original)
            accountCopies[ObjectIdentifier(original)] = made
            detached.append(made)
            if let parent = original.parent { account(parent).addChild(made) }
            return made
        }

        let book = Book(guid: guid, rootAccount: root, kvp: kvp)
        book.commodities = commodities
        book.prices = prices
        // The price index too, when it is built: values, so the copy is free
        // until either side changes, where a replica left to build its own
        // bucketed and sorted every price (0.35 s on the reference book) for
        // each report built off the main actor — and counted it in the time
        // that decides whether the next one goes there.
        book.pairIndex = pairIndex
        book.commodityIndex = commodityIndex
        book.nextBookOrder = nextBookOrder

        var transactionCopies: [ObjectIdentifier: Transaction] = [:]
        var splitCopies: [ObjectIdentifier: Split] = [:]
        func copy(_ split: Split) -> Split {
            let made = Split(guid: split.guid, account: split.account.map(account),
                             value: split.value, quantity: split.quantity,
                             reconcileState: split.reconcileState, reconcileDate: split.reconcileDate,
                             memo: split.memo, action: split.action, kvp: split.kvp)
            splitCopies[ObjectIdentifier(split)] = made
            return made
        }
        func copy(_ transaction: Transaction) -> Transaction {
            let made = Transaction(guid: transaction.guid, currency: transaction.currency,
                                   datePosted: transaction.datePosted, dateEntered: transaction.dateEntered,
                                   number: transaction.number, description: transaction.transactionDescription,
                                   notes: transaction.notes, kvp: transaction.kvp)
            for split in transaction.splits { made.addSplit(copy(split)) }
            made.bookOrder = transaction.bookOrder
            transactionCopies[ObjectIdentifier(transaction)] = made
            return made
        }
        book.transactions = transactions.map(copy)
        func split(_ original: Split) -> Split {
            splitCopies[ObjectIdentifier(original)] ?? copy(original)
        }
        func transaction(_ original: Transaction) -> Transaction {
            transactionCopies[ObjectIdentifier(original)] ?? copy(original)
        }

        var lotCopies: [ObjectIdentifier: Lot] = [:]
        book.lots = lots.map { lot in
            let made = Lot(guid: lot.guid, account: lot.account.map(account), title: lot.title,
                           notes: lot.notes, isClosed: lot.isClosed, kvp: lot.kvp)
            for member in lot.splits { made.add(split(member)) }
            lotCopies[ObjectIdentifier(lot)] = made
            return made
        }
        func lot(_ original: Lot) -> Lot {
            if let known = lotCopies[ObjectIdentifier(original)] { return known }
            let made = Lot(guid: original.guid, account: original.account.map(account),
                           title: original.title, notes: original.notes,
                           isClosed: original.isClosed, kvp: original.kvp)
            for member in original.splits { made.add(split(member)) }
            lotCopies[ObjectIdentifier(original)] = made
            return made
        }

        var termCopies: [ObjectIdentifier: BillTerm] = [:]
        func term(_ original: BillTerm) -> BillTerm {
            if let known = termCopies[ObjectIdentifier(original)] { return known }
            let made = BillTerm(guid: original.guid, name: original.name,
                                termDescription: original.termDescription, kind: original.kind,
                                dueDays: original.dueDays, discountDays: original.discountDays,
                                cutoff: original.cutoff, discountPercent: original.discountPercent,
                                active: original.active)
            termCopies[ObjectIdentifier(original)] = made
            return made
        }
        book.billTerms = billTerms.map(term)

        var tableCopies: [ObjectIdentifier: TaxTable] = [:]
        func table(_ original: TaxTable) -> TaxTable {
            if let known = tableCopies[ObjectIdentifier(original)] { return known }
            let made = TaxTable(guid: original.guid, name: original.name,
                                entries: original.entries.map {
                                    TaxTableEntry(account: account($0.account), kind: $0.kind, amount: $0.amount)
                                },
                                active: original.active)
            tableCopies[ObjectIdentifier(original)] = made
            return made
        }
        book.taxTables = taxTables.map(table)

        var customerCopies: [ObjectIdentifier: Customer] = [:]
        func customer(_ original: Customer) -> Customer {
            if let known = customerCopies[ObjectIdentifier(original)] { return known }
            let made = Customer(guid: original.guid, id: original.id, name: original.name,
                                address: original.address, notes: original.notes,
                                active: original.active, currency: original.currency,
                                terms: original.terms.map(term), taxTable: original.taxTable.map(table),
                                taxTableOverride: original.taxTableOverride,
                                taxIncluded: original.taxIncluded,
                                discountPercent: original.discountPercent,
                                creditLimit: original.creditLimit)
            customerCopies[ObjectIdentifier(original)] = made
            return made
        }
        var vendorCopies: [ObjectIdentifier: Vendor] = [:]
        func vendor(_ original: Vendor) -> Vendor {
            if let known = vendorCopies[ObjectIdentifier(original)] { return known }
            let made = Vendor(guid: original.guid, id: original.id, name: original.name,
                              address: original.address, notes: original.notes,
                              active: original.active, currency: original.currency,
                              terms: original.terms.map(term), taxTable: original.taxTable.map(table),
                              taxTableOverride: original.taxTableOverride,
                              taxIncluded: original.taxIncluded)
            vendorCopies[ObjectIdentifier(original)] = made
            return made
        }
        var employeeCopies: [ObjectIdentifier: Employee] = [:]
        func employee(_ original: Employee) -> Employee {
            if let known = employeeCopies[ObjectIdentifier(original)] { return known }
            let made = Employee(guid: original.guid, id: original.id, username: original.username,
                                address: original.address, notes: original.notes,
                                active: original.active, currency: original.currency,
                                hourlyRate: original.hourlyRate,
                                creditAccount: original.creditAccount.map(account))
            employeeCopies[ObjectIdentifier(original)] = made
            return made
        }
        var jobCopies: [ObjectIdentifier: Job] = [:]
        func job(_ original: Job) -> Job {
            if let known = jobCopies[ObjectIdentifier(original)] { return known }
            let made = Job(guid: original.guid, id: original.id, name: original.name,
                           reference: original.reference, active: original.active,
                           owner: owner(original.owner))
            jobCopies[ObjectIdentifier(original)] = made
            return made
        }
        func owner(_ original: BusinessOwner) -> BusinessOwner {
            switch original {
            case .customer(let party): .customer(customer(party))
            case .vendor(let party): .vendor(vendor(party))
            case .employee(let party): .employee(employee(party))
            case .job(let party): .job(job(party))
            }
        }
        book.customers = customers.map(customer)
        book.vendors = vendors.map(vendor)
        book.employees = employees.map(employee)
        book.jobs = jobs.map(job)

        book.invoices = invoices.map { invoice in
            let made = Invoice(guid: invoice.guid, id: invoice.id, kind: invoice.kind,
                               isCreditNote: invoice.isCreditNote, owner: owner(invoice.owner),
                               dateOpened: invoice.dateOpened, datePosted: invoice.datePosted,
                               dueDate: invoice.dueDate, terms: invoice.terms.map(term),
                               billingID: invoice.billingID, notes: invoice.notes,
                               currency: invoice.currency,
                               entries: invoice.entries.map { entry in
                                   InvoiceEntry(guid: entry.guid, date: entry.date, entered: entry.entered,
                                                entryDescription: entry.entryDescription,
                                                action: entry.action, account: entry.account.map(account),
                                                quantity: entry.quantity, price: entry.price,
                                                discount: entry.discount, discountType: entry.discountType,
                                                discountHow: entry.discountHow, taxable: entry.taxable,
                                                taxIncluded: entry.taxIncluded,
                                                taxTable: entry.taxTable.map(table))
                               },
                               active: invoice.active, kvp: invoice.kvp)
            made.postedAccount = invoice.postedAccount.map(account)
            made.postedTransaction = invoice.postedTransaction.map(transaction)
            made.postedLot = invoice.postedLot.map(lot)
            return made
        }
        return BookReplica(book: book, detached: detached)
    }
}

/// A ``Book/replica()``: a book nothing else holds, so it may cross to one
/// other thread and be read there. Hand it to one consumer, not two — a book
/// builds its lookup indexes lazily, on first use, so two readers of the same
/// replica would race on building them.
///
/// `@unchecked` because the compiler cannot follow the copy far enough to see
/// that nothing in it is shared with the original; `BookReplicaTests` checks
/// that instead, object by object.
public struct BookReplica: @unchecked Sendable {
    public let book: Book
    /// Copies of accounts outside the tree, kept alive for the ones under
    /// them, whose parent links are weak.
    let detached: [Account]
}

// MARK: - What the next save has to write

extension Book {

    /// Starts keeping track of what changes, from a book exactly as its file
    /// holds it — just read, or just written whole. Until this is called, and
    /// again after any change the book could not follow, the next save
    /// writes everything (P10b).
    public func markPersisted() {
        unsavedTransactions = []
        unsavedPrices = UnsavedPrices()
        persistedOrderCeiling = nextBookOrder
    }

    /// What has changed since the last save, for an incremental one — and from
    /// now on, nothing has. `nil` parts mean "everything". Give it back with
    /// ``restoreUnsaved(_:)`` if the save it was taken for fails.
    public func takeUnsaved() -> UnsavedChanges {
        let taken = UnsavedChanges(transactions: unsavedTransactions, prices: unsavedPrices,
                                   orderCeiling: persistedOrderCeiling)
        markPersisted()
        return taken
    }

    /// Puts back what a failed save took, joined with what changed since.
    public func restoreUnsaved(_ taken: UnsavedChanges) {
        if let since = unsavedTransactions, let earlier = taken.transactions {
            unsavedTransactions = since.union(earlier)
        } else {
            unsavedTransactions = nil
        }
        if let since = unsavedPrices, let earlier = taken.prices {
            unsavedPrices = earlier.followed(by: since)
        } else {
            unsavedPrices = nil
        }
        persistedOrderCeiling = min(persistedOrderCeiling, taken.orderCeiling)
    }
}

/// What changed since a book was last saved (``Book/takeUnsaved()``).
public struct UnsavedChanges: Sendable {
    /// Every transaction added, removed, or edited in place — `nil`: all.
    public let transactions: Set<GncGUID>?
    /// The prices added and removed — `nil`: all.
    public let prices: UnsavedPrices?
    /// The book order at the last save. A transaction ordered at or past it
    /// was added since — at the end of the book, so at the end of the file;
    /// one before it is where the file has it, and is rewritten in place.
    public let orderCeiling: Int
}

/// The prices a save has to write. Every price added since the last save is
/// at the end of the book's prices, in the order added (removals keep the
/// order of the rest), so they are its last ``added`` prices — written at the
/// end of the file, as the file's order is what decides which of a day's
/// prices is the latest. ``removed`` are prices the file has and the book no
/// longer does, or has again, re-added at the end.
public struct UnsavedPrices: Sendable, Equatable {
    /// Every addition, in order. An entry counts while it is its GUID's
    /// latest and has not been removed since — ``live`` says which.
    private var log: [GncGUID] = []
    private var live: [GncGUID: Int] = [:]
    public private(set) var removed: Set<GncGUID> = []

    /// The prices added since, in the order they were added.
    public var added: [GncGUID] {
        log.indices.compactMap { live[log[$0]] == $0 ? log[$0] : nil }
    }

    mutating func added(_ guid: GncGUID) {
        live[guid] = log.count
        log.append(guid)
    }

    mutating func removed(_ guid: GncGUID) {
        // The entry stays in the log and stops counting. Finding and cutting
        // it out of an array made undoing a large price import — every price
        // removed in turn — quadratic.
        live.removeValue(forKey: guid)
        // Whether or not it was added since, the file may hold it: delete it
        // there. Deleting a row that is not there is nothing.
        removed.insert(guid)
    }

    /// These changes, then `later`'s.
    func followed(by later: UnsavedPrices) -> UnsavedPrices {
        var joined = self
        for guid in later.removed { joined.removed(guid) }
        for guid in later.added { joined.added(guid) }
        return joined
    }

    public static func == (lhs: UnsavedPrices, rhs: UnsavedPrices) -> Bool {
        lhs.added == rhs.added && lhs.removed == rhs.removed
    }
}
