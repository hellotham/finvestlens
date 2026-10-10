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

    /// Looks up an account by GUID.
    public func account(with guid: GncGUID) -> Account? {
        accounts.first { $0.guid == guid }
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
        if pairIndex == nil, priceChangeLog == nil {
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

    /// Adds a transaction to the book.
    @discardableResult
    public func addTransaction(_ transaction: Transaction) -> Transaction {
        registerCommodity(transaction.currency)
        transactions.append(transaction)
        invalidateLookupIndexes()
        return transaction
    }

    /// Removes a transaction (and detaches its splits).
    public func removeTransaction(_ transaction: Transaction) {
        transactions.removeAll { $0 === transaction }
        for split in transaction.splits { split.transaction = nil }
        invalidateLookupIndexes()
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
    private var transactionIndex: [GncGUID: Transaction]?
    private var splitIndex: [GncGUID: Split]?
    /// Splits bucketed by the account they post to, in transaction order.
    private var splitsByAccount: [ObjectIdentifier: [Split]]?
    private var lookupRetriedAfterMiss = false

    /// Drops the GUID lookup indexes. Called by the book's own transaction
    /// add/remove, and by the app after any edit (splits can change on a
    /// transaction without the book seeing it).
    public func invalidateLookupIndexes() {
        transactionIndex = nil
        splitIndex = nil
        splitsByAccount = nil
        lookupRetriedAfterMiss = false
    }

    private func buildLookupIndexesIfNeeded() {
        guard transactionIndex == nil || splitIndex == nil || splitsByAccount == nil else { return }
        var txns = [GncGUID: Transaction](minimumCapacity: transactions.count)
        var splits = [GncGUID: Split](minimumCapacity: transactions.count * 2)
        var byAccount: [ObjectIdentifier: [Split]] = [:]
        for transaction in transactions {
            txns[transaction.guid] = transaction
            for split in transaction.splits {
                splits[split.guid] = split
                if let account = split.account {
                    byAccount[ObjectIdentifier(account), default: []].append(split)
                }
            }
        }
        transactionIndex = txns
        splitIndex = splits
        splitsByAccount = byAccount
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
        if let hit = splitsByAccount?[ObjectIdentifier(account)] { return hit }
        // A miss is either "no splits" or "index predates this account"; the
        // same one-rebuild-per-generation rule the GUID lookups use tells them
        // apart without letting an empty account rebuild on every call.
        guard rebuildOnceAfterMiss() else { return [] }
        return splitsByAccount?[ObjectIdentifier(account)] ?? []
    }

    // MARK: Balances

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
