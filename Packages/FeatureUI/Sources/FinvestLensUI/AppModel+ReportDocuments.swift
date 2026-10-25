//
//  AppModel+ReportDocuments.swift
//  FinvestLens — FeatureUI
//
//  Printable ``ReportDocument`` builders for the interactive reports
//  (`FR-RPT-05`). Each keeps its live view; these give the same figures a
//  static, paginated form so the report scaffold's PDF export covers them too.
//  One builder per report, from the report type the view already computes.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    private func shortDate(_ date: Date) -> String {
        AppDateFormat.current.long(date)
    }


    /// A period label "1 Jan 2026 – 31 Mar 2026".
    private func range(_ from: Date, _ to: Date) -> String {
        "\(shortDate(from)) – \(shortDate(to))"
    }

    // MARK: Spending Insights (FR-PLAN-13)

    func spendingInsightsDocument(period: ReportPeriod) -> ReportDocument? {
        guard let insights = spendingInsights(period: period) else { return nil }
        let code = insights.currencyCode
        func money(_ value: Decimal) -> String { AmountFormat.string(value, code: code) }

        func comparison(_ title: String, rows: [CategoryComparison],
                        totalCurrent: Decimal, totalPrior: Decimal) -> ReportDocumentSection? {
            guard !rows.isEmpty else { return nil }
            return ReportDocumentSection(
                title: title,
                rows: rows.map { row in
                    // A whole phrase each: "(new)" hung on a name is English order.
                    let label = row.isNew ? String(localized: "\(row.name) (new)")
                        : row.isGone ? String(localized: "\(row.name) (gone)") : row.name
                    return ReportDocumentRow(label: label, amounts: [row.current, row.prior, row.delta])
                },
                columns: [String(localized: "This period"), String(localized: "Prior"), String(localized: "Change")],
                columnTotals: (String(localized: "Total"), [totalCurrent, totalPrior, totalCurrent - totalPrior]))
        }

        return ReportDocument(
            title: String(localized: "Spending Insights"),
            periodLabel: String(localized: "\(label(for: period)) · vs \(range(insights.priorFrom, insights.priorTo))"),
            currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Spending"), amount: insights.totalSpendingCurrent),
                   ReportKPI(label: String(localized: "Income"), amount: insights.totalIncomeCurrent),
                   ReportKPI(label: String(localized: "Net saved"),
                             amount: insights.totalIncomeCurrent - insights.totalSpendingCurrent,
                             signed: true)],
            summary: insights.summary(format: money),
            chart: nil,
            sections: [
                comparison(String(localized: "Spending by category"), rows: insights.expenses,
                           totalCurrent: insights.totalSpendingCurrent,
                           totalPrior: insights.totalSpendingPrior),
                comparison(String(localized: "Income"), rows: insights.income,
                           totalCurrent: insights.totalIncomeCurrent,
                           totalPrior: insights.totalIncomePrior),
            ].compactMap { $0 },
            notes: [String(localized: "Compared against the immediately-preceding period of the same length. Categories are top-level, subtrees rolled up — the same figures as the income & expense breakdown.")],
            facts: ReportFactsSource(
                headline: [(String(localized: "Spending"), insights.totalSpendingCurrent),
                           (String(localized: "Prior spending"), insights.totalSpendingPrior),
                           (String(localized: "Income"), insights.totalIncomeCurrent)],
                lines: insights.expenses.prefix(12).map { ($0.name, $0.delta) }))
    }

    // MARK: Transactions (FR-RPT-01)

    /// Every account in scope, each its own table of postings with a running
    /// balance and its period's change — GnuCash's default layout for this
    /// report: by account, subtotalled, then in register order. One account
    /// keeps the opening, change and closing it always had as its headline.
    func transactionsDocument(accountIDs: Set<GncGUID>?, from: Date, to: Date) -> ReportDocument? {
        guard let report = transactionReport(accountIDs: accountIDs, from: from, to: to) else { return nil }
        // The headline is one account's — the account chosen, with nothing
        // beneath it — even over a period with nothing in it. A chosen parent
        // gets none: its one active subaccount's figures are not the parent's.
        let chosen = accountIDs?.count == 1 ? accountIDs?.first : nil
        let single = report.groups.count == 1 && report.groups.first?.id == chosen ? report.groups.first : nil
        let title: String
        if let chosen, let name = accountName(chosen) {
            title = String(localized: "Transactions — \(name)")
        } else if accountIDs == nil {
            title = String(localized: "Transactions — All Accounts")
        } else {
            title = String(localized: "Transactions")
        }
        let kpis: [ReportKPI]
        if let single {
            kpis = [ReportKPI(label: String(localized: "Opening"), amount: single.opening),
                    ReportKPI(label: String(localized: "Net change"), amount: single.total, signed: true),
                    ReportKPI(label: String(localized: "Closing"), amount: single.closing)]
        } else {
            kpis = []
        }
        // A date is formatted once, not once a posting: a year of the whole
        // book is tens of thousands of rows and a few hundred days.
        var days: [Date: String] = [:]
        func dayText(_ date: Date) -> String {
            if let known = days[date] { return known }
            let text = shortDate(date)
            days[date] = text
            return text
        }
        let sections = report.groups.map { group in
            ReportDocumentSection(
                title: group.accountName,
                rows: group.rows.map { row in
                    ReportDocumentRow(label: "\(dayText(row.date))  \(row.description)",
                                      amounts: [row.amount, row.balance])
                },
                columns: [String(localized: "Amount"), String(localized: "Balance")],
                columnTotals: (String(localized: "Net change and closing balance"), [group.total, group.closing]),
                currencyCode: group.currencyCode,
                identity: group.id.hexString)
        }
        var notes = [String(localized: "Postings: \(report.postingCount) · Accounts: \(report.groups.count)"),
                     String(localized: "Each account shows its postings in date order with a running balance, in the account’s own currency — a security’s in its units.")]
        if accountIDs != nil {
            notes.append(String(localized: "Each chosen account includes all of its subaccounts."))
        }
        return ReportDocument(
            title: title,
            periodLabel: range(from, to), currencyCode: single?.currencyCode ?? reportCurrency.mnemonic,
            kpis: kpis, chart: nil, sections: sections, notes: notes, facts: nil)
    }

    // MARK: Reconciliation (FR-RPT-04)

    func reconcileDocument(accountID: GncGUID, asOf: Date) -> ReportDocument? {
        guard let report = reconcileReport(accountID: accountID, asOf: asOf) else { return nil }
        func rows(_ list: [ReconcileReportRow]) -> [ReportDocumentRow] {
            list.map { ReportDocumentRow(label: "\(shortDate($0.date))  \($0.description)", amount: $0.amount) }
        }
        return ReportDocument(
            title: String(localized: "Reconciliation — \(accountName(accountID) ?? String(localized: "Account"))"),
            periodLabel: String(localized: "As of \(shortDate(asOf))"), currencyCode: report.currencyCode,
            kpis: [ReportKPI(label: String(localized: "Reconciled"), amount: report.reconciledBalance),
                   ReportKPI(label: String(localized: "Cleared"), amount: report.clearedBalance),
                   ReportKPI(label: String(localized: "Ending"), amount: report.endingBalance)],
            chart: nil,
            sections: [
                ReportDocumentSection(title: String(localized: "Funds In"), rows: rows(report.fundsIn),
                                      total: (String(localized: "Total in"), report.totalIn)),
                ReportDocumentSection(title: String(localized: "Funds Out"), rows: rows(report.fundsOut),
                                      total: (String(localized: "Total out"), report.totalOut)),
                ReportDocumentSection(title: String(localized: "Cleared — not yet reconciled"), rows: rows(report.cleared),
                                      total: (String(localized: "Cleared total"), report.clearedTotal)),
                ReportDocumentSection(title: String(localized: "Outstanding — not on a statement"), rows: rows(report.outstanding),
                                      total: (String(localized: "Outstanding total"), report.outstandingTotal)),
            ],
            notes: report.isConsistent ? [] : [String(localized: "The sections above do not sum to the ending balance — the account may hold edits newer than its last reconciliation.")],
            facts: nil)
    }

    // MARK: Investment reports (FR-RPT-02, FR-RPT-02b, FR-RPT-03)
    //
    // Four reports, one shape. Asked for on build 8: "by portfolio, then
    // security … filtering by portfolio, open/close toggle, and sorted by
    // decreasing gain … an equivalent yield per annum based on original
    // purchase price … all the investment reports should be filterable by
    // portfolio, financial year, open/close toggle etc. They need to be
    // consistent." Each is a section per portfolio with its securities in
    // order of gain, largest first, and the portfolio's total under them; more
    // than one portfolio closes with a table of the portfolios themselves.
    // Every table ends in the same Yield p.a. column (`InvestmentYield`), and
    // the notes say which way each switch is set.

    /// One security as an investment report lays it out: its row, the parcels
    /// under it, and what its portfolio's total is summed from.
    private struct InvestmentRow {
        var portfolio: PortfolioRef?
        /// The gain the rows are ordered by.
        var gain: Decimal
        var label: String
        /// The money columns; `nil` prints blank (an unpriced holding).
        var amounts: [Decimal?]
        var yield: Double?
        /// The yield's ingredients, for the totals' own yield.
        var yieldItem: (gain: Decimal, cost: Decimal, years: Double?)
        /// Parcels under the security, each already carrying its yield column.
        var detail: [ReportDocumentRow] = []
    }

    /// The sections of an investment report over `rows`: one per portfolio,
    /// its securities in order of gain, largest first, and its total under
    /// them; then, with more than one portfolio, the portfolios themselves in
    /// the same order. `columns` are the money columns; the yield is added.
    private func investmentSections(_ rows: [InvestmentRow], columns: [String]) -> [ReportDocumentSection] {
        let allColumns = columns + [String(localized: "Yield p.a.")]
        let formats = columns.map { _ in ReportColumnFormat.amount } + [.percent]
        func total(_ members: [InvestmentRow]) -> (amounts: [Decimal?], gain: Decimal, yield: Double?) {
            var sums = Array(repeating: Decimal(0), count: columns.count)
            for member in members {
                for (column, amount) in member.amounts.enumerated() where column < sums.count {
                    sums[column] += amount ?? 0
                }
            }
            return (sums.map { Optional($0) }, members.reduce(0) { $0 + $1.gain },
                    InvestmentYield.combined(members.map(\.yieldItem)))
        }
        func yieldColumn(_ yield: Double?) -> Decimal? { yield.map { Decimal($0) } }

        var byPortfolio: [GncGUID?: [InvestmentRow]] = [:]
        for row in rows { byPortfolio[row.portfolio?.id, default: []].append(row) }
        let portfolios = byPortfolio.map { id, members in
            (id: id, name: members.first?.portfolio?.name, members: members, total: total(members))
        }.sorted { lhs, rhs in
            // By gain, largest first; securities with no portfolio last.
            if (lhs.id == nil) != (rhs.id == nil) { return rhs.id == nil }
            if lhs.total.gain != rhs.total.gain { return lhs.total.gain > rhs.total.gain }
            return (lhs.name ?? "") < (rhs.name ?? "")
        }

        var sections = portfolios.map { portfolio -> ReportDocumentSection in
            let ordered = portfolio.members.sorted { $0.gain > $1.gain }
            return ReportDocumentSection(
                title: portfolio.name ?? String(localized: "No portfolio"),
                rows: ordered.flatMap { member in
                    [ReportDocumentRow(label: member.label,
                                       amounts: member.amounts + [yieldColumn(member.yield)])]
                        + member.detail
                },
                columns: allColumns,
                columnTotals: (String(localized: "Total"),
                               portfolio.total.amounts + [yieldColumn(portfolio.total.yield)]),
                columnFormats: formats,
                identity: "portfolio:\(portfolio.id?.hexString ?? "none")")
        }
        if portfolios.count > 1 {
            let grand = total(rows)
            sections.append(ReportDocumentSection(
                title: String(localized: "All portfolios"),
                rows: portfolios.map {
                    ReportDocumentRow(label: $0.name ?? String(localized: "No portfolio"),
                                      amounts: $0.total.amounts + [yieldColumn($0.total.yield)])
                },
                columns: allColumns,
                columnTotals: (String(localized: "Total"), grand.amounts + [yieldColumn(grand.yield)]),
                columnFormats: formats))
        }
        return sections
    }

    /// "CBA  120 sh", or "CBA  closed" for a position sold out of.
    private func securityLabel(_ symbol: String, units: Decimal) -> String {
        units == 0
            ? String(localized: "\(symbol)  closed")
            : String(localized: "\(symbol)  \(units.formatted()) sh")
    }

    /// Which way the report's Closed positions switch is set, on its face.
    private func closedPositionsNote(included: Bool) -> String {
        included
            ? String(localized: "Positions sold out of are included.")
            : String(localized: "Positions sold out of are left out; turn on Closed positions to include them.")
    }

    /// Which portfolio the report covers, on its face.
    private func portfolioNote(_ portfolioID: GncGUID?) -> String {
        if let portfolioID, let name = accountName(portfolioID) {
            return String(localized: "Portfolio: \(name). Choose All portfolios to report on every one.")
        }
        return String(localized: "Every portfolio; choose one above to narrow the report.")
    }

    /// What the Yield p.a. column is and how the rows are ordered — the same
    /// words on all four reports.
    private var investmentYieldNote: String {
        String(localized: "Yield p.a. is the gain as a simple annual rate on what the parcels cost — gain ÷ cost ÷ years held, the years weighted by cost — so holdings of different ages read alike. Securities and portfolios are in order of gain, largest first.")
    }

    private func methodNote(_ method: CostBasisMethod) -> String {
        String(localized: "\(method.displayName) cost basis")
    }

    // MARK: Portfolio (FR-RPT-02)

    /// What is held, valued, with its lifetime gain in GnuCash's advanced-
    /// portfolio columns — cost, value, unrealised, realised, income — by
    /// portfolio and security.
    func portfolioDocument(asOf: Date = Date(), includeClosed: Bool = false,
                           portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let portfolio = advancedPortfolio(asOf: asOf, includeClosed: includeClosed,
                                                portfolioID: portfolioID) else { return nil }
        let code = portfolio.currencyCode
        let rows = portfolio.holdings.map { holding in
            InvestmentRow(portfolio: holding.portfolio, gain: holding.totalGain,
                          label: securityLabel(holding.symbol, units: holding.shares),
                          amounts: [holding.costBasis, holding.marketValue, holding.unrealizedGain,
                                    holding.realizedGain, holding.income],
                          yield: holding.yieldPerAnnum,
                          yieldItem: (holding.totalGain, holding.moneyIn, holding.heldYears))
        }
        var kpis = [ReportKPI(label: String(localized: "Cost basis"), amount: portfolio.totalCost),
                    ReportKPI(label: String(localized: "Market value"), amount: portfolio.totalValue),
                    ReportKPI(label: String(localized: "Unrealised"), amount: portfolio.totalUnrealized, signed: true)]
        if portfolio.totalRealized != 0 {
            kpis.append(ReportKPI(label: String(localized: "Realised"), amount: portfolio.totalRealized, signed: true))
        }
        if portfolio.totalIncome != 0 {
            kpis.append(ReportKPI(label: String(localized: "Income"), amount: portfolio.totalIncome))
        }
        // The allocation donut: the largest holdings by value, the tail rolled
        // into "Other" so the legend stays legible.
        let valued = portfolio.holdings
            .compactMap { h in (h.marketValue ?? 0) > 0 ? (h.symbol, h.marketValue!) : nil }
            .sorted { $0.1 > $1.1 }
        var slices = valued.prefix(9).map { (label: $0.0, value: $0.1) }
        let tail = valued.dropFirst(9).reduce(Decimal(0)) { $0 + $1.1 }
        if tail > 0 { slices.append((label: String(localized: "Other"), value: tail)) }

        return ReportDocument(
            title: String(localized: "Portfolio"), periodLabel: String(localized: "As of \(shortDate(asOf))"), currencyCode: code,
            kpis: kpis, chart: slices.count > 1 ? .allocation(slices) : nil,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: [
                String(localized: "Cost"), String(localized: "Value"), String(localized: "Unrealised"),
                String(localized: "Realised"), String(localized: "Income")]),
            notes: [String(localized: "Securities valued at their most recent price; unpriced holdings show zero value. Realised gain and income are since the first purchase."),
                    methodNote(portfolio.method),
                    closedPositionsNote(included: includeClosed),
                    portfolioNote(portfolioID),
                    investmentYieldNote],
            facts: nil)
    }

    // MARK: Investment return (FR-RPT-02b)

    /// Capital gain, dividends and franking credits over the period, by
    /// portfolio and security, and together against the money put in. Asked
    /// for on build 7: "No report to show total investment return (capital
    /// gain plus dividends plus franking credits)."
    func investmentReturnDocument(from: Date, to: Date, periodLabel: String, includeClosed: Bool = true,
                                  portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = investmentReturn(from: from, to: to, includeClosed: includeClosed,
                                            portfolioID: portfolioID) else { return nil }
        let code = report.currencyCode
        let rows = report.lines.map { line in
            InvestmentRow(portfolio: line.portfolio, gain: line.totalReturn,
                          label: securityLabel(line.symbol, units: line.units),
                          amounts: [line.capitalGain, line.dividends, line.frankingCredits, line.totalReturn],
                          yield: line.yieldPerAnnum,
                          yieldItem: (line.totalReturn, line.moneyIn, line.heldYears))
        }
        var summary: [String] = []
        if let fraction = report.totalReturnFraction {
            let percent = fraction.formatted(.percent.precision(.fractionLength(1)))
            summary.append(String(localized: "Return on money in: \(percent)"))
        }
        if let yield = report.yieldPerAnnum {
            let percent = yield.formatted(.percent.precision(.fractionLength(1)))
            summary.append(String(localized: "Yield per annum: \(percent)"))
        }
        var notes = [
            String(localized: "Capital gain is the realised gain on the period’s disposals plus the move over the period in the unrealised gain on what is held, at the prices on its first and last days. Dividends and franking credits are the income the book records against each security in the period — in a transaction that touches the holding, or under an income account named for it. Over All Time, that is the return since the first purchase."),
            methodNote(report.method),
            closedPositionsNote(included: includeClosed),
            portfolioNote(portfolioID),
            investmentYieldNote,
        ]
        if !report.unpricedSymbols.isEmpty {
            let symbols = report.unpricedSymbols.joined(separator: ", ")
            notes.append(String(localized: "Unpriced: \(symbols) — no price on the date, so their unrealised gain is left out."))
        }
        if !report.unconvertedCurrencyCodes.isEmpty {
            let codes = report.unconvertedCurrencyCodes.joined(separator: ", ")
            notes.append(String(localized: "Incomplete: income in \(codes) is not included, because no exchange rate to \(code) was available on its dates."))
        }
        return ReportDocument(
            title: String(localized: "Investment Return"),
            periodLabel: periodLabel, currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Total return"), amount: report.totalReturn, signed: true),
                   ReportKPI(label: String(localized: "Capital gain"), amount: report.totalCapitalGain, signed: true),
                   ReportKPI(label: String(localized: "Dividends"), amount: report.totalDividends),
                   ReportKPI(label: String(localized: "Franking credits"), amount: report.totalFranking),
                   ReportKPI(label: String(localized: "Money in"), amount: report.totalMoneyIn)],
            summary: summary, chart: nil,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: [
                String(localized: "Capital gain"), String(localized: "Dividends"),
                String(localized: "Franking"), String(localized: "Total")]),
            notes: notes,
            facts: nil)
    }

    // MARK: Investment lots (FR-RPT-02)

    /// Every parcel under its security, by portfolio: what is held, at the
    /// price on the date — and, with Closed positions on, what has been sold,
    /// at what it fetched.
    func investmentLotsDocument(asOf: Date = Date(), includeClosed: Bool = false,
                                portfolioID: GncGUID? = nil) -> ReportDocument? {
        let lots = investmentLots(asOf: asOf, includeClosed: includeClosed, portfolioID: portfolioID)
        guard !lots.isEmpty else { return nil }
        let code = reportCurrency.mnemonic

        var byAccount: [GncGUID: [LotDetail]] = [:]
        var accounts: [GncGUID] = []
        for lot in lots {
            if byAccount[lot.accountID] == nil { accounts.append(lot.accountID) }
            byAccount[lot.accountID, default: []].append(lot)
        }
        let rows = accounts.map { accountID -> InvestmentRow in
            let parcels = byAccount[accountID]!
            let units = parcels.filter { !$0.isClosed }.reduce(Decimal(0)) { $0 + $1.quantity }
            let cost = parcels.reduce(Decimal(0)) { $0 + $1.costBasis }
            // One unpriced parcel and the security has no value or gain to
            // show — a part would read as the whole.
            let priced = parcels.allSatisfy { $0.gain != nil }
            let value: Decimal? = priced ? parcels.reduce(Decimal(0)) { $0 + ($1.value ?? 0) } : nil
            let gain: Decimal? = priced ? parcels.reduce(Decimal(0)) { $0 + ($1.gain ?? 0) } : nil
            let years = InvestmentYield.weightedYears(parcels.compactMap { parcel in
                parcel.heldYears.map { HeldParcel(cost: parcel.costBasis, years: $0) }
            })
            let detail = parcels.sorted(by: lotOrder).map { lot in
                ReportDocumentRow(label: lotLabel(lot), depth: 1,
                                  amounts: [lot.costBasis, lot.value, lot.gain,
                                            lot.yieldPerAnnum.map { Decimal($0) }])
            }
            // An unpriced security has no gain to annualise, and lends the
            // portfolio's yield neither its cost nor a gain of nothing.
            return InvestmentRow(
                portfolio: parcels[0].portfolio, gain: gain ?? 0,
                label: securityLabel(parcels[0].symbol, units: units),
                amounts: [cost, value, gain],
                yield: gain.flatMap { InvestmentYield.annualised(gain: $0, cost: cost, years: years) },
                yieldItem: priced ? (gain ?? 0, cost, years) : (0, 0, nil), detail: detail)
        }

        let open = lots.filter { !$0.isClosed }
        let sold = lots.filter(\.isClosed)
        var kpis = [
            ReportKPI(label: String(localized: "Cost basis"), amount: open.reduce(0) { $0 + $1.costBasis }),
            ReportKPI(label: String(localized: "Market value"), amount: open.reduce(0) { $0 + ($1.marketValue ?? 0) }),
            ReportKPI(label: String(localized: "Unrealised"), amount: open.reduce(0) { $0 + ($1.unrealizedGain ?? 0) },
                      signed: true),
        ]
        if !sold.isEmpty {
            kpis.append(ReportKPI(label: String(localized: "Realised"),
                                  amount: sold.reduce(0) { $0 + ($1.realizedGain ?? 0) }, signed: true))
        }
        return ReportDocument(
            title: String(localized: "Investment Lots"), periodLabel: String(localized: "As of \(shortDate(asOf))"), currencyCode: code,
            kpis: kpis, chart: nil,
            sections: investmentSections(rows, columns: [
                String(localized: "Cost"), String(localized: "Value"), String(localized: "Gain")]),
            notes: [String(localized: "A parcel still held is valued at the price on the date; a parcel sold, at what it fetched."),
                    methodNote(costBasisMethod),
                    includeClosed
                        ? String(localized: "Parcels already sold are listed with their realised gain.")
                        : String(localized: "Parcels already sold are left out; turn on Closed positions to list them with their realised gain."),
                    portfolioNote(portfolioID),
                    investmentYieldNote],
            facts: nil)
    }

    /// Open parcels first, then by the dates on them.
    private func lotOrder(_ a: LotDetail, _ b: LotDetail) -> Bool {
        if a.isClosed != b.isClosed { return !a.isClosed }
        return (a.acquisitionDate ?? .distantPast, a.disposalDate ?? .distantPast)
            < (b.acquisitionDate ?? .distantPast, b.disposalDate ?? .distantPast)
    }

    /// "acquired 12 Mar 2024 · 100 sh"; for a parcel sold, "sold 3 Jun 2025 ·
    /// 100 sh, acquired 12 Mar 2024"; a pooled lot has no date of its own.
    private func lotLabel(_ lot: LotDetail) -> String {
        let units = lot.quantity.formatted()
        switch (lot.disposalDate, lot.acquisitionDate) {
        case (let sold?, let acquired?):
            return String(localized: "sold \(shortDate(sold)) · \(units) sh, acquired \(shortDate(acquired))")
        case (let sold?, nil):
            return String(localized: "sold \(shortDate(sold)) · \(units) sh")
        case (nil, let acquired?):
            return String(localized: "acquired \(shortDate(acquired)) · \(units) sh")
        case (nil, nil):
            return String(localized: "pooled · \(units) sh")
        }
    }

    // MARK: Capital gains (FR-RPT-03)

    /// Realised gains over the period, by portfolio and security, each
    /// disposal under its security.
    func capitalGainsDocument(from: Date = .distantPast, to: Date = .distantFuture, periodLabel: String,
                              includeClosed: Bool = true, portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = capitalGains(from: from, to: to, includeClosed: includeClosed,
                                        portfolioID: portfolioID) else { return nil }
        let code = report.currencyCode

        var byAccount: [GncGUID: [CapitalGainLine]] = [:]
        var accounts: [GncGUID] = []
        for line in report.lines {
            if byAccount[line.accountID] == nil { accounts.append(line.accountID) }
            byAccount[line.accountID, default: []].append(line)
        }
        let rows = accounts.map { accountID -> InvestmentRow in
            let lines = byAccount[accountID]!
            let sold = lines.reduce(Decimal(0)) { $0 + $1.quantity }
            let proceeds = lines.reduce(Decimal(0)) { $0 + $1.proceeds }
            let cost = lines.reduce(Decimal(0)) { $0 + $1.costBasis }
            let gain = lines.reduce(Decimal(0)) { $0 + $1.gain }
            let years = InvestmentYield.weightedYears(lines.compactMap { line in
                line.heldYears.map { HeldParcel(cost: line.costBasis, years: $0) }
            })
            let detail = lines.sorted { $0.disposalDate < $1.disposalDate }.map { line in
                ReportDocumentRow(label: disposalLabel(line), depth: 1,
                                  amounts: [line.proceeds, line.costBasis, line.gain,
                                            line.yieldPerAnnum.map { Decimal($0) }])
            }
            return InvestmentRow(
                portfolio: lines[0].portfolio, gain: gain,
                label: String(localized: "\(lines[0].symbol)  \(sold.formatted()) sh sold"),
                amounts: [proceeds, cost, gain],
                yield: InvestmentYield.annualised(gain: gain, cost: cost, years: years),
                yieldItem: (gain, cost, years), detail: detail)
        }

        return ReportDocument(
            title: String(localized: "Capital Gains"),
            periodLabel: periodLabel,
            currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Short-term"), amount: report.shortTermGain, signed: true),
                   ReportKPI(label: String(localized: "Long-term"), amount: report.longTermGain, signed: true),
                   ReportKPI(label: String(localized: "Total realised"), amount: report.totalGain, signed: true)],
            chart: nil,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: [
                String(localized: "Proceeds"), String(localized: "Cost"), String(localized: "Gain")]),
            notes: capitalGainsNotes(report) + [
                methodNote(report.method),
                includeClosed
                    ? String(localized: "Gains on positions sold out of entirely are included.")
                    : String(localized: "Gains on positions sold out of entirely are left out; turn on Closed positions to include them."),
                portfolioNote(portfolioID),
                investmentYieldNote],
            facts: nil)
    }

    /// "sold 3 Jun 2025 · 100 sh, acquired 12 Mar 2024 (LT)". LT and ST: held
    /// over a year, or not — the abbreviations a tax return uses, and a phrase
    /// each so each language has its own.
    private func disposalLabel(_ line: CapitalGainLine) -> String {
        let units = line.quantity.formatted()
        let sold = shortDate(line.disposalDate)
        switch (line.longTerm, line.acquisitionDate.map(shortDate)) {
        case (true?, let acquired?):
            return String(localized: "sold \(sold) · \(units) sh, acquired \(acquired) (LT)")
        case (false?, let acquired?):
            return String(localized: "sold \(sold) · \(units) sh, acquired \(acquired) (ST)")
        case (nil, let acquired?):
            return String(localized: "sold \(sold) · \(units) sh, acquired \(acquired)")
        case (true?, nil):
            return String(localized: "sold \(sold) · \(units) sh (LT)")
        case (false?, nil):
            return String(localized: "sold \(sold) · \(units) sh (ST)")
        case (nil, nil):
            return String(localized: "sold \(sold) · \(units) sh")
        }
    }

    /// What the capital-gains report cannot vouch for, said out loud.
    ///
    /// A disposal whose currency has no exchange rate on its date is dropped
    /// from `lines` rather than reported at face value, and `report`'s own
    /// `unconvertedCurrencyCodes` records that it happened — but nothing read
    /// that field, anywhere. So a tax report could omit a whole brokerage
    /// account's disposals and look identical to one that genuinely had none.
    /// This is the report people file tax from; an omission it knows about has
    /// to be visible on its face.
    private func capitalGainsNotes(_ report: CapitalGainsReport) -> [String] {
        var notes: [String] = []
        if report.lines.isEmpty { notes.append(String(localized: "No realised gains in this period.")) }
        if !report.unconvertedCurrencyCodes.isEmpty {
            let codes = report.unconvertedCurrencyCodes.joined(separator: ", ")
            notes.append(String(localized: """
                Incomplete: disposals in \(codes) are not included, because no \
                exchange rate to \(report.currencyCode) was available on their \
                dates. Add those rates and run this report again before filing.
                """))
        }
        return notes
    }

    // MARK: Price history (FR-RPT — Price Scatter)

    /// Memoised on the book revision, the report currency and the date order
    /// its rows are written in: the Price History toolbar asks for it on
    /// every pass of its body, and a key without the date order kept the old
    /// dates after Settings ▸ Dates changed (17 October review).
    func priceHistoryDocument() -> ReportDocument? {
        cachedReport("pricehistorydoc:\(reportCurrency.mnemonic):\(AppDateFormat.current.order.rawValue)") {
            buildPriceHistoryDocument()
        }
    }

    private func buildPriceHistoryDocument() -> ReportDocument? {
        let securities = securitiesWithPriceHistory
        guard !securities.isEmpty else { return nil }
        let code = reportCurrency.mnemonic
        let rows = securities.compactMap { commodity -> ReportDocumentRow? in
            let history = priceHistory(for: commodity).sorted { $0.date < $1.date }
            guard let latest = history.last else { return nil }
            return ReportDocumentRow(
                label: String(localized: "\(commodity.mnemonic)  \(history.count) prices, latest \(shortDate(latest.date))"),
                amount: latest.value)
        }
        guard !rows.isEmpty else { return nil }
        return ReportDocument(
            title: String(localized: "Price History"), periodLabel: String(localized: "Latest prices"), currencyCode: code,
            kpis: [], chart: nil,
            sections: [ReportDocumentSection(title: String(localized: "Securities"), rows: rows)],
            notes: [String(localized: "The interactive report plots every price over time; this lists each security’s latest price.")],
            facts: nil)
    }

    // MARK: Cash-flow forecast (FR-RPT — Forecast)

    /// The forecast as a printable, from a projection already built — the
    /// Forecast view hands over the points it shows, so its toolbar never
    /// walks the book again.
    func forecastDocument(accountID: GncGUID, points: [CashFlowPoint]) -> ReportDocument? {
        let events = points.filter { $0.change != 0 }
        guard !events.isEmpty else { return nil }
        let code = reportCurrency.mnemonic
        let rows = events.map { event in
            let dated = "\(shortDate(event.date))  \(event.label)"
            return ReportDocumentRow(label: event.isWhatIf ? String(localized: "\(dated) (what-if)") : dated,
                                     amounts: [event.change, event.balance])
        }
        return ReportDocument(
            title: String(localized: "Cash-Flow Forecast — \(accountName(accountID) ?? String(localized: "Account"))"),
            periodLabel: String(localized: "Projected from scheduled transactions"), currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Ending balance"), amount: points.last?.balance ?? 0, signed: true)],
            chart: nil,
            sections: [ReportDocumentSection(
                title: String(localized: "Upcoming Activity"), rows: rows, columns: [String(localized: "Change"), String(localized: "Balance")])],
            notes: [], facts: nil)
    }
}
