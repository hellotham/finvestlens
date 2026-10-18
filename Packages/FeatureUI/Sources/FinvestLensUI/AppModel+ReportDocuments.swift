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

    // MARK: Portfolio (FR-RPT-02)

    func portfolioDocument(asOf: Date = Date()) -> ReportDocument? {
        guard let portfolio = advancedPortfolio(asOf: asOf) else { return nil }
        let code = portfolio.currencyCode
        let rows = portfolio.holdings.map { h -> ReportDocumentRow in
            let detail = h.income != 0
                ? String(localized: "\(h.symbol)  \(h.shares.formatted()) sh  · income \(AmountFormat.string(h.income, code: code))")
                : String(localized: "\(h.symbol)  \(h.shares.formatted()) sh")
            return ReportDocumentRow(label: detail, amount: h.marketValue ?? 0)
        }
        var kpis = [ReportKPI(label: String(localized: "Cost basis"), amount: portfolio.totalCost),
                    ReportKPI(label: String(localized: "Market value"), amount: portfolio.totalValue),
                    ReportKPI(label: String(localized: "Unrealised"), amount: portfolio.totalUnrealized, signed: true)]
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
            sections: [ReportDocumentSection(title: String(localized: "Holdings"), rows: rows,
                                             total: (String(localized: "Market value"), portfolio.totalValue))],
            notes: [String(localized: "Securities valued at their most recent price; unpriced holdings show zero value.")],
            facts: nil)
    }

    // MARK: Investment lots (FR-RPT-02)

    func investmentLotsDocument(asOf: Date = Date()) -> ReportDocument? {
        let lots = investmentLots(asOf: asOf)
        guard !lots.isEmpty else { return nil }
        let code = reportCurrency.mnemonic
        let rows = lots.map { lot -> ReportDocumentRow in
            let cost = AmountFormat.string(lot.costBasis, code: code)
            let label = lot.acquisitionDate.map {
                String(localized: "\(lot.symbol)  \(lot.quantity.formatted()) @ cost \(cost) acq \(shortDate($0))")
            } ?? String(localized: "\(lot.symbol)  \(lot.quantity.formatted()) @ cost \(cost)")
            return ReportDocumentRow(label: label, amount: lot.marketValue ?? lot.costBasis)
        }
        let totalCost = lots.reduce(Decimal(0)) { $0 + $1.costBasis }
        return ReportDocument(
            title: String(localized: "Investment Lots"), periodLabel: String(localized: "As of \(shortDate(asOf))"), currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Open lots"), amount: Decimal(lots.count)),
                   ReportKPI(label: String(localized: "Cost basis"), amount: totalCost)],
            chart: nil,
            sections: [ReportDocumentSection(title: String(localized: "Open Lots (\(costBasisMethod.displayName))"),
                                             rows: rows, total: (String(localized: "Cost basis"), totalCost))],
            notes: [], facts: nil)
    }

    // MARK: Capital gains (FR-RPT-03)

    func capitalGainsDocument(from: Date = .distantPast, to: Date = .distantFuture) -> ReportDocument? {
        guard let report = capitalGains(from: from, to: to) else { return nil }
        let code = report.currencyCode
        let rows = report.lines.map { line -> ReportDocumentRow in
            let quantity = line.quantity.formatted()
            let sold = shortDate(line.disposalDate)
            // LT and ST: held over a year, or not — the abbreviations a tax
            // return uses, and a phrase each so each language has its own.
            let label = switch line.longTerm {
            case true?: String(localized: "\(line.symbol) (LT)  \(quantity) sold \(sold)")
            case false?: String(localized: "\(line.symbol) (ST)  \(quantity) sold \(sold)")
            case nil: String(localized: "\(line.symbol)  \(quantity) sold \(sold)")
            }
            return ReportDocumentRow(label: label, amount: line.gain)
        }
        return ReportDocument(
            title: String(localized: "Capital Gains"),
            periodLabel: String(localized: "\(report.method.displayName) cost basis"),
            currencyCode: code,
            kpis: [ReportKPI(label: String(localized: "Short-term"), amount: report.shortTermGain, signed: true),
                   ReportKPI(label: String(localized: "Long-term"), amount: report.longTermGain, signed: true),
                   ReportKPI(label: String(localized: "Total realised"), amount: report.totalGain, signed: true)],
            chart: nil,
            sections: rows.isEmpty ? [] : [ReportDocumentSection(
                title: String(localized: "Realised Gains"), rows: rows, total: (String(localized: "Total realised"), report.totalGain))],
            notes: capitalGainsNotes(report),
            facts: nil)
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
