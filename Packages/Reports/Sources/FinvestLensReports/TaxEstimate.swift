//
//  TaxEstimate.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The tax estimator (`FR-PLAN-12`, docs/planning-design.md §3): progressive
/// bracket arithmetic over the book's tax-tagged figures. The bracket table is
/// **data, not law** — seeded with Australian resident rates, edited by the
/// user as rules change — and the result is an estimate from the user's own
/// books, never advice.
public enum TaxEstimate {

    /// One marginal bracket: the rate applying to income **over** `over`.
    public struct Bracket: Codable, Sendable, Equatable, Identifiable {
        public var id: Decimal { over }
        public var over: Decimal
        public var rate: Decimal

        public init(over: Decimal, rate: Decimal) {
            self.over = over
            self.rate = rate
        }
    }

    /// The editable model: brackets plus the flat levy and the long-term
    /// capital-gains discount share — and, for the Capital Gains report's
    /// ATO assessment, who the taxpayer is and the CPI series the reform's
    /// indexation reads.
    public struct Settings: Codable, Sendable, Equatable {
        public var brackets: [Bracket]
        /// A flat levy on taxable income (Medicare levy: 0.02). The real levy
        /// has low-income phase-ins this deliberately ignores — documented on
        /// the estimate screen.
        public var levyRate: Decimal
        /// The share of long-term gains excluded (AU CGT discount: 0.5).
        public var longTermDiscount: Decimal
        /// Who made the gains: sets the discount share and whether the 2027
        /// reform indexes (`CGTEntity`).
        public var cgtEntity: CGTEntity
        /// A foreign or temporary resident gets neither the discount nor the
        /// reform's indexation.
        public var foreignResident: Bool
        /// Income-support recipients are outside the reform's minimum tax.
        public var incomeSupportRecipient: Bool
        /// The consumer price index, all groups, Australia, by quarter
        /// (`"2026-Q2"`) — RBA statistical table G1, series GCPIAG. Any
        /// consistent series serves: indexation is a ratio of two readings.
        public var cpiQuarters: [String: Double]

        public init(brackets: [Bracket], levyRate: Decimal, longTermDiscount: Decimal,
                    cgtEntity: CGTEntity = .individual, foreignResident: Bool = false,
                    incomeSupportRecipient: Bool = false, cpiQuarters: [String: Double] = [:]) {
            self.brackets = brackets.sorted { $0.over < $1.over }
            self.levyRate = levyRate
            self.longTermDiscount = longTermDiscount
            self.cgtEntity = cgtEntity
            self.foreignResident = foreignResident
            self.incomeSupportRecipient = incomeSupportRecipient
            self.cpiQuarters = cpiQuarters
        }

        private enum CodingKeys: String, CodingKey {
            case brackets, levyRate, longTermDiscount, cgtEntity, foreignResident, incomeSupportRecipient, cpiQuarters
        }

        /// A book saved before the CGT fields existed decodes with their
        /// defaults rather than losing its rate table.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(brackets: try container.decode([Bracket].self, forKey: .brackets),
                      levyRate: try container.decode(Decimal.self, forKey: .levyRate),
                      longTermDiscount: try container.decode(Decimal.self, forKey: .longTermDiscount),
                      cgtEntity: try container.decodeIfPresent(CGTEntity.self, forKey: .cgtEntity) ?? .individual,
                      foreignResident: try container.decodeIfPresent(Bool.self, forKey: .foreignResident) ?? false,
                      incomeSupportRecipient: try container.decodeIfPresent(Bool.self, forKey: .incomeSupportRecipient) ?? false,
                      cpiQuarters: try container.decodeIfPresent([String: Double].self, forKey: .cpiQuarters) ?? [:])
        }

        /// Australian resident rates for the financial year **ending** in
        /// `year` (e.g. 2027 = FY 2026–27, whose first taxed bracket is 15%
        /// under the legislated 2026 cut; 16% for FY 2024–25/2025–26).
        public static func australian(financialYearEnding year: Int) -> Settings {
            let firstRate: Decimal
            switch year {
            case ..<2027: firstRate = Decimal(string: "0.16")!
            case 2027: firstRate = Decimal(string: "0.15")!
            default: firstRate = Decimal(string: "0.14")!
            }
            return Settings(brackets: [
                Bracket(over: 0, rate: 0),
                Bracket(over: 18_200, rate: firstRate),
                Bracket(over: 45_000, rate: Decimal(string: "0.30")!),
                Bracket(over: 135_000, rate: Decimal(string: "0.37")!),
                Bracket(over: 190_000, rate: Decimal(string: "0.45")!),
            ], levyRate: Decimal(string: "0.02")!, longTermDiscount: Decimal(string: "0.5")!)
        }

        /// The CPI quarter a date falls in, as the series is keyed: the
        /// calendar quarter, in UTC — a quarter's reading stands for every
        /// day in it, so a 10:59Z price date and a midday posting agree.
        public static func cpiQuarterKey(_ date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let components = calendar.dateComponents([.year, .month], from: date)
            return "\(components.year ?? 0)-Q\(((components.month ?? 1) - 1) / 3 + 1)"
        }

        /// The series as the CGT rules read it: a reading for a date, by its
        /// quarter, or `nil` where the table has none.
        public var cpiLookup: @Sendable (Date) -> Double? {
            let table = cpiQuarters
            return { table[Settings.cpiQuarterKey($0)] }
        }

        /// A fingerprint of the series for memo keys: two tables with the
        /// same readings share it, and one edited reading changes it.
        public var cpiRevision: Int {
            var hasher = Hasher()
            for (key, value) in cpiQuarters.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
            return hasher.finalize()
        }

        /// The latest quarter the table holds, for the settings screen.
        public var latestCPIQuarter: String? { cpiQuarters.keys.max() }
    }

    /// One source line feeding the estimate (an account and its FY total).
    public struct Line: Identifiable, Sendable {
        public let id: GncGUID
        public var name: String
        public var amount: Decimal

        public init(id: GncGUID, name: String, amount: Decimal) {
            self.id = id
            self.name = name
            self.amount = amount
        }
    }

    /// One bracket's contribution to the tax bill.
    public struct BracketTax: Identifiable, Sendable {
        public var id: Decimal { bracket.over }
        public let bracket: Bracket
        /// The slice of taxable income falling in this bracket.
        public let taxedAmount: Decimal
        public let tax: Decimal
    }

    public struct Result: Sendable {
        public let income: [Line]
        public let deductions: [Line]
        public let assessableIncome: Decimal
        public let totalDeductions: Decimal
        /// Gains before the discount: short, long, and unknown-holding.
        public let shortTermGains: Decimal
        public let longTermGains: Decimal
        public let otherGains: Decimal
        /// Long-term gains after the discount + the rest, floored at zero
        /// (losses aren't applied against other income here — carried forward
        /// in reality; documented on-screen).
        public let netCapitalGains: Decimal
        public let taxableIncome: Decimal
        public let bracketTaxes: [BracketTax]
        public let baseTax: Decimal
        public let levy: Decimal
        public let frankingCredits: Decimal
        public let withheld: Decimal
        /// The reform's top-up on gains accrued after 1 July 2027: what
        /// lifts the tax on them to the 30% minimum where the marginal rate
        /// is lower; zero before the reform, for income-support recipients,
        /// and when the marginal rate already reaches 30%.
        public let minimumTaxTopUp: Decimal
        /// Positive = estimated amount owing, negative = estimated refund.
        public let balance: Decimal
    }

    /// The reform's top-up for `gain` taxed at `marginalRate`: InvestaLens,
    /// `minimumTaxTopUp`: "(MINIMUM_TAX_RATE − marginalRateOnGain) ×
    /// minTaxCapitalGain", nothing for income-support recipients or where
    /// the rate already meets the minimum.
    public static func minimumTaxTopUp(gain: Decimal, marginalRate: Decimal,
                                       incomeSupportRecipient: Bool = false) -> Decimal {
        guard !incomeSupportRecipient, gain > 0, marginalRate < CapitalGainsTaxRules.minimumTaxRate else { return 0 }
        return roundCents((CapitalGainsTaxRules.minimumTaxRate - marginalRate) * gain)
    }

    /// The rate the last dollar of `taxable` bears under `settings`.
    public static func marginalRate(at taxable: Decimal, settings: Settings) -> Decimal {
        settings.brackets.sorted { $0.over < $1.over }.last { taxable > $0.over }?.rate ?? 0
    }

    public static func estimate(income: [Line], deductions: [Line],
                                shortTermGains: Decimal = 0,
                                longTermGains: Decimal = 0,
                                otherGains: Decimal = 0,
                                minimumTaxGain: Decimal = 0,
                                frankingCredits: Decimal = 0,
                                withheld: Decimal = 0,
                                settings: Settings) -> Result {
        let assessable = income.reduce(0) { $0 + $1.amount }
        let deductible = deductions.reduce(0) { $0 + $1.amount }

        // Net gains: the discount excludes a share of (positive) long-term
        // gains; a net capital loss doesn't reduce ordinary income.
        let discountedLong = longTermGains > 0
            ? longTermGains * (1 - settings.longTermDiscount) : longTermGains
        let netGains = max(0, discountedLong + shortTermGains + otherGains)

        let taxable = max(0, assessable + netGains - deductible)

        // Progressive brackets: each rate applies to the slice between its
        // threshold and the next.
        var bracketTaxes: [BracketTax] = []
        let brackets = settings.brackets.sorted { $0.over < $1.over }
        for (index, bracket) in brackets.enumerated() {
            guard taxable > bracket.over else { break }
            let upper = index + 1 < brackets.count ? brackets[index + 1].over : taxable
            let slice = min(taxable, upper) - bracket.over
            guard slice > 0 else { continue }
            let tax = roundCents(slice * bracket.rate)
            bracketTaxes.append(BracketTax(bracket: bracket, taxedAmount: slice, tax: tax))
        }
        let baseTax = bracketTaxes.reduce(0) { $0 + $1.tax }
        let levy = roundCents(taxable * settings.levyRate)
        // The post-2027 part of the net gain is taxed at no less than 30%.
        let topUp = minimumTaxTopUp(gain: min(max(minimumTaxGain, 0), netGains),
                                    marginalRate: marginalRate(at: taxable, settings: settings),
                                    incomeSupportRecipient: settings.incomeSupportRecipient)

        return Result(income: income, deductions: deductions,
                      assessableIncome: assessable, totalDeductions: deductible,
                      shortTermGains: shortTermGains, longTermGains: longTermGains,
                      otherGains: otherGains, netCapitalGains: netGains,
                      taxableIncome: taxable, bracketTaxes: bracketTaxes,
                      baseTax: baseTax, levy: levy,
                      frankingCredits: frankingCredits, withheld: withheld,
                      minimumTaxTopUp: topUp,
                      balance: baseTax + levy + topUp - frankingCredits - withheld)
    }

    private static func roundCents(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .bankers)
        return output
    }
}
