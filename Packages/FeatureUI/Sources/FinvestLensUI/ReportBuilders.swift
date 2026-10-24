//
//  ReportBuilders.swift
//  FinvestLens — FeatureUI
//
//  From a configuration to a document: resolve the period under the book's
//  financial-year convention, run the engine computation (one book walk since
//  the one-pass rewrite), and lay the result out as KPIs, tables, charts and
//  notes. The builders are the only place a report's presentation is decided,
//  and the PDF prints the same value.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

@MainActor
extension AppModel {

    /// The default scope for the cash-flow report: the accounts statements
    /// arrive for. Money is *followed through* bank and cash accounts; an
    /// expense account has no statement to check against.
    var defaultCashFlowAccountIDs: Set<GncGUID> {
        guard let book else { return [] }
        return Set(book.accounts
            .filter { !$0.isPlaceholder && ($0.type == .bank || $0.type == .cash) }
            .map(\.guid))
    }

    /// Net worth at each month end across a window — the chart the dashboard
    /// draws, generalised to any period.
    func netWorthPoints(from: Date, to: Date) -> [NetWorthPoint] {
        guard let book else { return [] }
        return cachedReport("nwp:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            netWorthPointsUncached(book: book, from: from, to: to)
        } ?? []
    }

    private func netWorthPointsUncached(book: Book, from: Date, to: Date) -> [NetWorthPoint] {
        // All-time starts where the book does, not at the epoch.
        let earliest = book.transactions.map(\.datePosted).min() ?? to
        let start = max(from, earliest)
        let calendar = Calendar.current

        var dates: [Date] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        while cursor <= to {
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor)!
            dates.append(min(nextMonth.addingTimeInterval(-1), to))
            cursor = nextMonth
        }
        if dates.isEmpty { dates = [to] }
        return FinancialReports.netWorthSeries(book, dates: dates, currency: reportCurrency)
    }

    /// Builds the slow parts of the report `configuration` asks for — the lot
    /// engine's reports, an account's postings — on a replica, off the main
    /// actor, so that ``reportDocument(for:)`` finds them in the memo and
    /// only assembles the document here (P3.3). The account and period are
    /// resolved exactly as the document resolves them.
    func warmReports(for configuration: ReportConfiguration) async {
        guard book != nil, let kind = ReportKind(rawValue: configuration.kind),
              kind.usesScaffold else { return }
        let (from, to) = resolve(configuration.period)
        switch kind {
        case .transactions:
            await warm(transactionsReportRequest(accountIDs: configuration.accountIDs, from: from, to: to))
        case .reconcile:
            guard let account = configuration.accountIDs?.first ?? selectedAccountID
                ?? postableAccounts.first?.id else { return }
            await warm(reconcileReportRequest(accountID: account, asOf: to))
        case .portfolio where !securityCommodities.isEmpty:
            await warm(advancedPortfolioRequest(asOf: to, includeClosed: configuration.includeClosed ?? false))
        case .investmentReturn where !securityCommodities.isEmpty:
            await warm(investmentReturnRequest(asOf: to, includeClosed: configuration.includeClosed ?? true))
        case .investmentLots where !securityCommodities.isEmpty:
            await warm(investmentLotsRequest(asOf: to))
        case .capitalGains where !securityCommodities.isEmpty:
            await warm(capitalGainsRequest(from: from, to: to))
        case .averageBalance:
            let scope = configuration.accountIDs ?? defaultCashFlowAccountIDs
            guard !scope.isEmpty else { return }
            await warm(averageBalanceRequest(accountIDs: scope, from: from, to: to,
                                             step: configuration.step ?? .month))
        default:
            break
        }
    }

    /// Builds the document for a scaffold report, or `nil` for kinds that keep
    /// interactive views (or a book that is not open).
    func reportDocument(for configuration: ReportConfiguration) -> ReportDocument? {
        guard book != nil, let kind = ReportKind(rawValue: configuration.kind),
              kind.usesScaffold else { return nil }

        let (from, to) = resolve(configuration.period)
        let asOfLabel = String(localized: "As of \(AppDateFormat.current.full(to))")
        let periodLabel = kind.isAsOf ? asOfLabel : label(for: configuration.period)

        switch kind {
        case .balanceSheet:
            if let columns = comparisonColumns(configuration.period,
                                               extra: configuration.comparePeriods ?? 0) {
                return comparativeBalanceSheet(columns)
            }
            guard let sheet = balanceSheet(asOf: to) else { return nil }
            return ReportDocument(
                title: String(localized: "Balance Sheet"),
                periodLabel: periodLabel,
                currencyCode: sheet.currencyCode,
                kpis: [
                    ReportKPI(label: String(localized: "Assets"), amount: sheet.totalAssets),
                    ReportKPI(label: String(localized: "Liabilities"), amount: sheet.totalLiabilities),
                    ReportKPI(label: String(localized: "Net worth"),
                              amount: sheet.totalAssets - sheet.totalLiabilities, signed: true),
                ],
                chart: nil,
                sections: [
                    section(String(localized: "Assets"), sheet.assets, total: (String(localized: "Total Assets"), sheet.totalAssets)),
                    section(String(localized: "Liabilities"), sheet.liabilities,
                            total: (String(localized: "Total Liabilities"), sheet.totalLiabilities)),
                    ReportDocumentSection(
                        title: String(localized: "Equity"),
                        rows: accountTreeRows([sheet.equity]).map {
                            ReportDocumentRow(label: $0.label, depth: $0.depth, amount: $0.amounts[0])
                        } + [ReportDocumentRow(label: String(localized: "Retained earnings"),
                                               amount: sheet.retainedEarnings)],
                        total: (String(localized: "Total Equity"), sheet.totalEquity)),
                ],
                notes: [valuationNote(to),
                        String(localized: "Retained earnings fold lifetime income less expenses into equity, so the sheet balances.")],
                facts: balanceSheetFacts(assets: sheet.totalAssets, liabilities: sheet.totalLiabilities,
                                         equity: sheet.totalEquity,
                                         lines: ranked((sheet.assets, .balance), (sheet.liabilities, .balance))))

        case .incomeStatement:
            if let columns = comparisonColumns(configuration.period,
                                               extra: configuration.comparePeriods ?? 0) {
                return comparativeIncomeStatement(columns)
            }
            guard let statement = incomeStatement(from: from, to: to) else { return nil }
            return ReportDocument(
                title: String(localized: "Income Statement"),
                periodLabel: periodLabel,
                currencyCode: statement.currencyCode,
                kpis: [
                    ReportKPI(label: String(localized: "Income"), amount: statement.totalIncome),
                    ReportKPI(label: String(localized: "Expenses"), amount: statement.totalExpenses),
                    ReportKPI(label: String(localized: "Net income"), amount: statement.netIncome, signed: true),
                ],
                chart: nil,
                sections: [
                    section(String(localized: "Income"), statement.income,
                            total: (String(localized: "Total Income"), statement.totalIncome)),
                    section(String(localized: "Expenses"), statement.expenses,
                            total: (String(localized: "Total Expenses"), statement.totalExpenses)),
                ],
                notes: [valuationNote(to)],
                facts: incomeStatementFacts(income: statement.totalIncome, expenses: statement.totalExpenses,
                                            net: statement.netIncome,
                                            lines: ranked((statement.income, .inflow), (statement.expenses, .outflow))))

        case .equityStatement:
            guard let statement = equityStatement(from: from, to: to) else { return nil }
            return ReportDocument(
                title: String(localized: "Equity Statement"),
                periodLabel: periodLabel,
                currencyCode: statement.currencyCode,
                kpis: [
                    ReportKPI(label: String(localized: "Opening capital"), amount: statement.openingCapital),
                    ReportKPI(label: String(localized: "Closing capital"), amount: statement.closingCapital),
                    ReportKPI(label: String(localized: "Net income"), amount: statement.netIncome, signed: true),
                ],
                chart: nil,
                sections: [ReportDocumentSection(
                    title: String(localized: "Movement in capital"),
                    rows: [
                        ReportDocumentRow(label: String(localized: "Opening capital"),
                                          amount: statement.openingCapital),
                        ReportDocumentRow(label: String(localized: "Net income"), amount: statement.netIncome),
                        ReportDocumentRow(label: String(localized: "Contributions"),
                                          amount: statement.contributions),
                        ReportDocumentRow(label: String(localized: "Withdrawals"),
                                          amount: -statement.withdrawals),
                        ReportDocumentRow(label: String(localized: "Unrealised gains and FX"),
                                          amount: statement.unrealisedChange),
                    ],
                    total: (String(localized: "Closing capital"), statement.closingCapital))],
                notes: [String(localized: "The unrealised line is the valuation change the period’s postings cannot account for: market moves and FX revaluation."),
                        valuationNote(to)],
                facts: {
                    let opening = String(localized: "Opening capital")
                    let closing = String(localized: "Closing capital")
                    let net = String(localized: "Net income")
                    let unrealised = String(localized: "Unrealised change")
                    var roles: [String: FigureRole] = [opening: .openingBalance, closing: .balance, net: .change]
                    if statement.unrealisedChange != 0 {
                        roles[unrealised] = statement.unrealisedChange > 0 ? .gain : .loss
                    }
                    return ReportFactsSource(
                        headline: [(opening, statement.openingCapital), (closing, statement.closingCapital),
                                   (net, statement.netIncome), (unrealised, statement.unrealisedChange)],
                        lines: [], roles: roles)
                }())

        case .trialBalance:
            guard let report = trialBalance(asOf: to) else { return nil }
            return ReportDocument(
                title: String(localized: "Trial Balance"),
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: String(localized: "Debits"), amount: report.totalDebits),
                    ReportKPI(label: String(localized: "Credits"), amount: report.totalCredits),
                    ReportKPI(label: String(localized: "Unrealised adjustment"),
                              amount: report.unrealisedAdjustment, signed: true),
                ],
                chart: nil,
                sections: [ReportDocumentSection(
                    title: String(localized: "Balances"),
                    rows: report.rows.map { row in
                        ReportDocumentRow(label: row.fullName,
                                          debit: row.debit, credit: row.credit)
                    },
                    total: (String(localized: "Totals"), report.totalDebits),
                    isDebitCredit: true)],
                notes: [String(localized: "Balances in the raw double-entry convention. The unrealised adjustment is what valuing holdings at market adds over cost — printed, not hidden, because it is the number that makes the columns agree."),
                        valuationNote(to)],
                facts: nil)

        case .accountSummary:
            let depth = min(configuration.depth ?? accountTreeDepth, accountTreeDepth)
            guard let report = accountSummary(asOf: to, depthLimit: depth) else { return nil }
            let assets = report.sections.first { $0.title == "Assets" }?.total ?? 0
            let liabilities = report.sections.first { $0.title == "Liabilities" }?.total ?? 0
            return ReportDocument(
                title: String(localized: "Account Summary"),
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: String(localized: "Assets"), amount: assets),
                    ReportKPI(label: String(localized: "Liabilities"), amount: liabilities),
                    ReportKPI(label: String(localized: "Net worth"), amount: assets - liabilities, signed: true),
                ],
                chart: nil,
                sections: report.sections.map { section in
                    let title = Self.accountClassName(section.title)
                    return ReportDocumentSection(
                        title: title,
                        rows: section.rows.flatMap { row in
                            var rows = [ReportDocumentRow(label: row.name, depth: row.depth - 1,
                                                          amount: row.balance)]
                            if row.hasChildren, row.own != 0 {
                                rows.append(ReportDocumentRow(label: String(localized: "\(row.name) (direct)"),
                                                              depth: row.depth, amount: row.own))
                            }
                            return rows
                        },
                        total: (String(localized: "Total \(title)"), section.total))
                },
                notes: [depth >= accountTreeDepth
                        ? String(localized: "Every level of the chart of accounts is shown, each account with everything beneath it. Income and expense balances are lifetime to date.")
                        : String(localized: "Accounts deeper than level \(depth) roll into their ancestor, so every depth sums to the same totals. Income and expense balances are lifetime to date."),
                        valuationNote(to)],
                facts: nil)

        case .netWorth:
            let points = netWorthPoints(from: from, to: to)
            guard let first = points.first, let last = points.last else { return nil }
            return ReportDocument(
                title: String(localized: "Net Worth"),
                periodLabel: periodLabel,
                currencyCode: reportCurrency.mnemonic,
                kpis: [
                    ReportKPI(label: String(localized: "Start"), amount: first.netWorth),
                    ReportKPI(label: String(localized: "End"), amount: last.netWorth),
                    ReportKPI(label: String(localized: "Change"),
                              amount: last.netWorth - first.netWorth, signed: true),
                ],
                chart: .line(points),
                sections: [],
                notes: [String(localized: "Month-end net worth: assets less liabilities, converted at each date’s rates."),
                        valuationNote(to)],
                facts: {
                    let start = String(localized: "Start"), end = String(localized: "End")
                    let change = String(localized: "Change")
                    return ReportFactsSource(
                        headline: [(start, first.netWorth), (end, last.netWorth),
                                   (change, last.netWorth - first.netWorth)],
                        lines: [],
                        roles: [start: .openingBalance, end: .balance, change: .change],
                        relations: [change: FigureRelation(end, less: start)])
                }())

        case .cashFlow:
            let scope = configuration.accountIDs ?? defaultCashFlowAccountIDs
            guard let report = cashFlow(accountIDs: scope, from: from, to: to) else { return nil }
            return ReportDocument(
                title: String(localized: "Cash Flow"),
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: Self.moneyIn, amount: report.totalIn),
                    ReportKPI(label: Self.moneyOut, amount: report.totalOut),
                    ReportKPI(label: String(localized: "Net change"), amount: report.netChange, signed: true),
                ],
                chart: nil,
                sections: [
                    // Largest first, as the cash-flow report orders them.
                    section(String(localized: "Money in, from"), report.inflows,
                            total: (String(localized: "Total in"), report.totalIn),
                            order: .largestFirst),
                    section(String(localized: "Money out, to"), report.outflows,
                            total: (String(localized: "Total out"), report.totalOut),
                            order: .largestFirst),
                ],
                notes: [String(localized: "Flows through \(report.accountNames.count) account(s): \(Self.listed(report.accountNames))."),
                        String(localized: "Transfers wholly inside the selected accounts are internal and excluded; by double entry, in minus out equals their net change.")],
                facts: {
                    // The sources and destinations are unsigned; their side
                    // goes with them, or a card paid off reads as money out.
                    let net = String(localized: "Net change")
                    let top = ranked((report.inflows, .inflow), (report.outflows, .outflow))
                    return ReportFactsSource(
                        headline: [(Self.moneyIn, report.totalIn), (Self.moneyOut, report.totalOut),
                                   (net, report.netChange)],
                        lines: top.lines,
                        roles: [Self.moneyIn: .inflow, Self.moneyOut: .outflow, net: .change],
                        relations: [net: FigureRelation(Self.moneyIn, less: Self.moneyOut)],
                        lineRoles: top.roles)
                }())

        case .incomeExpense:
            guard let breakdown = categoryBreakdown(from: from, to: to) else { return nil }
            return ReportDocument(
                title: String(localized: "Income & Expense"),
                periodLabel: periodLabel,
                currencyCode: breakdown.currencyCode,
                kpis: [
                    ReportKPI(label: String(localized: "Income"), amount: breakdown.totalIncome),
                    ReportKPI(label: String(localized: "Expenses"), amount: breakdown.totalExpenses),
                    ReportKPI(label: String(localized: "Net"),
                              amount: breakdown.totalIncome - breakdown.totalExpenses,
                              signed: true),
                ],
                chart: .monthlyBars(breakdown.months),
                sections: [
                    // Each category broken down into its subcategories, every
                    // level, largest first — the top rows are the slices to
                    // the cent, because each node is rounded once from the
                    // exact amounts beneath it.
                    section(String(localized: "Spending by category"), breakdown.expenseAccounts,
                            total: (String(localized: "Total Expenses"), breakdown.totalExpenses),
                            order: .largestFirst, round: reportCurrency.round),
                    section(String(localized: "Income by category"), breakdown.incomeAccounts,
                            total: (String(localized: "Total Income"), breakdown.totalIncome),
                            order: .largestFirst, round: reportCurrency.round),
                ],
                notes: [String(localized: "Each category is broken down into its subcategories at every level, and includes everything beneath it; the top-level categories sum to the income statement for the same period.")],
                facts: {
                    let income = String(localized: "Income"), expenses = String(localized: "Expenses")
                    let top = ranked((breakdown.expenseSlices, .outflow), (breakdown.incomeSlices, .inflow))
                    return ReportFactsSource(
                        headline: [(income, breakdown.totalIncome), (expenses, breakdown.totalExpenses)],
                        lines: top.lines, roles: [income: .inflow, expenses: .outflow],
                        lineRoles: top.roles)
                }())

        case .averageBalance:
            let scope = configuration.accountIDs ?? defaultCashFlowAccountIDs
            let step = configuration.step ?? .month
            guard let report = averageBalance(accountIDs: scope, from: from, to: to,
                                              step: step) else { return nil }
            let average = report.overallAverage ?? 0
            return ReportDocument(
                title: String(localized: "Average Balance"),
                periodLabel: periodLabel,
                currencyCode: report.currencyCode,
                kpis: [
                    ReportKPI(label: String(localized: "Average balance"), amount: average),
                    ReportKPI(label: String(localized: "Total in"), amount: report.totalGain),
                    ReportKPI(label: String(localized: "Total out"), amount: report.totalLoss),
                ],
                chart: report.intervals.isEmpty ? nil : .averageBars(report.intervals),
                sections: [
                    ReportDocumentSection(
                        title: Self.intervalTitle(step),
                        rows: report.intervals.map { interval in
                            ReportDocumentRow(
                                label: intervalLabel(interval),
                                amounts: [interval.average, interval.minimum, interval.maximum,
                                          interval.gain, interval.loss])
                        },
                        columns: [String(localized: "Average"), String(localized: "Minimum"), String(localized: "Maximum"), String(localized: "Gain"), String(localized: "Loss")],
                        columnTotals: (String(localized: "Weighted average / totals"),
                                       [average, nil, nil, report.totalGain, report.totalLoss])),
                ],
                notes: [String(localized: "Balances are sampled at each day’s end; an interval’s average is the mean of its daily balances."),
                        String(localized: "Across \(report.accountNames.count) account(s): \(Self.listed(report.accountNames))."),
                        String(localized: "Foreign-currency accounts convert at each day’s rate; an account with no rate contributes nothing that day.")],
                facts: {
                    let totalIn = String(localized: "Total in"), totalOut = String(localized: "Total out")
                    return ReportFactsSource(
                        headline: [(String(localized: "Average balance"), average), (totalIn, report.totalGain),
                                   (totalOut, report.totalLoss)],
                        lines: report.intervals.map { (intervalLabel($0), $0.average) },
                        roles: [totalIn: .inflow, totalOut: .outflow])
                }())

        case .receivableAging, .payableAging:
            let receivable = kind == .receivableAging
            guard let book else { return nil }
            let rows = book.agingByOwner(receivable: receivable, asOf: to)
            let code = reportCurrency.mnemonic
            let columns = [String(localized: "Current"), "31–60", "61–90", "91+", String(localized: "Total")]
            func amounts(_ b: AgingBuckets) -> [Decimal?] {
                [b.current, b.days31to60, b.days61to90, b.over90, b.total]
            }
            let totals = rows.reduce(into: AgingBuckets()) { acc, row in
                acc.current += row.buckets.current
                acc.days31to60 += row.buckets.days31to60
                acc.days61to90 += row.buckets.days61to90
                acc.over90 += row.buckets.over90
            }
            return ReportDocument(
                title: receivable ? String(localized: "Receivable Aging") : String(localized: "Payable Aging"),
                periodLabel: asOfLabel,
                currencyCode: code,
                kpis: [
                    ReportKPI(label: receivable ? String(localized: "Owed to you") : String(localized: "You owe"), amount: totals.total),
                    ReportKPI(label: String(localized: "Current"), amount: totals.current),
                    ReportKPI(label: String(localized: "Over 90 days"), amount: totals.over90, signed: true),
                ],
                chart: nil,
                sections: [ReportDocumentSection(
                    title: receivable ? String(localized: "Customers") : String(localized: "Vendors"),
                    rows: rows.map { ReportDocumentRow(label: $0.name, amounts: amounts($0.buckets)) },
                    columns: columns,
                    columnTotals: (String(localized: "Total"), amounts(totals)))],
                notes: [String(localized: "Open invoices are aged by their due date as of \(AppDateFormat.current.long(to)) into 0–30 (current), 31–60, 61–90 and 91+ day buckets.")],
                facts: {
                    // What is owed as at the report's date, in total, by age
                    // and by party: balances, not amounts that moved.
                    let total = String(localized: "Total"), current = String(localized: "Current")
                    let over90 = String(localized: "Over 90 days")
                    return ReportFactsSource(
                        headline: [(total, totals.total), (current, totals.current), (over90, totals.over90)],
                        lines: rows.map { ($0.name, $0.buckets.total) },
                        roles: [total: .balance, current: .balance, over90: .balance],
                        lineRoles: rows.map { _ in .balance })
                }())

        case .customerSummary:
            guard let book else { return nil }
            return ownerSummary(.customers, asOf: to, asOfLabel: asOfLabel,
                                owners: book.customers.map { ($0.guid, $0.name) })

        case .vendorSummary:
            guard let book else { return nil }
            return ownerSummary(.vendors, asOf: to, asOfLabel: asOfLabel,
                                owners: book.vendors.map { ($0.guid, $0.name) })

        case .employeeSummary:
            guard let book else { return nil }
            return ownerSummary(.employees, asOf: to, asOfLabel: asOfLabel,
                                owners: book.employees.map { ($0.guid, $0.username) })

        case .jobSummary:
            guard let book else { return nil }
            return ownerSummary(.jobs, asOf: to, asOfLabel: asOfLabel,
                                owners: book.jobs.map { ($0.guid, $0.name) })

        case .spendingInsights:
            return spendingInsightsDocument(period: configuration.period)
        case .transactions:
            return transactionsDocument(accountIDs: configuration.accountIDs, from: from, to: to)
        case .reconcile:
            guard let account = configuration.accountIDs?.first ?? selectedAccountID
                ?? postableAccounts.first?.id else { return nil }
            return reconcileDocument(accountID: account, asOf: to)
        case .portfolio:
            return portfolioDocument(asOf: to, includeClosed: configuration.includeClosed ?? false)
        case .investmentReturn:
            return investmentReturnDocument(asOf: to, includeClosed: configuration.includeClosed ?? true)
        case .investmentLots:
            return investmentLotsDocument(asOf: to)
        case .capitalGains:
            return capitalGainsDocument(from: from, to: to)
        default:
            return nil
        }
    }

    /// One row per party — charged / paid / outstanding over its posted
    /// documents, most-charged first — the shared shape behind the Customer,
    /// Vendor, Employee and Job summaries (GnuCash's per-owner reports). Parties
    /// with no posted document are omitted.
    private func ownerSummary(_ parties: OwnerSummaryWording,
                              asOf to: Date, asOfLabel: String,
                              owners: [(guid: GncGUID, name: String)]) -> ReportDocument? {
        guard let book else { return nil }
        let chargedNoun = parties.charged
        let code = reportCurrency.mnemonic
        struct Row { var name: String; var charged: Decimal = 0; var outstanding: Decimal = 0 }
        var rows: [Row] = []
        for owner in owners {
            let posted = book.invoices(forOwner: owner.guid).filter { $0.isPosted }
            guard !posted.isEmpty else { continue }
            var row = Row(name: owner.name)
            for invoice in posted {
                row.charged += invoice.total
                row.outstanding += book.outstanding(invoice)
            }
            rows.append(row)
        }
        rows.sort { $0.charged > $1.charged }
        let columns = [chargedNoun, String(localized: "Paid"), String(localized: "Outstanding")]
        func amounts(_ r: Row) -> [Decimal?] {
            [r.charged, r.charged - r.outstanding, r.outstanding]
        }
        let totalCharged = rows.reduce(Decimal(0)) { $0 + $1.charged }
        let totalOutstanding = rows.reduce(Decimal(0)) { $0 + $1.outstanding }
        return ReportDocument(
            title: parties.title,
            periodLabel: asOfLabel,
            currencyCode: code,
            kpis: [
                ReportKPI(label: parties.totalCharged, amount: totalCharged),
                ReportKPI(label: String(localized: "Paid"), amount: totalCharged - totalOutstanding),
                ReportKPI(label: String(localized: "Outstanding"), amount: totalOutstanding),
            ],
            chart: nil,
            sections: [ReportDocumentSection(
                title: parties.entity,
                rows: rows.map { ReportDocumentRow(label: $0.name, amounts: amounts($0)) },
                columns: columns,
                columnTotals: (String(localized: "Total"),
                               [totalCharged, totalCharged - totalOutstanding, totalOutstanding]))],
            notes: [String(localized: "Totals cover posted documents only, as of \(AppDateFormat.current.long(to))."),
                    parties.paidNote],
            facts: {
                let paid = String(localized: "Paid"), outstanding = String(localized: "Outstanding")
                return ReportFactsSource(
                    headline: [(chargedNoun, totalCharged), (paid, totalCharged - totalOutstanding),
                               (outstanding, totalOutstanding)],
                    lines: rows.map { ($0.name, $0.charged) },
                    roles: [outstanding: .balance],
                    relations: [paid: FigureRelation(chargedNoun, less: outstanding)])
            }())
    }

    /// A short label for one average-balance interval — the start date, since
    /// intervals abut (each ends the day before the next begins).
    private func intervalLabel(_ interval: AverageBalanceInterval) -> String {
        AppDateFormat.current.long(interval.start)
    }

    // MARK: Comparative statements

    /// The period columns for a comparative statement: the selected period plus
    /// `extra` earlier periods of the same length, most recent first. `nil` when
    /// no comparison is asked for, or the period does not tile the calendar.
    func comparisonColumns(_ period: ReportPeriod, extra: Int)
        -> [(label: String, from: Date, to: Date)]? {
        guard extra > 0, let stride = period.comparisonStride else { return nil }
        let calendar = Calendar.current
        var back = DateComponents()
        back.year = stride.year.map { -$0 }
        back.month = stride.month.map { -$0 }
        back.day = stride.day.map { -$0 }

        var columns: [(label: String, from: Date, to: Date)] = []
        var (from, to) = resolve(period)
        for _ in 0...extra {
            columns.append((comparisonLabel(from: from, to: to, stride: stride), from, to))
            from = calendar.date(byAdding: back, to: from)!
            to = calendar.date(byAdding: back, to: to)!
        }
        return columns
    }

    /// A compact column header for one comparative period, from its window and
    /// the stride: "FY 2024–25", "2025", "Q3 2025", or "Aug 2025".
    private func comparisonLabel(from: Date, to: Date, stride: DateComponents) -> String {
        let calendar = Calendar.current
        let fromMonth = calendar.component(.month, from: from)
        let fromYear = calendar.component(.year, from: from)
        let toYear = calendar.component(.year, from: to)
        if stride.year == 1 {
            // Bare year for January-start FYs (compact column headers); the FY
            // designation itself comes from the one shared formatter.
            return fromMonth == 1 ? "\(fromYear)"
                : ReportPeriod.financialYearLabel(fromYear: fromYear, toYear: toYear)
        }
        if stride.month == 3 {
            // The year as text: as a number it would be grouped ("2,026").
            return String(localized: "Q\((fromMonth - 1) / 3 + 1) \(String(fromYear))")
        }
        if stride.month == 1 {
            return AppDateFormat.current.monthYear(from)
        }
        return AppDateFormat.current.long(to)
    }

    /// Aligns report lines from several periods into comparative rows, keyed by
    /// full account name and ordered by first appearance across the columns. A
    /// `nil` amount means the account had no line in that period.
    private func alignedRows(_ columns: [[ReportLine]],
                             extra: [(label: String, amounts: [Decimal?])] = [])
        -> [ReportDocumentRow] {
        var rows = accountTreeRows(columns).map {
            ReportDocumentRow(label: $0.label, depth: $0.depth, amounts: $0.amounts)
        }
        rows += extra.map { ReportDocumentRow(label: $0.label, amounts: $0.amounts) }
        return rows
    }

    private func comparativeBalanceSheet(
        _ columns: [(label: String, from: Date, to: Date)]
    ) -> ReportDocument? {
        let sheets = columns.compactMap { balanceSheet(asOf: $0.to) }
        guard sheets.count == columns.count, let current = sheets.first else { return nil }
        let headers = columns.map(\.label)
        let equityExtra = [(label: String(localized: "Retained earnings"),
                            amounts: sheets.map { Optional($0.retainedEarnings) })]

        return ReportDocument(
            title: String(localized: "Balance Sheet"),
            periodLabel: Self.comparativeLabel(headers),
            currencyCode: current.currencyCode,
            kpis: [
                ReportKPI(label: String(localized: "Assets"), amount: current.totalAssets),
                ReportKPI(label: String(localized: "Liabilities"), amount: current.totalLiabilities),
                ReportKPI(label: String(localized: "Net worth"),
                          amount: current.totalAssets - current.totalLiabilities, signed: true),
            ],
            chart: nil,
            sections: [
                ReportDocumentSection(
                    title: String(localized: "Assets"), rows: alignedRows(sheets.map { $0.assets }),
                    columns: headers,
                    columnTotals: (String(localized: "Total Assets"), sheets.map { Optional($0.totalAssets) })),
                ReportDocumentSection(
                    title: String(localized: "Liabilities"), rows: alignedRows(sheets.map { $0.liabilities }),
                    columns: headers,
                    columnTotals: (String(localized: "Total Liabilities"), sheets.map { Optional($0.totalLiabilities) })),
                ReportDocumentSection(
                    title: String(localized: "Equity"),
                    rows: alignedRows(sheets.map { $0.equity }, extra: equityExtra),
                    columns: headers,
                    columnTotals: (String(localized: "Total Equity"), sheets.map { Optional($0.totalEquity) })),
            ],
            notes: [valuationNote(columns[0].to),
                    String(localized: "Columns compare the selected period with earlier periods of the same length; the leftmost is the most recent.")],
            facts: balanceSheetFacts(assets: current.totalAssets, liabilities: current.totalLiabilities,
                                     equity: current.totalEquity,
                                     lines: ranked((current.assets, .balance), (current.liabilities, .balance))))
    }

    private func comparativeIncomeStatement(
        _ columns: [(label: String, from: Date, to: Date)]
    ) -> ReportDocument? {
        let statements = columns.compactMap { incomeStatement(from: $0.from, to: $0.to) }
        guard statements.count == columns.count, let current = statements.first else { return nil }
        let headers = columns.map(\.label)

        return ReportDocument(
            title: String(localized: "Income Statement"),
            periodLabel: Self.comparativeLabel(headers),
            currencyCode: current.currencyCode,
            kpis: [
                ReportKPI(label: String(localized: "Income"), amount: current.totalIncome),
                ReportKPI(label: String(localized: "Expenses"), amount: current.totalExpenses),
                ReportKPI(label: String(localized: "Net income"), amount: current.netIncome, signed: true),
            ],
            chart: nil,
            sections: [
                ReportDocumentSection(
                    title: String(localized: "Income"), rows: alignedRows(statements.map { $0.income }),
                    columns: headers,
                    columnTotals: (String(localized: "Total Income"), statements.map { Optional($0.totalIncome) })),
                ReportDocumentSection(
                    title: String(localized: "Expenses"), rows: alignedRows(statements.map { $0.expenses }),
                    columns: headers,
                    columnTotals: (String(localized: "Total Expenses"), statements.map { Optional($0.totalExpenses) })),
                ReportDocumentSection(
                    title: String(localized: "Result"), rows: [], columns: headers,
                    columnTotals: (String(localized: "Net income"), statements.map { Optional($0.netIncome) })),
            ],
            notes: [valuationNote(columns[0].to),
                    String(localized: "Columns compare the selected period with earlier periods of the same length; the leftmost is the most recent.")],
            facts: incomeStatementFacts(income: current.totalIncome, expenses: current.totalExpenses,
                                        net: current.netIncome,
                                        lines: ranked((current.income, .inflow), (current.expenses, .outflow))))
    }

    // MARK: Helpers

    private func section(_ title: String, _ lines: [ReportLine],
                         total: (String, Decimal),
                         order: AccountTreeOrder = .name,
                         round: (Decimal) -> Decimal = { $0 }) -> ReportDocumentSection {
        ReportDocumentSection(
            title: title,
            rows: accountTreeRows([lines], order: order, round: round).map {
                ReportDocumentRow(label: $0.label, depth: $0.depth, amount: $0.amounts[0])
            },
            total: total)
    }

    /// How a level of the account tree is ordered: by name, as the chart of
    /// accounts is, or largest first, as a ranking of categories is.
    enum AccountTreeOrder { case name, largestFirst }

    /// Report lines — one period's, or several side by side — as the account
    /// tree they belong to: **every level**, each parent carrying the subtotal
    /// of everything beneath it, indented by depth.
    ///
    /// Asked for on build 4: "Income and expense report needs to break down
    /// into sub categories (recursively)", and "All reports should display max
    /// indentation depth." The lines were each account's own figure under its
    /// full name, flat, so a category's total was nowhere on the page. GnuCash
    /// offers this shape as Parent account balances ▸ Calculate Subtotal
    /// (`options-utilities.scm`, `'recursive-bal`); its income statement
    /// defaults to three levels and the parent's own balance
    /// (`income-statement.scm`), the depth asked to go.
    ///
    /// A parent that has postings of its own *and* subaccounts beneath shows
    /// its own as a "(direct)" row among them, so a parent is always the sum of
    /// the rows under it and the section still sums to its total. A column in
    /// which nothing under a row has a line stays blank, as the flat rows did.
    ///
    /// `round` is applied to each figure as it is printed, never to what is
    /// summed: given exact lines, every node is rounded once from the exact
    /// total beneath it.
    func accountTreeRows(_ columns: [[ReportLine]], order: AccountTreeOrder = .name,
                         round: (Decimal) -> Decimal = { $0 })
        -> [(label: String, depth: Int, amounts: [Decimal?])] {
        guard let book else { return [] }
        let width = columns.count
        var own: [ObjectIdentifier: [Decimal?]] = [:]
        var shown: Set<ObjectIdentifier> = []
        var tops: [Account] = []
        // Lines that are not an account — the balance sheet's unrealised FX
        // and translation rounding — keep their place after the tree, matched
        // across columns by name as before.
        var loose: [(label: String, amounts: [Decimal?])] = []
        for (column, lines) in columns.enumerated() {
            for line in lines {
                guard let account = book.account(with: line.id) else {
                    // By its own name — "Unrealised FX", in the reader's
                    // language — not its full name, which is GnuCash's
                    // "Trading".
                    if let at = loose.firstIndex(where: { $0.label == line.name }) {
                        loose[at].amounts[column] = (loose[at].amounts[column] ?? 0) + line.amount
                    } else {
                        var amounts = [Decimal?](repeating: nil, count: width)
                        amounts[column] = line.amount
                        loose.append((line.name, amounts))
                    }
                    continue
                }
                let key = ObjectIdentifier(account)
                var amounts = own[key] ?? Array(repeating: nil, count: width)
                amounts[column] = (amounts[column] ?? 0) + line.amount
                own[key] = amounts
                // The account and every ancestor below the root.
                var walk: Account? = account
                while let current = walk, current !== book.rootAccount,
                      shown.insert(ObjectIdentifier(current)).inserted {
                    if current.parent == nil || current.parent === book.rootAccount {
                        tops.append(current)
                    }
                    walk = current.parent
                }
            }
        }
        func add(_ a: [Decimal?], _ b: [Decimal?]) -> [Decimal?] {
            zip(a, b).map { x, y in x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0) }
        }
        var subtotal: [ObjectIdentifier: [Decimal?]] = [:]
        func total(_ account: Account) -> [Decimal?] {
            let key = ObjectIdentifier(account)
            if let known = subtotal[key] { return known }
            let mine = own[key] ?? Array(repeating: nil, count: width)
            let sum = account.children.filter { shown.contains(ObjectIdentifier($0)) }
                .reduce(mine) { add($0, total($1)) }
            subtotal[key] = sum
            return sum
        }
        func ordered(_ accounts: [Account]) -> [Account] {
            switch order {
            case .name:
                return accounts.sorted { $0.name < $1.name }
            case .largestFirst:
                return accounts.sorted {
                    let a = total($0).first.flatMap { $0 } ?? 0, b = total($1).first.flatMap { $0 } ?? 0
                    return a == b ? $0.name < $1.name : a > b
                }
            }
        }
        func printed(_ amounts: [Decimal?]) -> [Decimal?] { amounts.map { $0.map(round) } }
        var rows: [(label: String, depth: Int, amounts: [Decimal?])] = []
        func emit(_ account: Account, depth: Int) {
            let below = ordered(account.children.filter { shown.contains(ObjectIdentifier($0)) })
            rows.append((account.name, depth, printed(total(account))))
            if !below.isEmpty, let mine = own[ObjectIdentifier(account)],
               mine.contains(where: { ($0 ?? 0) != 0 }) {
                rows.append((String(localized: "\(account.name) (direct)"), depth + 1, printed(mine)))
            }
            for child in below { emit(child, depth: depth + 1) }
        }
        for top in ordered(tops) { emit(top, depth: 0) }
        return rows + loose.map { ($0.label, 0, printed($0.amounts)) }
    }

    /// The largest lines of several sections, ranked together by size, each
    /// with what its section is — the side a cash flow's unsigned lines are
    /// on, or that a balance sheet's are balances.
    private func ranked(_ sections: (lines: [ReportLine], role: FigureRole)...)
        -> (lines: [(String, Decimal)], roles: [FigureRole?]) {
        let ranked = sections.flatMap { section in section.lines.map { ($0, section.role) } }
            .sorted { abs($0.0.amount) > abs($1.0.amount) }
            .prefix(12)
        return (ranked.map { ($0.0.fullName, $0.0.amount) }, ranked.map { Optional($0.1) })
    }

    /// A balance sheet's commentary facts: three balances, equity being
    /// assets less liabilities.
    private func balanceSheetFacts(assets: Decimal, liabilities: Decimal, equity: Decimal,
                                   lines: (lines: [(String, Decimal)], roles: [FigureRole?])) -> ReportFactsSource {
        let assetsLabel = String(localized: "Assets"), liabilitiesLabel = String(localized: "Liabilities")
        let equityLabel = String(localized: "Equity")
        return ReportFactsSource(
            headline: [(assetsLabel, assets), (liabilitiesLabel, liabilities), (equityLabel, equity)],
            lines: lines.lines,
            roles: [assetsLabel: .balance, liabilitiesLabel: .balance, equityLabel: .balance],
            relations: [equityLabel: FigureRelation(assetsLabel, less: liabilitiesLabel)],
            lineRoles: lines.roles)
    }

    /// An income statement's commentary facts: money in, money out, and the
    /// net income that is one less the other.
    private func incomeStatementFacts(income: Decimal, expenses: Decimal, net: Decimal,
                                      lines: (lines: [(String, Decimal)], roles: [FigureRole?])) -> ReportFactsSource {
        let incomeLabel = String(localized: "Income"), expensesLabel = String(localized: "Expenses")
        let netLabel = String(localized: "Net income")
        return ReportFactsSource(
            headline: [(incomeLabel, income), (expensesLabel, expenses), (netLabel, net)],
            lines: lines.lines,
            roles: [incomeLabel: .inflow, expensesLabel: .outflow],
            relations: [netLabel: FigureRelation(incomeLabel, less: expensesLabel)],
            lineRoles: lines.roles)
    }

    private func valuationNote(_ date: Date) -> String {
        String(localized: "Security holdings are valued at market using the latest price on or before \(AppDateFormat.current.long(date)); foreign currencies convert at that date’s rate. Accounts with no available price are omitted.")
    }

    // MARK: Words

    /// "Money in" and "Money out" on a cash-flow statement: money arriving in
    /// and leaving the accounts followed. The same two English words head the
    /// investment decks, where they mean money *put into* and *taken out of*
    /// the market, and are translated that way ("Dinero aportado", "投入資金").
    /// One key cannot carry both, so these have keys of their own and English
    /// that is unchanged.
    static var moneyIn: String { String(localized: "Money in (cash flow)", defaultValue: "Money in") }
    static var moneyOut: String { String(localized: "Money out (cash flow)", defaultValue: "Money out") }

    /// Names in a sentence: "Everyday, Savings and Offset", joined the way
    /// the reader's language joins a list.
    static func listed(_ names: [String]) -> String {
        names.formatted(.list(type: .and, width: .standard))
    }

    /// "Comparative · FY 2025–26 vs FY 2024–25" — the period line of a
    /// comparative statement.
    static func comparativeLabel(_ headers: [String]) -> String {
        let versus = String(localized: "vs")
        return String(localized: "Comparative · \(headers.joined(separator: " \(versus) "))")
    }

    /// The engine names an account summary's sections after the five account
    /// classes, in English — they are keys there, and compared as keys
    /// above. Shown, each is the reader's word for it. Anything else the
    /// engine might one day send is shown as it came.
    static func accountClassName(_ engineTitle: String) -> String {
        switch engineTitle {
        case "Assets": String(localized: "Assets")
        case "Liabilities": String(localized: "Liabilities")
        case "Equity": String(localized: "Equity")
        case "Income": String(localized: "Income")
        case "Expenses": String(localized: "Expenses")
        default: engineTitle
        }
    }

    /// The heading over an average-balance table: "By month". A whole phrase
    /// for each interval, because "by" + a lowercased noun is English's way
    /// of saying it and nobody else's (German keeps the capital; Japanese has
    /// one word for the pair).
    static func intervalTitle(_ step: AverageBalanceStep) -> String {
        switch step {
        case .day: String(localized: "By day")
        case .week: String(localized: "By week")
        case .twoWeeks: String(localized: "By fortnight")
        case .month: String(localized: "By month")
        case .quarter: String(localized: "By quarter")
        case .halfYear: String(localized: "By half-year")
        case .year: String(localized: "By year")
        }
    }
}

/// What a per-party summary says, by whose it is. Whole phrases: the note
/// was built from the column's noun lowercased into a sentence ("\"Paid\" is
/// invoiced less…"), which reads in English and cannot be translated.
enum OwnerSummaryWording {
    case customers, vendors, employees, jobs

    var title: String {
        switch self {
        case .customers: String(localized: "Customer Summary")
        case .vendors: String(localized: "Vendor Summary")
        case .employees: String(localized: "Employee Summary")
        case .jobs: String(localized: "Job Summary")
        }
    }

    var entity: String {
        switch self {
        case .customers: String(localized: "Customers")
        case .vendors: String(localized: "Vendors")
        case .employees: String(localized: "Employees")
        case .jobs: String(localized: "Jobs")
        }
    }

    /// The column, and the headline figure's name for the narrator.
    var charged: String {
        switch self {
        case .customers, .jobs: String(localized: "Invoiced")
        case .vendors: String(localized: "Billed")
        case .employees: String(localized: "Claimed")
        }
    }

    var totalCharged: String {
        switch self {
        case .customers, .jobs: String(localized: "Total invoiced")
        case .vendors: String(localized: "Total billed")
        case .employees: String(localized: "Total claimed")
        }
    }

    var paidNote: String {
        switch self {
        case .customers, .jobs: String(localized: "“Paid” is what was invoiced less what is still outstanding.")
        case .vendors: String(localized: "“Paid” is what was billed less what is still outstanding.")
        case .employees: String(localized: "“Paid” is what was claimed less what is still outstanding.")
        }
    }
}
