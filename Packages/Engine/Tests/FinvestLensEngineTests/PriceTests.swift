//
//  PriceTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Price database")
struct PriceTests {

    private let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "Commonwealth Bank", smallestFraction: 10000)

    @Test("Latest price on or before a date")
    func latestPrice() {
        let book = Book(baseCurrency: .aud)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 1, 1), value: dec("100")))
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("110")))
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 3, 1), value: dec("105")))

        #expect(book.latestPrice(of: cba, in: .aud, on: day(2026, 2, 15))?.value == dec("110"))
        #expect(book.latestPrice(of: cba, in: .aud)?.value == dec("105"))          // overall latest
        #expect(book.latestPrice(of: cba, in: .aud, on: day(2025, 12, 1)) == nil)  // before any price
    }

    @Test("Valuation multiplies quantity by price")
    func valuation() {
        let book = Book(baseCurrency: .aud)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 2, 1), value: dec("110")))
        #expect(book.value(of: dec("10"), commodity: cba, in: .aud, on: day(2026, 3, 1)) == dec("1100"))
        // Same commodity → unchanged.
        #expect(book.value(of: dec("50"), commodity: .aud, in: .aud) == dec("50"))
        // No price for USD → nil.
        #expect(book.value(of: dec("10"), commodity: .usd, in: .aud) == nil)
    }

    @Test("Adding a price registers its commodities")
    func registersCommodities() {
        let book = Book(baseCurrency: .aud)
        book.addPrice(Price(commodity: cba, currency: .aud, date: day(2026, 1, 1), value: dec("100")))
        #expect(book.commodities.contains(cba))
    }
}

/// The price index replaced a linear scan of the whole database. These pin the
/// replacement to the scan's exact answers — including ties, where picking a
/// different duplicate would silently move a balance.
@Suite("Price index equivalence")
struct PriceIndexEquivalenceTests {

    /// The linear scan `latestPrice` used to be, kept here as the oracle.
    private func scan(_ book: Book, _ commodity: Commodity, _ currency: Commodity,
                      _ date: Date?) -> Price? {
        var best: Price?
        for price in book.prices {
            guard price.commodity == commodity, price.currency == currency else { continue }
            if let date, price.date > date { continue }
            // `>=`: the LAST price of the winning day wins, which is what
            // `Book.latest(in:on:)` now returns — later arrival is the only
            // evidence of recency there is once every price is day-neutral.
            if best == nil || price.date >= best!.date { best = price }
        }
        return best
    }

    private func scanAny(_ book: Book, _ commodity: Commodity, _ date: Date?) -> Price? {
        var best: Price?
        for price in book.prices {
            guard price.commodity == commodity else { continue }
            if let date, price.date > date { continue }
            // `>=`: the LAST price of the winning day wins, which is what
            // `Book.latest(in:on:)` now returns — later arrival is the only
            // evidence of recency there is once every price is day-neutral.
            if best == nil || price.date >= best!.date { best = price }
        }
        return best
    }

    private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }
    /// A cut-off safely inside day `d`'s day-neutral instant (10:59Z of its
    /// local day), which `day(d)` — midnight UTC — can fall before.
    private func noon(_ d: Int) -> Date { day(d).addingTimeInterval(12 * 3_600) }

    /// A book of pseudo-random prices with deliberate duplicate dates.
    private func book(seed: UInt64) -> (Book, [Commodity]) {
        var state = seed
        func next(_ bound: Int) -> Int {          // xorshift — deterministic
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }
        let b = Book(baseCurrency: .aud)
        let commodities = [
            Commodity(namespace: .security("ASX"), mnemonic: "AAA", fullName: "A", smallestFraction: 10000),
            Commodity(namespace: .security("ASX"), mnemonic: "BBB", fullName: "B", smallestFraction: 10000),
            Commodity.usd,
        ]
        for _ in 0..<400 {
            let c = commodities[next(commodities.count)]
            let cur = next(2) == 0 ? Commodity.aud : Commodity.usd
            guard c != cur else { continue }
            // Dates drawn from a small pool, so duplicates are common.
            b.addPrice(Price(commodity: c, currency: cur, date: day(next(20)),
                             value: Decimal(next(1000) + 1)))
        }
        return (b, commodities)
    }

    @Test("Indexed lookups match the linear scan, ties included")
    func matchesScan() {
        for seed in [UInt64(1), 42, 9_999] {
            let (b, commodities) = book(seed: seed)
            for c in commodities {
                for cur in [Commodity.aud, .usd] {
                    for d in [nil, day(-1), day(0), day(5), day(10), day(19), day(50)] as [Date?] {
                        let expected = scan(b, c, cur, d)
                        let actual = b.latestPrice(of: c, in: cur, on: d)
                        #expect(actual?.guid == expected?.guid,
                                "seed \(seed) \(c.mnemonic)/\(cur.mnemonic) on \(String(describing: d))")
                    }
                    _ = cur
                }
                for d in [nil, day(0), day(7), day(19)] as [Date?] {
                    #expect(b.latestPriceInAnyCurrency(of: c, on: d)?.guid == scanAny(b, c, d)?.guid)
                }
            }
        }
    }

    @Test("The index refreshes when the price database changes")
    func invalidation() {
        let b = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10000)
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(1), value: 10))
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 10)   // builds the index

        // Added after the index exists.
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(2), value: 20))
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 20)

        // Removed after the index exists.
        let newest = b.prices.first { $0.value == 20 }!
        b.removePrice(newest.guid)
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 10)

        // An unknown pair is nil, not a stale hit.
        #expect(b.latestPrice(of: cba, in: .usd) == nil)
    }

    /// The index is now maintained in place rather than rebuilt, so every
    /// mutation after it exists has to leave it equal to a rebuild — adds on
    /// new and existing days (the later arrival winning its day), removals by
    /// GUID and by predicate, and a removal big enough to take the rebuild path.
    @Test("Adds and removes after the index is built match the linear scan")
    func incrementalMaintenance() {
        for seed in [UInt64(7), 77, 7_777] {
            let (b, commodities) = book(seed: seed)
            // Build the index, then mutate behind it.
            for c in commodities { _ = b.latestPrice(of: c, in: .aud) }
            var state = seed &* 31
            func next(_ bound: Int) -> Int {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Int(state % UInt64(bound))
            }
            for _ in 0..<60 {
                let c = commodities[next(commodities.count)]
                let cur = next(2) == 0 ? Commodity.aud : Commodity.usd
                guard c != cur else { continue }
                b.addPrice(Price(commodity: c, currency: cur, date: day(next(24)),
                                 value: Decimal(next(1000) + 1)))
                if next(3) == 0, let victim = b.prices.dropFirst(next(b.prices.count)).first {
                    b.removePrice(victim.guid)
                }
            }
            _ = b.removePrices { $0.value < 50 }
            check(b, commodities, "seed \(seed)")

            // A bulk removal is maintained in place too.
            let removed = b.removePrices { $0.currency == .usd }
            #expect(removed > 0)
            check(b, commodities, "seed \(seed) after bulk removal")
            // A commodity metadata edit is the one mutation that drops the
            // index; the lazy rebuild after incremental maintenance has to
            // agree with the scan as well.
            b.updateCommodityMetadata(commodities[0], fullName: "Renamed", smallestFraction: nil)
            b.addPrice(Price(commodity: commodities[0], currency: .aud, date: day(3), value: 5))
            check(b, commodities, "seed \(seed) after rebuild")
        }
    }

    /// `addPrices(deduplicating:)` now answers from the index rather than a
    /// set of every identity; GnuCash's rule (same day, same value → the same
    /// row) must hold both before the index exists and after.
    @Test("Deduplication through the index matches the identity rule")
    func dedupeThroughIndex() {
        for warm in [false, true] {
            let b = Book(baseCurrency: .aud)
            let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "CBA", smallestFraction: 10000)
            b.addPrice(Price(commodity: cba, currency: .aud, date: day(1), value: 10))
            b.addPrice(Price(commodity: cba, currency: .aud, date: day(2), value: 11))
            if warm { _ = b.latestPrice(of: cba, in: .aud) }
            let added = b.addPrices(deduplicating: [
                Price(commodity: cba, currency: .aud, date: day(1), value: 10),   // duplicate
                Price(commodity: cba, currency: .aud, date: day(2), value: 12),   // new value, same day
                Price(commodity: cba, currency: .aud, date: day(3), value: 13),   // new day
                Price(commodity: cba, currency: .aud, date: day(3), value: 13),   // duplicate within the batch
                Price(commodity: cba, currency: .usd, date: day(1), value: 10),   // other currency
            ])
            #expect(added.count == 3, "warm index: \(warm)")
            #expect(b.prices.count == 5)
            #expect(b.latestPrice(of: cba, in: .aud, on: noon(2))?.value == 12)
            #expect(b.latestPrice(of: cba, in: .aud)?.value == 13)
            #expect(b.latestPrice(of: cba, in: .usd)?.value == 10)
        }
    }

    @Test("A recorded edit reverts to the prices before it, and the revert records the redo")
    func changeLogRevert() {
        let b = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10000)
        let kept = b.addPrice(Price(commodity: cba, currency: .aud, date: day(1), value: 10))
        let replaced = b.addPrice(Price(commodity: cba, currency: .aud, date: day(2), value: 11))
        _ = b.latestPrice(of: cba, in: .aud)   // index built, so the edit maintains it
        let before = b.prices

        b.beginRecordingPriceChanges()
        b.removePrice(replaced.guid)
        b.addPrice(Price(guid: replaced.guid, commodity: cba, currency: .aud, date: day(2), value: 12))
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(3), value: 13))
        let changes = b.endRecordingPriceChanges()
        #expect(changes.count == 3)
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 13)

        b.beginRecordingPriceChanges()
        b.revertPriceChanges(changes)
        let redo = b.endRecordingPriceChanges()
        #expect(Set(b.prices.map(\.guid)) == Set(before.map(\.guid)))
        #expect(b.latestPrice(of: cba, in: .aud, on: noon(2))?.value == 11)
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 11)
        #expect(b.prices.contains { $0.guid == kept.guid })

        b.revertPriceChanges(redo)
        #expect(b.latestPrice(of: cba, in: .aud, on: noon(2))?.value == 12)
        #expect(b.latestPrice(of: cba, in: .aud)?.value == 13)
        #expect(b.prices.count == 3)

        // Nothing recorded outside a recording.
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(4), value: 14))
        #expect(b.endRecordingPriceChanges().isEmpty)
    }

    /// Two prices on one day keep their order through a bulk removal and its
    /// undo: the later arrival is the day's latest before and after.
    @Test("Undoing a bulk removal restores the within-day order")
    func bulkRemovalRevertKeepsOrder() {
        let b = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10000)
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(2), value: 10))
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(2), value: Decimal(string: "10.5")!))
        _ = b.latestPrice(of: cba, in: .aud)
        #expect(b.latestPrice(of: cba, in: .aud)?.value == Decimal(string: "10.5")!)

        b.beginRecordingPriceChanges()
        _ = b.removePrices { $0.commodity == cba }
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(3), value: 11))
        let changes = b.endRecordingPriceChanges()
        b.revertPriceChanges(changes)
        #expect(b.prices.map(\.value) == [10, Decimal(string: "10.5")!])
        #expect(b.latestPrice(of: cba, in: .aud)?.value == Decimal(string: "10.5")!)
    }

    @Test("Removing a pair's last price removes the pair from the index")
    func emptiedBucketGoes() {
        let b = Book(baseCurrency: .aud)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "CBA", smallestFraction: 10000)
        b.addPrice(Price(commodity: cba, currency: .aud, date: day(1), value: 10))
        let usd = b.addPrice(Price(commodity: cba, currency: .usd, date: day(1), value: 7))
        #expect(b.pricedAgainst(cba) == [.aud, .usd])
        b.removePrice(usd.guid)
        #expect(b.pricedAgainst(cba) == [.aud])
    }

    private func check(_ b: Book, _ commodities: [Commodity], _ label: String) {
        for c in commodities {
            for cur in [Commodity.aud, .usd] {
                for d in [nil, day(-1), day(0), day(5), day(10), day(19), day(23), day(50)] as [Date?] {
                    #expect(b.latestPrice(of: c, in: cur, on: d)?.guid == scan(b, c, cur, d)?.guid,
                            "\(label) \(c.mnemonic)/\(cur.mnemonic) on \(String(describing: d))")
                }
            }
            for d in [nil, day(0), day(7), day(19), day(23)] as [Date?] {
                #expect(b.latestPriceInAnyCurrency(of: c, on: d)?.guid == scanAny(b, c, d)?.guid,
                        "\(label) any-currency \(c.mnemonic) on \(String(describing: d))")
            }
        }
    }
}
