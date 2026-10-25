//
//  ReportDocument.swift
//  FinvestLens — FeatureUI
//
//  A report as a document, not another register.
//
//  Every polished report is the same shape: a header naming the report and its
//  period, the few numbers it exists to produce (callouts), a chart where one
//  says something, tables with aligned numerals and ruled totals, and notes —
//  fixed methodology lines plus optional Apple Intelligence commentary. So that
//  shape is a value, `ReportDocument`, and one view renders it; the PDF export
//  consumes the same value, which is what keeps the print and the screen from
//  drifting apart.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

// MARK: - The value

/// One headline figure, displayed large.
struct ReportKPI: Identifiable {
    var id: String { label }
    var label: String
    var amount: Decimal
    /// Tint negative amounts red where sign carries meaning (net income);
    /// balances stay neutral.
    var signed = false
}

/// One line of a report table.
struct ReportDocumentRow: Identifiable {
    let id = UUID()
    var label: String
    /// Indentation level, 0 for a top-level row.
    var depth = 0
    /// The single amount, or —
    var amount: Decimal?
    /// — a debit/credit pair, for the trial balance's two columns.
    var debit: Decimal?
    var credit: Decimal?
    /// — several amounts, one per period, for a comparative statement. A `nil`
    /// entry renders blank (the account had no line in that period).
    var amounts: [Decimal?]?
    /// — or typed cells, one per column, where a column is a date, a count
    /// of units or words rather than money. Takes precedence over `amounts`.
    var cells: [ReportCell]?

    /// The row's cells, whichever way they were given: typed, or amounts
    /// read through the section's column formats.
    func resolvedCells(formats: [ReportColumnFormat]?) -> [ReportCell] {
        if let cells { return cells }
        return (amounts ?? []).enumerated().map { column, amount in
            switch formats?[safe: column] ?? .amount {
            case .amount: .money(amount)
            case .percent: .percent(amount)
            }
        }
    }
}

/// How a column's figures print: money in the section's currency, or a rate
/// — the investment reports' yield per annum, kept as a fraction.
enum ReportColumnFormat {
    case amount
    case percent

    func string(_ value: Decimal, code: String) -> String {
        switch self {
        case .amount: AmountFormat.string(value, code: code)
        case .percent: value.formatted(.percent.precision(.fractionLength(1)))
        }
    }
}

/// One cell of a report table. What it holds decides how it prints and
/// which way it aligns: figures to the right, dates and words to the left.
/// The investment reports need dates and units as columns of their own —
/// "a report needs acquisition date, consideration …" — not words folded
/// into a row's label.
enum ReportCell: Hashable {
    /// Money in the section's currency; red when negative.
    case money(Decimal?)
    /// A rate, kept as a fraction and printed with one decimal.
    case percent(Decimal?)
    /// A count of units or shares.
    case units(Decimal?)
    case date(Date?)
    case text(String)

    var isNumeric: Bool {
        switch self {
        case .money, .percent, .units: true
        case .date, .text: false
        }
    }

    /// Negative money or a negative rate — the figures drawn in red.
    var isNegative: Bool {
        switch self {
        case .money(let value?), .percent(let value?): value < 0
        default: false
        }
    }

    var isEmpty: Bool {
        switch self {
        case .money(nil), .percent(nil), .units(nil), .date(nil): true
        case .text(let text): text.isEmpty
        default: false
        }
    }

    /// The amount of a money cell, for a total that adds a column.
    var money: Decimal? {
        if case .money(let value) = self { return value }
        return nil
    }

    func string(code: String) -> String {
        switch self {
        case .money(let value): value.map { AmountFormat.string($0, code: code) } ?? ""
        case .percent(let value): value.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? ""
        case .units(let value): value.map { $0.formatted() } ?? ""
        case .date(let date): date.map { AppDateFormat.current.long($0) } ?? ""
        case .text(let text): text
        }
    }
}

/// A titled table with an optional ruled total.
struct ReportDocumentSection: Identifiable {
    /// The title, unless the section says otherwise: the Transactions
    /// report's sections are accounts, whose full names need not be unique,
    /// and two sections with one identity in a lazy stack drew one of them
    /// as a blank gap.
    var id: String { identity ?? title }
    var title: String
    var rows: [ReportDocumentRow]
    var total: (label: String, amount: Decimal)? = nil
    /// Two amount columns instead of one (trial balance).
    var isDebitCredit = false
    /// Column headers, when the rows carry `amounts` (a comparative statement).
    var columns: [String]? = nil
    /// A ruled total across the comparative columns.
    var columnTotals: (label: String, amounts: [Decimal?])? = nil
    /// How each of `columns` prints; `nil`, or a missing entry, is money.
    var columnFormats: [ReportColumnFormat]? = nil
    /// A ruled total row of typed cells, where the rows are typed.
    var cellTotals: (label: String, cells: [ReportCell])? = nil

    /// The total row's cells, typed or from the amounts.
    var resolvedTotals: (label: String, cells: [ReportCell])? {
        if let cellTotals { return cellTotals }
        guard let columnTotals else { return nil }
        return (columnTotals.label, ReportDocumentRow(label: "", amounts: columnTotals.amounts)
                    .resolvedCells(formats: columnFormats))
    }

    /// Whether column `column` reads from the left — a date or words — by
    /// what its rows hold.
    func isLeading(_ column: Int) -> Bool {
        for row in rows {
            let cells = row.resolvedCells(formats: columnFormats)
            guard column < cells.count else { continue }
            return !cells[column].isNumeric
        }
        return false
    }
    /// The section's own currency, where it is not the document's — each
    /// account of a transaction report prints in its own.
    var currencyCode: String? = nil
    /// An identity other than the title (``id``).
    var identity: String? = nil
}

/// The chart a report carries, when it carries one.
enum ReportDocumentChart {
    case monthlyBars([MonthlyFlow])
    case line([NetWorthPoint])
    case averageBars([AverageBalanceInterval])
    /// A composition donut (portfolio allocation): label + positive value.
    case allocation([(label: String, value: Decimal)])
    /// Signed bars by label, largest first — a gain or loss per security.
    case bars([(label: String, value: Decimal)])
    /// Stacked bars: for each label, one segment per series — a security's
    /// return split into its parts.
    case stackedBars(series: [String], bars: [(label: String, values: [Decimal])])
}

/// A complete report, ready to render or print.
struct ReportDocument {
    var title: String
    var periodLabel: String
    var currencyCode: String
    var kpis: [ReportKPI]
    /// Deterministic plain-language reading of the figures, shown between the
    /// callouts and the chart (Spending Insights' sentences).
    var summary: [String] = []
    var chart: ReportDocumentChart?
    var sections: [ReportDocumentSection]
    /// Fixed methodology notes ("Securities valued at market…").
    var notes: [String]
    /// The facts commentary is narrated from, when the report offers it.
    var facts: ReportFactsSource?
}

extension ReportDocument {
    /// No figures anywhere — the report ran but had nothing to say.
    var isEmpty: Bool {
        kpis.isEmpty && summary.isEmpty && chart == nil
            && sections.allSatisfy { $0.rows.isEmpty }
    }

    /// A document with a wide table — the investment reports' nine and ten
    /// columns — is laid out wider than a statement's reading measure.
    var wide: Bool { sections.contains { ($0.columns?.count ?? 0) > 6 } }
}

/// What the narrator gets: headline figures and ranked lines, no access to
/// anything it could miscompute.
struct ReportFactsSource {
    var headline: [(String, Decimal)]
    var lines: [(String, Decimal)]
    /// What each headline figure is, and which are one of the others less
    /// another, as the report computed them (``FigureRole``,
    /// ``FigureRelation``).
    var roles: [String: FigureRole] = [:]
    var relations: [String: FigureRelation] = [:]
    /// What each line is, by position in `lines`.
    var lineRoles: [FigureRole?] = []
}

// MARK: - Rendering

/// Renders a ``ReportDocument`` in the app's annual-report style.
struct ReportDocumentView: View {
    @Environment(\.isCompactShell) private var compact
    @Bindable var model: AppModel
    let document: ReportDocument
    @State private var commentary: [String]?
    /// Where the commentary on screen was written — which is not always
    /// where the next one would be.
    @State private var commentaryLeftDevice = false
    @State private var narrating = false
    @State private var narrationError: String?

    var body: some View {
        ScrollView {
            // Lazy: a transaction report over the whole book is hundreds of
            // sections and tens of thousands of rows, and only the screenful in
            // view is built.
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                if !document.kpis.isEmpty { kpiRow }
                if !document.summary.isEmpty { summaryBlock }
                if let chart = document.chart { chartView(chart) }
                ForEach(document.sections) { section in
                    ReportTableView(section: section, code: section.currencyCode ?? document.currencyCode)
                }
                notes
            }
            .padding(24)
            .frame(maxWidth: document.wide ? 1120 : 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        ReportMasthead(entity: model.statementEntityName,
                       title: document.title,
                       period: document.periodLabel,
                       code: document.currencyCode)
    }

    /// The headline figures. Side by side wherever they fit, which is every
    /// regular width; at phone width three still fit and four do not — the
    /// Portfolio report's four gave each about 55 points — so there they go
    /// two to a row, and a figure shrinks before it is ever cut short.
    @ViewBuilder
    private var kpiRow: some View {
        if compact, document.kpis.count > 3 {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                     count: 2),
                      spacing: 12) {
                ForEach(document.kpis) { kpiTile($0) }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(document.kpis) { kpiTile($0) }
            }
        }
    }

    private func kpiTile(_ kpi: ReportKPI) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kpi.label)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(AmountFormat.string(kpi.amount, code: document.currencyCode))
                .scaledFont(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(kpi.signed && kpi.amount < 0 ? Color.negativeAmount : Color.primary)
                // A figure is one word: three tiles across a phone broke a
                // six-figure amount in the middle of its digits. The regular
                // shell is left as it was.
                .lineLimit(compact ? 1 : nil)
                .minimumScaleFactor(compact ? 0.5 : 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The deterministic plain-language reading, one sentence per line.
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(document.summary, id: \.self) { line in
                Label {
                    Text(line).scaledFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func chartView(_ chart: ReportDocumentChart) -> some View {
        switch chart {
        case .monthlyBars(let months):
            // The two series are named by a *value*, and a value is drawn as
            // it is: the legend read "Income" and "Expenses" in every
            // language until the names were the reader's.
            let income = String(localized: "Income")
            let expenses = String(localized: "Expenses")
            Chart(months) { month in
                BarMark(x: .value("Month", month.month, unit: .month),
                        y: .value("Income", month.income))
                    .foregroundStyle(by: .value("Kind", income))
                    .position(by: .value("Kind", income))
                BarMark(x: .value("Month", month.month, unit: .month),
                        y: .value("Expenses", month.expenses))
                    .foregroundStyle(by: .value("Kind", expenses))
                    .position(by: .value("Kind", expenses))
            }
            .chartForegroundStyleScale([income: Color.appAccent,
                                        expenses: Color.red.opacity(0.75)])
            .frame(height: 200)
        case .line(let points):
            Chart(points) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Net Worth", point.netWorth))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Date", point.date),
                         y: .value("Net Worth", point.netWorth))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [Color.appAccent.opacity(0.3), .clear],
                                                     startPoint: .top, endPoint: .bottom))
            }
            // Twelve months across a phone give each label a third of the
            // room it needs ("Nov 20…"); a mark a quarter, whole labels.
            .chartXAxis {
                if compact {
                    AxisMarks(values: .stride(by: .month, count: 3))
                } else {
                    AxisMarks()
                }
            }
            .frame(height: 200)
        case .averageBars(let intervals):
            Chart(intervals) { interval in
                BarMark(x: .value("Period", interval.start),
                        y: .value("Average",
                                  NSDecimalNumber(decimal: interval.average).doubleValue))
                    .foregroundStyle(.tint)
            }
            .frame(height: 200)
        case .allocation(let slices):
            Chart(slices, id: \.label) { slice in
                SectorMark(angle: .value("Value",
                                         NSDecimalNumber(decimal: slice.value).doubleValue),
                           innerRadius: .ratio(0.6), angularInset: 1)
                    .cornerRadius(2)
                    .foregroundStyle(by: .value("Holding", slice.label))
            }
            .chartForegroundStyleScale(range: ReportPalette.categorical)
            .chartLegend(position: .trailing, alignment: .center)
            .frame(height: 220)
        case .bars(let bars):
            // Gains to the right, losses to the left, the largest first.
            Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
                BarMark(x: .value("Amount", NSDecimalNumber(decimal: bar.value).doubleValue),
                        y: .value("Security", bar.label))
                    .foregroundStyle(bar.value < 0 ? Color.negativeAmount : Color.appAccent)
            }
            .chartXAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.number.notation(.compactName)) }
            .frame(height: max(120, CGFloat(bars.count) * 26 + 40))
        case .stackedBars(let series, let bars):
            Chart {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    ForEach(Array(series.enumerated()), id: \.offset) { index, name in
                        if index < bar.values.count {
                            BarMark(x: .value("Security", bar.label),
                                    y: .value("Amount", NSDecimalNumber(decimal: bar.values[index]).doubleValue))
                                .foregroundStyle(by: .value("Part", name))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(range: ReportPalette.categorical)
            .chartYAxis { AxisMarks(format: FloatingPointFormatStyle<Double>.number.notation(.compactName)) }
            .chartLegend(position: .bottom)
            .frame(height: 240)
        }
    }

    @ViewBuilder
    private var notes: some View {
        if !document.notes.isEmpty || document.facts != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Notes")
                    .scaledFont(.headline)
                ForEach(document.notes, id: \.self) { note in
                    Text(note)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if let commentary {
                    ForEach(commentary, id: \.self) { line in
                        Label {
                            Text(line).scaledFont(.callout)
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                        }
                    }
                    IntelligenceRanNote(offDevice: commentaryLeftDevice,
                                        onDevice: "Commentary is generated on-device from the figures above.")
                } else if document.facts != nil, model.isIntelligenceAvailable(for: .reportNarrator) {
                    Button {
                        narrate()
                    } label: {
                        // A spinner while the model writes, as "Reading…" has
                        // beside the attachment: a label that only changes its
                        // words reads as stuck (Performance Review §3).
                        if narrating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Writing commentary…")
                            }
                        } else {
                            Label("Add commentary", systemImage: "sparkles")
                        }
                    }
                    .disabled(narrating)
                    IntelligenceRunsNote(.reportCommentary)
                }
                if let narrationError {
                    Text(narrationError).scaledFont(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func narrate() {
        guard let facts = document.facts else { return }
        narrating = true
        narrationError = nil
        let request = ReportFacts(reportTitle: document.title,
                                  periodLabel: document.periodLabel,
                                  currencyCode: document.currencyCode,
                                  headline: facts.headline, lines: facts.lines,
                                  roles: facts.roles, relations: facts.relations,
                                  lineRoles: facts.lineRoles)
        // Asked before the request, of the same list the request runs under.
        let leavesDevice = IntelligenceCommand.reportCommentary.leavesDevice
        Task {
            defer { narrating = false }
            do {
                commentary = try await model.reportCommentary(for: request)
                commentaryLeftDevice = leavesDevice
            } catch { narrationError = error.localizedDescription }
        }
    }
}

/// One table: label column, amount column(s), rules, a bold total.
struct ReportTableView: View {
    @Environment(\.isCompactShell) private var compact
    let section: ReportDocumentSection
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .scaledFont(.headline)
                .padding(.bottom, 6)
            Divider()
            if let columns = section.columns {
                if compact, columns.count > Self.compactColumnLimit {
                    stackedRows(columns)
                } else if section.rows.count > Self.gridLimit {
                    longColumns(columns)
                } else {
                    comparativeGrid(columns)
                }
            } else {
                singleGrid
            }
        }
    }

    /// Past this many amount columns a phone cannot hold the row: the
    /// investment reports' four to six, Average Balance's five. Seen on the
    /// iPhone 18 Pro capture of the Portfolio report (25 Oct 2026): six
    /// columns pushed the label column off the left edge. A comparative
    /// statement's two or three still fit.
    static let compactColumnLimit = 3

    /// The phone's form of a wide table: one block per row — its label, then
    /// each column's header against its figure — so nothing is cut off and
    /// the figures keep their width. Parcels under a security indent as they
    /// do in the grid.
    private func stackedRows(_ columns: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                stackedBlock(label: row.label, depth: row.depth,
                             cells: row.resolvedCells(formats: section.columnFormats),
                             columns: columns, bold: false)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
            }
            if let totals = section.resolvedTotals {
                stackedBlock(label: totals.label, depth: 0, cells: totals.cells,
                             columns: columns, bold: true)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func stackedBlock(label: String, depth: Int, cells: [ReportCell],
                              columns: [String], bold: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .scaledFont(.body)
                .fontWeight(bold ? .bold : (depth == 0 ? .medium : .regular))
                .foregroundStyle(depth > 0 ? .secondary : .primary)
            ForEach(Array(columns.enumerated()), id: \.offset) { column, header in
                HStack(spacing: 12) {
                    Text(header)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    cellText(column < cells.count ? cells[column] : .text(""))
                        .scaledFont(.body)
                        .fontWeight(bold ? .bold : .regular)
                }
                .padding(.leading, 12)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var singleGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            if section.isDebitCredit {
                GridRow {
                    Text("")
                    Text("Debit").gridColumnAlignment(.trailing)
                    Text("Credit").gridColumnAlignment(.trailing)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                GridRow {
                    Text(row.label)
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                    if section.isDebitCredit {
                        amountText(row.debit).gridColumnAlignment(.trailing)
                        amountText(row.credit).gridColumnAlignment(.trailing)
                    } else {
                        amountText(row.amount).gridColumnAlignment(.trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 5)
                .background(index.isMultiple(of: 2) ? Color.clear
                            : Color.primary.opacity(0.03))
            }
            if let total = section.total {
                GridRow {
                    Text(total.label).fontWeight(.bold)
                    if section.isDebitCredit {
                        Text("").gridColumnAlignment(.trailing)
                        amountText(total.amount).fontWeight(.bold)
                            .gridColumnAlignment(.trailing)
                    } else {
                        amountText(total.amount).fontWeight(.bold)
                            .gridColumnAlignment(.trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// Past this many rows a section is drawn lazily, in fixed columns: a
    /// `Grid` measures every row to size its columns, which for one busy
    /// account's year of postings is thousands of rows built at once.
    static let gridLimit = 120

    /// A long section's rows, built as they scroll into view.
    private func longColumns(_ columns: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Spacer()
                ForEach(Array(columns.enumerated()), id: \.offset) { column, header in
                    Text(header).frame(width: amountWidth, alignment: section.isLeading(column) ? .leading : .trailing)
                }
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            ForEach(section.rows.indices, id: \.self) { index in
                let row = section.rows[index]
                HStack(spacing: 16) {
                    Text(row.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(row.resolvedCells(formats: section.columnFormats).enumerated()), id: \.offset) { column, cell in
                        cellText(cell)
                            .lineLimit(1)
                            .frame(width: amountWidth, alignment: section.isLeading(column) ? .leading : .trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 5)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
            }
            if let totals = section.resolvedTotals {
                HStack(spacing: 16) {
                    Text(totals.label).fontWeight(.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(totals.cells.enumerated()), id: \.offset) { column, cell in
                        cellText(cell).fontWeight(.bold)
                            .lineLimit(1)
                            .frame(width: amountWidth, alignment: section.isLeading(column) ? .leading : .trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// One amount column of a long section: wide enough for a negative
    /// seven-figure amount in a foreign currency's code ("-USD 1,234,567.89"
    /// in bold measures 133 pt at 13 pt), at the current text size — Dynamic
    /// Type on iPhone and iPad, the app's own Text Size on the Mac, which no
    /// `@ScaledMetric` follows.
    @ScaledMetric(relativeTo: .body) private var amountBase: CGFloat = 140
    @Environment(\.appFontScale) private var appFontScale
    private var amountWidth: CGFloat { amountBase * appFontScale }

    /// One period per column, amounts right-aligned under each header.
    private func comparativeGrid(_ columns: [String]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text("")
                ForEach(Array(columns.enumerated()), id: \.offset) { column, header in
                    Text(header).gridColumnAlignment(section.isLeading(column) ? .leading : .trailing)
                }
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                GridRow {
                    Text(row.label)
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                    ForEach(Array(row.resolvedCells(formats: section.columnFormats).enumerated()), id: \.offset) { column, cell in
                        cellText(cell).gridColumnAlignment(section.isLeading(column) ? .leading : .trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 5)
                .background(index.isMultiple(of: 2) ? Color.clear
                            : Color.primary.opacity(0.03))
            }
            if let totals = section.resolvedTotals {
                GridRow {
                    Text(totals.label).fontWeight(.bold)
                    ForEach(Array(totals.cells.enumerated()), id: \.offset) { column, cell in
                        cellText(cell).fontWeight(.bold)
                            .gridColumnAlignment(section.isLeading(column) ? .leading : .trailing)
                    }
                }
                .scaledFont(.body)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// One cell, drawn as what it holds: figures monospaced and red when
    /// negative, dates and words plain.
    @ViewBuilder
    private func cellText(_ cell: ReportCell) -> some View {
        if cell.isEmpty {
            Text("")
        } else if cell.isNumeric {
            Text(cell.string(code: code))
                .monospacedDigit()
                .foregroundStyle(cell.isNegative ? Color.negativeAmount : Color.primary)
        } else {
            Text(cell.string(code: code))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func amountText(_ amount: Decimal?) -> some View {
        cellText(.money(amount))
    }
}

// MARK: - Print

extension ReportDocument {
    /// The same document as a printable statement — one source for screen and
    /// paper.
    var printable: PrintableStatement {
        var sections: [PrintableSection] = []
        if !kpis.isEmpty {
            sections.append(PrintableSection(heading: String(localized: "Summary"), rows:
                kpis.map { PrintableRow(label: $0.label, amount: $0.amount, bold: true) }))
        }
        if !summary.isEmpty {
            // Text-only rows: the single nil amount column renders blank.
            sections.append(PrintableSection(heading: String(localized: "In brief"), rows:
                summary.map { PrintableRow(label: $0, amount: 0, cells: [.text("")]) }))
        }
        for section in self.sections {
            if let columns = section.columns {
                var rows = section.rows.map {
                    PrintableRow(label: String(repeating: "    ", count: $0.depth) + $0.label,
                                 amount: 0, cells: $0.resolvedCells(formats: section.columnFormats))
                }
                if let totals = section.resolvedTotals {
                    rows.append(PrintableRow(label: totals.label, amount: 0, bold: true, cells: totals.cells))
                }
                sections.append(PrintableSection(heading: section.title, rows: rows,
                                                 columns: columns, code: section.currencyCode,
                                                 leadingColumns: Set(columns.indices.filter { section.isLeading($0) })))
                continue
            }
            var rows = section.rows.map {
                PrintableRow(label: String(repeating: "    ", count: $0.depth) + $0.label,
                             amount: $0.amount ?? $0.debit ?? ($0.credit.map { -$0 }) ?? 0)
            }
            if let total = section.total {
                rows.append(PrintableRow(label: total.label, amount: total.amount, bold: true))
            }
            sections.append(PrintableSection(heading: section.title, rows: rows,
                                             code: section.currencyCode))
        }
        return PrintableStatement(title: title,
                                  subtitle: "\(periodLabel) · \(currencyCode)",
                                  code: currencyCode,
                                  sections: sections)
    }

    /// The printable under the masthead's entity line (the book's name).
    func printable(entity: String) -> PrintableStatement {
        var printable = self.printable
        printable.entity = entity
        return printable
    }
}
