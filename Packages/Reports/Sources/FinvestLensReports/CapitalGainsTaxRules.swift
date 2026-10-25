//
//  CapitalGainsTaxRules.swift
//  FinvestLens — Reports
//
//  How Australia taxes the gain on one parcel when it is disposed of: the
//  gain or loss, the discount for a parcel held over twelve months, the
//  pre-CGT exemption, the frozen indexation method a parcel bought before
//  21 September 1999 may still choose, the netting of losses against gains
//  in the ATO's order — and, from 1 July 2027, the reform that trades the
//  discount for cost-base indexation on gains accruing after that day, with
//  a parcel owned across the boundary split into its before and its after by
//  its value on the day or, without one, by the days held each side. Pure
//  functions over dates and amounts: the report layer brings the prices, the
//  CPI series and the entity, and does the rounding. Each rule is applied
//  under the ATO's own sentence, from its pages "CGT discount" and "How to
//  calculate your CGT" (both last updated 29 June 2026) and "Capital gains
//  tax reform" (published 13 October 2026), so a reader can hold the words
//  against the code. Where the ATO has not yet published a mechanism — the
//  apportionment method, the loss ordering under the Bill — the rule is the
//  one InvestaLens (Hello Tham, MIT) models in `lib/calculations/cgt-2027.ts`
//  and `indexation.ts`, opened on 25 October 2026, and the comment says so.
//  Nothing here is advice: it is arithmetic on the person's own book.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Who made the gain. ATO, "CGT discount": "If an asset is owned for at
/// least 12 months: Australian trusts can discount a capital gain by 50%;
/// complying super funds can discount a capital gain by 33.33%. Companies
/// can't use the CGT discount."
public enum CGTEntity: String, Codable, Sendable, CaseIterable {
    case individual, trust, superFund, company

    /// The share of an eligible gain the discount removes. The super fund's
    /// third is kept exact as `Decimal(1) / Decimal(3)` rather than 0.3333:
    /// the report layer rounds once, at the end.
    public var discountFraction: Decimal {
        switch self {
        case .individual, .trust: return 0.5
        case .superFund: return Decimal(1) / Decimal(3)
        case .company: return 0
        }
    }

    /// Whether the reform's indexation reaches this entity. The reform page
    /// names "resident individuals trusts and partnerships"; a company and a
    /// complying super fund keep their present treatment (InvestaLens reads
    /// it the same way: "Companies and super funds keep existing settings").
    public var indexesAfterReform: Bool {
        switch self {
        case .individual, .trust: return true
        case .superFund, .company: return false
        }
    }
}

/// How a parcel owned across 1 July 2027 was split into its before and its
/// after. ATO, "Capital gains tax reform": the law applies "as if you have
/// disposed of the asset immediately before 1 July 2027 and reacquired it
/// on 1 July 2027", at its value then — the market-value method — and for
/// assets without a value "an apportionment method" is being developed.
/// Until it is published, the apportionment here is InvestaLens's days-based
/// safe harbour: the gain accrued before the reform in the proportion of the
/// ownership that ran before it.
public enum CGTTransitionMethod: String, Sendable {
    case marketValue, apportionment
}

/// One parcel's disposal as the report layer hands it over: what it cost,
/// what it fetched, when it was bought and sold, and — for a parcel owned
/// across 1 July 2027 — what it was worth the moment before the reform.
public struct CGTParcelDisposal: Hashable, Sendable {
    /// When the parcel was acquired; `nil` for a pooled (average-cost) lot or
    /// an uncovered short, which have no date of their own and so no holding
    /// period to test.
    public let acquisitionDate: Date?
    /// The CGT event: the sale, or the contract date for one.
    public let eventDate: Date
    /// The cost base. The ATO works a loss off the "reduced cost base"; the
    /// engine keeps one cost per parcel, so a loss is read off the same
    /// figure.
    public let costBase: Decimal
    /// "Capital proceeds": what the disposal fetched.
    public let proceeds: Decimal
    /// Market value "immediately before 1 July 2027" — price × units at the
    /// last price before the reform — when the parcel was owned then.
    public let valueBefore2027: Decimal?

    public init(acquisitionDate: Date?, eventDate: Date, costBase: Decimal, proceeds: Decimal,
                valueBefore2027: Decimal? = nil) {
        self.acquisitionDate = acquisitionDate
        self.eventDate = eventDate
        self.costBase = costBase
        self.proceeds = proceeds
        self.valueBefore2027 = valueBefore2027
    }
}

/// One taxed slice of a parcel's gain. Before the reform a parcel is one
/// slice; a parcel owned across 1 July 2027 and sold after it is two.
public struct CGTComponent: Hashable, Sendable {
    public enum Treatment: String, Sendable {
        /// Held long enough for the discount; ``CapitalGainsTaxRules/net``
        /// applies the entity's share of it.
        case discount
        /// A gain accruing after the reform: the cost base indexed by CPI
        /// where it could be (``CGTComponent/indexed`` says whether).
        case indexation
        /// A parcel acquired before 21 September 1999 whose cost base is
        /// indexed under the method frozen at the September 1999 quarter,
        /// because that assesses less than the discount would (a company,
        /// with no discount, takes it whenever it helps).
        case frozenIndexation
        /// A pre-CGT parcel's gain to 30 June 2027: outside CGT altogether.
        case exempt
        /// Taxed in full: held under twelve months, no acquisition date to
        /// test, a company's or a foreign resident's long-held gain.
        case other
    }

    public let treatment: Treatment
    /// The slice's assessable gain before losses and the discount, signed: a
    /// loss is negative. For an indexed slice it is the gain over the
    /// indexed cost base, not over the raw cost.
    public let gain: Decimal
    /// Whether the discount will apply to this slice — a `.discount` slice
    /// with a gain. A loss is never discounted: the ATO takes losses off the
    /// gains first, then discounts what is left.
    public let discountEligible: Bool
    /// Whether the cost base was indexed. `false` on an `.indexation` slice
    /// with a gain means the CPI series had no reading for one of its two
    /// dates, and the gain is on the raw cost — the report layer should say
    /// so. A loss needs no CPI: it is nominal, and reads as indexed at one.
    public let indexed: Bool
    /// The cost base after indexation, when ``indexed``.
    public let indexedCostBase: Decimal?

    public init(treatment: Treatment, gain: Decimal, discountEligible: Bool, indexed: Bool,
                indexedCostBase: Decimal?) {
        self.treatment = treatment
        self.gain = gain
        self.discountEligible = discountEligible
        self.indexed = indexed
        self.indexedCostBase = indexedCostBase
    }

    /// A slice taxed in full, on the raw cost.
    static func inFull(_ gain: Decimal) -> CGTComponent {
        CGTComponent(treatment: .other, gain: gain, discountEligible: false, indexed: false, indexedCostBase: nil)
    }

    /// A pre-CGT slice: outside the tax.
    static func exempt(_ gain: Decimal) -> CGTComponent {
        CGTComponent(treatment: .exempt, gain: gain, discountEligible: false, indexed: false, indexedCostBase: nil)
    }

    /// A long-held slice under the discount.
    static func discounted(_ gain: Decimal) -> CGTComponent {
        CGTComponent(treatment: .discount, gain: gain, discountEligible: gain > 0, indexed: false, indexedCostBase: nil)
    }
}

/// How one parcel's disposal is taxed: its slices and the facts about the
/// holding they rest on.
public struct CGTParcelResult: Hashable, Sendable {
    public let components: [CGTComponent]
    /// Whether the whole ownership ran past twelve months; `false` when
    /// there is no acquisition date to count from.
    public let heldTwelveMonths: Bool
    /// Whole calendar days held, counted in UTC like `RealizedGain
    /// .holdingDays` — the figure the Capital Gains report already prints
    /// beside the parcel, which this must match — or `nil` without an
    /// acquisition date.
    public let holdingDays: Int?
    /// How a parcel owned across 1 July 2027 and sold after it was split;
    /// `nil` for a parcel the reform does not divide.
    public let transitionMethod: CGTTransitionMethod?
    /// A parcel owned across 1 July 2027 and sold after it, assessed without
    /// its value immediately before the reform: split by apportionment
    /// instead (a pre-CGT parcel then shows no post-reform gain at all),
    /// until the report layer has a price for the day.
    public let transitionalValueMissing: Bool

    /// The parcel's assessable gain before losses and the discount, every
    /// slice summed — the exempt one too. ``CapitalGainsTaxRules/net`` is
    /// what leaves the exempt part out.
    public var gain: Decimal { components.reduce(0) { $0 + $1.gain } }

    public init(components: [CGTComponent], heldTwelveMonths: Bool, holdingDays: Int?,
                transitionMethod: CGTTransitionMethod? = nil, transitionalValueMissing: Bool = false) {
        self.components = components
        self.heldTwelveMonths = heldTwelveMonths
        self.holdingDays = holdingDays
        self.transitionMethod = transitionMethod
        self.transitionalValueMissing = transitionalValueMissing
    }
}

/// The ATO's capital gains tax rules for one parcel, as pure arithmetic.
public enum CapitalGainsTaxRules {

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 1 July 2027, midnight UTC. ATO, "Capital gains tax reform": "From
    /// 1 July 2027, the CGT changes will: replace the 50% CGT discount for
    /// resident individuals trusts and partnerships with cost base indexation
    /// on gains that accrue on or after 1 July 2027; introduce a minimum 30%
    /// tax for individuals on certain net capital gains which accrue on or
    /// after 1 July 2027; subject those with pre-CGT assets to CGT for gains
    /// accruing on or after 1 July 2027." Dates compare as instants against
    /// this one; a posted date carries the canonical time of day, so its
    /// civil date is what decides.
    public static let reformDate: Date = utc.date(from: DateComponents(year: 2027, month: 7, day: 1))!

    /// 20 September 1985, midnight UTC: CGT's first day. ATO, "Capital gains
    /// tax reform": "Assets purchased before 20 September 1985 will continue
    /// to be exempt for gains accrued before 1 July 2027. The new
    /// arrangements will then apply to any gains accrued on or after 1 July
    /// 2027."
    public static let preCGTDate: Date = utc.date(from: DateComponents(year: 1985, month: 9, day: 20))!

    /// 11:45 am AEST on 21 September 1999 (01:45 UTC): a parcel acquired
    /// from then on cannot use the indexation method; one acquired before it
    /// may, with the CPI frozen at the September 1999 quarter
    /// (``frozenQuarterEnd``). InvestaLens, `indexation.ts`: "the current-law
    /// indexation method for assets acquired before 11:45am 21 September 1999
    /// (CPI frozen at the September 1999 quarter)".
    public static let indexationCutoff: Date =
        utc.date(from: DateComponents(year: 1999, month: 9, day: 21, hour: 1, minute: 45))!

    /// The last day of the September 1999 quarter: the latest CPI reading the
    /// frozen method may use.
    public static let frozenQuarterEnd: Date = utc.date(from: DateComponents(year: 1999, month: 9, day: 30))!

    /// The reform's minimum effective rate on net gains accruing after
    /// 1 July 2027 ("a minimum 30% tax for individuals on certain net capital
    /// gains"). A rate on a gain, applied by the tax estimate; this file only
    /// says which gains it reaches (``NetGain/minimumTaxGain``).
    public static let minimumTaxRate: Decimal = Decimal(string: "0.3")!

    /// The twelve-month test the discount and indexation share. ATO, "CGT
    /// discount": "For an asset to qualify for the CGT discount you must own
    /// it for at least 12 months before the 'CGT event' happens … You exclude
    /// the day of acquisition and the day of the CGT event when working out
    /// if you owned the CGT asset for at least 12 months before the 'CGT
    /// event' happens." Both days excluded, twelve months is first reached
    /// the day *after* the acquisition's first anniversary: bought 1 July
    /// 2025, a sale on 1 July 2026 has 364 days between the two excluded days
    /// and does not qualify; one on 2 July 2026 has 365 and does. The reform
    /// page applies the same test to indexation: "For an asset to qualify
    /// for the CGT discount or cost base indexation, you must own it for at
    /// least 12 months before the CGT event happens." The anniversary is a
    /// calendar year in `calendar` (so a leap day counts as the calendar
    /// says), compared by civil day, not clock time.
    public static func heldTwelveMonths(acquired: Date, event: Date, calendar: Calendar = .current) -> Bool {
        guard let anniversary = calendar.date(byAdding: .year, value: 1, to: acquired) else { return false }
        return calendar.compare(event, to: anniversary, toGranularity: .day) == .orderedDescending
    }

    /// One parcel's disposal, sliced and classed.
    ///
    /// ATO, "How to calculate your CGT", step 3: "Subtract the costs (step
    /// 2) from what you received (step 1). If the result is: more than zero,
    /// you have a capital gain for this asset; less than zero, you have a
    /// capital loss for this asset." Before the reform that is the one
    /// slice, discounted if held twelve months, exempt if pre-CGT, else taxed
    /// in full — and for a parcel acquired before 21 September 1999 and held
    /// twelve months, indexed under the frozen method instead when that
    /// assesses less (the ATO lets the person choose; a company has only
    /// indexation).
    ///
    /// From the reform page: "There is no change for assets purchased and
    /// sold prior to 1 July 2027." "Assets purchased on or after 1 July 2027
    /// will be treated wholly under the new arrangements." "Assets owned
    /// prior to 1 July 2027 and sold on or after that date will be treated
    /// under current arrangements on gains made prior to 1 July 2027, and
    /// the new arrangements for gains made on or after 1 July 2027 … This
    /// means: indexation and the minimum tax will be used to calculate the
    /// CGT on gains accruing on or after 1 July 2027 (using the asset's value
    /// at 1 July 2027 as the asset's cost base); the 50% CGT discount will
    /// apply to the difference between the asset's cost base and its value
    /// immediately before 1 July 2027." "The law will apply as if you have
    /// disposed of the asset immediately before 1 July 2027 and reacquired
    /// it on 1 July 2027." So a parcel owned across the day is two slices:
    /// `valueBefore2027 − costBase` under the old rules, and `proceeds −
    /// valueBefore2027` with that value as the cost base, indexed from
    /// 1 July 2027 (``CGTTransitionMethod/marketValue``). Without the value
    /// the gain is apportioned by days held each side of the reform
    /// (``CGTTransitionMethod/apportionment``), and the result says
    /// `transitionalValueMissing` so the report can ask for a price.
    ///
    /// The twelve-month test runs over the whole ownership for both slices:
    /// "if you purchase an asset less than 12 months prior to 1 July 2027 but
    /// you hold the asset for at least 12 months before disposing of it you
    /// can apply: the CGT discount to your pre-1 July 2027 gain, and cost
    /// base indexation to your post-1 July 2027 gain." A pre-CGT parcel's
    /// first slice is `.exempt` and its second is taxed like any other, per
    /// the page's table: "Capital gains remain subject to the CGT exemptions
    /// for pre-CGT assets" to 1 July 2027, and "Capital gains accruing from
    /// 1 July 2027 will be subject to CGT. Cost base indexation may be used
    /// to calculate gains accruing from this date."
    ///
    /// Indexation: "Cost base indexation adjusts an asset's purchase price
    /// for inflation using the consumer price index (CPI) before calculating
    /// the capital gain." The factor is the CPI at the event over the CPI at
    /// the base date — the acquisition, or 1 July 2027 for the second slice —
    /// both read from `cpi`, the quarterly series the person maintains,
    /// rounded to three decimal places as the 1999 method rounded its own.
    /// With either reading missing the slice is `.indexation` but not
    /// `indexed`, its gain on the raw cost. A factor under one is taken as
    /// one: the ATO's 1999 indexation method only ever raised a cost ("The
    /// increased cost amounts will reduce your capital gain on the asset")
    /// and could not be used on a loss, so a fall in the CPI never lowers a
    /// cost base, and a loss is nominal — never indexed, never enlarged.
    ///
    /// Who gets what: `entity` and `foreignResident` gate the discount and
    /// the reform's indexation. A foreign resident gets neither (the
    /// discount closed to foreign residents in 2012; InvestaLens reads the
    /// reform the same way). A company and a complying super fund keep
    /// their present treatment after the reform — the page names "resident
    /// individuals trusts and partnerships" — so their post-2027 slice is a
    /// `.discount` slice for the fund and `.other` for the company.
    public static func assess(_ parcel: CGTParcelDisposal, entity: CGTEntity = .individual,
                              foreignResident: Bool = false, cpi: (Date) -> Double?,
                              calendar: Calendar = .current) -> CGTParcelResult {
        let wholeGain = parcel.proceeds - parcel.costBase
        guard let acquired = parcel.acquisitionDate else {
            return CGTParcelResult(components: [.inFull(wholeGain)], heldTwelveMonths: false, holdingDays: nil)
        }
        let event = parcel.eventDate
        let held = heldTwelveMonths(acquired: acquired, event: event, calendar: calendar)
        let days = wholeCalendarDays(from: acquired, to: event)
        let preCGT = acquired < preCGTDate
        let discounts = !foreignResident && entity.discountFraction > 0
        let indexes = !foreignResident && entity.indexesAfterReform

        func result(_ components: [CGTComponent], method: CGTTransitionMethod? = nil,
                    valueMissing: Bool = false) -> CGTParcelResult {
            CGTParcelResult(components: components, heldTwelveMonths: held, holdingDays: days,
                            transitionMethod: method, transitionalValueMissing: valueMissing)
        }

        // A slice under the arrangements in force before the reform, on a
        // cost base of `cost`.
        func currentSlice(gain: Decimal, cost: Decimal) -> CGTComponent {
            if preCGT { return .exempt(gain) }
            guard held else { return .inFull(gain) }
            let usual: CGTComponent = discounts ? .discounted(gain) : .inFull(gain)
            // The frozen indexation method, where it assesses less.
            guard gain > 0, acquired < indexationCutoff, !foreignResident,
                  let factor = indexationFactor(from: acquired, to: min(event, frozenQuarterEnd), cpi: cpi),
                  factor > 1 else { return usual }
            let indexedCost = cost * factor
            let indexedGain = max(0, cost + gain - indexedCost)
            let usualAssessable = discounts ? gain * (1 - entity.discountFraction) : gain
            guard indexedGain < usualAssessable else { return usual }
            return CGTComponent(treatment: .frozenIndexation, gain: indexedGain, discountEligible: false,
                                indexed: true, indexedCostBase: indexedCost)
        }

        // A slice under the reform: cost indexed from `base` to the event.
        func reformSlice(cost: Decimal, proceeds: Decimal, base: Date) -> CGTComponent {
            let gain = proceeds - cost
            guard held else { return .inFull(gain) }
            guard indexes else { return discounts ? .discounted(gain) : .inFull(gain) }
            guard gain > 0 else {
                return CGTComponent(treatment: .indexation, gain: gain, discountEligible: false,
                                    indexed: true, indexedCostBase: cost)
            }
            guard let factor = indexationFactor(from: base, to: event, cpi: cpi) else {
                return CGTComponent(treatment: .indexation, gain: gain, discountEligible: false,
                                    indexed: false, indexedCostBase: nil)
            }
            let indexedCost = cost * max(factor, 1)
            return CGTComponent(treatment: .indexation, gain: max(0, proceeds - indexedCost),
                                discountEligible: false, indexed: true, indexedCostBase: indexedCost)
        }

        if event < reformDate {
            return result([currentSlice(gain: wholeGain, cost: parcel.costBase)])
        }
        if acquired >= reformDate {
            return result([reformSlice(cost: parcel.costBase, proceeds: parcel.proceeds, base: acquired)])
        }
        if let value = parcel.valueBefore2027 {
            return result([currentSlice(gain: value - parcel.costBase, cost: parcel.costBase),
                           reformSlice(cost: value, proceeds: parcel.proceeds, base: reformDate)],
                          method: .marketValue)
        }
        if preCGT {
            // Nothing to reset the cost base to: the whole gain stays exempt
            // and the post-reform slice reads nothing, until there is a price.
            return result([.exempt(wholeGain),
                           CGTComponent(treatment: .indexation, gain: 0, discountEligible: false,
                                        indexed: false, indexedCostBase: nil)],
                          method: .marketValue, valueMissing: true)
        }
        // Apportionment: the gain accrued before the reform in the share of
        // the days held before it (InvestaLens, `cgt-2027.ts`: "pre-gain =
        // total gain × (days held before 1 Jul 2027 ÷ total days held)").
        let total = max(days, 1)
        let before = min(max(wholeCalendarDays(from: acquired, to: reformDate), 0), total)
        let preGain = wholeGain * Decimal(before) / Decimal(total)
        return result([currentSlice(gain: preGain, cost: parcel.costBase),
                       reformSlice(cost: parcel.costBase + preGain, proceeds: parcel.proceeds, base: reformDate)],
                      method: .apportionment, valueMissing: true)
    }

    /// CPI at the event over CPI at the base date, from the caller's series,
    /// rounded to three decimal places — the ATO's 1999 method rounded its
    /// factor so, and InvestaLens rounds the reform's the same way; `nil`
    /// when either reading is missing or not positive.
    static func indexationFactor(from base: Date, to event: Date, cpi: (Date) -> Double?) -> Decimal? {
        guard let atEvent = cpi(event).flatMap({ decimal($0) }), let atBase = cpi(base).flatMap({ decimal($0) }),
              atEvent > 0, atBase > 0 else { return nil }
        var quotient = atEvent / atBase
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 3, .plain)
        return rounded
    }

    /// A CPI reading as a Decimal by way of its shortest decimal spelling, so
    /// 139.4 arrives as 139.4 and not the binary neighbour `Decimal(Double)`
    /// keeps (139.400000000000005…), which would leak into every indexed
    /// cost base.
    private static func decimal(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return Decimal(string: "\(value)")
    }

    /// A year's gains and losses netted the ATO's way.
    public struct NetGain: Hashable, Sendable {
        /// The positive slice gains summed, exempt slices aside.
        public let grossGains: Decimal
        /// The losses as a positive magnitude: this year's slices plus the
        /// loss carried forward.
        public let losses: Decimal
        /// The discount-eligible gains left after the losses: what the
        /// discount is applied to.
        public let discountableGains: Decimal
        /// `discountableGains × entity.discountFraction`.
        public let discountApplied: Decimal
        /// What is taxed: the gains left after the losses, less the discount;
        /// zero when the losses swallow the gains.
        public let netCapitalGain: Decimal
        /// The losses the gains could not absorb, for next year; zero when
        /// there was a net gain.
        public let lossCarriedForward: Decimal
        /// The part of ``netCapitalGain`` that accrued after 1 July 2027 —
        /// the indexed slices left after the losses — which the reform's
        /// minimum 30% tax reaches ("the minimum tax capital gain").
        public let minimumTaxGain: Decimal
    }

    /// Net the year's slices. ATO, "How to calculate your CGT", step 5:
    /// "Subtract your capital losses from your capital gains … If you have a
    /// net capital loss carried forward from previous years, subtract this
    /// first. You can choose which capital gains to subtract your losses
    /// from. If you have any capital gains that are not eligible for the CGT
    /// discount, subtract your losses from these gains first. This will give
    /// you the best result (the lowest CGT)." Step 6: a remainder "less than
    /// zero – this is your net capital loss". Step 7: "Apply the CGT discount
    /// (50% for individuals and trusts) to any remaining capital gains that
    /// are eligible … For complying super funds, the discount is 33.33%.
    /// Companies can't use the discount." Step 8: a net capital loss "you can
    /// carry … forward to reduce capital gains you make in future years".
    /// The page's Rhi, with "$70,000 (gain from property) − $4,500 (losses
    /// from share) = $65,500" and "$65,500 × 50% = $32,750", is the test.
    ///
    /// Every loss — the year's and the one carried forward — goes into one
    /// pool, so which is subtracted first changes nothing; the pool comes off
    /// the ineligible gains first, then the eligible. `carriedForwardLoss` is
    /// read by magnitude, whichever sign the caller keeps it in. `.exempt`
    /// slices are neither gains nor losses. A `.discount` slice counts as
    /// eligible only through ``CGTComponent/discountEligible``, which
    /// ``assess(_:entity:foreignResident:cpi:calendar:)`` sets.
    ///
    /// A year with an indexed slice is a year under the reform, and the
    /// losses then come off in the Bill's order as InvestaLens models it
    /// (`applyLossOrdering`: "against discount (deferred) gains first, then
    /// non-discountable pre-2027 gains, then indexed (post-2027) gains …
    /// Losses are nominal (never indexed)") — the ATO page has not yet
    /// published the order, and the comment is the receipt for where this
    /// one comes from.
    public static func net(components: [CGTComponent], entity: CGTEntity,
                           carriedForwardLoss: Decimal = 0) -> NetGain {
        let taxed = components.filter { $0.treatment != .exempt }
        let grossGains = taxed.reduce(Decimal(0)) { $0 + max($1.gain, 0) }
        let losses = taxed.reduce(carriedForwardLoss.magnitude) { $0 + max(-$1.gain, 0) }
        let eligible = taxed.reduce(Decimal(0)) { $0 + ($1.discountEligible ? max($1.gain, 0) : 0) }
        let indexed = taxed.reduce(Decimal(0)) { $0 + ($1.treatment == .indexation ? max($1.gain, 0) : 0) }
        let ineligible = grossGains - eligible - indexed
        var pool = losses
        func absorb(_ gains: Decimal) -> Decimal {
            let used = min(pool, gains)
            pool -= used
            return gains - used
        }
        let remainingEligible: Decimal, remainingIneligible: Decimal, remainingIndexed: Decimal
        if taxed.contains(where: { $0.treatment == .indexation }) {
            remainingEligible = absorb(eligible)
            remainingIneligible = absorb(ineligible)
            remainingIndexed = absorb(indexed)
        } else {
            remainingIneligible = absorb(ineligible)
            remainingEligible = absorb(eligible)
            remainingIndexed = absorb(indexed)
        }
        let discountApplied = remainingEligible * entity.discountFraction
        return NetGain(grossGains: grossGains,
                       losses: losses,
                       discountableGains: remainingEligible,
                       discountApplied: discountApplied,
                       netCapitalGain: remainingIneligible + remainingEligible - discountApplied + remainingIndexed,
                       lossCarriedForward: pool,
                       minimumTaxGain: remainingIndexed)
    }
}
