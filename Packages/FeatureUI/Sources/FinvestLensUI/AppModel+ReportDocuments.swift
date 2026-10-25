//
//  AppModel+ReportDocuments.swift
//  FinvestLens — FeatureUI
//
//  ``ReportDocument`` builders (`FR-RPT-05`): the investment reports, the
//  transactions and reconciliation reports, Spending Insights, and the
//  printable forms of the two interactive tools. One builder per report,
//  from the report type the model computes; the screen and the PDF draw
//  the same value.
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
    // Nine reports, one shape. Asked for on build 8: "by portfolio, then
    // security … filtering by portfolio, open/close toggle, and sorted by
    // decreasing gain … all the investment reports should be filterable by
    // portfolio, financial year, open/close toggle etc. They need to be
    // consistent." And on build 10: "They are missing key features like
    // acquisition date, consideration, etc. This is required in a report."
    // So every column is a typed cell — a date, a count of units, money, a
    // rate — never words folded into a label. Each report is a section per
    // portfolio with its securities in order of the figure the report is
    // about, largest first, the parcels or history beneath, and the
    // portfolio's total under them; more than one portfolio closes with a
    // table of the portfolios themselves. The notes say which way each
    // switch is set and what every column is.

    /// One security as an investment report lays it out: its row, the rows
    /// under it, and what it is ranked by.
    private struct InvestmentRow {
        var portfolio: PortfolioRef?
        /// The figure the rows are ordered by, largest first.
        var rank: Decimal
        var label: String
        var cells: [ReportCell]
        /// Parcels or events under the security, indented.
        var detail: [ReportDocumentRow] = []
    }

    /// The sections of an investment report over `rows`: one per portfolio,
    /// its securities in order of rank, largest first, and its total under
    /// them; then, with more than one portfolio, the portfolios themselves in
    /// the same order. `total` gives a group's total row from its members.
    private func investmentSections(_ rows: [InvestmentRow], columns: [String],
                                    total: ([InvestmentRow]) -> [ReportCell]) -> [ReportDocumentSection] {
        var byPortfolio: [GncGUID?: [InvestmentRow]] = [:]
        for row in rows { byPortfolio[row.portfolio?.id, default: []].append(row) }
        let portfolios = byPortfolio.map { id, members in
            (id: id, name: members.first?.portfolio?.name, members: members,
             rank: members.reduce(Decimal(0)) { $0 + $1.rank })
        }.sorted { lhs, rhs in
            // By rank, largest first; securities with no portfolio last.
            if (lhs.id == nil) != (rhs.id == nil) { return rhs.id == nil }
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            return (lhs.name ?? "") < (rhs.name ?? "")
        }
        var sections = portfolios.map { portfolio -> ReportDocumentSection in
            let ordered = portfolio.members.sorted { $0.rank > $1.rank }
            return ReportDocumentSection(
                title: portfolio.name ?? String(localized: "No portfolio"),
                rows: ordered.flatMap { [ReportDocumentRow(label: $0.label, cells: $0.cells)] + $0.detail },
                columns: columns,
                cellTotals: (String(localized: "Total"), total(portfolio.members)),
                identity: "portfolio:\(portfolio.id?.hexString ?? "none")")
        }
        if portfolios.count > 1 {
            sections.append(ReportDocumentSection(
                title: String(localized: "All portfolios"),
                rows: portfolios.map {
                    ReportDocumentRow(label: $0.name ?? String(localized: "No portfolio"), cells: total($0.members))
                },
                columns: columns,
                cellTotals: (String(localized: "Total"), total(rows))))
        }
        return sections
    }

    /// A group's total row: money and unit columns summed over the members
    /// that have them, every other column blank.
    private func summedCells(_ members: [InvestmentRow], columns: Int) -> [ReportCell] {
        (0..<columns).map { column in
            var money: Decimal?
            var units: Decimal?
            for member in members where column < member.cells.count {
                switch member.cells[column] {
                case .money(let value?): money = (money ?? 0) + value
                case .units(let value?): units = (units ?? 0) + value
                default: break
                }
            }
            if let money { return .money(money) }
            if let units { return .units(units) }
            return .text("")
        }
    }

    private func percentCell(_ rate: Double?) -> ReportCell { .percent(rate.map { Decimal($0) }) }

    /// "2.3 y", or "140 d" under a year.
    private func heldLabel(days: Int?) -> String {
        guard let days else { return "" }
        if days < 365 { return String(localized: "\(days) d") }
        let years = (Double(days) / 365.25).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(years) y")
    }

    /// What an event is, for the history tables.
    private func eventLabel(_ kind: InvestmentEvent.Kind) -> String {
        switch kind {
        case .buy: String(localized: "Buy")
        case .sell: String(localized: "Sell")
        case .dividendFranked: String(localized: "Franked dividend")
        case .dividendUnfranked: String(localized: "Unfranked dividend")
        case .frankingCredit: String(localized: "Franking credit")
        case .distribution: String(localized: "Distribution")
        case .interest: String(localized: "Interest")
        case .otherIncome: String(localized: "Income")
        case .returnOfCapital: String(localized: "Return of capital")
        case .split: String(localized: "Split")
        }
    }

    /// Who the gains are assessed for, as the notes say it.
    func entityLabel(_ entity: CGTEntity) -> String {
        switch entity {
        case .individual: String(localized: "Individual")
        case .trust: String(localized: "Trust")
        case .superFund: String(localized: "Super fund")
        case .company: String(localized: "Company")
        }
    }

    /// Which way the report's Closed positions switch is set, on its face,
    /// in the words that switch means for this report.
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

    /// What the annualised column is — the same words on every report that
    /// prints one.
    private var annualisedNote: String {
        String(localized: "Annualised is the money-weighted rate of return: the yearly rate at which the dated money in, money out and income, with what is held valued on the date, discount to zero (Excel’s XIRR). Nothing under a year old is annualised.")
    }

    private func methodNote(_ method: CostBasisMethod) -> String {
        String(localized: "\(method.displayName) cost basis")
    }

    private func unpricedNote(_ symbols: [String]) -> String? {
        guard !symbols.isEmpty else { return nil }
        let list = symbols.joined(separator: ", ")
        return String(localized: "Unpriced: \(list) — no price on the date, so no value or unrealised gain is shown for them, and the totals leave them out.")
    }

    private func unconvertedNote(_ codes: [String], code: String) -> String? {
        guard !codes.isEmpty else { return nil }
        let list = codes.joined(separator: ", ")
        return String(localized: "Incomplete: amounts in \(list) are not included, because no exchange rate to \(code) was available on their dates.")
    }

    /// The top securities by the size of a figure, for a chart's bars.
    private func topBars(_ items: [(label: String, value: Decimal)], limit: Int = 12) -> [(label: String, value: Decimal)] {
        Array(items.sorted { $0.value.magnitude > $1.value.magnitude }.prefix(limit))
            .sorted { $0.value > $1.value }
    }

    // MARK: Portfolio (FR-RPT-02)

    /// What is held, valued, with its lifetime gain in GnuCash's advanced-
    /// portfolio columns — units, price, cost, value, unrealised, realised,
    /// income, total gain, and the money-weighted rate — by portfolio and
    /// security.
    func portfolioDocument(asOf: Date = Date(), includeClosed: Bool = false,
                           portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let portfolio = advancedPortfolio(asOf: asOf, includeClosed: includeClosed,
                                                portfolioID: portfolioID) else { return nil }
        let code = portfolio.currencyCode
        let columns = [String(localized: "Acquired"), String(localized: "Units"), String(localized: "Price"),
                       String(localized: "Cost"), String(localized: "Value"), String(localized: "Unrealised"),
                       String(localized: "Realised"), String(localized: "Income"), String(localized: "Total gain"),
                       String(localized: "Annualised")]
        let rows = portfolio.holdings.map { holding in
            InvestmentRow(portfolio: holding.portfolio, rank: holding.totalGain,
                          label: holding.isClosed ? String(localized: "\(holding.symbol) (closed)") : holding.symbol,
                          cells: [.date(holding.firstAcquisition), .units(holding.shares), .money(holding.price),
                                  .money(holding.costBasis), .money(holding.marketValue),
                                  .money(holding.unrealizedGain), .money(holding.realizedGain),
                                  .money(holding.income), .money(holding.totalGain),
                                  percentCell(holding.annualisedReturn)])
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
        var summary: [String] = []
        if let fraction = portfolio.totalReturnFraction {
            let percent = fraction.formatted(.percent.precision(.fractionLength(1)))
            summary.append(String(localized: "Total gain on money in: \(percent)"))
        }
        if let rate = portfolio.annualisedReturn {
            let percent = rate.formatted(.percent.precision(.fractionLength(1)))
            summary.append(String(localized: "Annualised, money-weighted: \(percent) a year"))
        }
        // The allocation donut: the largest holdings by value, the tail rolled
        // into "Other" so the legend stays legible.
        let valued = portfolio.holdings
            .compactMap { h in (h.marketValue ?? 0) > 0 ? (h.symbol, h.marketValue!) : nil }
            .sorted { $0.1 > $1.1 }
        var slices = valued.prefix(9).map { (label: $0.0, value: $0.1) }
        let tail = valued.dropFirst(9).reduce(Decimal(0)) { $0 + $1.1 }
        if tail > 0 { slices.append((label: String(localized: "Other"), value: tail)) }

        var notes = [String(localized: "Securities valued at the price nearest the date. Realised gain and income are since the first purchase; total gain is unrealised plus realised plus income. Securities and portfolios are in order of total gain, largest first."),
                     methodNote(portfolio.method),
                     closedPositionsNote(included: includeClosed),
                     portfolioNote(portfolioID),
                     annualisedNote]
        if let note = unpricedNote(portfolio.unpricedSymbols) { notes.append(note) }
        if let note = unconvertedNote(portfolio.unconvertedCurrencyCodes, code: code) { notes.append(note) }
        return ReportDocument(
            title: String(localized: "Portfolio"), periodLabel: String(localized: "As of \(shortDate(asOf))"), currencyCode: code,
            kpis: kpis, summary: summary, chart: slices.count > 1 ? .allocation(slices) : nil,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: columns) { members in
                var cells = summedCells(members, columns: columns.count)
                cells[0] = .text(""); cells[2] = .text("")   // dates and prices do not add
                return cells
            },
            notes: notes,
            facts: nil)
    }

    // MARK: Investment return (FR-RPT-02b)

    /// Every security's total return since it was first bought — realised
    /// and unrealised gain, dividends and franking credits — to the period's
    /// end, with the history that produced it, by portfolio; and, for a
    /// bounded period, the period's own contribution beside the total. Asked
    /// for on build 10: "Total return means total return … you need to show
    /// acquisition history, and total return up till end of filtered period."
    func investmentReturnDocument(from: Date, to: Date, periodLabel: String, includeClosed: Bool = true,
                                  portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = investmentReturn(from: from, to: to, includeClosed: includeClosed,
                                            portfolioID: portfolioID) else { return nil }
        let code = report.currencyCode
        let bounded = from != .distantPast
        var columns = [String(localized: "Acquired"), String(localized: "Money in"), String(localized: "Money out"),
                       String(localized: "Realised"), String(localized: "Unrealised"), String(localized: "Dividends"),
                       String(localized: "Franking"), String(localized: "Total return"), String(localized: "Return"),
                       String(localized: "Annualised")]
        if bounded { columns.append(String(localized: "This period")) }

        var rates: [GncGUID?: Double?] = [:]
        let rows = report.lines.map { line -> InvestmentRow in
            var cells: [ReportCell] = [
                .date(line.firstAcquisition), .money(line.moneyIn), .money(line.moneyOut),
                .money(line.realizedGain), .money(line.unrealizedGain), .money(line.dividends),
                .money(line.frankingCredits), .money(line.totalReturn), percentCell(line.returnOnMoneyIn),
                percentCell(line.annualisedReturn)]
            if bounded { cells.append(.money(line.periodReturn)) }
            return InvestmentRow(portfolio: line.portfolio, rank: line.totalReturn,
                                 label: line.isClosed ? String(localized: "\(line.symbol) (closed)") : line.symbol,
                                 cells: cells)
        }
        // A portfolio's own rate: every member's flows together.
        var byPortfolio: [GncGUID?: [InvestmentReturnLine]] = [:]
        for line in report.lines { byPortfolio[line.portfolio?.id, default: []].append(line) }
        for (id, lines) in byPortfolio {
            let flows = lines.compactMap { $0.history.cashFlows(valuedAt: to) }
            guard flows.count == lines.count else { rates[id] = .some(nil); continue }
            let dated = flows.flatMap { $0 }.map { DatedCashFlow(date: $0.date, amount: $0.amount) }
            if let first = dated.map(\.date).min(), InvestmentYield.isAnnualisable(from: first, to: to) {
                rates[id] = .some(MoneyWeightedReturn.rate(of: dated))
            } else {
                rates[id] = .some(nil)
            }
        }
        func total(_ members: [InvestmentRow]) -> [ReportCell] {
            var cells = summedCells(members, columns: columns.count)
            cells[0] = .text("")
            let moneyIn = members.reduce(Decimal(0)) { $0 + (($1.cells[1].money) ?? 0) }
            let totalReturn = members.reduce(Decimal(0)) { $0 + (($1.cells[7].money) ?? 0) }
            cells[8] = .percent(moneyIn != 0 ? totalReturn / moneyIn : nil)
            let portfolios = Set(members.map { $0.portfolio?.id })
            if portfolios.count == 1, let id = portfolios.first {
                cells[9] = percentCell(rates[id] ?? nil)
            } else {
                cells[9] = percentCell(report.annualisedReturn)
            }
            return cells
        }

        // The history under each security: every event, dated.
        let historyColumns = [String(localized: "Date"), String(localized: "Event"), String(localized: "Units"),
                              String(localized: "Amount"), String(localized: "Fee"), String(localized: "Gain")]
        let histories = report.lines.map { line -> ReportDocumentSection in
            ReportDocumentSection(
                title: String(localized: "\(line.symbol) history"),
                rows: line.history.events.map { event in
                    ReportDocumentRow(label: event.description, cells: [
                        .date(event.date), .text(eventLabel(event.kind)), .units(event.units),
                        .money(event.converted ? event.amount : nil), .money(event.fee != 0 ? event.fee : nil),
                        .money(event.realizedGain)])
                },
                columns: historyColumns,
                identity: "history:\(line.id.hexString)")
        }

        var summary: [String] = []
        if let fraction = report.totalReturnFraction {
            let percent = fraction.formatted(.percent.precision(.fractionLength(1)))
            summary.append(String(localized: "Return on money in: \(percent)"))
        }
        if let rate = report.annualisedReturn {
            let percent = rate.formatted(.percent.precision(.fractionLength(1)))
            summary.append(String(localized: "Annualised, money-weighted: \(percent) a year"))
        }
        if bounded, let period = report.totalPeriodReturn {
            summary.append(String(localized: "This period’s contribution: \(AmountFormat.string(period, code: code))"))
        }
        let bars = topBars(report.lines.map { ($0.symbol, $0.totalReturn) })
        let chart: ReportDocumentChart? = bars.isEmpty ? nil : .stackedBars(
            series: [String(localized: "Realised"), String(localized: "Unrealised"),
                     String(localized: "Dividends"), String(localized: "Franking")],
            bars: bars.compactMap { bar in
                report.lines.first { $0.symbol == bar.label }.map {
                    (label: $0.symbol, values: [$0.realizedGain, $0.unrealizedGain ?? 0, $0.dividends, $0.frankingCredits])
                }
            })

        var notes = [
            String(localized: "Total return is everything a holding has earned since its first purchase, to the period’s end: the realised gain on every sale, the unrealised gain on what is held at the price nearest the date, and the dividends, distributions, interest and franking credits the book records against it — in a transaction that touches the holding, or under an income account named for it, each counted once. The period’s start changes none of it."),
            bounded
                ? String(localized: "This period is the period’s contribution: the total return at its end less the total return the day before it began. It is blank where a holding had no price on either day.")
                : String(localized: "Choose a period to see each holding’s contribution over it beside the total."),
            String(localized: "Return is total return over money in. Securities and portfolios are in order of total return, largest first; each security’s history follows the tables."),
            methodNote(report.method),
            closedPositionsNote(included: includeClosed),
            portfolioNote(portfolioID),
            annualisedNote,
        ]
        if let note = unpricedNote(report.unpricedSymbols) { notes.append(note) }
        if let note = unconvertedNote(report.unconvertedCurrencyCodes, code: code) { notes.append(note) }
        return ReportDocument(
            title: String(localized: "Investment Return"),
            periodLabel: periodLabel, currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Total return"), amount: report.totalReturn, signed: true),
                   ReportKPI(label: String(localized: "Capital gain"), amount: report.totalCapitalGain, signed: true),
                   ReportKPI(label: String(localized: "Dividends"), amount: report.totalDividends),
                   ReportKPI(label: String(localized: "Franking credits"), amount: report.totalFranking),
                   ReportKPI(label: String(localized: "Money in"), amount: report.totalMoneyIn)],
            summary: summary, chart: chart,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: columns, total: total) + histories,
            notes: notes,
            facts: nil)
    }

    // MARK: Investment lots (FR-RPT-02)

    /// Every parcel under its security, by portfolio: when it was acquired,
    /// what it cost, what it is worth at the price on the date, whether it
    /// has been owned twelve months — and, with Closed positions on, the
    /// parcels already sold, at what they fetched. The summary says what the
    /// open parcels would be assessed at if sold on the date (Sharesight’s
    /// unrealised CGT: "a forecasting tool only").
    func investmentLotsDocument(asOf: Date = Date(), includeClosed: Bool = false,
                                portfolioID: GncGUID? = nil) -> ReportDocument? {
        let lots = investmentLots(asOf: asOf, includeClosed: includeClosed, portfolioID: portfolioID)
        guard !lots.isEmpty else { return nil }
        let code = reportCurrency.mnemonic
        var columns = [String(localized: "Acquired")]
        if includeClosed { columns.append(String(localized: "Sold")) }
        columns += [String(localized: "Units"), String(localized: "Cost"), String(localized: "Price"),
                    String(localized: "Value"), String(localized: "Gain (loss)"), String(localized: "Annualised"),
                    String(localized: "Held 12 mo")]
        func cells(acquired: Date?, sold: Date?, units: Decimal, cost: Decimal, price: Decimal?, value: Decimal?,
                   gain: Decimal?, rate: Double?, term: Bool?) -> [ReportCell] {
            var cells: [ReportCell] = [.date(acquired)]
            if includeClosed { cells.append(.date(sold)) }
            cells += [.units(units), .money(cost), .money(price), .money(value), .money(gain), percentCell(rate),
                      .text(term.map { $0 ? String(localized: "Yes") : String(localized: "No") } ?? "")]
            return cells
        }

        var byAccount: [GncGUID: [LotDetail]] = [:]
        var accounts: [GncGUID] = []
        for lot in lots {
            if byAccount[lot.accountID] == nil { accounts.append(lot.accountID) }
            byAccount[lot.accountID, default: []].append(lot)
        }
        let rows = accounts.map { accountID -> InvestmentRow in
            let parcels = byAccount[accountID]!
            let open = parcels.filter { !$0.isClosed }
            let units = open.reduce(Decimal(0)) { $0 + $1.quantity }
            let cost = parcels.reduce(Decimal(0)) { $0 + $1.costBasis }
            // One unpriced parcel and the security has no value or gain to
            // show — a part would read as the whole.
            let priced = parcels.allSatisfy { $0.gain != nil }
            let value: Decimal? = priced ? parcels.reduce(Decimal(0)) { $0 + ($1.value ?? 0) } : nil
            let gain: Decimal? = priced ? parcels.reduce(Decimal(0)) { $0 + ($1.gain ?? 0) } : nil
            let detail = parcels.sorted(by: lotOrder).map { lot in
                ReportDocumentRow(
                    label: lot.isClosed ? String(localized: "Sold parcel") : String(localized: "Parcel"), depth: 1,
                    cells: cells(acquired: lot.acquisitionDate, sold: lot.disposalDate, units: lot.quantity,
                                 cost: lot.costBasis, price: lot.price, value: lot.value, gain: lot.gain,
                                 rate: lot.annualisedReturn, term: lot.longTerm))
            }
            let first = parcels.compactMap(\.acquisitionDate).min()
            return InvestmentRow(
                portfolio: parcels[0].portfolio, rank: gain ?? 0,
                label: units == 0 ? String(localized: "\(parcels[0].symbol) (closed)") : parcels[0].symbol,
                cells: cells(acquired: first, sold: nil, units: units, cost: cost, price: open.first?.price,
                             value: value, gain: gain, rate: nil, term: nil),
                detail: detail)
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
        var summary: [String] = []
        if let estimate = unrealisedCapitalGains(lots, asOf: asOf), !open.isEmpty {
            summary.append(String(localized: "If every open parcel were sold on the date: gains on parcels held twelve months \(AmountFormat.string(estimate.longTermGains, code: code)), on parcels held less \(AmountFormat.string(estimate.shortTermGains, code: code)), losses \(AmountFormat.string(estimate.losses, code: code))."))
            summary.append(String(localized: "Estimated net capital gain (\(entityLabel(estimate.entity)), losses offset, discount applied): \(AmountFormat.string(estimate.net.netCapitalGain, code: code))."))
        }
        let unpriced = Set(open.filter { $0.marketValue == nil }.map(\.symbol)).sorted()
        var notes = [String(localized: "A parcel still held is valued at the price nearest the date; a parcel sold, at what it fetched. Held 12 mo is the ATO’s test — the day bought and the day sold both excluded — so a Yes would be discounted (or, after 1 July 2027, indexed) if sold on the date. Securities are in order of gain, largest first, their parcels oldest first."),
                     methodNote(costBasisMethod),
                     includeClosed
                         ? String(localized: "Parcels already sold are listed with what they fetched and their realised gain.")
                         : String(localized: "Parcels already sold are left out; turn on Closed positions to list them with their realised gain."),
                     portfolioNote(portfolioID),
                     annualisedNote]
        if costBasisMethod == .average {
            notes.append(String(localized: "Average cost pools the parcels, so a pooled parcel has no acquisition date of its own and no twelve-month test; choose FIFO or LIFO to see each parcel."))
        }
        if let note = unpricedNote(unpriced) { notes.append(note) }
        return ReportDocument(
            title: String(localized: "Investment Lots"), periodLabel: String(localized: "As of \(shortDate(asOf))"), currencyCode: code,
            kpis: kpis, summary: summary, chart: nil,
            sections: investmentSections(rows, columns: columns) { members in
                var cells = summedCells(members, columns: columns.count)
                cells[0] = .text("")
                if includeClosed { cells[1] = .text("") }
                cells[includeClosed ? 4 : 3] = .text("")   // prices do not add
                return cells
            },
            notes: notes,
            facts: nil)
    }

    /// Open parcels first, then by the dates on them.
    private func lotOrder(_ a: LotDetail, _ b: LotDetail) -> Bool {
        if a.isClosed != b.isClosed { return !a.isClosed }
        return (a.acquisitionDate ?? .distantPast, a.disposalDate ?? .distantPast)
            < (b.acquisitionDate ?? .distantPast, b.disposalDate ?? .distantPast)
    }

    // MARK: Capital gains (FR-RPT-03)

    /// The capital-gains report a tax return is prepared from: every parcel
    /// sold in the period — when acquired and sold, units, cost base,
    /// proceeds, gain, how long held, and how the ATO treats it — under its
    /// security, by portfolio; the year’s net capital gain by the ATO’s
    /// method; and, with Closed positions on, the whole history of every
    /// position sold out of by the period’s end.
    func capitalGainsDocument(from: Date = .distantPast, to: Date = .distantFuture, periodLabel: String,
                              includeClosed: Bool = false, portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = capitalGains(from: from, to: to, includeClosed: includeClosed,
                                        portfolioID: portfolioID) else { return nil }
        let code = report.currencyCode
        let columns = [String(localized: "Acquired"), String(localized: "Sold"), String(localized: "Units"),
                       String(localized: "Cost base"), String(localized: "Proceeds"), String(localized: "Gain (loss)"),
                       String(localized: "Held"), String(localized: "Treatment"), String(localized: "Assessable")]

        var byAccount: [GncGUID: [CapitalGainLine]] = [:]
        var accounts: [GncGUID] = []
        for line in report.lines {
            if byAccount[line.accountID] == nil { accounts.append(line.accountID) }
            byAccount[line.accountID, default: []].append(line)
        }
        let rows = accounts.map { accountID -> InvestmentRow in
            let lines = byAccount[accountID]!
            let period = lines.filter(\.inPeriod)
            let detail = lines.sorted { $0.disposalDate < $1.disposalDate }.map { line in
                ReportDocumentRow(label: line.description, depth: 1, cells: [
                    .date(line.acquisitionDate), .date(line.disposalDate), .units(line.quantity),
                    .money(line.costBasis), .money(line.proceeds), .money(line.gain),
                    .text(heldLabel(days: line.holdingDays)), .text(treatmentLabel(line)),
                    .money(line.inPeriod ? assessable(line) : nil)])
            }
            // The security's row totals the period's parcels; history parcels
            // belong to other years' returns and stay out of every total.
            return InvestmentRow(
                portfolio: lines[0].portfolio, rank: period.reduce(0) { $0 + $1.gain },
                label: lines[0].symbol,
                cells: [.date(nil), .date(nil), .units(period.reduce(0) { $0 + $1.quantity }),
                        .money(period.reduce(0) { $0 + $1.costBasis }), .money(period.reduce(0) { $0 + $1.proceeds }),
                        .money(period.reduce(0) { $0 + $1.gain }), .text(""), .text(""),
                        .money(period.reduce(0) { $0 + assessable($1) })],
                detail: detail)
        }

        let net = report.net
        var assessment: [ReportDocumentRow] = [
            ReportDocumentRow(label: String(localized: "Capital gains"), amount: net.grossGains),
            ReportDocumentRow(label: String(localized: "Capital losses"), amount: -net.losses),
        ]
        if net.discountableGains > 0 {
            assessment.append(ReportDocumentRow(label: String(localized: "Gains eligible for the discount, after losses"),
                                                amount: net.discountableGains))
            let percent = report.entity.discountFraction.formatted(.percent.precision(.fractionLength(0...1)))
            assessment.append(ReportDocumentRow(label: String(localized: "CGT discount (\(percent))"),
                                                amount: -net.discountApplied))
        }
        if net.minimumTaxGain > 0 {
            assessment.append(ReportDocumentRow(label: String(localized: "Of which accrued after 1 July 2027 (30% minimum tax)"),
                                                amount: net.minimumTaxGain))
        }
        if net.lossCarriedForward > 0 {
            assessment.append(ReportDocumentRow(label: String(localized: "Net capital loss carried forward"),
                                                amount: net.lossCarriedForward))
        }
        let assessmentSection = ReportDocumentSection(
            title: String(localized: "Net capital gain — \(entityLabel(report.entity))"),
            rows: assessment,
            total: (String(localized: "Net capital gain"), net.netCapitalGain))

        let bars = topBars(rows.map { ($0.label, $0.rank) })
        var notes = capitalGainsNotes(report) + [
            String(localized: "A CGT event is filed by the day the parcel was sold; its acquisition date is kept however early. Cost base and proceeds are the parcel’s, in the report currency; Held counts whole days. Treatment is the ATO’s: Discount for a parcel owned at least twelve months (the day bought and the day sold excluded), Short for one owned less, Loss for a sale below cost, Exempt for a pre-20 September 1985 purchase, Indexed where the cost base was raised by CPI — the 1999 method on a parcel bought before 21 September 1999 when that assesses less, and from 1 July 2027 the reform’s indexation. Assessable is each parcel’s gain as it enters the year’s net capital gain, before losses and the discount."),
            String(localized: "The net capital gain follows the ATO’s steps: losses — this year’s — come off the gains, from those not eligible for the discount first; the discount applies to what is left of the eligible gains. It is worked over the period’s parcels alone."),
            methodNote(report.method),
            includeClosed
                ? String(localized: "Closed positions: every position sold out of by the period’s end is shown with its whole history; parcels sold outside the period are marked history and stay out of the totals.")
                : String(localized: "Parcels sold in the period only; turn on Closed positions to see the whole history of every position sold out of by the period’s end."),
            portfolioNote(portfolioID),
            String(localized: "Securities and portfolios are in order of gain, largest first; parcels oldest sale first."),
        ]
        if report.transitionalCount > 0 {
            notes.append(String(localized: "Parcels owned across 1 July 2027 are split as the reform splits them: the gain to the asset’s value just before that day under the old rules, the gain after it with that value as the cost base, indexed by CPI. A parcel with no price dated 30 June 2027 is split by the days held each side instead (apportionment), until a price is recorded."))
        }
        if !report.transitionalValueMissingSymbols.isEmpty {
            let list = report.transitionalValueMissingSymbols.joined(separator: ", ")
            notes.append(String(localized: "Apportioned for want of a 30 June 2027 price: \(list). Record one under Prices to use the market-value method."))
        }
        if report.unindexedCount > 0 {
            notes.append(String(localized: "\(report.unindexedCount) post-2027 gain(s) could not be indexed: the CPI table has no reading for a quarter they need. Update it under Planning ▸ Tax."))
        }
        if report.lines.contains(where: { $0.acquisitionDate == nil && $0.inPeriod }) {
            notes.append(String(localized: "Pooled: under average cost a parcel has no acquisition date, so its term cannot be settled and it is assessed in full; choose FIFO or LIFO to apply the twelve-month test."))
        }
        if report.foreignResident {
            notes.append(String(localized: "Assessed for a foreign or temporary resident: no discount and no indexation."))
        }
        notes.append(annualisedNote)
        return ReportDocument(
            title: String(localized: "Capital Gains"),
            periodLabel: periodLabel,
            currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Proceeds"), amount: report.totalProceeds),
                   ReportKPI(label: String(localized: "Cost base"), amount: report.totalCostBasis),
                   ReportKPI(label: String(localized: "Gain (loss)"), amount: report.totalGain, signed: true),
                   ReportKPI(label: String(localized: "Net capital gain"), amount: net.netCapitalGain, signed: true)],
            summary: [
                String(localized: "Held over twelve months: \(AmountFormat.string(report.longTermGain, code: code)); under: \(AmountFormat.string(report.shortTermGain, code: code))\(report.otherGain != 0 ? String(localized: "; undetermined: \(AmountFormat.string(report.otherGain, code: code))") : "")."),
            ],
            chart: bars.isEmpty ? nil : .bars(bars),
            sections: (rows.isEmpty ? [] : investmentSections(rows, columns: columns) { members in
                var cells = summedCells(members, columns: columns.count)
                cells[0] = .text(""); cells[1] = .text("")
                return cells
            }) + (report.periodLines.isEmpty ? [] : [assessmentSection]),
            notes: notes,
            facts: nil)
    }

    /// A parcel’s gain as it enters the net capital gain: its slices summed,
    /// the exempt one aside.
    private func assessable(_ line: CapitalGainLine) -> Decimal {
        line.components.filter { $0.treatment != .exempt }.reduce(0) { $0 + $1.gain }
    }

    /// The ATO treatment of a parcel, in a word or two.
    private func treatmentLabel(_ line: CapitalGainLine) -> String {
        var text: String
        if line.gain < 0 {
            text = String(localized: "Capital loss")
        } else if line.acquisitionDate == nil {
            text = String(localized: "Pooled")
        } else {
            text = line.components.map { component -> String in
                switch component.treatment {
                case .discount: String(localized: "Discount")
                case .indexation: component.indexed ? String(localized: "Indexed") : String(localized: "Unindexed")
                case .frozenIndexation: String(localized: "Indexed (1999)")
                case .exempt: String(localized: "Exempt")
                case .other: line.longTerm == false ? String(localized: "Short") : String(localized: "Full")
                }
            }.joined(separator: " + ")
        }
        if line.transitionMethod == .apportionment { text = String(localized: "\(text), apportioned") }
        if !line.inPeriod { text = String(localized: "\(text) · history") }
        return text
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
        if report.periodLines.isEmpty { notes.append(String(localized: "No parcels were sold in this period.")) }
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

    // MARK: Income (FR-RPT-02b — Income)

    /// The period’s investment income by holding — franked and unfranked
    /// dividends, franking credits, distributions, interest — and every
    /// payment under it (Sharesight’s Taxable Income report).
    func incomeDocument(from: Date, to: Date, periodLabel: String, portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = incomeReport(from: from, to: to, portfolioID: portfolioID) else { return nil }
        let code = report.currencyCode
        let columns = [String(localized: "Franked"), String(localized: "Unfranked"), String(localized: "Franking credits"),
                       String(localized: "Distributions"), String(localized: "Interest"), String(localized: "Other"),
                       String(localized: "Cash"), String(localized: "Grossed up")]
        let paymentColumns = [String(localized: "Date"), String(localized: "Kind"), String(localized: "Amount")]
        let rows = report.lines.map { line in
            InvestmentRow(portfolio: line.portfolio, rank: line.grossedUp, label: line.symbol,
                          cells: [.money(line.franked), .money(line.unfranked), .money(line.frankingCredits),
                                  .money(line.distributions), .money(line.interest), .money(line.other),
                                  .money(line.cash), .money(line.grossedUp)])
        }
        let payments = report.lines.map { line in
            ReportDocumentSection(
                title: String(localized: "\(line.symbol) payments"),
                rows: line.payments.sorted { $0.date < $1.date }.map { payment in
                    ReportDocumentRow(label: payment.isForeign ? String(localized: "\(payment.description) (foreign)") : payment.description,
                                      cells: [.date(payment.date), .text(eventLabel(payment.kind)), .money(payment.amount)])
                },
                columns: paymentColumns,
                identity: "payments:\(line.id.hexString)")
        }
        var notes = [
            String(localized: "Income the book records against each security in the period — in a transaction that touches the holding, or under an income account named for it. Franked, unfranked and franking credits come from the income account’s own name; distributions and interest from its parents; anything else is Other. Cash is what was paid; grossed up adds the franking credits, as a tax return does."),
            portfolioNote(portfolioID),
            String(localized: "Holdings are in order of grossed-up income, largest first; each holding’s payments follow the tables."),
        ]
        if report.totalForeign != 0 {
            notes.append(String(localized: "Foreign income in the period: \(AmountFormat.string(report.totalForeign, code: code)), converted on the day it was paid."))
        }
        if let note = unconvertedNote(report.unconvertedCurrencyCodes, code: code) { notes.append(note) }
        return ReportDocument(
            title: String(localized: "Income"), periodLabel: periodLabel, currencyCode: code,
            // No payments, no figures: the screen then says there is nothing
            // to report rather than showing three zeros.
            kpis: rows.isEmpty ? [] : [
                ReportKPI(label: String(localized: "Cash income"), amount: report.totalCash),
                ReportKPI(label: String(localized: "Franking credits"), amount: report.totalFrankingCredits),
                ReportKPI(label: String(localized: "Grossed up"), amount: report.totalGrossedUp)],
            chart: nil,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: columns) { summedCells($0, columns: columns.count) } + payments,
            notes: notes,
            facts: nil)
    }

    // MARK: Historical cost (FR-RPT-02 — Historical Cost)

    /// Each holding’s balance at cost at the period’s start and end, and the
    /// purchases, sales and adjustments between (Sharesight’s Historical Cost
    /// report), with the market value beside the closing cost.
    func historicalCostDocument(from: Date, to: Date, periodLabel: String, portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = historicalCost(from: from, to: to, portfolioID: portfolioID) else { return nil }
        let code = report.currencyCode
        let columns = [String(localized: "Opening units"), String(localized: "Opening cost"), String(localized: "Purchases"),
                       String(localized: "Cost of sales"), String(localized: "Adjustments"), String(localized: "Closing units"),
                       String(localized: "Closing cost"), String(localized: "Closing value")]
        let rows = report.lines.map { line in
            InvestmentRow(portfolio: line.portfolio, rank: line.closingCost, label: line.symbol,
                          cells: [.units(line.openingUnits), .money(line.openingCost), .money(line.purchases),
                                  .money(-line.costOfSales), .money(line.adjustments), .units(line.closingUnits),
                                  .money(line.closingCost), .money(line.closingValue)])
        }
        var notes = [
            String(localized: "Opening cost is the cost base of what was held the day before the period began; purchases add, the cost of sales takes the sold parcels out at their cost, adjustments are returns of capital and the like. Opening plus purchases less cost of sales plus adjustments reconciles to closing cost. Holdings are in order of closing cost, largest first."),
            methodNote(report.method),
            portfolioNote(portfolioID),
        ]
        if report.lines.contains(where: { !$0.reconciles }) {
            notes.append(String(localized: "A row whose movement does not reconcile to its closing cost is one whose parcels changed hands in a currency with no rate on the day; the figures shown are what could be converted."))
        }
        if let note = unpricedNote(report.unpricedSymbols) { notes.append(note) }
        if let note = unconvertedNote(report.unconvertedCurrencyCodes, code: code) { notes.append(note) }
        return ReportDocument(
            title: String(localized: "Historical Cost"), periodLabel: periodLabel, currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Opening cost"), amount: report.totalOpeningCost),
                   ReportKPI(label: String(localized: "Purchases"), amount: report.totalPurchases),
                   ReportKPI(label: String(localized: "Cost of sales"), amount: report.totalCostOfSales),
                   ReportKPI(label: String(localized: "Closing cost"), amount: report.totalClosingCost),
                   ReportKPI(label: String(localized: "Closing value"), amount: report.totalClosingValue)],
            chart: nil,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: columns) { summedCells($0, columns: columns.count) },
            notes: notes,
            facts: nil)
    }

    // MARK: Returns by period (FR-RPT-02b — Returns by Period)

    /// Each holding’s contribution in each of several periods, side by side,
    /// with its total return and annualised rate (Sharesight’s Multi-Period
    /// report).
    func multiPeriodReturnDocument(periods: [(label: String, from: Date, to: Date)], includeClosed: Bool = true,
                                   portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard !periods.isEmpty,
              let report = multiPeriodReturns(periods: periods.map { (from: $0.from, to: $0.to) },
                                              includeClosed: includeClosed, portfolioID: portfolioID)
        else { return nil }
        let code = report.currencyCode
        let columns = periods.map(\.label) + [String(localized: "Total return"), String(localized: "Annualised")]
        let rows = report.lines.map { line in
            InvestmentRow(portfolio: line.portfolio, rank: line.totalReturn, label: line.symbol,
                          cells: line.periodReturns.map { ReportCell.money($0) }
                              + [.money(line.totalReturn), percentCell(line.annualisedReturn)])
        }
        let last = periods.last.map { $0.to } ?? Date()
        let first = periods.first.map { $0.from } ?? last
        let bars = topBars(report.lines.map { ($0.symbol, $0.totalReturn) })
        let chart: ReportDocumentChart? = bars.isEmpty ? nil : .stackedBars(
            series: periods.map(\.label),
            bars: bars.compactMap { bar in
                report.lines.first { $0.symbol == bar.label }.map { (label: $0.symbol, values: $0.periodReturns.map { $0 ?? 0 }) }
            })
        return ReportDocument(
            title: String(localized: "Returns by Period"),
            periodLabel: String(localized: "\(shortDate(first)) – \(shortDate(last))"), currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Total return"), amount: report.totalReturn, signed: true)]
                + zip(periods, report.periodTotals).suffix(3).map { ReportKPI(label: $0.label, amount: $1 ?? 0, signed: true) },
            chart: chart,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: columns) { members in
                var cells = summedCells(members, columns: columns.count)
                cells[columns.count - 1] = .text("")
                return cells
            },
            notes: [
                String(localized: "Each period’s figure is the holding’s contribution over it: its total return at the period’s end less its total return the day before the period began — realised and unrealised gain, dividends and franking credits. A blank is a period the holding had no price at one end of. Total return and the annualised rate are since the first purchase, to the last period’s end."),
                String(localized: "The periods are financial years ending with the chosen period’s; the stepper sets how many."),
                methodNote(costBasisMethod),
                closedPositionsNote(included: includeClosed),
                portfolioNote(portfolioID),
                annualisedNote,
            ],
            facts: nil)
    }

    // MARK: Drawdown (FR-RPT-02 — Drawdown)

    /// Each held security’s worst fall over the period against its return
    /// (Sharesight’s Drawdown Risk report): how far it fell from a peak, when,
    /// and whether it has recovered.
    func drawdownDocument(from: Date, to: Date, periodLabel: String, portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = drawdownRisk(from: from, to: to, portfolioID: portfolioID) else { return nil }
        let code = report.currencyCode
        let columns = [String(localized: "Value"), String(localized: "Return"), String(localized: "Max drawdown"),
                       String(localized: "Peak"), String(localized: "Trough"), String(localized: "Recovered"),
                       String(localized: "Return ÷ drawdown")]
        let rows = report.lines.map { line in
            InvestmentRow(portfolio: line.portfolio,
                          rank: Decimal(-(line.drawdown?.fraction ?? 0)),
                          label: line.symbol,
                          cells: [.money(line.marketValue), percentCell(line.returnFraction),
                                  percentCell(line.drawdown.map { $0.fraction }),
                                  .date(line.drawdown?.peakDate), .date(line.drawdown?.troughDate),
                                  .text(line.drawdown.map { $0.recoveredDate.map { shortDate($0) } ?? String(localized: "Not yet") } ?? ""),
                                  .text(line.romad.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "")])
        }
        return ReportDocument(
            title: String(localized: "Drawdown"), periodLabel: periodLabel, currencyCode: code,
            kpis: [], chart: nil,
            sections: rows.isEmpty ? [] : investmentSections(rows, columns: columns) { members in
                var cells = summedCells(members, columns: columns.count)
                for column in 1..<columns.count { cells[column] = .text("") }
                return cells
            },
            notes: [
                String(localized: "Max drawdown is the largest fall from a peak to a later trough in the security’s price over the period, with the dates and the day the price regained its peak, if it has. Return is the price change over the period; return ÷ drawdown is Sharesight’s return over maximum drawdown, the return earned per unit of the worst fall. Securities are in order of drawdown, worst first."),
                portfolioNote(portfolioID),
                String(localized: "Only securities held at the period’s end, with prices in the period, appear."),
            ],
            facts: nil)
    }

    // MARK: Price history (FR-RPT — Price History)

    /// The Price History report, printable: the range’s statistics, the
    /// trades and income in it, and the month-end closes.
    func priceHistoryDocument(commodity: Commodity, from: Date, to: Date, periodLabel: String,
                              benchmark: PriceBenchmark? = nil, portfolioID: GncGUID? = nil) -> ReportDocument? {
        guard let report = priceHistory(commodity: commodity, from: from, to: to, benchmark: benchmark,
                                        portfolioID: portfolioID),
              let summary = report.summary else { return nil }
        let code = report.currencyCode
        func percent(_ value: Double?) -> String {
            value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? ""
        }
        var stats = [
            ReportDocumentRow(label: String(localized: "First price (\(shortDate(summary.first.date)))"), amount: summary.first.value),
            ReportDocumentRow(label: String(localized: "Last price (\(shortDate(summary.last.date)))"), amount: summary.last.value),
            ReportDocumentRow(label: String(localized: "Change (\(percent(summary.changeFraction)))"), amount: summary.change),
            ReportDocumentRow(label: String(localized: "High (\(shortDate(summary.high.date)))"), amount: summary.high.value),
            ReportDocumentRow(label: String(localized: "Low (\(shortDate(summary.low.date)))"), amount: summary.low.value),
        ]
        if let high = report.fiftyTwoWeekHigh, let low = report.fiftyTwoWeekLow {
            stats.append(ReportDocumentRow(label: String(localized: "52-week high (\(shortDate(high.date)))"), amount: high.value))
            stats.append(ReportDocumentRow(label: String(localized: "52-week low (\(shortDate(low.date)))"), amount: low.value))
        }
        if let average = report.averageCost, report.unitsHeld > 0 {
            stats.append(ReportDocumentRow(label: String(localized: "Average cost of \(report.unitsHeld.formatted()) units held"), amount: average))
        }
        var readings: [String] = []
        if report.priceWithIncome != report.series, let withIncome = report.priceWithIncomeChangeFraction {
            readings.append(String(localized: "With the income paid per unit added: \(percent(withIncome)) over the range, against \(percent(summary.changeFraction)) on price alone."))
        }
        if let label = report.benchmarkLabel ?? report.benchmark.map({ _ in String(localized: "cash") }),
           let change = report.benchmarkChangeFraction {
            readings.append(String(localized: "Benchmark \(label): \(percent(change)) over the range."))
        }
        if let volatility = report.volatility {
            readings.append(String(localized: "Annualised volatility: \(percent(volatility))."))
        }
        if let drawdown = report.drawdown {
            let recovered = drawdown.recoveredDate.map { String(localized: "recovered \(shortDate($0))") } ?? String(localized: "not yet recovered")
            readings.append(String(localized: "Largest fall: \(percent(drawdown.fraction)) from \(shortDate(drawdown.peakDate)) to \(shortDate(drawdown.troughDate)), \(recovered)."))
        }
        if let trend = report.trend {
            let word = switch trend {
            case .rising: String(localized: "rising")
            case .flat: String(localized: "flat")
            case .falling: String(localized: "falling")
            }
            readings.append(String(localized: "Trend over the range: \(word)."))
        }
        if let rsi = report.latestRSI {
            let reading = rsi >= 70 ? String(localized: "overbought") : rsi <= 30 ? String(localized: "oversold") : String(localized: "neutral")
            readings.append(String(localized: "RSI (14): \(rsi.formatted(.number.precision(.fractionLength(0)))), \(reading)."))
        }
        for crossover in report.crossovers {
            readings.append(crossover.kind == .golden
                ? String(localized: "Golden cross on \(shortDate(crossover.date)): the 50-day average rose through the 200-day.")
                : String(localized: "Death cross on \(shortDate(crossover.date)): the 50-day average fell through the 200-day."))
        }
        var sections = [ReportDocumentSection(title: String(localized: "Range"), rows: stats)]
        let eventColumns = [String(localized: "Date"), String(localized: "Event"), String(localized: "Units"), String(localized: "Amount")]
        if !report.trades.isEmpty {
            sections.append(ReportDocumentSection(
                title: String(localized: "Trades in the range"),
                rows: report.trades.map { event in
                    ReportDocumentRow(label: event.description, cells: [
                        .date(event.date), .text(eventLabel(event.kind)), .units(event.units), .money(event.amount)])
                },
                columns: eventColumns))
        }
        if !report.income.isEmpty {
            sections.append(ReportDocumentSection(
                title: String(localized: "Income in the range"),
                rows: report.income.map { event in
                    ReportDocumentRow(label: event.description, cells: [
                        .date(event.date), .text(eventLabel(event.kind)), .units(nil), .money(event.amount)])
                },
                columns: eventColumns))
        }
        if report.monthlyCloses.count > 1 {
            var previous: Decimal?
            sections.append(ReportDocumentSection(
                title: String(localized: "Month-end closes"),
                rows: report.monthlyCloses.map { close in
                    let change: Decimal? = previous.flatMap { $0 != 0 ? (close.value - $0) / $0 : nil }
                    previous = close.value
                    return ReportDocumentRow(label: AppDateFormat.current.monthYear(close.date),
                                             cells: [.money(close.value), .percent(change)])
                },
                columns: [String(localized: "Close"), String(localized: "Change")]))
        }
        var notes = [String(localized: "Prices as recorded in the book, in the report currency; the 50- and 200-day averages, the RSI and the crosses are computed on them, with earlier prices warming the averages. Nothing here is a recommendation.")]
        if let note = unconvertedNote(report.unconvertedCurrencyCodes, code: code) { notes.append(note) }
        return ReportDocument(
            title: String(localized: "Price History — \(commodity.mnemonic)"), periodLabel: periodLabel, currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Last price"), amount: summary.last.value),
                   ReportKPI(label: String(localized: "Change"), amount: summary.change, signed: true),
                   ReportKPI(label: String(localized: "High"), amount: summary.high.value),
                   ReportKPI(label: String(localized: "Low"), amount: summary.low.value)],
            summary: readings, chart: nil,
            sections: sections, notes: notes, facts: nil)
    }

    /// The printable for the first security with prices over all time —
    /// what the report shows before a security is chosen.
    func priceHistoryDocument() -> ReportDocument? {
        guard let commodity = securitiesWithPriceHistory.first else { return nil }
        return cachedReport("pricehistorydoc:\(commodity.namespace)|\(commodity.mnemonic):\(reportCurrency.mnemonic):\(AppDateFormat.current.order.rawValue)") {
            priceHistoryDocument(commodity: commodity, from: .distantPast, to: Self.endOfToday(),
                                 periodLabel: String(localized: "All recorded prices"))
        }
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
