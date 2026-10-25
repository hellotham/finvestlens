//
//  CapitalGainsTaxRulesTests.swift
//  FinvestLens — Reports
//
//  The ATO's rules on one parcel, held against the ATO's own examples: the
//  twelve-month boundary, the discount, the netting order, the super fund's
//  third, and the 1 July 2027 reform's indexation and transitional split.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}
private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
/// Slack for the super fund's third, which Decimal carries to 38 digits.
private let tiny = Decimal(sign: .plus, exponent: -30, significand: 1)

/// A CPI series keyed by the exact dates the rules ask for.
private func cpi(_ readings: [Date: Double]) -> (Date) -> Double? { { readings[$0] } }
private func noCPI(_: Date) -> Double? { nil }

private func assess(_ parcel: CGTParcelDisposal, entity: CGTEntity = .individual, foreignResident: Bool = false,
                    cpi: (Date) -> Double? = noCPI) -> CGTParcelResult {
    CapitalGainsTaxRules.assess(parcel, entity: entity, foreignResident: foreignResident, cpi: cpi, calendar: utc)
}
private func slice(_ treatment: CGTComponent.Treatment, _ gain: Decimal, eligible: Bool = false) -> CGTComponent {
    CGTComponent(treatment: treatment, gain: gain, discountEligible: eligible, indexed: false, indexedCostBase: nil)
}

@Suite("CGT rules: dates")
struct CGTDateTests {

    @Test("Twelve months excludes the day bought and the day sold")
    func twelveMonthBoundary() {
        let bought = date(2025, 7, 1)
        #expect(!CapitalGainsTaxRules.heldTwelveMonths(acquired: bought, event: date(2026, 6, 30), calendar: utc))
        #expect(!CapitalGainsTaxRules.heldTwelveMonths(acquired: bought, event: date(2026, 7, 1), calendar: utc))
        #expect(CapitalGainsTaxRules.heldTwelveMonths(acquired: bought, event: date(2026, 7, 2), calendar: utc))
    }

    @Test("The reform and pre-CGT days are midnight UTC")
    func constants() {
        #expect(CapitalGainsTaxRules.reformDate == date(2027, 7, 1))
        #expect(CapitalGainsTaxRules.preCGTDate == date(1985, 9, 20))
    }
}

@Suite("CGT rules: one parcel before the reform")
struct CGTPreReformTests {

    @Test("Held over twelve months: one discount slice")
    func discountParcel() throws {
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2024, 1, 10), eventDate: date(2026, 3, 1),
                                              costBase: 1000, proceeds: 1500))
        #expect(result.components.count == 1)
        let only = try #require(result.components.first)
        #expect(only.treatment == .discount)
        #expect(only.gain == 500)
        #expect(only.discountEligible)
        #expect(!only.indexed && only.indexedCostBase == nil)
        #expect(result.heldTwelveMonths)
        #expect(result.holdingDays == 781)
        #expect(result.gain == 500)
        #expect(!result.transitionalValueMissing)
    }

    @Test("Held a hundred days: taxed in full")
    func shortParcel() throws {
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2026, 1, 1), eventDate: date(2026, 4, 11),
                                              costBase: 1000, proceeds: 1500))
        let only = try #require(result.components.first)
        #expect(only.treatment == .other && only.gain == 500 && !only.discountEligible)
        #expect(!result.heldTwelveMonths)
        #expect(result.holdingDays == 100)
    }

    @Test("A long-held loss is classed discount but is not discountable")
    func discountLoss() throws {
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2020, 1, 1), eventDate: date(2026, 1, 1),
                                              costBase: 1000, proceeds: 600))
        let only = try #require(result.components.first)
        #expect(only.treatment == .discount && only.gain == -400 && !only.discountEligible)
    }

    @Test("No acquisition date: taxed in full, with no holding period")
    func pooled() throws {
        let result = assess(CGTParcelDisposal(acquisitionDate: nil, eventDate: date(2026, 1, 1),
                                              costBase: 1000, proceeds: 1500))
        let only = try #require(result.components.first)
        #expect(only.treatment == .other && only.gain == 500 && !only.discountEligible)
        #expect(!result.heldTwelveMonths && result.holdingDays == nil)
    }

    @Test("Bought before 20 September 1985 and sold before the reform: exempt")
    func preCGT() throws {
        let result = assess(CGTParcelDisposal(acquisitionDate: date(1980, 5, 1), eventDate: date(2026, 1, 1),
                                              costBase: 100, proceeds: 5000))
        let only = try #require(result.components.first)
        #expect(result.components.count == 1 && only.treatment == .exempt && only.gain == 4900)
        let net = CapitalGainsTaxRules.net(components: result.components, entity: .individual)
        #expect(net.grossGains == 0 && net.netCapitalGain == 0)
    }
}

@Suite("CGT rules: netting gains and losses")
struct CGTNetTests {

    @Test("Each entity's discount share")
    func fractions() {
        #expect(CGTEntity.individual.discountFraction == dec("0.5"))
        #expect(CGTEntity.trust.discountFraction == dec("0.5"))
        #expect(CGTEntity.company.discountFraction == 0)
        #expect(abs(CGTEntity.superFund.discountFraction * 3 - 1) < tiny)
    }

    @Test("The ATO's Rhi: a $70,000 property gain and a $4,500 share loss net to $32,750")
    func atoWorkedExample() {
        let property = assess(CGTParcelDisposal(acquisitionDate: date(2021, 2, 1), eventDate: date(2026, 2, 1),
                                                costBase: 530_000, proceeds: 600_000))
        let shares = assess(CGTParcelDisposal(acquisitionDate: date(2025, 9, 1), eventDate: date(2026, 3, 1),
                                              costBase: 10_000, proceeds: 5_500))
        let net = CapitalGainsTaxRules.net(components: property.components + shares.components, entity: .individual)
        #expect(net.grossGains == 70_000)
        #expect(net.losses == 4_500)
        #expect(net.discountableGains == 65_500)
        #expect(net.discountApplied == 32_750)
        #expect(net.netCapitalGain == 32_750)
        #expect(net.lossCarriedForward == 0)
        // Her single-asset example: no losses, $70,000 × 50% = $35,000.
        let alone = CapitalGainsTaxRules.net(components: property.components, entity: .individual)
        #expect(alone.discountApplied == 35_000 && alone.netCapitalGain == 35_000)
    }

    @Test("Losses come off the ineligible gains first")
    func lossOrder() {
        let net = CapitalGainsTaxRules.net(components: [
            slice(.discount, 10_000, eligible: true), slice(.other, 3_000), slice(.other, -2_000),
        ], entity: .individual)
        #expect(net.grossGains == 13_000 && net.losses == 2_000)
        #expect(net.discountableGains == 10_000 && net.discountApplied == 5_000)
        #expect(net.netCapitalGain == 6_000)
        #expect(net.lossCarriedForward == 0)
    }

    @Test("A company gets no discount")
    func company() {
        let net = CapitalGainsTaxRules.net(components: [slice(.discount, 10_000, eligible: true)], entity: .company)
        #expect(net.discountApplied == 0 && net.netCapitalGain == 10_000)
    }

    @Test("A complying super fund discounts by a third")
    func superFund() {
        let net = CapitalGainsTaxRules.net(components: [slice(.discount, 300, eligible: true)], entity: .superFund)
        #expect(abs(net.discountApplied - 100) < tiny)
        #expect(abs(net.netCapitalGain - 200) < tiny)
    }

    @Test("A loss carried forward reduces this year's gains")
    func carriedForward() {
        let net = CapitalGainsTaxRules.net(components: [slice(.discount, 10_000, eligible: true)],
                                           entity: .individual, carriedForwardLoss: 4_000)
        #expect(net.losses == 4_000 && net.discountableGains == 6_000)
        #expect(net.netCapitalGain == 3_000 && net.lossCarriedForward == 0)
        // Read by magnitude, whichever sign the caller keeps a loss in.
        let negative = CapitalGainsTaxRules.net(components: [slice(.discount, 10_000, eligible: true)],
                                                entity: .individual, carriedForwardLoss: -4_000)
        #expect(negative == net)
    }

    @Test("Losses past the gains carry forward, and nothing is taxed")
    func netLoss() {
        let net = CapitalGainsTaxRules.net(components: [slice(.other, 1_000), slice(.other, -3_000)], entity: .individual)
        #expect(net.grossGains == 1_000 && net.losses == 3_000)
        #expect(net.netCapitalGain == 0 && net.discountApplied == 0 && net.lossCarriedForward == 2_000)
    }

    @Test("Exempt slices are neither gains nor losses")
    func exemptOutside() {
        let net = CapitalGainsTaxRules.net(components: [
            slice(.exempt, 50_000), slice(.exempt, -1_000), slice(.other, 400),
        ], entity: .individual)
        #expect(net.grossGains == 400 && net.losses == 0 && net.netCapitalGain == 400)
    }
}

@Suite("CGT rules: the 1 July 2027 reform")
struct CGTReformTests {

    @Test("Bought after the reform and held twelve months: the cost base is indexed by CPI")
    func postReformIndexed() throws {
        let bought = date(2027, 8, 1), sold = date(2029, 1, 15)
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: sold, costBase: 1000, proceeds: 1300),
                            cpi: cpi([bought: 100, sold: 110]))
        #expect(result.components.count == 1)
        let only = try #require(result.components.first)
        #expect(only.treatment == .indexation && only.indexed)
        #expect(only.indexedCostBase == 1100)
        #expect(only.gain == 200)
        #expect(!only.discountEligible)
        #expect(result.gain == 200 && result.heldTwelveMonths)
    }

    @Test("The same parcel with no CPI is reported unindexed")
    func postReformNoCPI() throws {
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2027, 8, 1), eventDate: date(2029, 1, 15),
                                              costBase: 1000, proceeds: 1300))
        let only = try #require(result.components.first)
        #expect(only.treatment == .indexation && !only.indexed && only.indexedCostBase == nil)
        #expect(only.gain == 300)
    }

    @Test("Bought after the reform and sold inside twelve months: taxed in full")
    func postReformShort() throws {
        let bought = date(2027, 8, 1), sold = date(2028, 3, 1)
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: sold, costBase: 1000, proceeds: 1300),
                            cpi: cpi([bought: 100, sold: 110]))
        let only = try #require(result.components.first)
        #expect(only.treatment == .other && !only.indexed && only.gain == 300)
    }

    @Test("Owned across the reform: a discount slice to 30 June 2027, an indexed slice after")
    func transitional() throws {
        let sold = date(2028, 6, 30)
        let parcel = CGTParcelDisposal(acquisitionDate: date(2020, 1, 1), eventDate: sold,
                                       costBase: 1000, proceeds: 2200, valueBefore2027: 1800)
        let result = assess(parcel, cpi: cpi([CapitalGainsTaxRules.reformDate: 100, sold: 104]))
        #expect(result.components.count == 2)
        let pre = try #require(result.components.first), post = try #require(result.components.last)
        #expect(pre.treatment == .discount && pre.gain == 800 && pre.discountEligible && !pre.indexed)
        #expect(post.treatment == .indexation && post.indexed && post.indexedCostBase == 1872)
        #expect(post.gain == 328)
        #expect(result.gain == 1128)
        #expect(result.heldTwelveMonths && !result.transitionalValueMissing)

        // Without the CPI the second slice is on the raw 1 July 2027 value.
        let unindexed = assess(parcel)
        let after = try #require(unindexed.components.last)
        #expect(after.treatment == .indexation && !after.indexed && after.gain == 400)
    }

    @Test("Owned across the reform without a 30 June 2027 value: split by the days held each side, flagged")
    func transitionalValueMissing() throws {
        // 1 January 2020 to 30 June 2028 is 3,103 days, 2,738 of them before
        // the reform: the pre-reform slice gets 2,738 ÷ 3,103 of the gain.
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2020, 1, 1), eventDate: date(2028, 6, 30),
                                              costBase: 1000, proceeds: 2200))
        #expect(result.transitionMethod == .apportionment && result.transitionalValueMissing)
        #expect(result.components.map(\.treatment) == [.discount, .indexation])
        let pre = try #require(result.components.first), post = try #require(result.components.last)
        let expectedPre = Decimal(1200) * Decimal(2738) / Decimal(3103)
        #expect(abs(pre.gain - expectedPre) < tiny && pre.discountEligible)
        #expect(!post.indexed && abs(pre.gain + post.gain - 1200) < tiny, "no CPI: the after slice is on its raw base")
    }

    @Test("Apportionment with CPI: the after slice is indexed from 1 July 2027 on its apportioned base")
    func apportionedAndIndexed() throws {
        // 1 July 2025 to 1 July 2029: 1,461 days, 730 before the reform. A
        // gain of 1,461 splits 730 before and 731 after; the after slice's
        // base is 1,730, indexed by 1.1 to 1,903, so its gain is 558.
        let sold = date(2029, 7, 1)
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2025, 7, 1), eventDate: sold,
                                              costBase: 1000, proceeds: 2461),
                            cpi: cpi([CapitalGainsTaxRules.reformDate: 100, sold: 110]))
        let pre = try #require(result.components.first), post = try #require(result.components.last)
        #expect(result.transitionMethod == .apportionment)
        #expect(pre.treatment == .discount && pre.gain == 730)
        #expect(post.treatment == .indexation && post.indexed && post.indexedCostBase == 1903 && post.gain == 558)
    }

    @Test("A loss after the reform is nominal: never indexed, never enlarged")
    func postReformLoss() throws {
        let bought = date(2027, 8, 1), sold = date(2029, 1, 15)
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: sold, costBase: 1000, proceeds: 900),
                            cpi: cpi([bought: 100, sold: 110]))
        let only = try #require(result.components.first)
        #expect(only.treatment == .indexation && only.gain == -100 && only.indexedCostBase == 1000)
    }

    @Test("A super fund keeps its discount after the reform; a company and a foreign resident get nothing")
    func entitiesAfterReform() throws {
        let bought = date(2027, 8, 1), sold = date(2029, 1, 15)
        let parcel = CGTParcelDisposal(acquisitionDate: bought, eventDate: sold, costBase: 1000, proceeds: 1300)
        let readings = cpi([bought: 100, sold: 110])
        let fund = try #require(assess(parcel, entity: .superFund, cpi: readings).components.first)
        #expect(fund.treatment == .discount && fund.discountEligible && fund.gain == 300)
        let company = try #require(assess(parcel, entity: .company, cpi: readings).components.first)
        #expect(company.treatment == .other && company.gain == 300)
        let foreign = try #require(assess(parcel, foreignResident: true, cpi: readings).components.first)
        #expect(foreign.treatment == .other && foreign.gain == 300)
        // Before the reform a foreign resident's long-held gain is taxed in full too.
        let earlier = assess(CGTParcelDisposal(acquisitionDate: date(2020, 1, 1), eventDate: date(2026, 1, 1),
                                               costBase: 1000, proceeds: 1300), foreignResident: true)
        #expect(earlier.components.first?.treatment == .other)
    }

    @Test("The indexation factor is rounded to three decimal places")
    func factorRounding() {
        let bought = date(2027, 8, 1), sold = date(2029, 1, 15)
        // 139.4 ÷ 124.5 is 1.11967…, which rounds to 1.120.
        #expect(CapitalGainsTaxRules.indexationFactor(from: bought, to: sold, cpi: cpi([bought: 124.5, sold: 139.4]))
                == Decimal(string: "1.12"))
        #expect(CapitalGainsTaxRules.indexationFactor(from: bought, to: sold, cpi: cpi([bought: 100, sold: 0])) == nil)
    }

    @Test("Bought under twelve months before the reform but held past twelve: both slices qualify")
    func transitionalShortBeforeReform() throws {
        let sold = date(2028, 3, 1)
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2027, 2, 1), eventDate: sold,
                                              costBase: 1000, proceeds: 1500, valueBefore2027: 1200),
                            cpi: cpi([CapitalGainsTaxRules.reformDate: 100, sold: 102]))
        let pre = try #require(result.components.first), post = try #require(result.components.last)
        #expect(pre.treatment == .discount && pre.discountEligible && pre.gain == 200)
        #expect(post.treatment == .indexation && post.indexed && post.indexedCostBase == 1224 && post.gain == 276)
    }

    @Test("Owned across the reform and sold inside twelve months of purchase: neither slice qualifies")
    func transitionalShortOverall() {
        let result = assess(CGTParcelDisposal(acquisitionDate: date(2027, 5, 1), eventDate: date(2027, 9, 1),
                                              costBase: 1000, proceeds: 1500, valueBefore2027: 1200))
        #expect(result.components.map(\.treatment) == [.other, .other])
        #expect(result.components.map(\.gain) == [200, 300])
        #expect(!result.heldTwelveMonths)
    }

    @Test("A CPI factor below one never lowers the cost base")
    func cpiFell() throws {
        let bought = date(2027, 8, 1), sold = date(2029, 1, 15)
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: sold, costBase: 1000, proceeds: 1300),
                            cpi: cpi([bought: 100, sold: 98]))
        let only = try #require(result.components.first)
        #expect(only.treatment == .indexation && only.indexed)
        #expect(only.indexedCostBase == 1000 && only.gain == 300)
    }

    @Test("A pre-CGT parcel sold after the reform: exempt to 30 June 2027, taxed after")
    func preCGTAcrossReform() throws {
        let sold = date(2028, 2, 1)
        let result = assess(CGTParcelDisposal(acquisitionDate: date(1980, 5, 1), eventDate: sold,
                                              costBase: 100, proceeds: 5200, valueBefore2027: 5000),
                            cpi: cpi([CapitalGainsTaxRules.reformDate: 100, sold: 102]))
        let pre = try #require(result.components.first), post = try #require(result.components.last)
        #expect(pre.treatment == .exempt && pre.gain == 4900 && !pre.discountEligible)
        #expect(post.treatment == .indexation && post.indexed && post.indexedCostBase == 5100 && post.gain == 100)
        let net = CapitalGainsTaxRules.net(components: result.components, entity: .individual)
        #expect(net.grossGains == 100 && net.netCapitalGain == 100)
    }

    @Test("A CPI reading keeps its decimal spelling")
    func cpiDecimal() throws {
        // 139.4 ÷ 124.5 rounds to 1.120, and 1.120 × 1245 is exactly 1394.4
        // in decimal; the Doubles' binary neighbours would leave a tail.
        let bought = date(2027, 8, 1), sold = date(2029, 1, 15)
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: sold, costBase: 1245, proceeds: 2000),
                            cpi: cpi([bought: 124.5, sold: 139.4]))
        let indexedCost = try #require(result.components.first?.indexedCostBase)
        #expect(indexedCost == Decimal(string: "1394.4"))
    }
}

@Suite("CGT rules: the frozen indexation method")
struct CGTFrozenIndexationTests {

    /// Bought 1 January 1990 at 1,000, CPI 50 then and 60 by the September
    /// 1999 quarter: an indexed cost base of 1,200.
    private let bought = date(1990, 1, 1)
    private var readings: (Date) -> Double? { cpi([bought: 50, CapitalGainsTaxRules.frozenQuarterEnd: 60]) }

    @Test("Indexation wins when it assesses less than the discounted gain")
    func indexationWins() throws {
        // Gain 300: discounted 150, indexed 100.
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: date(2026, 1, 1),
                                              costBase: 1000, proceeds: 1300), cpi: readings)
        let only = try #require(result.components.first)
        #expect(only.treatment == .frozenIndexation && only.indexed && only.indexedCostBase == 1200 && only.gain == 100)
        #expect(!only.discountEligible)
        let net = CapitalGainsTaxRules.net(components: result.components, entity: .individual)
        #expect(net.netCapitalGain == 100 && net.minimumTaxGain == 0)
    }

    @Test("The discount wins when it assesses less")
    func discountWins() throws {
        // Gain 1,000: discounted 500, indexed 800.
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: date(2026, 1, 1),
                                              costBase: 1000, proceeds: 2000), cpi: readings)
        let only = try #require(result.components.first)
        #expect(only.treatment == .discount && only.discountEligible && only.gain == 1000)
    }

    @Test("A company, with no discount, indexes whenever it helps")
    func company() throws {
        let result = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: date(2026, 1, 1),
                                              costBase: 1000, proceeds: 2000), entity: .company, cpi: readings)
        let only = try #require(result.components.first)
        #expect(only.treatment == .frozenIndexation && only.gain == 800)
    }

    @Test("Acquired after 21 September 1999, or without the CPI, the method is not offered")
    func notOffered() {
        let later = assess(CGTParcelDisposal(acquisitionDate: date(2000, 1, 1), eventDate: date(2026, 1, 1),
                                             costBase: 1000, proceeds: 1300),
                           cpi: cpi([date(2000, 1, 1): 50, CapitalGainsTaxRules.frozenQuarterEnd: 60]))
        #expect(later.components.first?.treatment == .discount)
        let noCPI = assess(CGTParcelDisposal(acquisitionDate: bought, eventDate: date(2026, 1, 1),
                                             costBase: 1000, proceeds: 1300))
        #expect(noCPI.components.first?.treatment == .discount)
    }
}

@Suite("CGT rules: netting under the reform")
struct CGTReformNettingTests {

    private func indexed(_ gain: Decimal) -> CGTComponent {
        CGTComponent(treatment: .indexation, gain: gain, discountEligible: false, indexed: true, indexedCostBase: nil)
    }

    @Test("Losses come off the discount gains first, then the other pre-2027 gains, then the indexed")
    func billOrdering() {
        let net = CapitalGainsTaxRules.net(
            components: [slice(.discount, 1000, eligible: true), slice(.other, 500), indexed(800), slice(.other, -1200)],
            entity: .individual)
        // 1,200 of loss: 1,000 off the discount gains, 200 off the other.
        #expect(net.discountableGains == 0 && net.discountApplied == 0)
        #expect(net.netCapitalGain == 1100)
        #expect(net.minimumTaxGain == 800)
        #expect(net.lossCarriedForward == 0)
    }

    @Test("Without an indexed slice the ATO's order stands: the other gains first")
    func atoOrdering() {
        let net = CapitalGainsTaxRules.net(
            components: [slice(.discount, 1000, eligible: true), slice(.other, 500), slice(.other, -1200)],
            entity: .individual)
        // 500 off the other gains, 700 off the discount gains: 300 left, discounted to 150.
        #expect(net.discountableGains == 300 && net.netCapitalGain == 150 && net.minimumTaxGain == 0)
    }

    @Test("The minimum-tax gain is what is left of the indexed slices after the losses")
    func minimumTaxGain() {
        let net = CapitalGainsTaxRules.net(components: [indexed(800), slice(.other, -1000)], entity: .individual)
        #expect(net.netCapitalGain == 0 && net.minimumTaxGain == 0 && net.lossCarriedForward == 200)
    }
}
