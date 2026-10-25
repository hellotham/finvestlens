//
//  AppModel+Prices.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensInterchange

/// A row in the price editor.
public struct PriceRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var currencyCode: String
    public var date: Date
    public var value: Decimal
}

@MainActor
extension AppModel {

    /// Commodities that are held in a security account (candidates to price).
    public var securityCommodities: [Commodity] {
        guard let book else { return [] }
        // Memoised per revision: every portfolio memo hit paid this walk first
        // (0.33 ms, several times per dashboard pass; Performance Review 2, R9).
        if let cached = securityCommoditiesCache, cached.revision == bookRevision { return cached.value }
        var seen = Set<String>()
        var result: [Commodity] = []
        for account in book.accounts where account.type.isSecurityType {
            let key = "\(account.commodity.namespace)|\(account.commodity.mnemonic)"
            if seen.insert(key).inserted { result.append(account.commodity) }
        }
        securityCommoditiesCache = (bookRevision, result)
        return result
    }

    /// Adds a price to the database (`FR-INV-02`).
    ///
    /// A bond typed by hand takes the same par scaling a fetched one does. The
    /// market quotes 98.345 whether the number arrives from FIIG or from the
    /// keyboard, and only fetched rows were being put onto the security's own
    /// unit — so a book priced by both routes held both readings of the same
    /// figure, a hundredfold apart, and a chart drew a cliff between them.
    /// ``parPercentScaled(_:for:)`` picks whichever reading sits beside what
    /// the security has actually cost, so someone who types the already-scaled
    /// value is left alone.
    public func addPrice(commodity: Commodity, currency: Commodity, date: Date, value: Decimal) {
        guard let book else { return }
        let scaled = isParQuoted(commodity) ? parPercentScaled(value, for: commodity) : value
        editingPrices(named: "Add Price") {
            book.addPrice(Price(commodity: commodity, currency: currency, date: date, value: scaled))
        }
    }

    public func deletePrice(_ id: GncGUID) {
        guard let book else { return }
        editingPrices(named: "Delete Price") {
            book.removePrice(id)
        }
    }

    /// The outcome of a CSV price import (`FR-XIO-03`).
    public struct PriceImportOutcome: Sendable {
        public var imported = 0
        /// Symbols in the file that matched no known commodity (skipped).
        public var unmatchedSymbols: [String] = []
        /// Currency codes the file named that the book does not know (skipped).
        ///
        /// These used to be silently replaced by the book's base currency, so a
        /// file of USD closes imported into an AUD book became AUD closes — the
        /// same mislabel that `QuoteService` now refuses on the fetch path, and
        /// the one that wrote 1,205 wrong rows. A currency nobody can resolve
        /// is a reason to skip the row and say so.
        public var unknownCurrencies: [String] = []
        /// True when the file's header couldn't be recognised.
        public var unrecognisedFormat = false
    }

    /// Imports commodity prices from a CSV file (`FR-XIO-03`), auto-detecting
    /// the columns from the header. A symbol is resolved against the book's
    /// commodities by mnemonic; the currency column (if any) is resolved by
    /// mnemonic, otherwise the base currency is assumed. Unknown symbols are
    /// reported, not invented.
    @discardableResult
    public func importPrices(csv text: String) -> PriceImportOutcome {
        var outcome = PriceImportOutcome()
        guard let book else { return outcome }
        guard let staged = CSVPriceImporter.parseAutodetect(text) else {
            outcome.unrecognisedFormat = true
            return outcome
        }

        // Resolve commodities/currencies by mnemonic (case-insensitive).
        var byMnemonic: [String: Commodity] = [:]
        for c in book.commodities { byMnemonic[c.mnemonic.uppercased()] = c }
        let base = reportCurrency

        var toAdd: [Price] = []
        var unmatched = Set<String>()
        var unknownCurrency = Set<String>()
        for row in staged {
            guard let commodity = byMnemonic[row.commoditySymbol.uppercased()] else {
                unmatched.insert(row.commoditySymbol); continue
            }
            // A named currency must resolve. Falling back to the base currency
            // would relabel the number rather than reject it.
            let currency: Commodity
            if row.currencyCode.isEmpty {
                currency = base
            } else if let named = byMnemonic[row.currencyCode.uppercased()] {
                currency = named
            } else {
                unknownCurrency.insert(row.currencyCode); continue
            }
            guard row.value > 0 else { continue }
            toAdd.append(Price(commodity: commodity, currency: currency, date: row.date,
                               value: row.value, source: "user:price"))
        }

        var added = 0
        if !toAdd.isEmpty {
            editingPrices(named: "Import Prices") {
                added = book.addPrices(deduplicating: toAdd).count
            }
        }
        outcome.imported = added
        outcome.unmatchedSymbols = unmatched.sorted()
        outcome.unknownCurrencies = unknownCurrency.sorted()
        return outcome
    }

    /// The portfolio valuation over security accounts (`FR-RPT-02`).
    public func portfolio(asOf: Date = Date()) -> Portfolio? {
        guard let book, !securityCommodities.isEmpty else { return nil }
        return cachedReport("pf:\(asOf.timeIntervalSinceReferenceDate)") {
            FinancialReports.portfolio(book, currency: reportCurrency, asOf: asOf)
        }
    }

    /// The market unit price of the security in `accountID`, in the report
    /// currency, nearest in time to `date` — the price series that drives a
    /// holding's return regardless of how many shares were held then.
    public func securityUnitPrice(accountID: GncGUID, on date: Date) -> Decimal? {
        guard let book, let account = book.account(with: accountID) else { return nil }
        return book.securityUnitValue(account.commodity, in: reportCurrency, on: date)
    }

    /// Realised capital gains and open lots under the selected cost-basis
    /// method (`FR-RPT-03`) — every security's, or one portfolio's, with or
    /// without the positions sold out of entirely.
    public func capitalGains(from: Date = .distantPast, to: Date = .distantFuture,
                             includeClosed: Bool = false, portfolioID: GncGUID? = nil) -> CapitalGainsReport? {
        guard !securityCommodities.isEmpty else { return nil }
        return report(capitalGainsRequest(from: from, to: to, includeClosed: includeClosed,
                                          portfolioID: portfolioID))
    }

    func capitalGainsRequest(from: Date, to: Date, includeClosed: Bool = false,
                             portfolioID: GncGUID? = nil) -> ReportRequest<CapitalGainsReport> {
        let currency = reportCurrency, method = costBasisMethod, fees = feeTreatment
        let tax = currentTaxSettings()
        let entity = tax.cgtEntity
        let foreign = tax.foreignResident
        let cpi = tax.cpiLookup
        let calendar = Calendar.current
        return ReportRequest(key: "cg:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate):\(method.rawValue):\(fees.rawValue):\(includeClosed):\(Self.portfolioKey(portfolioID)):\(entity.rawValue):\(foreign):\(tax.cpiRevision)") { book in
            FinancialReports.capitalGains(book, currency: currency, from: from, to: to,
                                          method: method, feeTreatment: fees,
                                          includeClosed: includeClosed, portfolioID: portfolioID,
                                          entity: entity, foreignResident: foreign, cpi: cpi, calendar: calendar)
        }
    }

    /// The year's income by payment and holding (`FR-RPT-02b`, the Income report).
    public func incomeReport(from: Date, to: Date, portfolioID: GncGUID? = nil) -> IncomeReport? {
        guard !securityCommodities.isEmpty else { return nil }
        return report(incomeReportRequest(from: from, to: to, portfolioID: portfolioID))
    }

    func incomeReportRequest(from: Date, to: Date, portfolioID: GncGUID? = nil) -> ReportRequest<IncomeReport> {
        let currency = reportCurrency
        return ReportRequest(key: "income:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate):\(Self.portfolioKey(portfolioID))") { book in
            FinancialReports.incomeReport(book, currency: currency, from: from, to: to, portfolioID: portfolioID)
        }
    }

    /// Opening and closing balances at cost over a period.
    public func historicalCost(from: Date, to: Date, portfolioID: GncGUID? = nil) -> HistoricalCostReport? {
        guard !securityCommodities.isEmpty else { return nil }
        return report(historicalCostRequest(from: from, to: to, portfolioID: portfolioID))
    }

    func historicalCostRequest(from: Date, to: Date, portfolioID: GncGUID? = nil) -> ReportRequest<HistoricalCostReport> {
        let currency = reportCurrency, method = costBasisMethod, fees = feeTreatment
        let cap = min(to, Self.endOfToday())
        return ReportRequest(key: "hcost:\(from.timeIntervalSinceReferenceDate):\(cap.timeIntervalSinceReferenceDate):\(method.rawValue):\(fees.rawValue):\(Self.portfolioKey(portfolioID))") { book in
            FinancialReports.historicalCost(book, currency: currency, from: from, to: cap,
                                            method: method, feeTreatment: fees, portfolioID: portfolioID)
        }
    }

    /// Returns in each of `periods`, side by side.
    public func multiPeriodReturns(periods: [(from: Date, to: Date)], includeClosed: Bool = true,
                                   portfolioID: GncGUID? = nil) -> MultiPeriodReturnReport? {
        guard !securityCommodities.isEmpty, !periods.isEmpty else { return nil }
        return report(multiPeriodRequest(periods: periods, includeClosed: includeClosed, portfolioID: portfolioID))
    }

    func multiPeriodRequest(periods: [(from: Date, to: Date)], includeClosed: Bool,
                            portfolioID: GncGUID? = nil) -> ReportRequest<MultiPeriodReturnReport> {
        let currency = reportCurrency, method = costBasisMethod, fees = feeTreatment
        let capped = periods.map { (from: $0.from, to: min($0.to, Self.endOfToday())) }
        let key = capped.map { "\($0.from.timeIntervalSinceReferenceDate)-\($0.to.timeIntervalSinceReferenceDate)" }
            .joined(separator: ",")
        return ReportRequest(key: "mperiod:\(key):\(method.rawValue):\(fees.rawValue):\(includeClosed):\(Self.portfolioKey(portfolioID))") { book in
            FinancialReports.multiPeriodReturns(book, currency: currency, periods: capped, method: method,
                                                feeTreatment: fees, includeClosed: includeClosed,
                                                portfolioID: portfolioID)
        }
    }

    /// Each held security's worst fall against its return over a period.
    public func drawdownRisk(from: Date, to: Date, portfolioID: GncGUID? = nil) -> DrawdownReport? {
        guard !securityCommodities.isEmpty else { return nil }
        return report(drawdownRequest(from: from, to: to, portfolioID: portfolioID))
    }

    func drawdownRequest(from: Date, to: Date, portfolioID: GncGUID? = nil) -> ReportRequest<DrawdownReport> {
        let currency = reportCurrency
        let cap = min(to, Self.endOfToday())
        return ReportRequest(key: "ddown:\(from.timeIntervalSinceReferenceDate):\(cap.timeIntervalSinceReferenceDate):\(Self.portfolioKey(portfolioID))") { book in
            FinancialReports.drawdownRisk(book, currency: currency, from: from, to: cap, portfolioID: portfolioID)
        }
    }

    /// What the open parcels would be assessed at if sold on the date —
    /// the Lots report's unrealised-CGT estimate, under the book's tax
    /// settings.
    func unrealisedCapitalGains(_ lots: [LotDetail], asOf: Date) -> UnrealisedCapitalGains? {
        guard let book else { return nil }
        let tax = currentTaxSettings()
        let currency = reportCurrency
        let reformEve = FinancialReports.instantBefore(CapitalGainsTaxRules.reformDate)
        return FinancialReports.unrealisedCapitalGains(
            lots, asOf: asOf, entity: tax.cgtEntity, foreignResident: tax.foreignResident,
            valueBefore2027: { lot in
                guard let acquired = lot.acquisitionDate, acquired < CapitalGainsTaxRules.reformDate,
                      asOf >= CapitalGainsTaxRules.reformDate,
                      let account = book.account(with: lot.accountID),
                      let unit = book.securityUnitValue(account.commodity, in: currency, on: reformEve)
                else { return nil }
                return currency.round(lot.quantity * unit)
            },
            cpi: tax.cpiLookup)
    }

    /// A portfolio filter's part of a memo key: the account, or every one.
    static func portfolioKey(_ portfolioID: GncGUID?) -> String {
        portfolioID?.hexString ?? "all"
    }

    /// How many clock conventions the stored prices actually use, and how many
    /// rows are not yet on the canonical one. Public because `finlab` reports
    /// it before touching anything, and the book itself is not its to read.
    public func priceTimeConventions() -> (total: Int, conventions: [String], stale: Int) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var seen: Set<String> = []
        var stale = 0
        let prices = book?.prices ?? []
        for price in prices {
            let parts = utc.dateComponents([.hour, .minute], from: price.date)
            seen.insert(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
            if !price.isDayNeutral { stale += 1 }
        }
        return (prices.count, seen.sorted(), stale)
    }

    /// Restamps every stored price to the book's one convention — 10:59:00Z of
    /// the day it already belongs to (`Price.dayNeutral`).
    ///
    /// Only the time within a day moves; the day itself never does, so no price
    /// changes which session it describes. Idempotent, and undoable as a single
    /// edit like any other.
    public func normalisePriceTimes(onChange: () -> Void = {}) {
        guard let book else { return }
        let stale = book.prices.filter { !$0.isDayNeutral }
        guard !stale.isEmpty else { return }
        // One removal pass for all of them, not one per price: `removePrices`
        // scans the whole database, so calling it per row turns a migration of
        // sixty thousand prices into sixty thousand scans of a hundred and
        // sixty thousand. The same shape as the Engine's `splits(for:)`, and it
        // ran for ten minutes before being killed.
        let staleGuids = Set(stale.map(\.guid))
        editingPrices(named: "Normalise Price Times") {
            book.removePrices { staleGuids.contains($0.guid) }
            for price in stale {
                var restamped = price
                restamped.date = Price.dayNeutral(price.date)
                book.addPrice(restamped)
                onChange()
            }
        }
    }

    /// The advanced portfolio (cost basis, avg cost, unrealized/realized gain,
    /// allocation) under the selected cost-basis method (`FR-RPT-02a`).
    ///
    /// Every position by default, sold out of or not — the hub, a security's
    /// page and the review decks read the whole history; the Portfolio
    /// report asks for what is held unless its Closed positions switch is on.
    public func advancedPortfolio(asOf: Date = Date(), includeClosed: Bool = true,
                                  portfolioID: GncGUID? = nil) -> AdvancedPortfolio? {
        guard !securityCommodities.isEmpty else { return nil }
        return report(advancedPortfolioRequest(asOf: asOf, includeClosed: includeClosed,
                                               portfolioID: portfolioID))
    }

    func advancedPortfolioRequest(asOf: Date, includeClosed: Bool = true,
                                  portfolioID: GncGUID? = nil) -> ReportRequest<AdvancedPortfolio> {
        // "As of now" quantises to end-of-day: a live Date() key would defeat
        // the memo (one entry per call), and holdings don't move mid-day here.
        let cap = min(asOf, Self.endOfToday())
        let currency = reportCurrency, method = costBasisMethod, fees = feeTreatment
        return ReportRequest(key: "apf:\(cap.timeIntervalSinceReferenceDate):\(method.rawValue):\(fees.rawValue):\(includeClosed):\(Self.portfolioKey(portfolioID))") { book in
            FinancialReports.advancedPortfolio(book, currency: currency, asOf: cap,
                                               method: method, feeTreatment: fees,
                                               includeClosed: includeClosed, portfolioID: portfolioID)
        }
    }

    /// Every security's capital gain, dividends and franking credits over a
    /// period, against the money put in (`FR-RPT-02b`) — every portfolio's or
    /// one's, with or without the positions sold out of.
    public func investmentReturn(from: Date = .distantPast, to: Date = Date(), includeClosed: Bool = true,
                                 portfolioID: GncGUID? = nil) -> InvestmentReturnReport? {
        guard !securityCommodities.isEmpty else { return nil }
        return report(investmentReturnRequest(from: from, to: to, includeClosed: includeClosed,
                                              portfolioID: portfolioID))
    }

    /// One security's price history over a range, with the holding's own
    /// trades and income — the holding under `portfolioID`, when one is
    /// chosen — and a benchmark to read it against.
    public func priceHistory(commodity: Commodity, from: Date, to: Date,
                             benchmark: PriceBenchmark? = nil, portfolioID: GncGUID? = nil) -> PriceHistoryReport? {
        guard let book else { return nil }
        let cap = min(to, Self.endOfToday())
        let currency = reportCurrency, method = costBasisMethod, fees = feeTreatment
        let benchmarkKey: String = switch benchmark {
        case .cashRate(let rate)?: "cash:\(rate)"
        case .commodity(let other)?: "\(other.namespace)|\(other.mnemonic)"
        case nil: "none"
        }
        let key = "phist:\(commodity.namespace)|\(commodity.mnemonic):\(from.timeIntervalSinceReferenceDate):\(cap.timeIntervalSinceReferenceDate):\(benchmarkKey):\(method.rawValue):\(fees.rawValue):\(Self.portfolioKey(portfolioID))"
        return cachedReport(key) {
            let account = FinancialReports.securityAccounts(book, inPortfolio: portfolioID).first { $0.commodity == commodity }
            return FinancialReports.priceHistory(book, commodity: commodity, account: account, currency: currency,
                                                 from: from, to: cap, benchmark: benchmark,
                                                 method: method, feeTreatment: fees)
        }
    }

    func investmentReturnRequest(from: Date, to: Date, includeClosed: Bool,
                                 portfolioID: GncGUID? = nil) -> ReportRequest<InvestmentReturnReport> {
        let cap = min(to, Self.endOfToday())
        let currency = reportCurrency, method = costBasisMethod, fees = feeTreatment
        return ReportRequest(key: "iret:\(from.timeIntervalSinceReferenceDate):\(cap.timeIntervalSinceReferenceDate):\(method.rawValue):\(fees.rawValue):\(includeClosed):\(Self.portfolioKey(portfolioID))") { book in
            FinancialReports.investmentReturn(book, currency: currency, from: from, to: cap,
                                              method: method, feeTreatment: fees,
                                              includeClosed: includeClosed, portfolioID: portfolioID)
        }
    }

    /// Every open tax lot valued at the latest price, under the selected
    /// cost-basis method (`FR-RPT-02`, Investment Lots) — and, with
    /// `includeClosed`, every parcel already sold.
    public func investmentLots(asOf: Date = Date(), includeClosed: Bool = false,
                               portfolioID: GncGUID? = nil) -> [LotDetail] {
        guard !securityCommodities.isEmpty else { return [] }
        return report(investmentLotsRequest(asOf: asOf, includeClosed: includeClosed,
                                            portfolioID: portfolioID)) ?? []
    }

    func investmentLotsRequest(asOf: Date, includeClosed: Bool = false,
                               portfolioID: GncGUID? = nil) -> ReportRequest<[LotDetail]> {
        let cap = min(asOf, Self.endOfToday())
        let currency = reportCurrency, method = costBasisMethod, fees = feeTreatment
        return ReportRequest(key: "lots:\(cap.timeIntervalSinceReferenceDate):\(method.rawValue):\(fees.rawValue):\(includeClosed):\(Self.portfolioKey(portfolioID))") { book in
            FinancialReports.investmentLots(book, currency: currency, asOf: cap,
                                            method: method, feeTreatment: fees,
                                            includeClosed: includeClosed, portfolioID: portfolioID)
        }
    }

    /// End of the current day — the stable stand-in for "now" in report memo
    /// keys (a raw `Date()` would make every call a cache miss).
    static func endOfToday() -> Date {
        // Calendar arithmetic, not +86 400: a DST transition day is 23 or 25
        // hours long, and the fixed offset put the cap at 23:00 the same day
        // (dropping late-evening postings) or 01:00 tomorrow (leaking the
        // next day in) — mis-bounding every "as of now" report twice a year.
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
    }

    /// The priced securities Price History can show: every one, or those
    /// held in the security accounts under `portfolioID`.
    func pricedSecurities(inPortfolio portfolioID: GncGUID?) -> [Commodity] {
        let priced = securitiesWithPriceHistory
        guard let portfolioID, let book else { return priced }
        let held = Set(FinancialReports.securityAccounts(book, inPortfolio: portfolioID).map(\.commodity))
        return priced.filter { held.contains($0) }
    }

    /// Securities that have at least one recorded price (candidates for the
    /// price-history chart).
    public var securitiesWithPriceHistory: [Commodity] {
        guard let book else { return [] }
        var seen = Set<String>()
        var result: [Commodity] = []
        for price in book.prices where price.commodity.namespace != .currency {
            if seen.insert(price.commodity.mnemonic).inserted { result.append(price.commodity) }
        }
        return result.sorted { $0.mnemonic < $1.mnemonic }
    }

    /// The recorded price series for `commodity`, oldest first.
    public func priceHistory(for commodity: Commodity) -> [PricePoint] {
        guard let book else { return [] }
        return book.prices
            .filter { $0.commodity == commodity }
            .sorted { $0.date < $1.date }
            .map { PricePoint(date: $0.date, value: $0.value, currencyCode: $0.currency.mnemonic) }
    }
}

/// One point in a security's price-history chart.
public struct PricePoint: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var value: Decimal
    public var currencyCode: String
}
